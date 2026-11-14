# ==============================================================================
# 1. Bastion Host 보안 그룹
# ==============================================================================
resource "aws_security_group" "bastion" {
  name        = "${var.tag_header}bastion-sg"
  description = "Security group for Bastion Host (SSH locked; prefer SSM Session Manager)"
  vpc_id      = var.vpc_id

  # SSH: office_cidr(/32)만 허용. 비우면 인바운드 없음 → SSM Session Manager 전용
  dynamic "ingress" {
    for_each = var.bastion_ssh_cidr != "" ? [var.bastion_ssh_cidr] : []
    content {
      description = "SSH from admin CIDR only"
      from_port   = 22
      to_port     = 22
      protocol    = "tcp"
      cidr_blocks = [ingress.value]
    }
  }

  egress {
    description = "Allow all outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${var.tag_header}bastion-sg" })
}

# ==============================================================================
# 2. Application Load Balancer (ALB) 보안 그룹
# ==============================================================================
resource "aws_security_group" "alb_sg" {
  name        = "${var.tag_header}alb-sg"
  description = "Security group for Internet-facing Application Load Balancer"
  vpc_id      = var.vpc_id

  ingress {
    description = "Allow HTTP from Internet"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Allow HTTPS from Internet"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Allow all outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${var.tag_header}alb-sg" })
}

# ==============================================================================
# 3. EKS 워커 노드 보안 그룹 (ALB SG 체이닝)
# ==============================================================================
resource "aws_security_group" "node_sg" {
  name        = "${var.tag_header}k8s-node-sg"
  description = "Security group for EKS worker nodes"
  vpc_id      = var.vpc_id

  # 노드 간 오버레이 네트워크 통신 완전 허용
  ingress {
    description = "Allow node-to-node communication"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    self        = true
  }

  # Nodes also attach the EKS cluster SG (see eks/main.tf). Its self-reference
  # carries control-plane/kubelet/webhook traffic; no VPC-wide rule is needed.
  # All Services are ClusterIP and ALB target-type=ip: no NodePort range.
  # [체이닝] ALB -> Pod IP (target-type: ip 모드 대응)
  ingress {
    description     = "Allow ALB HTTP and health checks to Web Pods only"
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.alb_sg.id]
  }

  egress {
    description = "Allow all outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(
    var.tags,
    {
      Name                                                                                              = "${var.tag_header}k8s-node-sg"
      "kubernetes.io/cluster/${var.cluster_name != "" ? var.cluster_name : "${var.tag_header}cluster"}" = "owned"
    },
    var.karpenter_discovery_cluster_name != "" ? {
      "karpenter.sh/discovery" = var.karpenter_discovery_cluster_name
    } : {}
  )
}

# ==============================================================================
# 4. RDS Proxy 보안 그룹 (EKS -> Proxy -> Aurora SG 체이닝)
# ==============================================================================
resource "aws_security_group" "proxy_sg" {
  name        = "${var.tag_header}rds-proxy-sg"
  description = "Security group for RDS Proxy"
  vpc_id      = var.vpc_id

  ingress {
    description     = "Allow MySQL access from EKS Worker Nodes"
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_security_group.node_sg.id]
  }

  egress {
    description = "Allow all outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${var.tag_header}rds-proxy-sg" })
}

# ==============================================================================
# 5. 데이터베이스 (Aurora RDS) 보안 그룹 (Proxy SG 체이닝)
# ==============================================================================
resource "aws_security_group" "rds_sg" {
  name        = "${var.tag_header}rds-sg"
  description = "Security group for Aurora MySQL cluster"
  vpc_id      = var.vpc_id

  ingress {
    description     = "Allow MySQL access strictly from RDS Proxy"
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_security_group.proxy_sg.id]
  }

  # Rotation validates the actual database credential, independently of Proxy.
  dynamic "ingress" {
    for_each = var.enable_rotation ? [1] : []
    content {
      description     = "MySQL credential validation from rotation Lambda only"
      from_port       = 3306
      to_port         = 3306
      protocol        = "tcp"
      security_groups = [aws_security_group.rotation_lambda_sg[0].id]
    }
  }

  egress {
    description = "Allow outbound for maintenance"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${var.tag_header}rds-sg" })
}

# No incoming connections are required. HTTPS reaches AWS APIs through the
# existing NAT; this VPC has no Secrets Manager or RDS interface endpoint.
resource "aws_security_group" "rotation_lambda_sg" {
  count       = var.enable_rotation ? 1 : 0
  name        = "${var.tag_header}secrets-rotation-lambda-sg"
  description = "Security group for Aurora credential rotation Lambda"
  vpc_id      = var.vpc_id

  tags = merge(var.tags, { Name = "${var.tag_header}secrets-rotation-lambda-sg" })
}

resource "aws_security_group_rule" "rotation_https_egress" {
  count             = var.enable_rotation ? 1 : 0
  type              = "egress"
  description       = "AWS Secrets Manager and RDS HTTPS APIs via NAT"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  security_group_id = aws_security_group.rotation_lambda_sg[0].id
  cidr_blocks       = ["0.0.0.0/0"]
}

# Keep this direction outside both inline SGs to avoid an SG dependency cycle.
resource "aws_security_group_rule" "rotation_mysql_egress" {
  count                    = var.enable_rotation ? 1 : 0
  type                     = "egress"
  description              = "MySQL to Aurora only"
  from_port                = 3306
  to_port                  = 3306
  protocol                 = "tcp"
  security_group_id        = aws_security_group.rotation_lambda_sg[0].id
  source_security_group_id = aws_security_group.rds_sg.id
}

# ==============================================================================
# 6. 캐시 (ElastiCache Redis) 보안 그룹 (워커 노드 SG 체이닝)
# ==============================================================================
resource "aws_security_group" "redis_sg" {
  name        = "${var.tag_header}redis-sg"
  description = "Security group for ElastiCache Redis cluster"
  vpc_id      = var.vpc_id

  ingress {
    description     = "Allow Redis access strictly from EKS Worker Nodes"
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    security_groups = [aws_security_group.node_sg.id]
  }

  egress {
    description = "Allow all outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${var.tag_header}redis-sg" })
}
