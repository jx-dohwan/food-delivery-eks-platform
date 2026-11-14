mock_provider "aws" {
  override_during = plan
  mock_data "aws_caller_identity" { defaults = { account_id = "123456789012" } }
  mock_data "aws_partition" { defaults = { partition = "aws" } }
  mock_data "aws_region" { defaults = { region = "ap-northeast-2" } }
  mock_resource "aws_secretsmanager_secret" {
    defaults = { arn = "arn:aws:secretsmanager:ap-northeast-2:123456789012:secret:test" }
  }
  mock_resource "aws_iam_role" { defaults = { arn = "arn:aws:iam::123456789012:role/test" } }
  mock_resource "aws_lambda_function" { defaults = { arn = "arn:aws:lambda:ap-northeast-2:123456789012:function:test" } }
  mock_resource "aws_sns_topic" { defaults = { arn = "arn:aws:sns:ap-northeast-2:123456789012:test" } }
  mock_resource "aws_cloudwatch_log_group" {
    defaults = { arn = "arn:aws:logs:ap-northeast-2:123456789012:log-group:/aws/lambda/test" }
  }
}
mock_provider "random" { override_during = plan }
mock_provider "archive" { override_during = plan }
variables {
  enable_rotation            = true
  db_cluster_identifier      = "aurora-mysql-cluster"
  db_cluster_arn             = "arn:aws:rds:ap-northeast-2:123456789012:cluster:aurora-mysql-cluster"
  rotation_subnet_ids        = ["subnet-private-a", "subnet-private-b"]
  rotation_security_group_id = "sg-rotation"
  slack_webhook_url          = "https://hooks.slack.com/services/TEST/ONLY/FIXTURE"
}
run "explicit_log_groups" {
  command = plan
  assert {
    condition     = aws_cloudwatch_log_group.rotation[0].retention_in_days == 30 && aws_cloudwatch_log_group.rotation[0].name == "/aws/lambda/${aws_lambda_function.rotation[0].function_name}" && aws_cloudwatch_log_group.slack_notify[0].retention_in_days == 14 && aws_cloudwatch_log_group.slack_notify[0].name == "/aws/lambda/${aws_lambda_function.slack_notify[0].function_name}"
    error_message = "Both runtime Lambda groups must be precreated with explicit retention."
  }
  assert {
    condition     = !contains(jsondecode(aws_iam_role_policy.rotation_lambda[0].policy).Statement[2].Action, "logs:CreateLogGroup") && !contains(jsondecode(aws_iam_role_policy.slack_notify_logs[0].policy).Statement[0].Action, "logs:CreateLogGroup") && jsondecode(aws_iam_role_policy.slack_notify_logs[0].policy).Statement[0].Resource == ["${aws_cloudwatch_log_group.slack_notify[0].arn}:*"]
    error_message = "Function roles must not silently recreate unlimited-retention groups or write to unrelated groups."
  }
}
run "disabled_groups" {
  command = plan
  variables {
    enable_rotation   = false
    slack_webhook_url = ""
  }
  assert {
    condition     = length(aws_cloudwatch_log_group.rotation) == 0 && length(aws_cloudwatch_log_group.slack_notify) == 0
    error_message = "Disabled functions must not leave newly provisioned groups."
  }
}
