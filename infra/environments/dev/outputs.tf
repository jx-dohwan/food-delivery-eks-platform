# ECR 주소
output "ecr_web_url" {
  value = module.ecr.repository_urls["web"]
}

output "was_irsa_config" {
  value = module.eks.was_irsa_config
}

output "tracing_irsa_config" {
  value = module.eks.tracing_irsa_config
}

output "ecr_was_url" {
  value = module.ecr.repository_urls["was"]
}

# RDS Proxy 주소 (WAS 및 migration Job의 DB_HOST)
output "rds_proxy_endpoint" {
  value = module.rds.proxy_endpoint
}

# Redis 주소
output "redis_endpoint" {
  value = module.redis.redis_primary_endpoint
}

output "waf_web_acl_id" {
  description = "Dev Regional Web ACL ID for operator verification"
  value       = module.waf.web_acl_id
}

output "waf_ingress_config" {
  description = "Explicit WAF state for the dev GitOps Ingress renderer (including disabled state)"
  value = {
    environment = var.environment
    enabled     = var.enable_waf
    web_acl_arn = module.waf.web_acl_arn
  }
}
output "metrics_server_tls_verified" {
  value = var.metrics_server_kubelet_tls_verified
}
output "full_deploy_config" {
  value = {
    environment                 = var.environment
    region                      = var.region
    metrics_server_tls_verified = var.metrics_server_kubelet_tls_verified
    karpenter                   = { enabled = var.enable_karpenter, ami_id = var.karpenter_ami_id, verified = var.karpenter_ami_verified }
  }
}

output "runtime_bindings" {
  description = "Non-secret Terraform-to-GitOps bindings; publish before application sync."
  value = {
    infrastructure_complete = true
    environment             = var.environment
    namespace               = "app"
    account_id              = data.aws_caller_identity.runtime.account_id
    region                  = var.region
    cluster_name            = module.eks.cluster_name
    vpc_cidr                = module.network.vpc_cidr
    public_subnet_cidrs     = sort([for subnet in values(local.subnet_map) : subnet.cidr if subnet.type == "public"])
    private_subnet_cidrs    = sort([for subnet in values(local.subnet_map) : subnet.cidr if subnet.type == "private"])
    alb_security_group_id   = module.security_group.alb_sg_id
    eso                     = module.eks.eso_irsa_config
    db_proxy_endpoint       = module.rds.proxy_endpoint
    redis_endpoint          = module.redis.redis_primary_endpoint
    ecr_urls                = module.ecr.repository_urls
    waf                     = { enabled = var.enable_waf, web_acl_arn = module.waf.web_acl_arn }
  }
}

output "secret_rotation_schedule_enabled" {
  description = "False during initialization; activate only after live Proxy health verification."
  value       = module.secrets_manager.rotation_schedule_enabled
}
