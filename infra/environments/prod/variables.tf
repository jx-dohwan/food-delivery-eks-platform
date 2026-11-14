variable "owner" {
  description = "사용자 계정명"
  type        = string
  default     = ""
}

variable "az_names" {
  description = "가용영역 이름"
  type        = list(string)
  default     = []
}

variable "vpc_cidr" {
  description = "VPC CIDR"
  type        = string
  default     = "10.0.0.0/16"
}

variable "cluster_name" {
  type        = string
  default     = "food-delivery-prod-cluster"
  description = "EKS 클러스터 이름 (서브넷 태그 연동)"
}

variable "office_cidr" {
  type        = string
  default     = "" # SSM-only by default; never public SSH.
  description = "관리자 접속 허용 CIDR"
}
variable "region" {
  type        = string
  description = "ap-northeast-2"
  default     = "ap-northeast-2"
}

# This is a platform reference, not an approved production deployment. Existing
# remote state (including the old 'pod' key), legacy stores and DB/ESO need review.
variable "prod_deployment_reviewed" {
  type    = bool
  default = false
  validation {
    condition     = var.prod_deployment_reviewed
    error_message = "Prod plan/apply is gated: review state key migration, legacy S3/EFS, DB/ESO, naming and cost first; this task performs no state migration."
  }
}
variable "enable_oss_observability" {
  type    = bool
  default = false
}
variable "enable_karpenter" {
  type    = bool
  default = false
}
variable "karpenter_ami_id" {
  type    = string
  default = ""
}
variable "karpenter_ami_verified" {
  type    = bool
  default = false
}
variable "was_aws_access" {
  type    = object({ s3 = optional(object({ bucket_name = string, encryption = string })), ses = optional(object({ identity = string, from_address = string })) })
  default = {}
}
variable "metrics_server_kubelet_tls_verified" {
  type    = bool
  default = false
}


# Account- and owner-specific values come from git-ignored tfvars (see terraform.tfvars.example).
variable "allowed_account_ids" {
  description = "The only AWS account(s) this environment may touch"
  type        = list(string)
  validation {
    condition     = length(var.allowed_account_ids) > 0 && alltrue([for id in var.allowed_account_ids : can(regex("^[0-9]{12}$", id))])
    error_message = "allowed_account_ids must list 12-digit AWS account IDs."
  }
}

variable "terraform_state_bucket_name" {
  description = "Terraform state bucket; the WAS is never granted access to it"
  type        = string
  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.terraform_state_bucket_name))
    error_message = "terraform_state_bucket_name must be a valid S3 bucket name."
  }
}
