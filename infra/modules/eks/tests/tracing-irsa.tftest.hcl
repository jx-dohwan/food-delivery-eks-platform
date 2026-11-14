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

run "collector_identity_and_minimal_export" {
  command = plan
  assert {
    condition     = aws_iam_role.adot_collector.name == "platform-test-dev-adot" && jsondecode(aws_iam_role.adot_collector.assume_role_policy).Statement[0].Principal.Federated == aws_iam_openid_connect_provider.this.arn && jsondecode(aws_iam_role.adot_collector.assume_role_policy).Statement[0].Condition.StringEquals["oidc.eks.ap-northeast-2.amazonaws.com/id/TEST:aud"] == "sts.amazonaws.com" && jsondecode(aws_iam_role.adot_collector.assume_role_policy).Statement[0].Condition.StringEquals["oidc.eks.ap-northeast-2.amazonaws.com/id/TEST:sub"] == "system:serviceaccount:app:adot-collector"
    error_message = "Collector must have an exact dedicated EKS OIDC/aud/sub trust."
  }
  assert {
    condition     = jsondecode(aws_iam_role_policy.adot_collector.policy).Statement[0].Action == ["xray:PutTraceSegments"] && jsondecode(aws_iam_role_policy.adot_collector.policy).Statement[0].Resource == "*"
    error_message = "Only PutTraceSegments is used. Its resource wildcard is required by AWS API; telemetry/sampling are disabled."
  }
  assert {
    condition     = output.tracing_irsa_config.role_arn == aws_iam_role.adot_collector.arn && output.tracing_irsa_config.service_account == "adot-collector" && output.tracing_irsa_config.namespace == "app"
    error_message = "GitOps receives the exact Collector identity output."
  }
}
run "was_has_no_xray_permissions" {
  command = plan
  variables {
    was_aws_access = { s3 = { bucket_name = "food-delivery-dev-assets-test", encryption = "AES256" }, ses = { identity = "example.com", from_address = "sender@example.com" } }
  }
  assert {
    condition     = alltrue([for s in jsondecode(aws_iam_role_policy.was[0].policy).Statement : alltrue([for a in s.Action : !startswith(a, "xray:")])])
    error_message = "Tracing transport must never extend the WAS S3/SES policy."
  }
}
run "prod_collector_trust_is_separate" {
  command = plan
  variables { was_environment = "prod" }
  assert {
    condition     = jsondecode(aws_iam_role.adot_collector.assume_role_policy).Statement[0].Condition.StringEquals["oidc.eks.ap-northeast-2.amazonaws.com/id/TEST:sub"] == "system:serviceaccount:app-prod:adot-collector" && output.tracing_irsa_config.namespace == "app-prod"
    error_message = "Prod SA may not assume the dev Collector role."
  }
}
