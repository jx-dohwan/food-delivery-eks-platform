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

run "unverified_is_explicit_debt" {
  command = plan
  assert {
    condition     = contains(yamldecode(helm_release.metrics_server.values[0]).args, "--kubelet-insecure-tls")
    error_message = "Do not assume a valid serving CA/SAN without real-cluster evidence."
  }
}
run "verified_uses_cluster_ca_and_no_insecure_flag" {
  command = plan
  variables { metrics_server_kubelet_tls_verified = true }
  assert {
    condition     = !contains(yamldecode(helm_release.metrics_server.values[0]).args, "--kubelet-insecure-tls") && contains(yamldecode(helm_release.metrics_server.values[0]).args, "--kubelet-certificate-authority=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt") && contains(yamldecode(helm_release.metrics_server.values[0]).args, "--kubelet-preferred-address-types=InternalIP")
    error_message = "Only the evidence-backed setting may use the mounted cluster CA and validated InternalIP."
  }
}
