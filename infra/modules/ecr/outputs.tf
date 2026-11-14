output "repository_urls" {
  description = "생성된 ECR 레포지토리 URL 맵"
  value       = { for k, v in aws_ecr_repository.this : k => v.repository_url }
}

output "repository_arns" {
  description = "생성된 ECR 레포지토리 ARN 맵"
  value       = { for k, v in aws_ecr_repository.this : k => v.arn }
}
