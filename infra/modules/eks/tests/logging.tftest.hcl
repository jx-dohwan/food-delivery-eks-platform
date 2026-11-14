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
    defaults = { arn = "arn:aws:iam::000000000000:role/test" }
  }
  mock_resource "aws_iam_policy" {
    defaults = { arn = "arn:aws:iam::000000000000:policy/test" }
  }
  mock_resource "aws_iam_openid_connect_provider" {
    defaults = { arn = "arn:aws:iam::000000000000:oidc-provider/oidc.eks.ap-northeast-2.amazonaws.com/id/TEST" }
  }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  mock_data "aws_ami" {
    defaults = { id = "ami-00000000000000001" }
  }
  mock_data "aws_caller_identity" {
    defaults = { account_id = "000000000000" }
  }
  mock_resource "aws_iam_instance_profile" {
    defaults = { arn = "arn:aws:iam::000000000000:instance-profile/platform-test-karpenter" }
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

mock_provider "kubernetes" { override_during = plan }

variables {
  cluster_name           = "platform-test"
  vpc_id                 = "vpc-00000000000000001"
  subnet_ids             = ["subnet-00000000000000001", "subnet-00000000000000002"]
  node_security_group_id = "sg-00000000000000001"
}

run "central_logging_contract" {
  command = plan
  variables {
    instance_type            = "t3.large"
    enable_central_logging   = true
    enable_oss_observability = true
    loki_bucket_name         = "food-delivery-loki-mock"
  }
  assert {
    condition     = jsondecode(aws_iam_role.logging["loki"].assume_role_policy).Statement[0].Condition.StringEquals["oidc.eks.ap-northeast-2.amazonaws.com/id/TEST:sub"] == "system:serviceaccount:monitoring:loki"
    error_message = "Only the Loki service account may assume the archive role."
  }
  assert {
    condition     = alltrue([for st in jsondecode(aws_iam_role_policy.loki_s3[0].policy).Statement : !contains(st.Action, "s3:*") && st.Resource != "*"])
    error_message = "Loki must not get wildcard S3 access or account-wide objects."
  }
  assert {
    condition     = !strcontains(aws_iam_role_policy.ebs[0].policy, "CreateSnapshot") && !strcontains(aws_iam_role_policy.ebs[0].policy, "EnableFastSnapshotRestores")
    error_message = "WAL volumes do not require paid snapshot/FSR privileges."
  }
  assert {
    condition     = helm_release.loki[0].version == "20.0.2" && helm_release.alloy[0].version == "1.14.3" && helm_release.ebs_csi[0].version == "2.67.2"
    error_message = "Do not resolve floating chart versions at deploy time."
  }
  assert {
    condition     = yamldecode(helm_release.loki[0].values[0]).loki.storage.bucketNames.chunks == "food-delivery-loki-mock" && !yamldecode(helm_release.loki[0].values[0]).loki.storage.s3.insecure
    error_message = "Rendering placeholders must be replaced and HTTPS retained."
  }
  assert {
    condition     = yamldecode(helm_release.loki[0].values[0]).singleBinary.replicas == 1 && yamldecode(helm_release.loki[0].values[0]).loki.limits_config.retention_period == "168h"
    error_message = "One dev replica and compactor retention are explicit, not HA claims."
  }
  assert {
    condition     = !yamldecode(helm_release.alloy[0].values[0]).alloy.configMap.create && strcontains(kubernetes_config_map_v1.alloy[0].data["config.alloy"], "stage.template")
    error_message = "Alloy Go templates must not be expanded by Helm tpl."
  }
  assert {
    condition     = yamldecode(helm_release.alloy[0].values[0]).controller.podAnnotations["checksum/config"] == sha256(kubernetes_config_map_v1.alloy[0].data["config.alloy"])
    error_message = "The final deployed config must drive the DaemonSet template hash."
  }
  assert {
    condition     = length(local.observability_scrapes) == 3 && length(distinct([for job in local.observability_scrapes : job.job_name])) == 3
    error_message = "Base and logging scrapes must merge once, never replace/duplicate cadvisor."
  }
  assert {
    condition     = yamldecode(helm_release.ebs_csi[0].values[0]).controller.extraVolumeTags.Cluster == var.cluster_name && yamldecode(helm_release.ebs_csi[0].values[0]).controller.extraVolumeTags.Environment == "dev"
    error_message = "Controller-created retained volumes need exact cluster/environment ownership."
  }
  assert {
    condition     = contains([for r in yamldecode(helm_release.observability[0].values[1]).alertmanager.config.receivers : r.name], "null")
    error_message = "The chart's default Watchdog route sends to \"null\"; overriding receivers must keep it."
  }

  assert {
    condition     = alltrue([for st in jsondecode(aws_iam_role_policy.ebs[0].policy).Statement : !contains(st.Action, "ec2:CreateVolume") || try(st.Condition.StringEquals["aws:RequestTag/Cluster"] == var.cluster_name && st.Condition.StringEquals["aws:RequestTag/Environment"] == "dev", false)])
    error_message = "CSI volume creation must be scoped to the actual cluster and environment tags."
  }

}
