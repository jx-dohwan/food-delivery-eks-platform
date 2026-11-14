variable "tag_header" {
  type    = string
  default = ""
}
variable "tags" {
  type = map(string)
  validation {
    condition     = alltrue([for key in ["Project", "Environment", "ManagedBy"] : try(length(var.tags[key]) > 0, false)]) && try(var.tags["ManagedBy"] == "terraform", false)
    error_message = "Require explicit Project/Environment and ManagedBy=terraform tags."
  }
}
variable "enable" {
  description = "Explicit opt-in after verifying the management trail and Slack configuration"
  type        = bool
  default     = false
}
variable "vpc_id" {
  type = string
}
variable "management_trail_arn" {
  description = "Operator-verified active trail capturing Seoul EC2 write management events"
  type        = string
  default     = ""
}
variable "slack_webhook_url" {
  type      = string
  sensitive = true
  default   = ""
}
