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

run "platform" {
  command = plan
  assert {
    condition     = aws_launch_template.this.metadata_options[0].http_tokens == "required" && aws_launch_template.this.metadata_options[0].http_put_response_hop_limit == 1
    error_message = "MNG must enforce IMDSv2/hop=1 like Karpenter; applications use IRSA."
  }
  assert {
    condition     = aws_eks_cluster.this.version == "1.36" && !aws_eks_cluster.this.bootstrap_self_managed_addons
    error_message = "Pin Kubernetes 1.36 and avoid competing self-managed add-ons."
  }
  assert {
    condition     = aws_eks_cluster.this.upgrade_policy[0].support_type == "STANDARD"
    error_message = "Do not opt into paid Extended Support."
  }
  assert {
    condition     = one([for f in data.aws_ami.eks_al2023_latest.filter : f.values if f.name == "name"]) == toset(["amazon-eks-node-al2023-x86_64-standard-${aws_eks_cluster.this.version}-v*"])
    error_message = "The custom node AMI must use the cluster minor, AL2023 and x86_64."
  }
  assert {
    condition     = aws_launch_template.this.image_id == data.aws_ami.eks_al2023_latest.id && aws_launch_template.this.key_name == null
    error_message = "Use the matched node AMI without SSH keys by default."
  }
  assert {
    condition     = contains(aws_launch_template.this.vpc_security_group_ids, var.node_security_group_id) && length(aws_launch_template.this.vpc_security_group_ids) == 2
    error_message = "Keep both node SG and EKS cluster SG for control-plane traffic."
  }
  assert {
    condition     = aws_eks_addon.vpc_cni.addon_name == "vpc-cni" && aws_eks_addon.vpc_cni.addon_version == "v1.23.1-eksbuild.1" && jsondecode(aws_eks_addon.vpc_cni.configuration_values).enableNetworkPolicy == "true" && jsondecode(aws_eks_addon.vpc_cni.configuration_values).env.NETWORK_POLICY_ENFORCING_MODE == "standard"
    error_message = "A managed CNI must actually enable NetworkPolicy, using the safe startup mode."
  }
  assert {
    condition     = aws_eks_addon.coredns.addon_name == "coredns" && aws_eks_addon.coredns.addon_version == "v1.14.7-eksbuild.10" && aws_eks_addon.kube_proxy.addon_name == "kube-proxy" && aws_eks_addon.kube_proxy.addon_version == "v1.36.0-eksbuild.21"
    error_message = "Pin DNS and kube-proxy to the reviewed 1.36 versions."
  }
  assert {
    condition     = aws_eks_addon.vpc_cni.service_account_role_arn == aws_iam_role.vpc_cni.arn && aws_iam_role_policy_attachment.vpc_cni.policy_arn == "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy" && !contains(local.node_policies, "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy") && !contains(local.node_policies, "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy")
    error_message = "CNI permissions belong to aws-node IRSA, not nodes; no unused CloudWatch agent policy."
  }
  assert {
    condition     = jsondecode(aws_iam_role.vpc_cni.assume_role_policy).Statement[0].Condition.StringEquals["oidc.eks.ap-northeast-2.amazonaws.com/id/TEST:sub"] == "system:serviceaccount:kube-system:aws-node" && jsondecode(aws_iam_role.vpc_cni.assume_role_policy).Statement[0].Condition.StringEquals["oidc.eks.ap-northeast-2.amazonaws.com/id/TEST:aud"] == "sts.amazonaws.com"
    error_message = "CNI IRSA must restrict both subject and audience."
  }
  assert {
    condition     = helm_release.aws_lbc.version == "3.5.0" && endswith(data.http.lbc_iam_policy.url, "/v3.5.0/docs/install/iam_policy.json")
    error_message = "Controller chart and IAM document must use the same release."
  }
  assert {
    condition     = helm_release.aws_lbc.wait
    error_message = "The LBC gate must wait for its workload readiness, not only submit manifests."
  }
  assert {
    condition     = toset(aws_eks_cluster.this.enabled_cluster_log_types) == toset(["audit", "authenticator"]) && aws_cloudwatch_log_group.control_plane.retention_in_days == 30
    error_message = "Bound security-relevant control-plane logs to 30 days."
  }
}

run "eso_dev_secret_scope" {
  command = plan
  variables { eso_secret_names = ["audit-auth", "audit-auth-connection"] }
  assert {
    condition = jsondecode(aws_iam_policy.eso_policy.policy).Statement[0].Resource == [
      "arn:aws:secretsmanager:ap-northeast-2:123456789012:secret:audit-auth-??????",
      "arn:aws:secretsmanager:ap-northeast-2:123456789012:secret:audit-auth-connection-??????"
    ] && toset(jsondecode(aws_iam_policy.eso_policy.policy).Statement[0].Action) == toset(["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"])
    error_message = "ESO must read only the configured auth/connection secrets, without account-wide enumeration."
  }
  assert {
    condition     = jsondecode(aws_iam_role.eso_role.assume_role_policy).Statement[0].Condition.StringEquals["oidc.eks.ap-northeast-2.amazonaws.com/id/TEST:sub"] == "system:serviceaccount:app:eso-service-account"
    error_message = "Use the exact dev ESO identity."
  }
}

run "eso_prod_namespace" {
  command = plan
  variables { was_environment = "prod" }
  assert {
    condition     = jsondecode(aws_iam_role.eso_role.assume_role_policy).Statement[0].Condition.StringEquals["oidc.eks.ap-northeast-2.amazonaws.com/id/TEST:sub"] == "system:serviceaccount:app-prod:eso-service-account" && jsondecode(aws_iam_role.eso_role.assume_role_policy).Statement[0].Condition.StringEquals["oidc.eks.ap-northeast-2.amazonaws.com/id/TEST:aud"] == "sts.amazonaws.com"
    error_message = "Prod Kustomize and ESO trust must use the same namespace and audience."
  }
}

run "pinned_node_ami" {
  command = plan
  variables { node_ami_id = "ami-0123456789abcdef0" }
  assert {
    condition     = aws_launch_template.this.image_id == "ami-0123456789abcdef0"
    error_message = "A pinned node AMI must override the latest AMI lookup."
  }
}

run "reject_unreviewed_minor" {
  command = plan
  variables { kubernetes_version = "1.31" }
  expect_failures = [var.kubernetes_version]
}

run "observability_enabled" {
  command = plan
  variables { enable_oss_observability = true }
  assert {
    condition     = length(helm_release.observability) == 1 && helm_release.observability[0].version == "92.7.0" && helm_release.observability[0].namespace == "monitoring"
    error_message = "Pin one OSS monitoring release in its own namespace."
  }
  assert {
    condition     = yamldecode(helm_release.observability[0].values[0]).prometheus.prometheusSpec.retention == "12h" && yamldecode(helm_release.observability[0].values[0]).prometheus.prometheusSpec.storageSpec.emptyDir.sizeLimit == "1Gi"
    error_message = "Keep metrics short-lived and ephemeral, without EBS/PVC."
  }
  assert {
    condition     = !yamldecode(helm_release.observability[0].values[0]).alertmanager.enabled && !yamldecode(helm_release.observability[0].values[0]).grafana.persistence.enabled && !yamldecode(helm_release.observability[0].values[0]).grafana.ingress.enabled
    error_message = "No duplicate alert system, Grafana disk or public exposure."
  }
  assert {
    condition     = jsondecode(yamldecode(helm_release.observability[0].values[0]).grafana.dashboards.default.food-delivery-overview.json).uid == "food-delivery-overview"
    error_message = "Provision the Git-managed dashboard, not mutable UI state."
  }
}

run "observability_disabled" {
  command = plan
  assert {
    condition     = length(helm_release.observability) == 0
    error_message = "Disabling monitoring must not create a monitoring release."
  }
}

run "karpenter_enabled" {
  command = plan
  variables {
    enable_karpenter         = true
    karpenter_ami_id         = "ami-00000000000000001"
    karpenter_ami_verified   = true
    enable_oss_observability = true
    tags                     = { Project = "food-delivery", Environment = "dev", ManagedBy = "terraform" }
  }
  assert {
    condition     = helm_release.karpenter[0].version == "1.14.1" && helm_release.karpenter_crd[0].version == helm_release.karpenter[0].version && helm_release.karpenter[0].skip_crds
    error_message = "CRDs and controller must share a fixed version and a single owner."
  }
  assert {
    condition     = yamldecode(helm_release.karpenter[0].values[0]).nodeSelector["eks.amazonaws.com/nodegroup"] == aws_eks_node_group.this.node_group_name && yamldecode(aws_eks_addon.coredns.configuration_values).nodeSelector["eks.amazonaws.com/nodegroup"] == aws_eks_node_group.this.node_group_name
    error_message = "Controller and DNS must remain on system MNG."
  }
  assert {
    condition     = yamldecode(helm_release.observability[0].values[0]).prometheus.prometheusSpec.nodeSelector["eks.amazonaws.com/nodegroup"] == aws_eks_node_group.this.node_group_name && yamldecode(helm_release.metrics_server.values[0]).nodeSelector["eks.amazonaws.com/nodegroup"] == aws_eks_node_group.this.node_group_name
    error_message = "Monitoring and resource metrics must not depend on replaceable nodes."
  }
  assert {
    condition     = aws_eks_access_entry.karpenter_node[0].type == "EC2_LINUX" && length(aws_iam_role_policy_attachment.karpenter_node) == 2 && aws_iam_role_policy_attachment.karpenter_node["AmazonEC2ContainerRegistryPullOnly"].role == aws_iam_role.karpenter_node[0].name
    error_message = "Dedicated nodes have only worker and ECR pull permissions, no CNI/admin permissions."
  }
  assert {
    condition     = one([for s in jsondecode(aws_iam_role_policy.karpenter_controller[0].policy).Statement : s.Resource if s.Sid == "PassOnlyKarpenterNode"]) == aws_iam_role.karpenter_node[0].arn
    error_message = "PassRole must be limited to exactly the Karpenter node role."
  }
  assert {
    condition = alltrue([for sid in ["AllowNodeClassValidationActionsWithTags", "AllowNodeClassValidationCreationTagging"] :
      one([for s in jsondecode(aws_iam_role_policy.karpenter_controller[0].policy).Statement : s.Condition.StringEquals if s.Sid == sid])["aws:RequestTag/karpenter.sh/nodepool"] == "" &&
      one([for s in jsondecode(aws_iam_role_policy.karpenter_controller[0].policy).Statement : s.Condition.StringEquals if s.Sid == sid])["aws:RequestTag/karpenter.k8s.aws/ec2nodeclass"] == "food-delivery-app"
    ])
    error_message = "v1.14.1 validation requires an empty present pool tag, bounded to the one NodeClass."
  }
  assert {
    condition = alltrue([for sid in ["AllowScopedEC2InstanceActionsWithTags", "AllowScopedResourceCreationTagging"] :
      one([for s in jsondecode(aws_iam_role_policy.karpenter_controller[0].policy).Statement : s.Condition.StringLike if s.Sid == sid])["aws:RequestTag/karpenter.sh/nodepool"] == "food-delivery-app" &&
      one([for s in jsondecode(aws_iam_role_policy.karpenter_controller[0].policy).Statement : s.Condition.StringEquals if s.Sid == sid])["aws:RequestTag/karpenter.k8s.aws/ec2nodeclass"] == "food-delivery-app"
    ])
    error_message = "Actual provisioning must retain the exact allowed pool and NodeClass."
  }
  assert {
    condition     = one([for s in jsondecode(aws_iam_role_policy.karpenter_controller[0].policy).Statement : s.Action if s.Sid == "AllowNodeClassValidationLaunchTemplateDeletion"]) == "ec2:DeleteLaunchTemplate"
    error_message = "The validation deletion exception must not permit terminating empty-pool instances."
  }
  assert {
    condition     = yamldecode(helm_release.karpenter_capacity[0].values[0]).instanceProfile == aws_iam_instance_profile.karpenter[0].name && yamldecode(helm_release.karpenter_capacity[0].values[0]).amiID == data.aws_ami.karpenter_pinned[0].id
    error_message = "NodeClass must use the fixed AMI and Terraform-owned profile."
  }
  assert {
    condition     = aws_ec2_tag.karpenter_cluster_sg[0].resource_id == aws_eks_cluster.this.vpc_config[0].cluster_security_group_id && aws_ec2_tag.karpenter_cluster_sg[0].key == "karpenter.sh/discovery" && aws_ec2_tag.karpenter_cluster_sg[0].value == var.cluster_name
    error_message = "Discover the EKS cluster SG along with the existing node SG, without creating a replacement SG."
  }
}

run "karpenter_disabled" {
  command = plan
  assert {
    condition     = length(helm_release.karpenter) == 0 && length(aws_iam_role.karpenter_node) == 0 && length(helm_release.karpenter_capacity) == 0
    error_message = "Default must create no Karpenter capacity or IAM."
  }
}

run "reject_unverified_karpenter_ami" {
  command = plan
  variables { enable_karpenter = true }
  expect_failures = [var.karpenter_ami_id]
}
