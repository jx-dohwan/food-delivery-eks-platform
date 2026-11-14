# ==============================================================================
# 1. DB 서브넷 그룹 (3개 AZ의 격리 서브넷 묶음)
# ==============================================================================
resource "aws_db_subnet_group" "this" {
  name        = "${var.tag_header}db-subnet-group"
  subnet_ids  = var.db_subnet_ids
  description = "Air-gapped database subnet group across 3 AZs"

  tags = merge(var.tags, { Name = "${var.tag_header}db-subnet-group" })
}

# ==============================================================================
# 2. Aurora MySQL Serverless/Provisioned 클러스터
# ==============================================================================
resource "aws_rds_cluster" "this" {
  cluster_identifier     = "${var.tag_header}aurora-mysql-cluster"
  engine                 = "aurora-mysql"
  engine_version         = "8.0.mysql_aurora.3.08.2"
  database_name          = var.database_name
  master_username        = var.master_username
  master_password        = var.master_password
  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [var.rds_security_group_id]

  skip_final_snapshot = true # 개발/실습 환경용 (운영 승격 시 false 전환)
  deletion_protection = false

  # 저장 중 암호화 (기본 aws/rds KMS — 추가 요금 없음). 생성 시에만 설정 가능.
  storage_encrypted = true

  backup_retention_period = 7
  preferred_backup_window = "18:00-19:00" # UTC 기준 (한국 시각 새벽 3~4시)

  # Only the initial password is supplied by Terraform. Rotation owns updates.
  lifecycle {
    ignore_changes = [master_password]
  }

  tags = merge(var.tags, { Name = "${var.tag_header}aurora-mysql-cluster" })
}

# 다중 가용 영역(Multi-AZ) 고가용성을 위한 인스턴스 2기 (Writer 1, Reader 1)
resource "aws_rds_cluster_instance" "instances" {
  count               = 2
  identifier          = "${var.tag_header}aurora-instance-${count.index + 1}"
  cluster_identifier  = aws_rds_cluster.this.id
  instance_class      = "db.t4g.medium" # 비용과 성능이 균형 잡힌 Graviton 인스턴스
  engine              = aws_rds_cluster.this.engine
  engine_version      = aws_rds_cluster.this.engine_version
  publicly_accessible = false

  tags = merge(var.tags, { Name = "${var.tag_header}aurora-instance-${count.index + 1}" })
}

# ==============================================================================
# 3. RDS Proxy 전진 배치 (Connection Pooling & Shield)
# ==============================================================================

# Proxy가 Secrets Manager를 읽어 DB에 대신 인증하기 위한 IAM Role
resource "aws_iam_role" "proxy_role" {
  name = "${var.tag_header}rds-proxy-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "rds.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "proxy_secrets" {
  name = "${var.tag_header}rds-proxy-secrets-policy"
  role = aws_iam_role.proxy_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action   = ["secretsmanager:GetSecretValue"]
      Effect   = "Allow"
      Resource = [var.secret_arn]
    }]
  })
}

# RDS Proxy 본체
resource "aws_db_proxy" "this" {
  name                   = "${var.tag_header}aurora-proxy"
  debug_logging          = false
  engine_family          = "MYSQL"
  idle_client_timeout    = 1800
  require_tls            = true
  role_arn               = aws_iam_role.proxy_role.arn
  vpc_security_group_ids = [var.proxy_security_group_id]
  vpc_subnet_ids         = var.db_subnet_ids

  auth {
    auth_scheme = "SECRETS"
    description = "Authenticate via Secrets Manager"
    iam_auth    = "DISABLED"
    secret_arn  = var.secret_arn
  }

  tags = merge(var.tags, { Name = "${var.tag_header}aurora-proxy" })

  depends_on = [
    aws_iam_role_policy.proxy_secrets,
    aws_rds_cluster_instance.instances
  ]
}

# Proxy와 Aurora Cluster 바인딩
resource "aws_db_proxy_default_target_group" "this" {
  db_proxy_name = aws_db_proxy.this.name

  connection_pool_config {
    connection_borrow_timeout    = 120
    max_connections_percent      = 90
    max_idle_connections_percent = 50
  }
}

resource "aws_db_proxy_target" "cluster" {
  db_proxy_name         = aws_db_proxy.this.name
  target_group_name     = aws_db_proxy_default_target_group.this.name
  db_cluster_identifier = aws_rds_cluster.this.id
}
