variable "tag_header" {
  type        = string
  description = "리소스 접두사 (예: hdg-)"
  default     = ""
}

variable "tags" {
  type        = map(string)
  description = "공통 태그"
  default     = {}
}

variable "enable" {
  type        = bool
  description = "CloudWatch ops 알람 활성화 (root에서 webhook 유무까지 반영한 known bool)"
  default     = true
}

variable "sns_topic_arn" {
  type        = string
  description = "알람 액션용 SNS 토픽 ARN (ops-alerts)"
  default     = ""
}

variable "enable_alb_alarms" {
  type        = bool
  description = "Ingress ALB 가 있을 때만 true (plan-known)"
  default     = false
}

variable "enable_alb_unhealthy_alarm" {
  type        = bool
  description = "TG arn_suffix 를 넣었을 때만 UnHealthyHostCount 알람"
  default     = false
}

variable "alb_arn_suffix" {
  type        = string
  description = "ALB CloudWatch dimension LoadBalancer (arn_suffix)"
  default     = ""
}

variable "alb_target_group_arn_suffix" {
  type        = string
  description = "TargetGroup CloudWatch dimension (arn_suffix)"
  default     = ""
}

variable "alb_5xx_threshold" {
  type        = number
  description = "1분 Sum 5xx 임계값"
  default     = 10
}

variable "rds_instance_identifier" {
  type        = string
  description = "Aurora writer(또는 1번) 인스턴스 identifier"
  default     = ""
}

variable "rds_cpu_threshold" {
  type        = number
  description = "RDS CPUUtilization Average % 임계값"
  default     = 80
}

variable "rds_freeable_memory_bytes" {
  type        = number
  description = "FreeableMemory 하한(bytes). 기본 ~256MiB"
  default     = 268435456
}

variable "redis_cache_cluster_id" {
  type        = string
  description = "ElastiCache member CacheClusterId (예: xxx-redis-cluster-001)"
  default     = ""
}

variable "redis_cpu_threshold" {
  type        = number
  description = "Redis CPUUtilization Average % 임계값"
  default     = 80
}
