locals {
  # Same GitOps file used by CI/ArgoCD: no second hardcoded current SHA.
  dev_gitops_images = yamldecode(file("${path.module}/../../../k8s/overlays/dev/kustomization.yaml")).images
}

variable "ecr_additional_protected_shas" {
  description = "Live Pod/previous rollout SHAs not in GitOps yet; at most four per was/web repository"
  type        = map(list(string))
  default     = {}
  validation {
    condition = alltrue([for component, shas in var.ecr_additional_protected_shas :
      contains(["was", "web"], component) && length(shas) <= 4 && alltrue([for sha in shas : can(regex("^[0-9a-f]{40}$", sha))])
    ])
    error_message = "Use only was/web and up to four additional full SHA tags each."
  }
}
