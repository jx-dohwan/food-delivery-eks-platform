variable "tag_header" {
  description = "리소스 접두사용 태그 헤더"
  type        = string
  default     = ""
}

variable "cluster_name" {
  description = "EKS 클러스터 이름"
  type        = string
}

variable "region" {
  description = "AWS 리전"
  type        = string
  default     = "ap-northeast-2"
}

variable "vpc_id" {
  description = "VPC ID (addons.tf의 LBC Helm 차트에 주입용)"
  type        = string
}

variable "subnet_ids" {
  description = "EKS 클러스터 및 노드 그룹이 배치될 서브넷 ID 목록"
  type        = list(string)
}

# [핵심] modules/security_group에서 생성된 노드 보안 그룹 ID 수신
variable "node_security_group_id" {
  description = "Security Group ID for EKS Worker Nodes"
  type        = string
}

variable "kubernetes_version" {
  description = "EKS 쿠버네티스 버전"
  type        = string
  default     = "1.36"
  validation {
    condition     = var.kubernetes_version == "1.36"
    error_message = "This platform pins Kubernetes 1.36; review managed-addons.tf when changing the target."
  }
}

variable "instance_type" {
  description = "워커 노드 인스턴스 타입"
  type        = string
  default     = "t3.medium"
}

variable "key_name" {
  description = "노드 EC2 접속 키페어 이름"
  type        = string
  default     = ""
}

variable "desired_size" {
  type    = number
  default = 2
}

variable "min_size" {
  type    = number
  default = 2
}

variable "max_size" {
  type    = number
  default = 4
}

variable "admin_principal_arn" {
  description = "관리자 권한을 부여할 IAM 사용자/역할 ARN"
  type        = string
  default     = ""
}

variable "tags" {
  description = "공통 태그 맵"
  type        = map(string)
  default     = {}
}

variable "enable_oss_observability" {
  description = "Install the ephemeral OSS metrics stack; no managed AWS observability services."
  type        = bool
  default     = false
}

variable "enable_karpenter" {
  description = "Opt-in dev node autoscaling; requires an explicitly verified fixed AMI."
  type        = bool
  default     = false
}

variable "node_ami_id" {
  type        = string
  default     = ""
  description = "Pinned MNG AMI so unrelated applies do not roll nodes; empty follows the latest AL2023 AMI for the cluster minor."
  validation {
    condition     = var.node_ami_id == "" || can(regex("^ami-[0-9a-f]{17}$", var.node_ami_id))
    error_message = "node_ami_id must be empty or a full AMI ID."
  }
}

variable "karpenter_ami_id" {
  type        = string
  default     = ""
  description = "Fixed AWS-owned AL2023 x86_64 AMI for Kubernetes 1.36; never latest."
  validation {
    condition     = !var.enable_karpenter || (can(regex("^ami-[0-9a-f]{17}$", var.karpenter_ami_id)) && var.karpenter_ami_verified)
    error_message = "Enabling Karpenter requires a fixed AMI ID and karpenter_ami_verified=true after Full Deploy preflight."
  }
}

variable "karpenter_ami_verified" {
  type        = bool
  default     = false
  description = "Operator verified region, AWS owner, EKS 1.36, AL2023, x86_64 and image boot compatibility."
}
variable "metrics_server_kubelet_tls_verified" {
  description = "True only after verifying every MNG/Karpenter kubelet certificate chains to the mounted cluster CA and covers InternalIP. False preserves the known TLS debt."
  type        = bool
  default     = false
}

variable "eso_secret_names" {
  description = "Authentication and connection secret names, in that order; only these two may be read by the application ESO identity."
  type        = list(string)
  default     = []
  validation {
    condition = length(var.eso_secret_names) == 0 || (length(var.eso_secret_names) == 2 &&
      length(distinct(var.eso_secret_names)) == 2 &&
    alltrue([for name in var.eso_secret_names : can(regex("^[A-Za-z0-9/_+=.@-]+$", name))]))
    error_message = "Supply two distinct exact Secret names, without wildcard characters or ARNs."
  }
}
