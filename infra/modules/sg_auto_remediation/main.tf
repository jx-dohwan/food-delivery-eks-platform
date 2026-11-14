terraform {
  required_providers {
    aws     = { source = "hashicorp/aws", version = "~> 6.0" }
    archive = { source = "hashicorp/archive", version = "~> 2.4" }
  }
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

locals {
  name     = "${var.tag_header}${var.tags["Project"]}-${var.tags["Environment"]}-public-ssh-remediation"
  arn_base = "arn:${data.aws_partition.current.partition}"
  ec2_base = "${local.arn_base}:ec2:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}"
  log_arn  = "${local.arn_base}:logs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/${local.name}:*"
}

data "archive_file" "lambda" {
  count       = var.enable ? 1 : 0
  type        = "zip"
  source_file = "${path.module}/lambda_function.py"
  output_path = "${path.module}/remediation_lambda.zip"
}

resource "aws_cloudwatch_log_group" "this" {
  count             = var.enable ? 1 : 0
  name              = "/aws/lambda/${local.name}"
  retention_in_days = 30
  tags              = var.tags
}

resource "aws_iam_role" "this" {
  count = var.enable ? 1 : 0
  name  = "${local.name}-role"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = "sts:AssumeRole", Principal = { Service = "lambda.amazonaws.com" } }]
  })
  tags = var.tags
}

resource "aws_iam_role_policy" "this" {
  count = var.enable ? 1 : 0
  name  = "${local.name}-policy"
  role  = aws_iam_role.this[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadCurrentSecurityGroups"
        Effect   = "Allow"
        Action   = ["ec2:DescribeSecurityGroups", "ec2:DescribeSecurityGroupRules"]
        Resource = "*" # Describe APIs do not support resource-level permissions.
      },
      {
        Sid      = "RevokeOnlyProjectIngress"
        Effect   = "Allow"
        Action   = "ec2:RevokeSecurityGroupIngress"
        Resource = "${local.ec2_base}:security-group/*"
        Condition = { StringEquals = {
          "ec2:ResourceTag/Project"     = var.tags["Project"]
          "ec2:ResourceTag/Environment" = var.tags["Environment"]
          "ec2:ResourceTag/ManagedBy"   = var.tags["ManagedBy"]
          "ec2:Vpc"                     = "${local.ec2_base}:vpc/${var.vpc_id}"
        } }
      },
      {
        Sid      = "WriteOwnLogs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = local.log_arn
      }
    ]
  })
}

resource "aws_lambda_function" "this" {
  count            = var.enable ? 1 : 0
  function_name    = local.name
  role             = aws_iam_role.this[0].arn
  runtime          = "python3.12"
  handler          = "lambda_function.handler"
  filename         = data.archive_file.lambda[0].output_path
  source_code_hash = data.archive_file.lambda[0].output_base64sha256
  timeout          = 60
  memory_size      = 128
  # No VPC attachment: EC2 API and Slack need no access to application subnets.
  environment {
    variables = {
      ACCOUNT_ID        = data.aws_caller_identity.current.account_id
      TARGET_REGION     = data.aws_region.current.region
      PROJECT_TAG       = var.tags["Project"]
      ENV_TAG           = var.tags["Environment"]
      MANAGED_BY_TAG    = var.tags["ManagedBy"]
      VPC_ID            = var.vpc_id
      SLACK_WEBHOOK_URL = var.slack_webhook_url
    }
  }
  tags       = var.tags
  depends_on = [aws_cloudwatch_log_group.this, aws_iam_role_policy.this]
  lifecycle {
    precondition {
      condition     = can(regex("^arn:aws:cloudtrail:[a-z0-9-]+:${data.aws_caller_identity.current.account_id}:trail/.+$", var.management_trail_arn))
      error_message = "Verify an active management trail covering this account/region, then supply its ARN."
    }
    precondition {
      condition     = can(regex("^https://hooks.slack.com/services/[A-Za-z0-9/_-]+$", var.slack_webhook_url))
      error_message = "Enable remediation only with a configured Slack Incoming Webhook."
    }
  }
}

resource "aws_cloudwatch_event_rule" "this" {
  count = var.enable ? 1 : 0
  name  = local.name
  state = "ENABLED"
  event_pattern = jsonencode({
    source        = ["aws.ec2"]
    "detail-type" = ["AWS API Call via CloudTrail"]
    account       = [data.aws_caller_identity.current.account_id]
    region        = [data.aws_region.current.region]
    detail = {
      eventSource = ["ec2.amazonaws.com"]
      eventName   = ["AuthorizeSecurityGroupIngress", "ModifySecurityGroupRules"]
      errorCode   = [{ exists = false }]
    }
  })
  tags = var.tags
}

resource "aws_lambda_permission" "eventbridge" {
  count          = var.enable ? 1 : 0
  statement_id   = "AllowProjectSecurityGroupEvents"
  action         = "lambda:InvokeFunction"
  function_name  = aws_lambda_function.this[0].function_name
  principal      = "events.amazonaws.com"
  source_arn     = aws_cloudwatch_event_rule.this[0].arn
  source_account = data.aws_caller_identity.current.account_id
}

resource "aws_cloudwatch_event_target" "this" {
  count     = var.enable ? 1 : 0
  rule      = aws_cloudwatch_event_rule.this[0].name
  target_id = "PublicSshRemediation"
  arn       = aws_lambda_function.this[0].arn
  retry_policy {
    maximum_event_age_in_seconds = 3600
    maximum_retry_attempts       = 2
  }
  depends_on = [aws_lambda_permission.eventbridge]
}

resource "aws_lambda_function_event_invoke_config" "this" {
  count                        = var.enable ? 1 : 0
  function_name                = aws_lambda_function.this[0].function_name
  maximum_event_age_in_seconds = 3600
  maximum_retry_attempts       = 2
}

output "function_name" {
  value = try(aws_lambda_function.this[0].function_name, null)
}
output "event_rule_name" {
  value = try(aws_cloudwatch_event_rule.this[0].name, null)
}
