# ==============================================================================
# 1. Network Module
# ==============================================================================
module "network" {
  source           = "../../modules/network"
  owner            = local.owner
  vpc_cidr         = local.vpc_cidr
  tag_header       = local.tag_header
  region           = local.region
  subnet_map       = local.subnet_map
  cluster_name     = local.cluster_name
  enable_karpenter = var.enable_karpenter
}

# ==============================================================================
# 2. Security Group Module
# ==============================================================================
module "security_group" {
  cluster_name = local.cluster_name
  source       = "../../modules/security_group"
  tag_header   = local.tag_header
  vpc_id       = module.network.vpc_id
  vpc_cidr     = module.network.vpc_cidr
  tags         = local.common_tags
  # Bastion SSH: office_cidr 비우면 인바운드 닫힘 → SSM 전용
  bastion_ssh_cidr                 = var.office_cidr
  enable_rotation                  = var.enable_secret_rotation
  karpenter_discovery_cluster_name = var.enable_karpenter ? local.cluster_name : ""
}

# ==============================================================================
# 3. EKS Module (Control Plane & Node Group)
# ==============================================================================
module "eks" {
  region                 = var.region
  source                 = "../../modules/eks"
  instance_type          = var.mng_instance_type
  enable_central_logging = var.enable_central_logging
  loki_bucket_name       = var.loki_bucket_name

  tag_header                          = local.tag_header
  cluster_name                        = local.cluster_name
  vpc_id                              = module.network.vpc_id
  subnet_ids                          = module.network.private_app_subnet_ids
  node_security_group_id              = module.security_group.node_security_group_id
  enable_oss_observability            = var.enable_oss_observability
  enable_karpenter                    = var.enable_karpenter
  was_environment                     = var.environment
  was_aws_access                      = var.was_aws_access
  protected_bucket_names              = [var.terraform_state_bucket_name]
  eso_secret_names                    = [module.secrets_manager.secret_name, module.secrets_manager.connection_secret_name]
  metrics_server_kubelet_tls_verified = var.metrics_server_kubelet_tls_verified
  node_ami_id                         = var.mng_ami_id
  karpenter_ami_id                    = var.karpenter_ami_id
  karpenter_ami_verified              = var.karpenter_ami_verified

  desired_size = 2
  min_size     = 2
  max_size     = var.mng_max_size
  tags         = local.common_tags
}
# ==============================================================================
# 4. Root Outputs (EKS 접속 및 식별용)
# ==============================================================================

# EKS 클러스터 이름 (로컬 터미널 / CI 파이프라인 연동용)
output "eks_cluster_name" {
  description = "EKS Cluster Name"
  value       = module.eks.cluster_name
}

# EKS API 엔드포인트 주소
output "eks_cluster_endpoint" {
  description = "EKS API Server Endpoint"
  value       = module.eks.cluster_endpoint
}

# EKS IRSA(파드 IAM 연동)용 OIDC 공급자 ARN
output "eks_oidc_provider_arn" {
  description = "OIDC Provider ARN for IRSA"
  value       = module.eks.oidc_provider_arn
}

# ==============================================================================
# 5. Container Registry (ECR) Module
# ==============================================================================
module "ecr" {
  source           = "../../modules/ecr"
  tag_header       = local.tag_header
  repository_names = ["web", "was"]
  tags             = local.common_tags
  protected_image_tags = {
    for image in local.dev_gitops_images : trimprefix(image.name, "food-delivery-") => distinct(concat(
      [tostring(image.newTag)], lookup(var.ecr_additional_protected_shas, trimprefix(image.name, "food-delivery-"), [])
    )) if contains(["food-delivery-was", "food-delivery-web"], image.name)
  }
}

# ==============================================================================
# 6. Secrets Manager Module
# ==============================================================================
module "secrets_manager" {
  source      = "../../modules/secrets_manager"
  tag_header  = local.tag_header
  secret_name = "rds-aurora-credentials"
  db_username = "appadmin"
  tags        = local.common_tags

  db_host    = module.rds.proxy_endpoint
  db_port    = 3306
  db_name    = "fooddelivery"
  redis_host = module.redis.redis_primary_endpoint
  redis_port = module.redis.redis_port

  # 7일 Aurora 마스터 패스워드 자동 로테이션 + 실패 시 Slack(태그 기반)
  enable_rotation            = var.enable_secret_rotation
  activate_rotation          = var.activate_secret_rotation
  rotation_proxy_target_id   = module.rds.proxy_target_id
  rotation_days              = 7
  db_cluster_identifier      = module.rds.cluster_id
  db_cluster_arn             = module.rds.cluster_arn
  rotation_subnet_ids        = module.network.private_app_subnet_ids
  rotation_security_group_id = module.security_group.rotation_lambda_sg_id
  slack_webhook_url          = var.slack_webhook_url
  slack_alert_tags           = var.slack_alert_tags
}

# ==============================================================================
# 7. Database (Aurora MySQL & RDS Proxy) Module
# ==============================================================================
module "rds" {
  source = "../../modules/rds"

  tag_header              = local.tag_header
  vpc_id                  = module.network.vpc_id
  db_subnet_ids           = module.network.db_subnet_ids
  rds_security_group_id   = module.security_group.rds_sg_id
  proxy_security_group_id = module.security_group.proxy_sg_id
  database_name           = "fooddelivery"
  master_username         = module.secrets_manager.db_username
  master_password         = module.secrets_manager.db_password
  secret_arn              = module.secrets_manager.secret_arn
  tags                    = local.common_tags

}

# ==============================================================================
# 8. In-Memory Cache (ElastiCache Redis) Module
# ==============================================================================
module "redis" {
  source                  = "../../modules/redis"
  tag_header              = local.tag_header
  db_subnet_ids           = module.network.db_subnet_ids
  redis_security_group_id = module.security_group.redis_sg_id
  tags                    = local.common_tags
}

# ==============================================================================
# 9. Ops Monitoring — CloudWatch native alarms → SNS → Slack
#     AWS Alarm/Logs 전용. OSS metrics는 EKS Helm release에서 별도 관리.
# ==============================================================================
module "monitoring" {
  source = "../../modules/monitoring"

  tag_header = local.tag_header
  tags       = local.common_tags

  # plan-known: webhook 문자열은 변수라 count 판정에 안전
  enable = var.enable_ops_monitoring && var.slack_webhook_url != ""

  sns_topic_arn = module.secrets_manager.ops_alerts_topic_arn

  # Ingress ALB 존재 여부 (data source) — teardown 시 manage_ingress_alb_alias=false 로 끈다
  enable_alb_alarms           = var.manage_ingress_alb_alias
  enable_alb_unhealthy_alarm  = var.alb_target_group_arn_suffix != ""
  alb_arn_suffix              = var.manage_ingress_alb_alias ? try(data.aws_lb.app_ingress[0].arn_suffix, "") : ""
  alb_target_group_arn_suffix = var.alb_target_group_arn_suffix

  rds_instance_identifier = module.rds.writer_instance_identifier
  redis_cache_cluster_id  = module.redis.primary_cache_cluster_id
}

output "ops_monitoring_alarms" {
  description = "CloudWatch ops alarm names"
  value       = module.monitoring.alarm_names
}

# ==============================================================================
# 10. Persistent External Access Analyzer는 infra/bootstrap에서 관리
#     dev teardown과 별개로 유지하며 이 root에서는 생성하지 않음
# ==============================================================================

# ==============================================================================
# 11. WAFv2 — 환경 소유 ACL; Ingress/Controller가 ALB association 관리
# ==============================================================================
module "waf" {
  source = "../../modules/waf"

  tag_header = local.tag_header
  tags       = local.common_tags
  enable     = var.enable_waf
  rate_limit = var.waf_rate_limit
  count_mode = var.waf_count_mode
}

output "waf_web_acl_arn" {
  description = "WAFv2 WebACL ARN (enable_waf=false 이면 null)"
  value       = module.waf.web_acl_arn
}
