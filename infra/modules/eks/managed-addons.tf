# Pinned together for Kubernetes 1.36. Recheck availability in ap-northeast-2
# with describe-addon-versions before Full Deploy; never resolve "most_recent".
locals {
  managed_addon_versions = {
    vpc_cni    = "v1.23.1-eksbuild.1"
    coredns    = "v1.14.7-eksbuild.10"
    kube_proxy = "v1.36.0-eksbuild.21"
  }
}

# Install networking before compute with dedicated aws-node IRSA. Do not
# introduce a second aws-node DaemonSet or a Pod Identity migration.
resource "aws_eks_addon" "vpc_cni" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "vpc-cni"
  addon_version               = local.managed_addon_versions.vpc_cni
  service_account_role_arn    = aws_iam_role.vpc_cni.arn
  resolve_conflicts_on_create = "NONE"
  resolve_conflicts_on_update = "NONE"
  configuration_values = jsonencode({
    enableNetworkPolicy = "true"
    env = {
      NETWORK_POLICY_ENFORCING_MODE = "standard"
    }
    nodeAgent = {
      enablePolicyEventLogs = "false"
      enableCloudWatchLogs  = "false"
    }
  })
  tags       = var.tags
  depends_on = [aws_iam_role_policy_attachment.vpc_cni]
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "kube-proxy"
  addon_version               = local.managed_addon_versions.kube_proxy
  resolve_conflicts_on_create = "NONE"
  resolve_conflicts_on_update = "NONE"
  tags                        = var.tags
}

# CoreDNS needs schedulable nodes to become healthy. Managed CoreDNS owns its
# own PDB; no duplicate PDB/Corefile/Deployment is managed in GitOps.
resource "aws_eks_addon" "coredns" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "coredns"
  addon_version               = local.managed_addon_versions.coredns
  resolve_conflicts_on_create = "NONE"
  resolve_conflicts_on_update = "NONE"
  configuration_values        = var.enable_karpenter ? jsonencode({ nodeSelector = local.system_node_selector }) : null
  tags                        = var.tags
  depends_on                  = [aws_eks_node_group.this]
}

# Security-relevant control-plane events, with bounded storage. Other log
# categories and the wider observability stack remain outside this change.
resource "aws_cloudwatch_log_group" "control_plane" {
  name              = "/aws/eks/${var.cluster_name}/cluster"
  retention_in_days = 30
  tags              = var.tags
}
