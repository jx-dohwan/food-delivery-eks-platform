# Account-specific values live in a local, git-ignored terraform.tfvars
# (see terraform.tfvars.example). Nothing here identifies a real account.
variable "allowed_account_id" {
  description = "The only AWS account this configuration may touch"
  type        = string
  validation {
    condition     = can(regex("^[0-9]{12}$", var.allowed_account_id))
    error_message = "allowed_account_id must be a 12-digit AWS account ID."
  }
}

variable "terraform_state_bucket_name" {
  description = "Globally unique S3 bucket that stores every Terraform state of this project"
  type        = string
  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.terraform_state_bucket_name))
    error_message = "terraform_state_bucket_name must be a valid S3 bucket name."
  }
}
