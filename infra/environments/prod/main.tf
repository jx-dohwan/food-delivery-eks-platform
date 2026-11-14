# main.tf

# ==============================================================================
# 1. Network Module
# ==============================================================================
module "network" {
  source           = "../../modules/network"
  owner            = local.owner
  vpc_cidr         = local.vpc_cidr
  tag_header       = local.platform_tag_header
  region           = local.region
  subnet_map       = local.subnet_map
  cluster_name     = var.cluster_name
  enable_karpenter = var.enable_karpenter
  tags             = local.common_tags
}

module "security_group" {
  cluster_name                     = var.cluster_name
  source                           = "../../modules/security_group"
  tag_header                       = local.platform_tag_header
  vpc_id                           = module.network.vpc_id
  vpc_cidr                         = var.vpc_cidr
  tags                             = local.common_tags
  bastion_ssh_cidr                 = var.office_cidr
  karpenter_discovery_cluster_name = var.enable_karpenter ? var.cluster_name : ""
}

# ==============================================================================
# 2. Shared Store (S3 & EFS)
# ==============================================================================
resource "aws_s3_bucket" "state" {
  bucket = "${local.tag_header}state-bucket-2026"
  lifecycle { prevent_destroy = true }
}

resource "aws_s3_bucket" "website" {
  bucket = "${local.tag_header}website-bucket-2026"
  lifecycle { prevent_destroy = true }
}

resource "aws_s3_bucket" "log" {
  bucket = "${local.tag_header}log-bucket-2026"
  lifecycle { prevent_destroy = true }
}

resource "aws_efs_file_system" "main" {
  creation_token = "${local.tag_header}efs"
  tags           = { Name = "${local.tag_header}efs" }
  lifecycle { prevent_destroy = true }
}

# ==============================================================================
# 3. EKS Module (Control Plane & Node Group)
# ==============================================================================
# main.tf의 module "eks" 블록 수정
module "eks" {
  source                              = "../../modules/eks"
  cluster_name                        = var.cluster_name
  tag_header                          = local.platform_tag_header
  region                              = var.region
  vpc_id                              = module.network.vpc_id
  subnet_ids                          = module.network.private_app_subnet_ids
  node_security_group_id              = module.security_group.node_security_group_id
  instance_type                       = "t3.medium"
  was_environment                     = "prod"
  was_aws_access                      = var.was_aws_access
  protected_bucket_names              = [var.terraform_state_bucket_name]
  enable_oss_observability            = var.enable_oss_observability
  enable_karpenter                    = var.enable_karpenter
  karpenter_ami_id                    = var.karpenter_ami_id
  karpenter_ami_verified              = var.karpenter_ami_verified
  metrics_server_kubelet_tls_verified = var.metrics_server_kubelet_tls_verified
  tags                                = local.common_tags
}
# ==============================================================================
# 4. Root Outputs
# ==============================================================================
# output "alb_dns_name" {
#   description = "Application Load Balancer DNS Endpoint"
#   value       = module.compute.alb_dns_name
# }

output "eks_cluster_name" {
  description = "EKS Cluster Name"
  value       = module.eks.cluster_name
}

output "eks_cluster_endpoint" {
  description = "EKS API Endpoint"
  value       = module.eks.cluster_endpoint
}
