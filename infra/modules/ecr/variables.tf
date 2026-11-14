variable "tag_header" {
  description = "리소스 접두사"
  type        = string
  default     = ""
}

variable "repository_names" {
  description = "생성할 ECR 레포지토리 목록 (web, was)"
  type        = list(string)
  default     = ["web", "was"]
}

variable "tags" {
  description = "공통 태그"
  type        = map(string)
  default     = {}
}

variable "protected_image_tags" {
  description = "Up to five exact immutable deployed/rollback SHAs per logical repository; refresh with deployment state"
  type        = map(list(string))
  default     = {}
  validation {
    condition = alltrue([for repository, shas in var.protected_image_tags :
      contains(var.repository_names, repository) && length(shas) <= 5 && alltrue([for sha in shas : can(regex("^[0-9a-f]{40}$", sha))])
    ])
    error_message = "Protect only existing logical repositories and at most five full SHA tags each."
  }
}
