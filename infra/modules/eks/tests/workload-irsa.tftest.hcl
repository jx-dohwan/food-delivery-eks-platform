# Offline plans only: never connect to AWS, HTTP, Helm or a Kubernetes API.
mock_provider "aws" {
  override_during = plan
  mock_resource "aws_eks_cluster" {
    defaults = {
      endpoint                  = "https://eks.example.test"
      identity                  = [{ oidc = [{ issuer = "https://oidc.eks.ap-northeast-2.amazonaws.com/id/TEST" }] }]
      certificate_authority     = [{ data = "dGVzdA==" }]
      kubernetes_network_config = { service_ipv4_cidr = "172.20.0.0/16" }
      vpc_config                = { cluster_security_group_id = "sg-00000000000000002" }
    }
  }
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::123456789012:role/test" }
  }
  mock_resource "aws_iam_policy" {
    defaults = { arn = "arn:aws:iam::123456789012:policy/test" }
  }
  mock_resource "aws_iam_openid_connect_provider" {
    defaults = { arn = "arn:aws:iam::123456789012:oidc-provider/oidc.eks.ap-northeast-2.amazonaws.com/id/TEST" }
  }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  mock_data "aws_ami" {
    defaults = { id = "ami-00000000000000001" }
  }
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012" }
  }
  mock_resource "aws_iam_instance_profile" {
    defaults = { arn = "arn:aws:iam::123456789012:instance-profile/platform-test-karpenter" }
  }
}
mock_provider "tls" {
  override_during = plan
  mock_data "tls_certificate" {
    defaults = { certificates = [{ sha1_fingerprint = "0123456789abcdef0123456789abcdef01234567" }] }
  }
}
mock_provider "http" {
  override_during = plan
  mock_data "http" {
    defaults = { response_body = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
}
mock_provider "helm" { override_during = plan }

variables {
  cluster_name           = "platform-test"
  vpc_id                 = "vpc-00000000000000001"
  subnet_ids             = ["subnet-00000000000000001", "subnet-00000000000000002"]
  node_security_group_id = "sg-00000000000000001"
}

run "workload_access" {
  command = plan
  variables {
    was_aws_access = {
      s3  = { bucket_name = "food-delivery-dev-assets-test", encryption = "AES256" }
      ses = { identity = "example.com", from_address = "noreply@example.com" }
    }
  }
  assert {
    condition     = jsondecode(aws_iam_role.was.assume_role_policy).Statement[0].Principal.Federated == aws_iam_openid_connect_provider.this.arn && jsondecode(aws_iam_role.was.assume_role_policy).Statement[0].Condition.StringEquals["oidc.eks.ap-northeast-2.amazonaws.com/id/TEST:aud"] == "sts.amazonaws.com" && jsondecode(aws_iam_role.was.assume_role_policy).Statement[0].Condition.StringEquals["oidc.eks.ap-northeast-2.amazonaws.com/id/TEST:sub"] == "system:serviceaccount:app:food-delivery-was"
    error_message = "Exact EKS OIDC/aud/sub trust, never GitHub or wildcard SA."
  }
  assert {
    condition     = toset(jsondecode(aws_iam_role_policy.was[0].policy).Statement[0].Action) == toset(["s3:PutObject"]) && toset(jsondecode(aws_iam_role_policy.was[0].policy).Statement[0].Resource) == toset([for p in ["restaurant", "dish", "review", "profile", "common"] : "arn:aws:s3:::food-delivery-dev-assets-test/${p}/*"])
    error_message = "Only real image prefixes and single-part PutObject; no List/Get/Delete/ACL."
  }
  assert {
    condition     = toset(jsondecode(aws_iam_role_policy.was[0].policy).Statement[1].Action) == toset(["ses:SendEmail"]) && toset(jsondecode(aws_iam_role_policy.was[0].policy).Statement[1].Resource) == toset(["arn:aws:ses:ap-northeast-2:123456789012:identity/example.com"]) && jsondecode(aws_iam_role_policy.was[0].policy).Statement[1].Condition.StringEquals["ses:FromAddress"] == "noreply@example.com"
    error_message = "Only SendEmail from the verified identity and exact sender."
  }
  assert {
    condition     = alltrue([for s in jsondecode(aws_iam_role_policy.was[0].policy).Statement : !contains(s.Resource, "*") && alltrue([for a in s.Action : !strcontains(a, "*")])])
    error_message = "No wildcard actions or universal resources."
  }
  assert {
    condition     = toset(local.node_policies) == toset(["arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy", "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly", "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"])
    error_message = "MNG must have only node/operations policies, no application S3/SES."
  }
  assert {
    condition     = output.was_irsa_config.namespace == "app" && output.was_irsa_config.role_arn == aws_iam_role.was.arn && output.was_irsa_config.s3_bucket_name == "food-delivery-dev-assets-test" && output.was_irsa_config.ses_from_address == "noreply@example.com"
    error_message = "Manifest configuration must originate from the same IAM resource inputs."
  }
}
run "unconfigured_grants_nothing" {
  command = plan
  assert {
    condition     = length(aws_iam_role_policy.was) == 0 && output.was_irsa_config.s3_bucket_name == "" && output.was_irsa_config.ses_from_address == ""
    error_message = "Do not guess application buckets/SES identities or grant broad fallbacks."
  }
}
run "prod_identity_is_separate" {
  command = plan
  variables {
    was_environment = "prod"
    was_aws_access  = { s3 = { bucket_name = "food-delivery-prod-assets-test", encryption = "AES256" } }
  }
  assert {
    condition     = output.was_irsa_config.namespace == "app-prod" && aws_iam_role.was.name == "platform-test-prod-was" && jsondecode(aws_iam_role.was.assume_role_policy).Statement[0].Condition.StringEquals["oidc.eks.ap-northeast-2.amazonaws.com/id/TEST:sub"] == "system:serviceaccount:app-prod:food-delivery-was" && length(jsondecode(aws_iam_role_policy.was[0].policy).Statement) == 1
    error_message = "Prod must use its own namespace/role/resources and no unconfigured SES."
  }
}
run "reject_wildcard_bucket" {
  command = plan
  variables { was_aws_access = { s3 = { bucket_name = "*", encryption = "AES256" } } }
  expect_failures = [var.was_aws_access]
}
run "reject_unreviewed_kms" {
  command = plan
  variables { was_aws_access = { s3 = { bucket_name = "food-delivery-dev-assets-test", encryption = "aws:kms" } } }
  expect_failures = [var.was_aws_access]
}
run "reject_state_bucket" {
  command = plan
  variables {
    protected_bucket_names = ["example-terraform-state-bucket"]
    was_aws_access         = { s3 = { bucket_name = "example-terraform-state-bucket", encryption = "AES256" } }
  }
  expect_failures = [var.was_aws_access]
}
run "reject_wrong_sender" {
  command = plan
  variables { was_aws_access = { ses = { identity = "example.com", from_address = "sender@foreign.test" } } }
  expect_failures = [var.was_aws_access]
}
run "reject_wildcard_identity" {
  command = plan
  variables { was_aws_access = { ses = { identity = "*", from_address = "sender@example.com" } } }
  expect_failures = [var.was_aws_access]
}
