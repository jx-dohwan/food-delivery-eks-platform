# ==============================================================================
# Secrets Manager — Aurora password rotation (7 days) + Slack alert on failure
# ==============================================================================

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

locals {
  rotation_function_name = "${var.tag_header}secrets-rds-mysql-rotation"
  rotation_function_arn  = "arn:${data.aws_partition.current.partition}:lambda:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:function:${local.rotation_function_name}"
  rotation_log_arn       = "arn:${data.aws_partition.current.partition}:logs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/${local.rotation_function_name}:*"
}

data "archive_file" "rotation_lambda" {
  count       = var.enable_rotation ? 1 : 0
  type        = "zip"
  source_dir  = "${path.module}/rotation/build"
  output_path = "${path.module}/rotation/rotation_lambda.zip"
  excludes    = fileset("${path.module}/rotation/build", "**/*.pyc")

  lifecycle {
    precondition {
      condition = (
        try(filebase64sha256("${path.module}/rotation/build/lambda_function.py"), "") == filebase64sha256("${path.module}/rotation/lambda_function.py") &&
        try(filebase64sha256("${path.module}/rotation/build/rds-ca-bundle.pem"), "") == filebase64sha256("${path.module}/rotation/rds-ca-bundle.pem") &&
        fileexists("${path.module}/rotation/build/pymysql/__init__.py")
      )
      error_message = "Prepare the current Lambda and driver: bash infra/modules/secrets_manager/rotation/build-package.sh"
    }
  }
}

# Slack / SNS 는 로테이션과 독립 — 모니터링 알람 등 ops 공용 파이프
data "archive_file" "slack_notify_lambda" {
  count       = var.slack_webhook_url != "" ? 1 : 0
  type        = "zip"
  source_file = "${path.module}/rotation/slack_notify.py"
  output_path = "${path.module}/rotation/slack_notify_lambda.zip"
}

resource "aws_iam_role" "rotation_lambda" {
  count = var.enable_rotation ? 1 : 0
  name  = "${var.tag_header}secrets-rotation-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })

  tags = merge(var.tags, { Name = "${var.tag_header}secrets-rotation-lambda-role" })
}

resource "aws_iam_role_policy" "rotation_lambda" {
  count = var.enable_rotation ? 1 : 0
  name  = "${var.tag_header}secrets-rotation-policy"
  role  = aws_iam_role.rotation_lambda[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:DescribeSecret",
          "secretsmanager:GetSecretValue",
          "secretsmanager:PutSecretValue",
          "secretsmanager:UpdateSecretVersionStage"
        ]
        Resource = [aws_secretsmanager_secret.db_secret.arn]
      },
      {
        Effect = "Allow"
        Action = [
          "rds:ModifyDBCluster",
          "rds:DescribeDBClusters"
        ]
        Resource = [var.db_cluster_arn]
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = [local.rotation_log_arn]
      },
      {
        # Lambda's VPC service needs these operations on generated ENIs.
        Effect = "Allow"
        Action = [
          "ec2:CreateNetworkInterface", "ec2:DescribeNetworkInterfaces",
          "ec2:DescribeSubnets", "ec2:DeleteNetworkInterface",
          "ec2:AssignPrivateIpAddresses", "ec2:UnassignPrivateIpAddresses"
        ]
        Resource = ["*"]
      },
      {
        # Permit Lambda service ENI management, but deny EC2 API calls from code.
        Effect = "Deny"
        Action = [
          "ec2:CreateNetworkInterface", "ec2:DescribeNetworkInterfaces",
          "ec2:DescribeSubnets", "ec2:DeleteNetworkInterface",
          "ec2:AssignPrivateIpAddresses", "ec2:UnassignPrivateIpAddresses"
        ]
        Resource  = ["*"]
        Condition = { ArnEquals = { "lambda:SourceFunctionArn" = local.rotation_function_arn } }
      }
    ]
  })
}

resource "aws_lambda_function" "rotation" {
  count            = var.enable_rotation ? 1 : 0
  function_name    = local.rotation_function_name
  role             = aws_iam_role.rotation_lambda[0].arn
  handler          = "lambda_function.handler"
  runtime          = "python3.12"
  timeout          = 60
  filename         = data.archive_file.rotation_lambda[0].output_path
  source_code_hash = data.archive_file.rotation_lambda[0].output_base64sha256

  vpc_config {
    subnet_ids         = var.rotation_subnet_ids
    security_group_ids = [var.rotation_security_group_id]
  }

  environment {
    variables = {
      DB_CLUSTER_IDENTIFIER = var.db_cluster_identifier
      DB_CLUSTER_ARN        = var.db_cluster_arn
      SECRET_ARN            = aws_secretsmanager_secret.db_secret.arn
    }
  }

  lifecycle {
    precondition {
      condition     = length(var.rotation_subnet_ids) > 0 && var.rotation_security_group_id != "" && var.db_cluster_arn != "" && var.db_cluster_identifier != ""
      error_message = "Rotation requires the Aurora target, NAT-enabled private subnets and a dedicated security group."
    }
  }

  depends_on = [aws_iam_role_policy.rotation_lambda, aws_cloudwatch_log_group.rotation]

  tags = merge(var.tags, {
    Name        = "${var.tag_header}secrets-rds-mysql-rotation"
    Environment = lookup(var.tags, "Environment", "dev")
    Project     = lookup(var.tags, "Project", "food-delivery")
    Purpose     = "secrets-rotation"
  })
}

resource "aws_lambda_permission" "allow_secretsmanager" {
  count          = var.enable_rotation ? 1 : 0
  statement_id   = "AllowSecretsManagerInvoke"
  action         = "lambda:InvokeFunction"
  function_name  = aws_lambda_function.rotation[0].function_name
  principal      = "secretsmanager.amazonaws.com"
  source_arn     = aws_secretsmanager_secret.db_secret.arn
  source_account = data.aws_caller_identity.current.account_id
}

# Stage one never invokes rotation, including testSecret. Stage two is enabled
# only after a live Proxy target health check. false still invokes testSecret;
# it is not a substitute for the activation gate.
resource "aws_secretsmanager_secret_rotation" "db" {
  count               = var.enable_rotation && var.activate_rotation ? 1 : 0
  secret_id           = aws_secretsmanager_secret.db_secret.id
  rotation_lambda_arn = aws_lambda_function.rotation[0].arn
  rotate_immediately  = false

  rotation_rules {
    automatically_after_days = var.rotation_days
  }

  depends_on = [
    aws_lambda_permission.allow_secretsmanager,
    aws_secretsmanager_secret_version.db_secret_val
  ]
  lifecycle {
    precondition {
      condition     = var.rotation_proxy_target_id != ""
      error_message = "Register and verify the RDS Proxy target before activating rotation."
    }
  }
}

# --- Slack notify (ops 공용: rotation / CloudWatch alarms) ---
resource "aws_iam_role" "slack_notify" {
  count = var.slack_webhook_url != "" ? 1 : 0
  name  = "${var.tag_header}slack-alert-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "slack_notify_logs" {
  count = var.slack_webhook_url != "" ? 1 : 0
  name  = "${var.tag_header}slack-alert-logs"
  role  = aws_iam_role.slack_notify[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
      Resource = ["${aws_cloudwatch_log_group.slack_notify[0].arn}:*"]
    }]
  })
}

resource "aws_lambda_function" "slack_notify" {
  count            = var.slack_webhook_url != "" ? 1 : 0
  function_name    = "${var.tag_header}slack-ops-alert"
  role             = aws_iam_role.slack_notify[0].arn
  handler          = "slack_notify.handler"
  runtime          = "python3.12"
  timeout          = 15
  filename         = data.archive_file.slack_notify_lambda[0].output_path
  source_code_hash = data.archive_file.slack_notify_lambda[0].output_base64sha256
  depends_on       = [aws_iam_role_policy.slack_notify_logs, aws_cloudwatch_log_group.slack_notify]

  environment {
    variables = {
      SLACK_WEBHOOK_URL = var.slack_webhook_url
      SLACK_ALERT_TAGS  = var.slack_alert_tags
      ENV_TAG           = lookup(var.tags, "Environment", "dev")
      PROJECT_TAG       = lookup(var.tags, "Project", "food-delivery")
    }
  }

  tags = merge(var.tags, {
    Name        = "${var.tag_header}slack-ops-alert"
    Environment = lookup(var.tags, "Environment", "dev")
    Project     = lookup(var.tags, "Project", "food-delivery")
    Purpose     = "slack-alert"
  })
}

resource "aws_cloudwatch_event_rule" "rotation_failed" {
  count       = var.enable_rotation && var.slack_webhook_url != "" ? 1 : 0
  name        = "${var.tag_header}secrets-rotation-failed"
  description = "Notify Slack when Secrets Manager rotation fails"

  event_pattern = jsonencode({
    source        = ["aws.secretsmanager"]
    "detail-type" = ["AWS Service Event via CloudTrail"]
    detail = {
      eventSource = ["secretsmanager.amazonaws.com"]
      eventName   = ["RotationFailed", "RotationSucceeded"]
    }
  })
}

resource "aws_cloudwatch_event_target" "rotation_failed_slack" {
  count     = var.enable_rotation && var.slack_webhook_url != "" ? 1 : 0
  rule      = aws_cloudwatch_event_rule.rotation_failed[0].name
  target_id = "slack-notify"
  arn       = aws_lambda_function.slack_notify[0].arn
}

resource "aws_lambda_permission" "allow_events_slack" {
  count         = var.enable_rotation && var.slack_webhook_url != "" ? 1 : 0
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.slack_notify[0].function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.rotation_failed[0].arn
}

resource "aws_cloudwatch_metric_alarm" "rotation_lambda_errors" {
  count               = var.enable_rotation && var.slack_webhook_url != "" ? 1 : 0
  alarm_name          = "${var.tag_header}secrets-rotation-errors"
  alarm_description   = "Secrets rotation Lambda errors — Slack alert (Environment/Project tags)"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = 60
  statistic           = "Sum"
  threshold           = 0
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = aws_lambda_function.rotation[0].function_name
  }

  alarm_actions = [aws_sns_topic.ops_alerts[0].arn]
  ok_actions    = [aws_sns_topic.ops_alerts[0].arn]

  tags = merge(var.tags, {
    Environment = lookup(var.tags, "Environment", "dev")
    Project     = lookup(var.tags, "Project", "food-delivery")
    Purpose     = "secrets-rotation-alarm"
  })
}

resource "aws_sns_topic" "ops_alerts" {
  count = var.slack_webhook_url != "" ? 1 : 0
  name  = "${var.tag_header}ops-alerts"

  tags = merge(var.tags, {
    Environment = lookup(var.tags, "Environment", "dev")
    Project     = lookup(var.tags, "Project", "food-delivery")
    Purpose     = "ops-alerts-sns"
  })
}

resource "aws_sns_topic_subscription" "ops_alerts_lambda" {
  count     = var.slack_webhook_url != "" ? 1 : 0
  topic_arn = aws_sns_topic.ops_alerts[0].arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.slack_notify[0].arn
}

resource "aws_lambda_permission" "allow_sns_slack" {
  count         = var.slack_webhook_url != "" ? 1 : 0
  statement_id  = "AllowSNSInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.slack_notify[0].function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.ops_alerts[0].arn
}
