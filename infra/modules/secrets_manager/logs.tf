# Create before first invocation; avoid implicit groups with infinite retention.
resource "aws_cloudwatch_log_group" "rotation" {
  count             = var.enable_rotation ? 1 : 0
  name              = "/aws/lambda/${local.rotation_function_name}"
  retention_in_days = 30
  tags              = var.tags
}

resource "aws_cloudwatch_log_group" "slack_notify" {
  count             = var.slack_webhook_url != "" ? 1 : 0
  name              = "/aws/lambda/${var.tag_header}slack-ops-alert"
  retention_in_days = 14
  tags              = var.tags
}
