# ==============================================================================
# 1. EKS Control Plane Cluster
# ==============================================================================
resource "aws_eks_cluster" "this" {
  name     = var.cluster_name
  role_arn = aws_iam_role.cluster_role.arn
  version  = var.kubernetes_version
  # These components are owned exclusively by aws_eks_addon resources.
  bootstrap_self_managed_addons = false
  enabled_cluster_log_types     = ["audit", "authenticator"]

  kubernetes_network_config {
    ip_family = "ipv4"
  }

  upgrade_policy {
    support_type = "STANDARD"
  }

  vpc_config {
    subnet_ids              = var.subnet_ids
    endpoint_private_access = true
    endpoint_public_access  = true
    # 필요 시 클러스터 전용 SG 주입 가능 (미지정 시 AWS 기본 클러스터 SG 자동 생성)
  }

  access_config {
    authentication_mode                         = "API_AND_CONFIG_MAP"
    bootstrap_cluster_creator_admin_permissions = true
  }

  depends_on = [aws_iam_role_policy_attachment.cluster_policy, aws_cloudwatch_log_group.control_plane]

  tags = merge(
    var.tags,
    {
      Name = "${var.tag_header}eks-cluster"
    }
  )
}

# ==============================================================================
# 2. IRSA 연동을 위한 IAM OIDC Provider
# ==============================================================================
data "tls_certificate" "this" {
  url = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "this" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.this.certificates[0].sha1_fingerprint]
  url             = aws_eks_cluster.this.identity[0].oidc[0].issuer

  tags = merge(
    var.tags,
    {
      Name = "${var.tag_header}eks-irsa-provider"
    }
  )
}

# ==============================================================================
# 3. AL2023 AMI 검색 및 시작 템플릿 (Launch Template)
# ==============================================================================
data "aws_ami" "eks_al2023_latest" {
  most_recent = true
  owners      = ["602401143452"]

  filter {
    name   = "name"
    values = ["amazon-eks-node-al2023-x86_64-standard-${var.kubernetes_version}-v*"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

resource "aws_launch_template" "this" {
  name_prefix   = "${var.tag_header}k8s-node-"
  image_id      = var.node_ami_id != "" ? var.node_ami_id : data.aws_ami.eks_al2023_latest.id
  instance_type = var.instance_type
  key_name      = var.key_name != "" ? var.key_name : null

  # [핵심] security_group 모듈에서 생성된 Node SG ID와 클러스터 기본 SG 결합
  vpc_security_group_ids = [
    var.node_security_group_id,
    aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
  ]

  update_default_version = true

  # Host kubelet may use IMDS; ordinary Pods use their own IRSA identity.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  user_data = base64encode(<<-EOT
    ---
    apiVersion: node.eks.aws/v1alpha1
    kind: NodeConfig
    spec:
      cluster:
        name: ${aws_eks_cluster.this.name}
        apiServerEndpoint: ${aws_eks_cluster.this.endpoint}
        certificateAuthority: ${aws_eks_cluster.this.certificate_authority[0].data}
        cidr: ${aws_eks_cluster.this.kubernetes_network_config[0].service_ipv4_cidr}
  EOT
  )

  tag_specifications {
    resource_type = "instance"
    tags = merge(
      var.tags,
      {
        Name                                        = "${var.tag_header}k8s-node"
        "kubernetes.io/cluster/${var.cluster_name}" = "owned"
      }
    )
  }

  tag_specifications {
    resource_type = "volume"
    tags = merge(
      var.tags,
      {
        Name = "${var.tag_header}k8s-volume"
      }
    )
  }

  tags = merge(
    var.tags,
    {
      Name = "${var.tag_header}launch-template"
    }
  )
}

# ==============================================================================
# 4. Managed Node Group
# ==============================================================================
resource "aws_eks_node_group" "this" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "${var.tag_header}nodegroup-1"
  node_role_arn   = aws_iam_role.node_role.arn
  subnet_ids      = var.subnet_ids

  # The LT supplies a custom AMI ID, so EKS forbids version/ami_type here.
  # Its AL2023 AMI name filter uses the same kubernetes_version as the cluster.

  scaling_config {
    desired_size = var.desired_size
    min_size     = var.min_size
    max_size     = var.max_size
  }

  launch_template {
    name    = aws_launch_template.this.name
    version = aws_launch_template.this.latest_version
  }

  update_config {
    max_unavailable = 1
  }

  depends_on = [
    aws_iam_role_policy_attachment.node_policy,
    aws_eks_addon.vpc_cni,
    aws_eks_addon.kube_proxy
  ]

  tags = merge(
    var.tags,
    {
      Name = "${var.tag_header}nodegroup-1"
    }
  )
}

# ==============================================================================
# 5. EKS Access Entry 관리자 권한 부여
# ==============================================================================
resource "aws_eks_access_entry" "admin" {
  count             = var.admin_principal_arn != "" ? 1 : 0
  cluster_name      = aws_eks_cluster.this.name
  principal_arn     = var.admin_principal_arn
  kubernetes_groups = ["master"]
  type              = "STANDARD"
}

resource "aws_eks_access_policy_association" "admin" {
  count         = var.admin_principal_arn != "" ? 1 : 0
  cluster_name  = aws_eks_cluster.this.name
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
  principal_arn = aws_eks_access_entry.admin[0].principal_arn

  access_scope {
    type = "cluster"
  }

  depends_on = [aws_eks_access_entry.admin]
}
