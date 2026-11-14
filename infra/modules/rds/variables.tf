variable "tag_header" {
  description = "리소스 접두사"
  type        = string
  default     = ""
}

variable "vpc_id" {
  description = "VPC ID"
  type        = string
}

variable "db_subnet_ids" {
  description = "Aurora RDS가 배치될 완전 격리 DB 서브넷 ID 목록 (3개 AZ)"
  type        = list(string)
}

variable "rds_security_group_id" {
  description = "보안그룹 모듈에서 생성된 RDS 전용 SG ID"
  type        = string
}

variable "proxy_security_group_id" {
  description = "보안그룹 모듈에서 생성된 RDS Proxy 전용 SG ID"
  type        = string
}

variable "database_name" {
  description = "초기 생성할 데이터베이스 이름"
  type        = string
  default     = "fooddelivery"
}

variable "master_username" {
  description = "마스터 계정명"
  type        = string
}

variable "master_password" {
  description = "마스터 패스워드"
  type        = string
  sensitive   = true
}

variable "secret_arn" {
  description = "RDS Proxy 인증에 사용할 Secrets Manager Secret ARN"
  type        = string
}

variable "tags" {
  description = "공통 태그"
  type        = map(string)
  default     = {}
}
