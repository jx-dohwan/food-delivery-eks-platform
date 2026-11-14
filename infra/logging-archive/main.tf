# Independent retained log archive. Never include this root in dev destroy.
terraform {
  required_version = ">= 1.14.0, < 2.0.0"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.0"
    }
  }
  backend "s3" {} # Explicit separate key supplied by reviewed -backend-config; never dev key.
}
variable "region" {
  type    = string
  default = "ap-northeast-2"
}
variable "bucket_name" {
  type = string
  validation {
    condition     = startswith(var.bucket_name, "food-delivery-loki-") && can(regex("^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$", var.bucket_name))
    error_message = "Supply a globally unique dedicated logging bucket name."

  }
}
provider "aws" {
  allowed_account_ids = [var.allowed_account_id]
  region              = var.region
}
resource "aws_s3_bucket" "logs" {
  bucket        = var.bucket_name
  force_destroy = false
  lifecycle {
    prevent_destroy = true
  }
  tags = { Project = "food-delivery", Purpose = "retained-loki-logs"
  }
}
resource "aws_s3_bucket_public_access_block" "logs" {
  bucket                  = aws_s3_bucket.logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
resource "aws_s3_bucket_server_side_encryption_configuration" "logs" {
  bucket = aws_s3_bucket.logs.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}
resource "aws_s3_bucket_versioning" "logs" {
  bucket = aws_s3_bucket.logs.id
  versioning_configuration {
    status = "Suspended"
  }
}
resource "aws_s3_bucket_policy" "tls" {
  bucket = aws_s3_bucket.logs.id
  policy = jsonencode({ Version = "2012-10-17", Statement = [{
    Sid      = "DenyNonTLS", Effect = "Deny", Principal = "*", Action = "s3:*",
    Resource = [aws_s3_bucket.logs.arn, "${aws_s3_bucket.logs.arn}/*"],
    Condition = { Bool = { "aws:SecureTransport" = "false"
      }
    }

    }]
  })
}
# No object expiry shortcut: Compactor owns index/chunk retention while running.
# After dev teardown Compactor is stopped; explicit archive cleanup is required.
output "bucket_name" {
  value = aws_s3_bucket.logs.id
}
output "bucket_arn" {
  value = aws_s3_bucket.logs.arn
}

variable "allowed_account_id" {
  description = "Explicit account allow-list for the separate archive root; never inferred from ambient credentials."
  type        = string
  validation {
    condition     = can(regex("^[0-9]{12}$", var.allowed_account_id))
    error_message = "Supply the approved AWS account ID."
  }
}
