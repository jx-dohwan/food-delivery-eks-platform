# Offline plans only: never connect to AWS, HTTP, Helm or a Kubernetes API.
mock_provider "aws" {
  mock_data "aws_availability_zones" { defaults = { names = ["ap-northeast-2a", "ap-northeast-2b", "ap-northeast-2c"] } }
  mock_resource "aws_security_group" { defaults = { id = "sg-00000000000000001", arn = "arn:aws:ec2:ap-northeast-2:123456789012:security-group/sg-00000000000000001" } }
  mock_resource "aws_vpc" { defaults = { id = "vpc-00000000000000001" } }
  mock_resource "aws_subnet" { defaults = { id = "subnet-00000000000000001" } }

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

mock_provider "aws" {
  alias           = "dokyo"
  override_during = plan
}
mock_provider "kubernetes" { override_during = plan }

variables {
  prod_deployment_reviewed    = true
  allowed_account_ids         = ["123456789012"]
  terraform_state_bucket_name = "example-terraform-state-bucket"
}

run "prod_platform_contract" {
  command = plan
  assert {
    condition     = !output.runtime_bindings.infrastructure_complete
    error_message = "Prod platform mocks may not claim DB/ESO/WAF/ECR runtime wiring is complete."
  }
  assert {
    condition     = module.eks.was_irsa_config.namespace == "app-prod" && module.eks.tracing_irsa_config.namespace == "app-prod" && module.eks.was_irsa_config.environment == "prod" && output.full_deploy_config.environment == "prod"
    error_message = "Prod must use the same current platform module with isolated workload identities."
  }
  assert {
    condition     = length(module.network.private_app_subnet_ids) == 3 && length(module.network.db_subnet_ids) == 3
    error_message = "Workers need the private app tier, and legacy cluster type must be replaced with supported db routing."
  }
}
run "prod_optional_platform_tools_are_wired" {
  command = plan
  variables {
    enable_oss_observability = true
    enable_karpenter         = true
    karpenter_ami_id         = "ami-00000000000000001"
    karpenter_ami_verified   = true
  }
  assert {
    condition     = output.full_deploy_config.karpenter.enabled && module.eks.tracing_irsa_config.service_account == "adot-collector"
    error_message = "Optional tools and tracing must be available without legacy module paths."
  }
}
run "prod_is_not_implicitly_approved_for_apply" {
  command = plan
  variables { prod_deployment_reviewed = false }
  expect_failures = [var.prod_deployment_reviewed]
}
