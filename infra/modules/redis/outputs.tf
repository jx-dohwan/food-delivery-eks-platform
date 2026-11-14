output "redis_primary_endpoint" {
  description = "Redis 쓰기/읽기 기본 엔드포인트"
  value       = aws_elasticache_replication_group.this.primary_endpoint_address
}

output "redis_port" {
  description = "Redis 통신 포트"
  value       = aws_elasticache_replication_group.this.port
}

output "replication_group_id" {
  description = "ElastiCache replication group id"
  value       = aws_elasticache_replication_group.this.replication_group_id
}

output "primary_cache_cluster_id" {
  description = "Primary member CacheClusterId (CloudWatch dimension)"
  value       = sort(tolist(aws_elasticache_replication_group.this.member_clusters))[0]
}
