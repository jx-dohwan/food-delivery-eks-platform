terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region              = "ap-northeast-2"
  allowed_account_ids = [var.allowed_account_id]
  default_tags {
    tags = {
      Owner = "user0"
    }
  }
}

# 상태 파일 저장을 위한 S3 버킷
resource "aws_s3_bucket" "terraform_state" {
  bucket        = var.terraform_state_bucket_name
  force_destroy = false
  lifecycle {
    prevent_destroy = true
  }
}

# S3 버전 관리 활성화
resource "aws_s3_bucket_versioning" "terraform_state_versioning" {
  bucket = aws_s3_bucket.terraform_state.id

  versioning_configuration {
    status = "Enabled"
  }
}
