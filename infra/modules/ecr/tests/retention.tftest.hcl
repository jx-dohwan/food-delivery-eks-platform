mock_provider "aws" { override_during = plan }
variables {
  protected_image_tags = {
    was = ["0123456789abcdef0123456789abcdef01234567"]
    web = ["abcdef0123456789abcdef0123456789abcdef01"]
  }
}
run "immutable_rollback_repositories" {
  command = plan
  assert {
    condition = toset(keys(aws_ecr_repository.this)) == toset(["was", "web"]) && alltrue([
      for repository in aws_ecr_repository.this : repository.image_tag_mutability == "IMMUTABLE" && repository.force_delete && repository.image_scanning_configuration[0].scan_on_push && one(repository.encryption_configuration).encryption_type == "KMS"
    ])
    error_message = "WAS/Web must use immutable tags, scan/KMS, and explicit complete-dev-teardown policy."
  }
  assert {
    condition = alltrue([for policy in aws_ecr_lifecycle_policy.this :
      length(jsondecode(policy.policy).rules) == 3 && length(distinct([for rule in jsondecode(policy.policy).rules : rule.rulePriority])) == 3
    ])
    error_message = "Use three distinct priorities: exact deployed SHA, untagged and recent tagged images."
  }
  assert {
    condition = alltrue([for name, policy in aws_ecr_lifecycle_policy.this :
      jsondecode(policy.policy).rules[0].rulePriority == 1 && toset(jsondecode(policy.policy).rules[0].selection.tagPatternList) == toset(var.protected_image_tags[name]) && jsondecode(policy.policy).rules[0].selection.countNumber == 1 && jsondecode(policy.policy).rules[0].selection.countType == "imageCountMoreThan"
    ])
    error_message = "The exact immutable current SHA must never exceed one image or expire via lower priority."
  }
  assert {
    condition = alltrue([for policy in aws_ecr_lifecycle_policy.this :
      jsondecode(policy.policy).rules[1].selection.tagStatus == "untagged" && jsondecode(policy.policy).rules[1].selection.countType == "sinceImagePushed" && jsondecode(policy.policy).rules[1].selection.countNumber == 3 && !can(jsondecode(policy.policy).rules[1].selection.tagPatternList)
    ])
    error_message = "Clean untagged images only after three days; do not match SHA tags."
  }
  assert {
    condition = alltrue([for policy in aws_ecr_lifecycle_policy.this :
      jsondecode(policy.policy).rules[2].selection.tagStatus == "tagged" && jsondecode(policy.policy).rules[2].selection.tagPatternList == ["*"] && jsondecode(policy.policy).rules[2].selection.countNumber == 30 && jsondecode(policy.policy).rules[2].selection.countType == "imageCountMoreThan"
    ])
    error_message = "Retain the newest 30 tagged images; full SHA needs wildcard matching, not v/sha- prefixes."
  }
}
run "unprotected_current_image_rejected" {
  command = plan
  variables { protected_image_tags = {} }
  expect_failures = [aws_ecr_lifecycle_policy.this]
}
run "invalid_mutable_tag_rejected" {
  command = plan
  variables { protected_image_tags = { was = ["latest"], web = ["current"] } }
  expect_failures = [var.protected_image_tags]
}
