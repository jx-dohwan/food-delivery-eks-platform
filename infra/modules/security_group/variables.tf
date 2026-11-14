variable "tag_header" {
  description = "리소스 접두사용 태그 헤더"
  type        = string
  default     = ""
}

variable "vpc_id" {
  description = "VPC ID (AWS Load Balancer Controller에 주입)"
  type        = string
}

variable "vpc_cidr" {
  description = "VPC CIDR 블록 (보안 그룹 인바운드/아웃바운드 규칙용)"
  type        = string
  default     = "10.0.0.0/16"
}
variable "tags" {
  description = "공통 태그 맵"
  type        = map(string)
  default     = {}
}

variable "bastion_ssh_cidr" {
  description = "Bastion SSH(22) 허용 CIDR. 본인 공인 IP/32 권장. 빈 문자열이면 SSH 인바운드 닫음(SSM 전용)"
  type        = string
  default     = ""
  validation {
    condition = var.bastion_ssh_cidr == "" || (
      can(cidrnetmask(var.bastion_ssh_cidr)) && try(tonumber(split("/", var.bastion_ssh_cidr)[1]) > 0, false)
    )
    error_message = "Bastion SSH must be disabled or limited to a valid non-public IPv4 CIDR; /0 is forbidden."
  }
}

variable "enable_rotation" {
  description = "Create the Aurora credential rotation Lambda security group"
  type        = bool
  default     = false
}


variable "karpenter_discovery_cluster_name" {
  type    = string
  default = ""
}


variable "cluster_name" {
  type        = string
  default     = ""
  description = "Explicit cluster discovery identity supplied by the environment root."
}
