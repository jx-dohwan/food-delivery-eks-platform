locals {
  karpenter_version         = "1.14.1"
  karpenter_node_class_name = "food-delivery-app"
  system_node_selector = var.enable_karpenter ? {
    "eks.amazonaws.com/nodegroup" = "${var.tag_header}nodegroup-1"
  } : {}
}

data "external" "karpenter_legacy_profile" {
  count   = var.enable_karpenter ? 1 : 0
  program = ["python3", "${path.module}/karpenter/legacy_profile.py"]
  query = {
    cluster_name    = var.cluster_name
    region          = var.region
    node_class_name = local.karpenter_node_class_name
  }
}

data "aws_caller_identity" "karpenter" {
  count = var.enable_karpenter ? 1 : 0
}

data "aws_ami" "karpenter_pinned" {
  count  = var.enable_karpenter ? 1 : 0
  owners = ["602401143452"]
  filter {
    name   = "image-id"
    values = [var.karpenter_ami_id]
  }
  filter {
    name   = "name"
    values = ["amazon-eks-node-al2023-x86_64-standard-${var.kubernetes_version}-v*"]
  }
  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

resource "aws_iam_role" "karpenter_node" {
  count = var.enable_karpenter ? 1 : 0
  name  = "${var.cluster_name}-karpenter-node"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = "sts:AssumeRole", Principal = { Service = "ec2.amazonaws.com" } }]
  })
  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "karpenter_node" {
  for_each   = var.enable_karpenter ? toset(["AmazonEKSWorkerNodePolicy", "AmazonEC2ContainerRegistryPullOnly"]) : toset([])
  role       = aws_iam_role.karpenter_node[0].name
  policy_arn = "arn:aws:iam::aws:policy/${each.key}"
}

# Static profile: runtime controller cannot create/mutate/delete IAM profiles.
resource "aws_iam_instance_profile" "karpenter" {
  count = var.enable_karpenter ? 1 : 0
  name  = "${var.cluster_name}-karpenter"
  role  = aws_iam_role.karpenter_node[0].name
  tags  = var.tags
}

resource "aws_eks_access_entry" "karpenter_node" {
  count         = var.enable_karpenter ? 1 : 0
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = aws_iam_role.karpenter_node[0].arn
  type          = "EC2_LINUX"
  tags          = var.tags
}

resource "aws_iam_role" "karpenter_controller" {
  count = var.enable_karpenter ? 1 : 0
  name  = "${var.cluster_name}-karpenter-controller"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow", Action = "sts:AssumeRoleWithWebIdentity"
      Principal = { Federated = aws_iam_openid_connect_provider.this.arn }
      Condition = { StringEquals = {
        "${replace(aws_iam_openid_connect_provider.this.url, "https://", "")}:aud" = "sts.amazonaws.com"
        "${replace(aws_iam_openid_connect_provider.this.url, "https://", "")}:sub" = "system:serviceaccount:kube-system:karpenter"
      } }
    }]
  })
  tags = var.tags
}

resource "aws_iam_role_policy" "karpenter_controller" {
  count = var.enable_karpenter ? 1 : 0
  name  = "karpenter-controller"
  role  = aws_iam_role.karpenter_controller[0].id
  # v1.14.1 NodeClass validation uses an empty (present) nodepool tag. Keep its
  # exact cluster/NodeClass context separate from normal food-delivery-app nodes.
  policy = templatefile("${path.module}/karpenter/controller-policy.json.tftpl", {
    region                      = var.region
    account_id                  = data.aws_caller_identity.karpenter[0].account_id
    cluster_name                = var.cluster_name
    node_class_name             = local.karpenter_node_class_name
    ami_id                      = var.karpenter_ami_id
    node_role_arn               = aws_iam_role.karpenter_node[0].arn
    instance_profile_arn        = aws_iam_instance_profile.karpenter[0].arn
    legacy_instance_profile_arn = "arn:aws:iam::${data.aws_caller_identity.karpenter[0].account_id}:instance-profile/${data.external.karpenter_legacy_profile[0].result.name}"
    node_sg_arn                 = "arn:aws:ec2:${var.region}:${data.aws_caller_identity.karpenter[0].account_id}:security-group/${var.node_security_group_id}"
    cluster_sg_arn              = "arn:aws:ec2:${var.region}:${data.aws_caller_identity.karpenter[0].account_id}:security-group/${aws_eks_cluster.this.vpc_config[0].cluster_security_group_id}"
    subnet_arns                 = [for id in var.subnet_ids : "arn:aws:ec2:${var.region}:${data.aws_caller_identity.karpenter[0].account_id}:subnet/${id}"]
  })
}

# EKS-created SG has no separate Terraform SG resource; only its tag lives here.
resource "aws_ec2_tag" "karpenter_cluster_sg" {
  count       = var.enable_karpenter ? 1 : 0
  resource_id = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
  key         = "karpenter.sh/discovery"
  value       = var.cluster_name
}

resource "helm_release" "karpenter_crd" {
  count      = var.enable_karpenter ? 1 : 0
  name       = "karpenter-crd"
  repository = "oci://public.ecr.aws/karpenter"
  chart      = "karpenter-crd"
  version    = local.karpenter_version
  namespace  = "kube-system"
  depends_on = [aws_eks_node_group.this]
}

resource "helm_release" "karpenter" {
  count      = var.enable_karpenter ? 1 : 0
  name       = "karpenter"
  repository = "oci://public.ecr.aws/karpenter"
  chart      = "karpenter"
  version    = local.karpenter_version
  namespace  = "kube-system"
  skip_crds  = true
  values = [yamlencode({
    replicas     = 2
    nodeSelector = local.system_node_selector
    serviceAccount = {
      name        = "karpenter"
      annotations = { "eks.amazonaws.com/role-arn" = aws_iam_role.karpenter_controller[0].arn }
    }
    controller = { resources = {
      requests = { cpu = "100m", memory = "192Mi" }
      limits   = { cpu = "500m", memory = "512Mi" }
    } }
    settings = {
      clusterName       = aws_eks_cluster.this.name
      clusterEndpoint   = aws_eks_cluster.this.endpoint
      interruptionQueue = ""
      enableZonalShift  = false
      featureGates = {
        reservedCapacity = false, spotToSpotConsolidation = false
        nodeRepair       = false, nodeOverlay = false, staticCapacity = false, capacityBuffer = false
      }
    }
  })]
  depends_on = [helm_release.karpenter_crd, aws_iam_role_policy.karpenter_controller, aws_eks_addon.coredns, helm_release.aws_lbc]
}

resource "helm_release" "karpenter_capacity" {
  count     = var.enable_karpenter ? 1 : 0
  name      = "food-delivery-karpenter-capacity"
  chart     = "${path.module}/karpenter-config"
  version   = "0.1.0"
  namespace = "kube-system"
  values = [yamlencode({
    clusterName     = var.cluster_name
    nodeClassName   = local.karpenter_node_class_name
    amiID           = data.aws_ami.karpenter_pinned[0].id
    instanceProfile = aws_iam_instance_profile.karpenter[0].name
    tags            = var.tags
    environment     = var.was_environment
  })]
  depends_on = [helm_release.karpenter, aws_eks_access_entry.karpenter_node, aws_iam_role_policy_attachment.karpenter_node, aws_ec2_tag.karpenter_cluster_sg]
}
