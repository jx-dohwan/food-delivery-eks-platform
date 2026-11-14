# Persistent opt-in trail. First inventory existing trails; never create a duplicate
# if an existing active trail covers Seoul EC2 write management events.
variable "create_management_trail" {
  type        = bool
  default     = false
  description = "Create a dedicated regional write-management trail only after ruling out an existing suitable trail"
}

variable "existing_management_trail_arn" {
  type        = string
  default     = ""
  description = "Read-only reference to an operator-verified existing active trail; no import or ownership transfer"
  validation {
    condition     = var.existing_management_trail_arn == "" || can(regex("^arn:aws:cloudtrail:[a-z0-9-]+:${var.allowed_account_id}:trail/.+$", var.existing_management_trail_arn))
    error_message = "Use an existing trail ARN in the expected account."
  }
}

locals {
  management_trail_name = "food-delivery-management-events"
  management_trail_arn  = "arn:${data.aws_partition.current.partition}:cloudtrail:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:trail/${local.management_trail_name}"
  management_trail_tags = {
    Project   = "food-delivery"
    ManagedBy = "terraform"
    Purpose   = "security-group-change-audit"
  }
}

resource "aws_s3_bucket" "management_trail" {
  count         = var.create_management_trail ? 1 : 0
  bucket        = "food-delivery-cloudtrail-${data.aws_caller_identity.current.account_id}-${data.aws_region.current.region}"
  force_destroy = false
  tags          = local.management_trail_tags
  lifecycle {
    prevent_destroy = true
    precondition {
      condition     = var.existing_management_trail_arn == ""
      error_message = "Choose an existing trail OR create one; never both."
    }
  }
}

resource "aws_s3_bucket_public_access_block" "management_trail" {
  count                   = var.create_management_trail ? 1 : 0
  bucket                  = aws_s3_bucket.management_trail[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "management_trail" {
  count  = var.create_management_trail ? 1 : 0
  bucket = aws_s3_bucket.management_trail[0].id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "management_trail" {
  count  = var.create_management_trail ? 1 : 0
  bucket = aws_s3_bucket.management_trail[0].id
  rule {
    id     = "expire-audit-logs"
    status = "Enabled"
    filter { prefix = "AWSLogs/" }
    expiration { days = 90 }
  }
}

resource "aws_s3_bucket_policy" "management_trail" {
  count  = var.create_management_trail ? 1 : 0
  bucket = aws_s3_bucket.management_trail[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "CloudTrailAclCheck", Effect = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action    = "s3:GetBucketAcl", Resource = aws_s3_bucket.management_trail[0].arn
        Condition = { StringEquals = { "aws:SourceArn" = local.management_trail_arn } }
      },
      {
        Sid       = "CloudTrailWrite", Effect = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.management_trail[0].arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/*"
        Condition = { StringEquals = { "aws:SourceArn" = local.management_trail_arn, "s3:x-amz-acl" = "bucket-owner-full-control" } }
      },
      {
        Sid       = "DenyInsecureTransport", Effect = "Deny", Principal = "*"
        Action    = "s3:*", Resource = [aws_s3_bucket.management_trail[0].arn, "${aws_s3_bucket.management_trail[0].arn}/*"]
        Condition = { Bool = { "aws:SecureTransport" = "false" } }
      }
    ]
  })
}

resource "aws_cloudtrail" "management" {
  count                         = var.create_management_trail ? 1 : 0
  name                          = local.management_trail_name
  s3_bucket_name                = aws_s3_bucket.management_trail[0].id
  enable_logging                = true
  enable_log_file_validation    = true
  is_multi_region_trail         = false
  is_organization_trail         = false
  include_global_service_events = false
  event_selector {
    include_management_events = true
    read_write_type           = "WriteOnly"
  }
  tags       = local.management_trail_tags
  depends_on = [aws_s3_bucket_policy.management_trail, aws_s3_bucket_public_access_block.management_trail, aws_s3_bucket_server_side_encryption_configuration.management_trail]
  lifecycle {
    prevent_destroy = true
  }
}

output "management_trail_arn" {
  description = "Supply to dev sg_management_trail_arn only after checking actual logging/selectors/region coverage"
  value       = var.create_management_trail ? aws_cloudtrail.management[0].arn : (var.existing_management_trail_arn == "" ? null : var.existing_management_trail_arn)
}
