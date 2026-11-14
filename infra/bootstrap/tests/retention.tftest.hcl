mock_provider "aws" {
  override_during = plan
  mock_data "aws_caller_identity" { defaults = { account_id = "123456789012" } }
  mock_data "aws_partition" { defaults = { partition = "aws" } }
  mock_data "aws_region" { defaults = { region = "ap-northeast-2" } }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  mock_resource "aws_s3_bucket" {
    defaults = { arn = "arn:aws:s3:::mock-audit" }
  }
  mock_resource "aws_iam_openid_connect_provider" {
    defaults = { arn = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com" }
  }
}
variables {
  allowed_account_id          = "123456789012"
  terraform_state_bucket_name = "example-terraform-state-bucket"
}

run "state_current_protected_history_bounded" {
  command = plan
  assert {
    condition     = aws_s3_bucket.terraform_state.bucket == "example-terraform-state-bucket" && !aws_s3_bucket.terraform_state.force_destroy && aws_s3_bucket_versioning.terraform_state_versioning.versioning_configuration[0].status == "Enabled"
    error_message = "Preserve the versioned state bucket and prevent force emptying it."
  }
  assert {
    condition = alltrue([for rule in aws_s3_bucket_lifecycle_configuration.terraform_state.rule :
      rule.filter[0].prefix == "terraform/" && alltrue([for expiry in rule.expiration : expiry.expired_object_delete_marker == true])
    ])
    error_message = "Never expire current state objects by age/date; only remove truly empty delete markers."
  }
  assert {
    condition = length(flatten([for rule in aws_s3_bucket_lifecycle_configuration.terraform_state.rule :
      [for expiry in rule.noncurrent_version_expiration : expiry if expiry.noncurrent_days == 90 && expiry.newer_noncurrent_versions == 10]
    ])) == 1
    error_message = "Keep at least ten noncurrent versions and all versions younger than 90 noncurrent days."
  }
}
run "audit_expiration_and_public_access_block_preserved" {
  command = plan
  variables { create_management_trail = true }
  assert {
    condition     = one(aws_s3_bucket_lifecycle_configuration.management_trail[0].rule).expiration[0].days == 90 && one(aws_s3_bucket_lifecycle_configuration.management_trail[0].rule).filter[0].prefix == "AWSLogs/" && length(one(aws_s3_bucket_lifecycle_configuration.management_trail[0].rule).transition) == 0
    error_message = "Keep existing 90-day audit expiration without storage-class transition complexity."
  }
  assert {
    condition     = aws_s3_bucket_public_access_block.management_trail[0].block_public_acls && aws_s3_bucket_public_access_block.management_trail[0].block_public_policy && aws_s3_bucket_public_access_block.management_trail[0].ignore_public_acls && aws_s3_bucket_public_access_block.management_trail[0].restrict_public_buckets
    error_message = "Preserve all existing CloudTrail public-access blocks."
  }
}
