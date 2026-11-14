# ==============================================================================
# 1. S3 Gateway Endpoint
# ==============================================================================
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"

  # Public 1개 + DB 1개 + Private 3개(a, b, c) = 총 5개 라우팅 테이블 바인딩
  route_table_ids = concat(
    [aws_route_table.public.id, aws_route_table.db.id],
    [for rt in aws_route_table.private : rt.id]
  )

  tags = { Name = "${var.tag_header}s3-gw-endpoint" }
}
# ==============================================================================
# 2. ECR Interface Endpoints (API & DKR)
# ==============================================================================
# ECR API Interface Endpoint
resource "aws_vpc_endpoint" "ecr_api" {
  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${var.region}.ecr.api"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true

  # AZ별 프라이빗 서브넷 3개 자동 선택 (정상)
  subnet_ids         = [for k, v in aws_subnet.this : v.id if v.tags["Type"] == "private"]
  security_group_ids = [aws_security_group.endpoint_sg.id]
  tags               = { Name = "${var.tag_header}ecr-api-endpoint" }
}

# ECR DKR Interface Endpoint (도커 이미지 레이어 통신용)
resource "aws_vpc_endpoint" "ecr_dkr" {
  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${var.region}.ecr.dkr"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true

  subnet_ids         = [for k, v in aws_subnet.this : v.id if v.tags["Type"] == "private"]
  security_group_ids = [aws_security_group.endpoint_sg.id]
  tags               = { Name = "${var.tag_header}ecr-dkr-endpoint" }
}

# ==============================================================================
# 3. VPC Endpoint 전용 보안 그룹
# ==============================================================================
resource "aws_security_group" "endpoint_sg" {
  name        = "${var.tag_header}vpc-endpoint-sg"
  description = "Security group for VPC Endpoints"
  vpc_id      = aws_vpc.this.id

  ingress {
    description = "Allow HTTPS from VPC"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.tag_header}vpc-endpoint-sg"
  }
}
