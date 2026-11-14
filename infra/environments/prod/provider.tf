
# ==============================================================================
# 1. 테라폼 실행 환경 및 필수 프로바이더 설정
# ==============================================================================
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.15"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.32"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    http = {
      source  = "hashicorp/http"
      version = "~> 3.4"
    }
  }

  # public-state에서 생성한 버킷을 원격 백엔드로 사용 (주석 해제)
  # bucket comes from a local, git-ignored backend.hcl: terraform init -backend-config=backend.hcl
  backend "s3" {
    key          = "terraform/prod/terraform.tfstate"
    region       = "ap-northeast-2"
    use_lockfile = true
    encrypt      = true
  }
}

# ==============================================================================
# 2. AWS Provider
# ==============================================================================
provider "aws" {
  allowed_account_ids = var.allowed_account_ids
  region              = var.region
  default_tags {
    tags = merge(local.common_tags, { Owner = var.owner })
  }
}

provider "aws" {
  allowed_account_ids = var.allowed_account_ids
  alias               = "dokyo"
  region              = "ap-northeast-1"
  default_tags {
    tags = {
      Owner = "user0"
    }
  }
}

# ==============================================================================
# 3. Helm Provider
# ==============================================================================
provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      args        = ["eks", "get-token", "--region", var.region, "--cluster-name", module.eks.cluster_name]
      command     = "aws"
    }
  }
}

# ==============================================================================
# 4. Kubernetes Provider
# ==============================================================================
provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    args        = ["eks", "get-token", "--region", var.region, "--cluster-name", module.eks.cluster_name]
    command     = "aws"
  }
}
