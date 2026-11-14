# Run with mocked AWS/random providers. archive_file only writes a local ZIP.
mock_provider "aws" {
  override_during = plan
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012" }
  }
  mock_data "aws_region" {
    defaults = { region = "ap-northeast-2" }
  }
  mock_data "aws_partition" {
    defaults = { partition = "aws" }
  }
  mock_resource "aws_secretsmanager_secret" {
    defaults = { arn = "arn:aws:secretsmanager:ap-northeast-2:123456789012:secret:rds-aurora-credentials-example" }
  }
}

mock_provider "random" {
  override_during = plan
  mock_resource "random_password" {
    defaults = { result = "Static-Mock-Password-123!" }
  }
}

variables {
  enable_rotation            = true
  activate_rotation          = true
  rotation_proxy_target_id   = "proxy-target-mock"
  db_cluster_identifier      = "aurora-mysql-cluster"
  db_cluster_arn             = "arn:aws:rds:ap-northeast-2:123456789012:cluster:aurora-mysql-cluster"
  db_host                    = "aurora-proxy.proxy-example.ap-northeast-2.rds.amazonaws.com"
  rotation_subnet_ids        = ["subnet-private-a", "subnet-private-b"]
  rotation_security_group_id = "sg-rotation"
}

run "rotation_structure" {
  command = plan

  assert {
    condition     = aws_secretsmanager_secret_rotation.db[0].rotation_rules[0].automatically_after_days == 7
    error_message = "Keep the existing seven-day schedule."
  }
  assert {
    condition     = !contains(keys(jsondecode(aws_secretsmanager_secret_version.db_secret_val.secret_string)), "host")
    error_message = "The authentication secret must not depend on a Proxy host."
  }
  assert {
    condition     = jsondecode(aws_secretsmanager_secret_version.db_connection_val.secret_string) == { host = var.db_host, redis_host = var.redis_host, redis_port = var.redis_port }
    error_message = "Connection information must remain separate from credentials."
  }
  assert {
    condition     = aws_lambda_function.rotation[0].environment[0].variables.SECRET_ARN == aws_secretsmanager_secret.db_secret.arn
    error_message = "Rotation must target the same authentication secret."
  }
  assert {
    condition     = aws_lambda_function.rotation[0].vpc_config[0].security_group_ids == toset([var.rotation_security_group_id])
    error_message = "Use only the dedicated rotation security group."
  }
  assert {
    condition     = aws_lambda_permission.allow_secretsmanager[0].source_arn == aws_secretsmanager_secret.db_secret.arn
    error_message = "Secrets Manager invocation must be scoped to this secret."
  }
  assert {
    condition     = jsondecode(aws_iam_role_policy.rotation_lambda[0].policy).Statement[0].Resource == [aws_secretsmanager_secret.db_secret.arn]
    error_message = "Secrets Manager permissions must be scoped to the auth secret."
  }
  assert {
    condition     = jsondecode(aws_iam_role_policy.rotation_lambda[0].policy).Statement[1].Resource == [var.db_cluster_arn]
    error_message = "RDS actions must be restricted to the configured cluster."
  }
  assert {
    condition     = jsondecode(aws_iam_role_policy.rotation_lambda[0].policy).Statement[4].Effect == "Deny"
    error_message = "Function code must not inherit Lambda service ENI powers."
  }
}

run "rotation_disabled" {
  command = plan
  variables {
    enable_rotation   = false
    activate_rotation = false
  }
  assert {
    condition     = length(aws_lambda_function.rotation) == 0 && length(aws_secretsmanager_secret_rotation.db) == 0
    error_message = "Disabling rotation must remove only the optional rotation resources."
  }
}

run "initial_deployment_no_rotation_invocation" {
  command = plan
  variables { activate_rotation = false }
  assert {
    condition     = length(aws_lambda_function.rotation) == 1 && length(aws_secretsmanager_secret_rotation.db) == 0
    error_message = "Initial apply must prepare rotation infrastructure without invoking any rotation step."
  }
}
run "activation_requires_proxy_registration" {
  command = plan
  variables { rotation_proxy_target_id = "" }
  expect_failures = [aws_secretsmanager_secret_rotation.db]
}
run "activation_defers_password_change" {
  command = plan
  assert {
    condition     = aws_secretsmanager_secret_rotation.db[0].rotate_immediately == false
    error_message = "Schedule activation may test credentials but must not immediately reset the master password."
  }
}
