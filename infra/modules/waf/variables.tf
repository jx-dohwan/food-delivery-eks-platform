variable "tag_header" {
  description = "리소스 접두사용 태그 헤더"
  type        = string
  default     = ""
}

variable "tags" {
  description = "공통 태그"
  type        = map(string)
  default     = {}
}

variable "enable" {
  description = "Environment WAFv2 Web ACL creation switch (disabled by default for cost control)"
  type        = bool
  default     = false
}

variable "rate_limit" {
  description = "Coarse source-IP request budget over 300 seconds"
  type        = number
  default     = 6000
  validation {
    condition     = var.rate_limit >= 10 && var.rate_limit <= 2000000000 && floor(var.rate_limit) == var.rate_limit
    error_message = "WAF rate limit must be an integer between 10 and 2000000000."
  }
}

variable "count_mode" {
  description = "Observe all rules in Count before restoring managed actions and Rate Block"
  type        = bool
  default     = true
}
