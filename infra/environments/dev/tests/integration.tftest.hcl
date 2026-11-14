# Offline plans only: never connect to AWS, HTTP, Helm or a Kubernetes API.
mock_provider "aws" {
  mock_data "aws_lbs" { defaults = { arns = [] } }
  mock_resource "aws_db_proxy" { defaults = { endpoint = "audit.proxy-example.ap-northeast-2.rds.amazonaws.com" } }
  mock_resource "aws_elasticache_replication_group" { defaults = { primary_endpoint_address = "audit.example.apn2.cache.amazonaws.com", member_clusters = ["audit-001", "audit-002"] } }
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


mock_provider "random" {
  override_during = plan
  mock_resource "random_password" { defaults = { result = "MOCK_ONLY_password123!" } }
}
mock_provider "archive" { override_during = plan }
variables {
  allowed_account_ids         = ["123456789012"]
  terraform_state_bucket_name = "example-terraform-state-bucket"
  route53_zone_name           = "example.com"
  dev_domain_name             = "dev.example.com"
  www_domain_name             = "www.example.com"
  enable_secret_rotation      = false
  enable_ops_monitoring       = false
  enable_oss_observability    = false
  manage_ingress_alb_alias    = false
}
run "runtime_outputs_match_connection_and_eso_sources" {
  command = plan
  assert {
    condition     = output.runtime_bindings.infrastructure_complete && output.runtime_bindings.eso.authentication_secret_name == module.secrets_manager.secret_name && output.runtime_bindings.eso.connection_secret_name == module.secrets_manager.connection_secret_name && output.runtime_bindings.db_proxy_endpoint == module.rds.proxy_endpoint && output.runtime_bindings.redis_endpoint == module.redis.redis_primary_endpoint
    error_message = "Terraform-to-renderer bindings must use the same ESO/Proxy/Redis sources."
  }
  assert {
    condition     = output.runtime_bindings.cluster_name == module.eks.cluster_name && output.runtime_bindings.alb_security_group_id == module.security_group.alb_sg_id && output.runtime_bindings.vpc_cidr == module.network.vpc_cidr
    error_message = "Use actual cluster/network/SG outputs rather than names or default CIDRs."
  }
}
run "reject_wrong_environment" {
  command = plan
  variables { environment = "prod" }
  expect_failures = [var.environment]
}
run "reject_wrong_region" {
  command = plan
  variables { region = "us-east-1" }
  expect_failures = [var.region]
}
run "missing_alb_must_not_delete_or_repoint_dns" {
  command = plan
  variables { manage_ingress_alb_alias = true }
  # mock_data above supplies an empty result. Keep the data source itself
  # intact so its real lifecycle postcondition is exercised during this plan.
  expect_failures = [data.aws_lbs.app_ingress]
}
run "ambiguous_alb_must_not_repoint_dns" {
  command = plan
  variables { manage_ingress_alb_alias = true }
  override_data {
    target = data.aws_lbs.app_ingress[0]
    values = { arns = [
      "arn:aws:elasticloadbalancing:ap-northeast-2:123456789012:loadbalancer/app/dev-a/0000000000000001",
      "arn:aws:elasticloadbalancing:ap-northeast-2:123456789012:loadbalancer/app/dev-b/0000000000000002"
    ] }
  }
  expect_failures = [data.aws_lbs.app_ingress]
}
run "single_alb_preserves_project_filter_and_dns_counts" {
  command = plan
  variables { manage_ingress_alb_alias = true }
  override_data {
    target = data.aws_lbs.app_ingress[0]
    values = { arns = [
      "arn:aws:elasticloadbalancing:ap-northeast-2:123456789012:loadbalancer/app/dev-a/0000000000000001"
    ] }
  }
  assert {
    condition     = local.ingress_alb_arn == "arn:aws:elasticloadbalancing:ap-northeast-2:123456789012:loadbalancer/app/dev-a/0000000000000001" && length(data.aws_lb.app_ingress) == 1 && length(aws_route53_record.dev_app) == 1 && length(aws_route53_record.www_app) == 0
    error_message = "Known input flags must control instance counts; a single ALB may populate dev DNS only."
  }
  assert {
    condition     = data.aws_lbs.app_ingress[0].tags["elbv2.k8s.aws/cluster"] == module.eks.cluster_name && data.aws_lbs.app_ingress[0].tags["ingress.k8s.aws/stack"] == "app/main-ingress"
    error_message = "ALB lookup must retain both the actual cluster and exact Ingress boundary."
  }
}

run "rotation_infrastructure_initial_stage" {
  command = plan
  variables {
    enable_secret_rotation   = true
    activate_secret_rotation = false
  }
  assert {
    condition     = !module.secrets_manager.rotation_schedule_enabled
    error_message = "Root initial deployment must not activate a rotation callback."
  }
}
