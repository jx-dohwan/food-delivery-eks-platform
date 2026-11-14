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
  default     = "eks-cluster"
  description = "EKS 클러스터 이름 (서브넷 태그 연동)"
}

variable "office_cidr" {
  type        = string
  default     = "" # 비우면 Bastion SSH 닫힘(SSM Session Manager 전용). 본인 공인 IP/32 권장
  description = "관리자 Bastion SSH 허용 CIDR (예: 1.2.3.4/32)"
}
variable "region" {
  type        = string
  default     = "ap-northeast-2"
  description = "AWS 리전"
  validation {
    condition     = var.region == "ap-northeast-2"
    error_message = "This dev root and its GitOps/teardown contract are Seoul-only."
  }
}
variable "tags" {
  description = "리소스에 부여할 공통 태그 맵"
  type        = map(string)
  default     = {}
}

variable "project_name" {
  description = "프로젝트 식별자 이름"
  type        = string
  default     = "food-delivery"
  validation {
    condition     = var.project_name == "food-delivery"
    error_message = "This root manages only the food-delivery project."
  }
}

variable "environment" {
  description = "배포 환경 (dev, stage, prod)"
  type        = string
  default     = "dev"
  validation {
    condition     = var.environment == "dev"
    error_message = "Use the separate reviewed prod root; dev state may not own prod resources."
  }
}
variable "common_tags" {
  description = "리소스 전반에 일괄 적용할 공통 태그 맵"
  type        = map(string)
  default = {
    Project     = "food-delivery"
    Environment = "dev"
    ManagedBy   = "terraform"
  }
}

variable "route53_zone_name" {
  description = "Route53 public hosted zone name"
  type        = string
}

variable "dev_domain_name" {
  description = "Dev app FQDN (A Alias -> Ingress ALB)"
  type        = string
}

variable "www_domain_name" {
  description = "WWW FQDN (prod 준비용 Alias)"
  type        = string
}

variable "manage_www_record" {
  description = "www Alias 레코드를 Terraform으로 관리할지 여부"
  type        = bool
  default     = false
}

variable "alb_ingress_stack_tag" {
  description = "AWS LB Controller Ingress stack tag (ingress.k8s.aws/stack)"
  type        = string
  default     = "app/main-ingress"
}

variable "manage_ingress_alb_alias" {
  description = "Manage Route53 A Alias to Ingress ALB (disable during teardown after ALB is gone)"
  type        = bool
  default     = false
}

variable "enable_secret_rotation" {
  description = "Enable Secrets Manager 7-day Aurora password rotation Lambda"
  type        = bool
  default     = true
}

variable "slack_webhook_url" {
  description = "Slack Incoming Webhook URL for ops alerts (rotation/CI)"
  type        = string
  default     = ""
  sensitive   = true
}

variable "slack_alert_tags" {
  description = "Slack mention on failure (e.g. <!channel>, <!here>, <@UXXXX>)"
  type        = string
  default     = "<!here>"
}

variable "enable_ops_monitoring" {
  description = "CloudWatch native alarms (ALB/RDS/Redis → SNS → Slack). No Prometheus/Grafana"
  type        = bool
  default     = true
}

variable "alb_target_group_arn_suffix" {
  description = "Optional TG CloudWatch dimension (targetgroup/name/id). Empty skips UnHealthyHostCount alarm"
  type        = string
  default     = ""
}

variable "enable_waf" {
  description = "Enable the dev Regional Web ACL; publish its Terraform output to the Ingress patch before deployment"
  type        = bool
  default     = false
}

variable "enable_access_analyzer" {
  description = "Deprecated compatibility input; External Access Analyzer is always managed by infra/bootstrap"
  type        = bool
  default     = true
}

variable "waf_rate_limit" {
  description = "WAF source-IP request budget over 300 seconds"
  type        = number
  default     = 6000
}

variable "waf_count_mode" {
  description = "WAF observation mode; false restores managed actions and blocks rate violations"
  type        = bool
  default     = true
}
variable "enable_oss_observability" {
  description = "Enable the in-cluster Prometheus/Grafana demo stack without managed services or PVCs."
  type        = bool
  default     = true
}
variable "enable_karpenter" {
  type        = bool
  default     = false
  description = "Opt-in node autoscaling after AMI verification and cost review."
}

variable "was_aws_access" {
  description = "Verified dev application bucket/SES identity; absent features grant nothing."
  type = object({
    s3  = optional(object({ bucket_name = string, encryption = string }))
    ses = optional(object({ identity = string, from_address = string }))
  })
  default = {}
}

variable "mng_ami_id" {
  type        = string
  default     = "ami-023ee3e4ba8987102" # amazon-eks-node-al2023-x86_64-standard-1.36-v20261026
  description = "Committed MNG AMI pin so unrelated applies never roll nodes; bump deliberately in a node-upgrade change."
}

variable "karpenter_ami_id" {
  type    = string
  default = ""
}

variable "karpenter_ami_verified" {
  type    = bool
  default = false
}
variable "metrics_server_kubelet_tls_verified" {
  type        = bool
  default     = false
  description = "Full Deploy certificate/CA/SAN proof is required before removing the metrics-server insecure flag."
}

variable "activate_secret_rotation" {
  description = "Second-stage only: enable the seven-day schedule after live Aurora/Proxy target health verification. Keep false on initial deployment."
  type        = bool
  default     = false
  validation {
    condition     = !var.activate_secret_rotation || var.enable_secret_rotation
    error_message = "Rotation activation requires enable_secret_rotation."
  }
}

variable "enable_central_logging" {
  type    = bool
  default = false
}
variable "loki_bucket_name" {
  type    = string
  default = ""
}

variable "mng_instance_type" {
  description = "Baseline t3.medium; approved logging batch uses t3.large from initial creation."
  type        = string
  default     = "t3.medium"
}

variable "mng_max_size" {
  description = "Baseline permits four; the attended R2 target caps the system MNG at two."
  type        = number
  default     = 4
  validation {
    condition     = contains([2, 3, 4], var.mng_max_size)
    error_message = "Keep the existing two-node minimum and a maximum of two to four."
  }
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
