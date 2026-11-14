# ==============================================================================
# Security Group Outputs
# ==============================================================================

# EKS 워커 노드 보안 그룹 ID (EKS 모듈 주입용)
output "node_security_group_id" {
  description = "Security Group ID for EKS Worker Nodes"
  value       = aws_security_group.node_sg.id
}

# Bastion Host 보안 그룹 ID
output "bastion_sg_id" {
  description = "Security Group ID for Bastion Host"
  value       = aws_security_group.bastion.id
}

# ALB 보안 그룹 ID
output "alb_sg_id" {
  description = "Security Group ID for Internet-facing ALB"
  value       = aws_security_group.alb_sg.id
}

# RDS Proxy 보안 그룹 ID (RDS 모듈 주입용)
output "proxy_sg_id" {
  description = "Security Group ID for RDS Proxy"
  value       = aws_security_group.proxy_sg.id
}

output "rotation_lambda_sg_id" {
  description = "Security group for the optional Aurora rotation Lambda"
  value       = try(aws_security_group.rotation_lambda_sg[0].id, "")
  depends_on = [
    aws_security_group_rule.rotation_mysql_egress,
    aws_security_group_rule.rotation_https_egress
  ]
}

# Aurora RDS 보안 그룹 ID (RDS 모듈 주입용)
output "rds_sg_id" {
  description = "Security Group ID for Aurora RDS"
  value       = aws_security_group.rds_sg.id
}

# ElastiCache Redis 보안 그룹 ID (Redis 모듈 주입용)
output "redis_sg_id" {
  description = "Security Group ID for ElastiCache Redis"
  value       = aws_security_group.redis_sg.id
}
