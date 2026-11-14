mock_provider "aws" {
  override_during = plan
  mock_data "aws_caller_identity" { defaults = { account_id = "123456789012" } }
  mock_data "aws_partition" { defaults = { partition = "aws" } }
  mock_data "aws_region" { defaults = { region = "ap-northeast-2" } }
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::123456789012:role/remediation" }
  }
  mock_resource "aws_lambda_function" {
    defaults = { arn = "arn:aws:lambda:ap-northeast-2:123456789012:function:remediation" }
  }
  mock_resource "aws_cloudwatch_event_rule" {
    defaults = { arn = "arn:aws:events:ap-northeast-2:123456789012:rule/remediation" }
  }
}
mock_provider "archive" {
  override_during = plan
}

variables {
  enable               = true
  tags                 = { Project = "food-delivery", Environment = "dev", ManagedBy = "terraform" }
  vpc_id               = "vpc-0123456789abcdef0"
  management_trail_arn = "arn:aws:cloudtrail:ap-northeast-2:123456789012:trail/verified-management"
  slack_webhook_url    = "https://hooks.slack.com/services/TEST/ONLY/FIXTURE"
}

run "enabled" {
  command = plan
  assert {
    condition = jsondecode(aws_cloudwatch_event_rule.this[0].event_pattern).source == ["aws.ec2"] && toset(
      jsondecode(aws_cloudwatch_event_rule.this[0].event_pattern).detail.eventName
    ) == toset(["AuthorizeSecurityGroupIngress", "ModifySecurityGroupRules"])
    error_message = "Detect only ingress creation and modern rule changes."
  }
  assert {
    condition     = jsondecode(aws_cloudwatch_event_rule.this[0].event_pattern)["detail-type"] == ["AWS API Call via CloudTrail"] && jsondecode(aws_cloudwatch_event_rule.this[0].event_pattern).detail.eventSource == ["ec2.amazonaws.com"] && jsondecode(aws_cloudwatch_event_rule.this[0].event_pattern).detail.errorCode[0].exists == false && aws_cloudwatch_event_rule.this[0].state == "ENABLED"
    error_message = "Use successful CloudTrail EC2 write API events on the default bus."
  }
  assert {
    condition     = aws_cloudwatch_event_target.this[0].arn == aws_lambda_function.this[0].arn && aws_cloudwatch_event_target.this[0].rule == aws_cloudwatch_event_rule.this[0].name && aws_lambda_permission.eventbridge[0].principal == "events.amazonaws.com" && aws_lambda_permission.eventbridge[0].source_arn == aws_cloudwatch_event_rule.this[0].arn && aws_lambda_permission.eventbridge[0].source_account == "123456789012"
    error_message = "Only the specific EventBridge rule/account may invoke this target."
  }
  assert {
    condition = jsondecode(aws_iam_role_policy.this[0].policy).Statement[1].Action == "ec2:RevokeSecurityGroupIngress" && jsondecode(aws_iam_role_policy.this[0].policy).Statement[1].Resource == "arn:aws:ec2:ap-northeast-2:123456789012:security-group/*" && jsondecode(aws_iam_role_policy.this[0].policy).Statement[1].Condition.StringEquals == {
      "ec2:ResourceTag/Project"     = "food-delivery"
      "ec2:ResourceTag/Environment" = "dev"
      "ec2:ResourceTag/ManagedBy"   = "terraform"
      "ec2:Vpc"                     = "arn:aws:ec2:ap-northeast-2:123456789012:vpc/vpc-0123456789abcdef0"
    }
    error_message = "Revoke permission requires all three tags AND the dev VPC."
  }
  assert {
    condition     = toset(jsondecode(aws_iam_role_policy.this[0].policy).Statement[0].Action) == toset(["ec2:DescribeSecurityGroups", "ec2:DescribeSecurityGroupRules"]) && toset(jsondecode(aws_iam_role_policy.this[0].policy).Statement[2].Action) == toset(["logs:CreateLogStream", "logs:PutLogEvents"]) && length(jsondecode(aws_iam_role_policy.this[0].policy).Statement) == 3
    error_message = "No broad EC2, tagging, Secrets Manager, Terraform or infrastructure permissions."
  }
  assert {
    condition     = aws_cloudwatch_log_group.this[0].retention_in_days == 30 && aws_lambda_function.this[0].timeout == 60 && aws_lambda_function.this[0].environment[0].variables["VPC_ID"] == var.vpc_id && aws_lambda_function.this[0].environment[0].variables["PROJECT_TAG"] == "food-delivery" && aws_lambda_function.this[0].environment[0].variables["ENV_TAG"] == "dev" && aws_lambda_function.this[0].environment[0].variables["MANAGED_BY_TAG"] == "terraform"
    error_message = "Bound runtime to the project environment/VPC and retain security logs for 30 days."
  }
}

run "disabled" {
  command = plan
  variables {
    enable               = false
    management_trail_arn = ""
    slack_webhook_url    = ""
  }
  assert {
    condition     = length(aws_lambda_function.this) == 0 && length(aws_iam_role.this) == 0 && length(aws_cloudwatch_event_rule.this) == 0 && length(aws_cloudwatch_event_target.this) == 0 && length(aws_lambda_permission.eventbridge) == 0 && length(aws_cloudwatch_log_group.this) == 0 && length(data.archive_file.lambda) == 0
    error_message = "Explicit opt-out must create no remediation resources or package."
  }
}

run "missing_trail" {
  command = plan
  variables { management_trail_arn = "" }
  expect_failures = [aws_lambda_function.this]
}

run "missing_slack" {
  command = plan
  variables { slack_webhook_url = "" }
  expect_failures = [aws_lambda_function.this]
}

run "missing_project_boundary" {
  command = plan
  variables { tags = { Project = "food-delivery", Environment = "dev", ManagedBy = "manual" } }
  expect_failures = [var.tags]
}
