output "was_irsa_config" {
  value = module.eks.was_irsa_config
}
output "tracing_irsa_config" {
  value = module.eks.tracing_irsa_config
}
output "metrics_server_tls_verified" {
  value = var.metrics_server_kubelet_tls_verified
}
output "full_deploy_config" {
  value = {
    environment                 = "prod"
    region                      = var.region
    metrics_server_tls_verified = var.metrics_server_kubelet_tls_verified
    karpenter                   = { enabled = var.enable_karpenter, ami_id = var.karpenter_ami_id, verified = var.karpenter_ami_verified }
  }
}

# Do not let a manual checkbox turn this platform-only root into a complete
# application environment. DB/ESO sources/WAF/ECR ownership need a separate review.
output "runtime_bindings" {
  value = {
    environment             = "prod"
    infrastructure_complete = false
  }
}
