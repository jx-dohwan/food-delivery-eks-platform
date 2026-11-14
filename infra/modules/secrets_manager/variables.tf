variable "tag_header" {
  description = "리소스 접두사 (예: dev-)"
  type        = string
  default     = ""
}

variable "secret_name" {
  description = "Secrets Manager 시크릿 이름"
  type        = string
  default     = "rds-aurora-credentials"
}

variable "tags" {
  description = "공통 태그"
  type        = map(string)
  default     = {}
}

# DB 설정 변수
variable "db_host" {
  type        = string
  description = "애플리케이션 DB 연결 엔드포인트 (RDS Proxy)"
  default     = ""
}

variable "db_port" {
  type        = number
  description = "Aurora MySQL 포트"
  default     = 3306
}

variable "db_username" {
  type        = string
  description = "Aurora MySQL 마스터 유저명"
  default     = "appadmin"
}

variable "db_name" {
  type        = string
  description = "Aurora MySQL 데이터베이스명"
  default     = "fooddelivery"
}

# Redis 설정 변수
variable "redis_host" {
  type        = string
  description = "ElastiCache Redis 엔드포인트"
  default     = ""
}

variable "redis_port" {
  type        = number
  description = "ElastiCache Redis 포트"
  default     = 6379
}

variable "enable_rotation" {
  type        = bool
  description = "Secrets Manager 7일 주기 Aurora 패스워드 로테이션 활성화"
  default     = false
}

variable "rotation_days" {
  type        = number
  description = "자동 로테이션 주기(일)"
  default     = 7
}

variable "db_cluster_identifier" {
  type        = string
  description = "Aurora cluster identifier (ModifyDBCluster용)"
  default     = ""
}

variable "db_cluster_arn" {
  type        = string
  description = "Aurora cluster ARN used to scope rotation IAM and validate the target"
  default     = ""
}

variable "rotation_subnet_ids" {
  type        = list(string)
  description = "Private application subnets with NAT access for rotation AWS APIs"
  default     = []
}

variable "rotation_security_group_id" {
  type        = string
  description = "Dedicated rotation Lambda security group"
  default     = ""
}

variable "slack_webhook_url" {
  type        = string
  description = "Ops Slack Incoming Webhook (로테이션 실패 알림)"
  default     = ""
  sensitive   = true
}

variable "slack_alert_tags" {
  type        = string
  description = "Slack mention tags on failure (e.g. <!channel>, <!here>, <@U123>)"
  default     = "<!here>"
}

variable "activate_rotation" {
  description = "Second-stage activation only after Aurora and the Proxy target are verified healthy. The initial apply creates the Lambda but no rotation schedule."
  type        = bool
  default     = false
  validation {
    condition     = !var.activate_rotation || var.enable_rotation
    error_message = "Rotation activation requires the rotation infrastructure."
  }
}

variable "rotation_proxy_target_id" {
  description = "Registered RDS Proxy target dependency; live target health must also be verified before second-stage activation."
  type        = string
  default     = ""
}
