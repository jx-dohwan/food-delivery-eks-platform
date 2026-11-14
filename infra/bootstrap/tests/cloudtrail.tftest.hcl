# Plan-only mocks; no actual AWS/state access. Other bootstrap resources are not applied.
mock_provider "aws" {
  override_during = plan
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  mock_data "aws_caller_identity" { defaults = { account_id = "123456789012" } }
  mock_data "aws_partition" { defaults = { partition = "aws" } }
  mock_data "aws_region" { defaults = { region = "ap-northeast-2" } }
  mock_resource "aws_s3_bucket" {
    defaults = { arn = "arn:aws:s3:::food-delivery-cloudtrail-123456789012-ap-northeast-2" }
  }
  mock_resource "aws_cloudtrail" {
    defaults = { arn = "arn:aws:cloudtrail:ap-northeast-2:123456789012:trail/food-delivery-management-events" }
  }
  mock_resource "aws_iam_openid_connect_provider" {
    defaults = { arn = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com" }
  }
}

variables {
  allowed_account_id          = "123456789012"
  terraform_state_bucket_name = "example-terraform-state-bucket"
}

run "no_duplicate_by_default" {
  command = plan
  assert {
    condition     = length(aws_cloudtrail.management) == 0 && length(aws_s3_bucket.management_trail) == 0 && output.management_trail_arn == null
    error_message = "Default must not create a duplicate account trail."
  }
}

run "existing_trail_read_only_reference" {
  command = plan
  variables { existing_management_trail_arn = "arn:aws:cloudtrail:ap-northeast-2:123456789012:trail/existing" }
  assert {
    condition     = length(aws_cloudtrail.management) == 0 && output.management_trail_arn == var.existing_management_trail_arn
    error_message = "Refer to verified existing trail without importing/modifying it."
  }
}

run "create_minimal_management_trail" {
  command = plan
  variables { create_management_trail = true }
  assert {
    condition     = aws_cloudtrail.management[0].enable_logging && aws_cloudtrail.management[0].event_selector[0].include_management_events && aws_cloudtrail.management[0].event_selector[0].read_write_type == "WriteOnly" && length(aws_cloudtrail.management[0].event_selector[0].data_resource) == 0 && !aws_cloudtrail.management[0].is_multi_region_trail && !aws_cloudtrail.management[0].is_organization_trail && length(aws_cloudtrail.management[0].insight_selector) == 0 && aws_cloudtrail.management[0].enable_log_file_validation
    error_message = "Use regional write management events only; no data events or Insights."
  }
  assert {
    condition     = aws_s3_bucket_public_access_block.management_trail[0].block_public_acls && aws_s3_bucket_public_access_block.management_trail[0].block_public_policy && aws_s3_bucket_public_access_block.management_trail[0].ignore_public_acls && aws_s3_bucket_public_access_block.management_trail[0].restrict_public_buckets && !aws_s3_bucket.management_trail[0].force_destroy
    error_message = "Keep audit storage private and outside dev destroy."
  }
  assert {
    condition     = jsondecode(aws_s3_bucket_policy.management_trail[0].policy).Statement[1].Condition.StringEquals["aws:SourceArn"] == local.management_trail_arn && jsondecode(aws_s3_bucket_policy.management_trail[0].policy).Statement[1].Resource == "${aws_s3_bucket.management_trail[0].arn}/AWSLogs/123456789012/*"
    error_message = "Allow only this CloudTrail service source to write this account's log prefix."
  }
  assert {
    condition     = one(aws_s3_bucket_server_side_encryption_configuration.management_trail[0].rule).apply_server_side_encryption_by_default[0].sse_algorithm == "AES256" && one(aws_s3_bucket_lifecycle_configuration.management_trail[0].rule).expiration[0].days == 90
    error_message = "Encrypt logs and bound storage to 90 days."
  }
}

run "reject_duplicate_configuration" {
  command = plan
  variables {
    create_management_trail       = true
    existing_management_trail_arn = "arn:aws:cloudtrail:ap-northeast-2:123456789012:trail/existing"
  }
  expect_failures = [aws_s3_bucket.management_trail]
}
