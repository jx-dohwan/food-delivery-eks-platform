variable "tag_header" {
  description = "리소스 접두사"
  type        = string
  default     = ""
}

variable "db_subnet_ids" {
  description = "Redis가 배치될 서브넷 ID 목록 (3개 AZ)"
  type        = list(string)
}

variable "redis_security_group_id" {
  description = "보안그룹 모듈에서 생성된 Redis 전용 SG ID"
  type        = string
}

variable "tags" {
  description = "공통 태그"
  type        = map(string)
  default     = {}
}
