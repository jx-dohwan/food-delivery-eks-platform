module "sg_auto_remediation" {
  source = "../../modules/sg_auto_remediation"

  enable               = var.enable_sg_auto_remediation
  tag_header           = local.tag_header
  tags                 = local.common_tags
  vpc_id               = module.network.vpc_id
  management_trail_arn = var.sg_management_trail_arn
  slack_webhook_url    = var.slack_webhook_url
}

variable "enable_sg_auto_remediation" {
  description = "Opt in to public SSH remediation after verifying the active management trail"
  type        = bool
  default     = false
}

variable "sg_management_trail_arn" {
  description = "Verified trail covering Seoul EC2 write events; bootstrap management_trail_arn output or an existing trail"
  type        = string
  default     = ""
}

output "sg_auto_remediation" {
  value = {
    function_name   = module.sg_auto_remediation.function_name
    event_rule_name = module.sg_auto_remediation.event_rule_name
  }
}
