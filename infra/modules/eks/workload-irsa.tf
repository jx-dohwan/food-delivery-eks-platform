variable "was_environment" {
  type    = string
  default = "dev"
  validation {
    condition     = contains(["dev", "prod"], var.was_environment)
    error_message = "WAS IRSA supports explicitly separated dev/prod namespaces."
  }
}

variable "protected_bucket_names" {
  description = "Buckets the WAS must never receive access to, such as the Terraform state bucket"
  type        = list(string)
  default     = []
}

variable "was_aws_access" {
  description = "Existing, verified application resources only. Null features receive no permissions. S3 currently supports SSE-S3 only."
  type = object({
    s3  = optional(object({ bucket_name = string, encryption = string }))
    ses = optional(object({ identity = string, from_address = string }))
  })
  default = {}
  validation {
    condition = var.was_aws_access.s3 == null ? true : (
      can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.was_aws_access.s3.bucket_name)) &&
      !contains(var.protected_bucket_names, var.was_aws_access.s3.bucket_name) &&
      var.was_aws_access.s3.encryption == "AES256"
    )
    error_message = "Use a verified application bucket, never tfstate, with confirmed SSE-S3 (AES256). KMS requires a separate permission review."
  }
  validation {
    condition = var.was_aws_access.ses == null ? true : (
      can(regex("^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}$", var.was_aws_access.ses.from_address)) &&
      (var.was_aws_access.ses.identity == var.was_aws_access.ses.from_address ||
      try(split("@", var.was_aws_access.ses.from_address)[1] == var.was_aws_access.ses.identity, false))
    )
    error_message = "SES identity must equal the exact sender email or its domain; no wildcards or arbitrary From addresses."
  }
}

data "aws_caller_identity" "was" {}

locals {
  was_namespace       = var.was_environment == "dev" ? "app" : "app-prod"
  was_service_account = "food-delivery-was"
  was_s3_statements = var.was_aws_access.s3 == null ? [] : [{
    Sid      = "S3ImageUpload"
    Effect   = "Allow"
    Action   = ["s3:PutObject"]
    Resource = [for prefix in ["restaurant", "dish", "review", "profile", "common"] : "arn:aws:s3:::${var.was_aws_access.s3.bucket_name}/${prefix}/*"]
  }]
  was_ses_statements = var.was_aws_access.ses == null ? [] : [{
    Sid      = "SESVerificationEmail"
    Effect   = "Allow"
    Action   = ["ses:SendEmail"]
    Resource = ["arn:aws:ses:${var.region}:${data.aws_caller_identity.was.account_id}:identity/${var.was_aws_access.ses.identity}"]
    Condition = { StringEquals = {
      "ses:FromAddress" = var.was_aws_access.ses.from_address
    } }
  }]
}

resource "aws_iam_role" "was" {
  name = "${var.cluster_name}-${var.was_environment}-was"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow", Action = "sts:AssumeRoleWithWebIdentity"
      Principal = { Federated = aws_iam_openid_connect_provider.this.arn }
      Condition = { StringEquals = {
        "${replace(aws_iam_openid_connect_provider.this.url, "https://", "")}:aud" = "sts.amazonaws.com"
        "${replace(aws_iam_openid_connect_provider.this.url, "https://", "")}:sub" = "system:serviceaccount:${local.was_namespace}:${local.was_service_account}"
      } }
    }]
  })
  tags = merge(var.tags, { Environment = var.was_environment })
}

resource "aws_iam_role_policy" "was" {
  count = var.was_aws_access.s3 != null || var.was_aws_access.ses != null ? 1 : 0
  name  = "was-application-access"
  role  = aws_iam_role.was.id
  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = concat(local.was_s3_statements, local.was_ses_statements)
  })
}

output "was_irsa_config" {
  description = "Non-secret input for the environment-specific GitOps SA/ConfigMap renderer."
  value = {
    environment      = var.was_environment
    namespace        = local.was_namespace
    service_account  = local.was_service_account
    account_id       = data.aws_caller_identity.was.account_id
    region           = var.region
    role_arn         = aws_iam_role.was.arn
    s3_bucket_name   = try(var.was_aws_access.s3.bucket_name, "")
    s3_encryption    = try(var.was_aws_access.s3.encryption, "")
    ses_identity     = try(var.was_aws_access.ses.identity, "")
    ses_from_address = try(var.was_aws_access.ses.from_address, "")
  }
}
