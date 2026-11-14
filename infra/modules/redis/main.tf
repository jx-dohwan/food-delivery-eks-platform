# ==============================================================================
# 1. ElastiCache Subnet Group
# ==============================================================================
resource "aws_elasticache_subnet_group" "this" {
  name       = "${var.tag_header}redis-subnet-group"
  subnet_ids = var.db_subnet_ids

  tags = merge(var.tags, { Name = "${var.tag_header}redis-subnet-group" })
}

# ==============================================================================
# 2. Redis Replication Group (고가용성 Multi-AZ)
# ==============================================================================
resource "aws_elasticache_replication_group" "this" {
  replication_group_id = "${var.tag_header}redis-cluster"
  description          = "Redis Replication Group for Session and Cache"

  engine         = "redis"
  engine_version = "7.1"
  node_type      = "cache.t4g.medium" # ARM 기반 고효율 Graviton 인스턴스
  port           = 6379

  num_cache_clusters         = 2 # Primary 1, Replica 1 (자동 장애 조치)
  automatic_failover_enabled = true
  multi_az_enabled           = true

  subnet_group_name  = aws_elasticache_subnet_group.this.name
  security_group_ids = [var.redis_security_group_id]

  # [보안 통제] 저장·전송 암호화. REDIS_TLS=true (앱 ConfigMap) 와 짝을 맞춤.
  at_rest_encryption_enabled = true
  transit_encryption_enabled = true

  tags = merge(var.tags, { Name = "${var.tag_header}redis-cluster" })
}
