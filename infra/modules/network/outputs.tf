# ==============================================================================
# VPC 기본 정보 출력
# ==============================================================================
output "vpc_id" {
  description = "생성된 VPC ID"
  value       = aws_vpc.this.id
}

output "vpc_cidr" {
  description = "생성된 VPC CIDR 대역 (보안 그룹 및 EKS 노드 규칙용)"
  value       = aws_vpc.this.cidr_block
}

# ==============================================================================
# 서브넷 객체 및 계층별 ID 목록
# ==============================================================================
output "subnets" {
  description = "생성된 전체 서브넷 리소스 맵"
  value       = aws_subnet.this
}

# 1. 퍼블릭 서브넷 (ALB, NAT Gateway, Bastion용)
output "public_subnet_ids" {
  description = "퍼블릭 서브넷 ID 목록"
  value = [
    for k, v in aws_subnet.this : v.id if var.subnet_map[k].type == "public"
  ]
}
output "db_subnet_ids" {
  description = "List of DB subnet IDs"
  value       = [for k, v in aws_subnet.this : v.id if v.tags["Type"] == "db"]
}

# 기존 코드 호환용
output "public_subnets" {
  description = "기존 호환용 퍼블릭 서브넷 ID 목록"
  value       = [for k, v in aws_subnet.this : v.id if var.subnet_map[k].type == "public"]
}

# 2. 프라이빗 앱 서브넷 (EKS 워커 노드 / 파드 배치용)
output "private_subnet_ids" {
  description = "프라이빗 서브넷 ID 목록"
  value = [
    for k, v in aws_subnet.this : v.id if var.subnet_map[k].type == "private"
  ]
}

# dev/main.tf에서 private_app_subnet_ids로 호출할 경우를 대비한 별칭(Alias)
output "private_app_subnet_ids" {
  description = "EKS 워커 노드가 배치될 프라이빗 서브넷 ID 목록 (호환용)"
  value = [
    for k, v in aws_subnet.this : v.id if var.subnet_map[k].type == "private"
  ]
}

# 3. 데이터베이스 / 클러스터 서브넷 (RDS, Redis용)
output "cluster_subnet_ids" {
  description = "데이터베이스/클러스터 전용 서브넷 ID 목록"
  value = [
    for k, v in aws_subnet.this : v.id if var.subnet_map[k].type == "cluster" || var.subnet_map[k].type == "db"
  ]
}
