# ==============================================================================
# 1. ECR Repositories (Web & WAS)
# ==============================================================================
resource "aws_ecr_repository" "this" {
  for_each             = toset(var.repository_names)
  name                 = "${var.tag_header}${each.key}"
  image_tag_mutability = "IMMUTABLE"
  # Complete dev teardown intentionally removes images, after evidence capture.
  force_delete = true

  # [보안 통제] 푸시 즉시 취약점 자동 검사 (Trivy CI 스캔과 더불어 2중 방어선)
  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "KMS"
  }

  tags = merge(var.tags, { Name = "${var.tag_header}${each.key}-ecr" })
}

# ==============================================================================
# 2. Lifecycle Policy (저장 공간 및 비용 최적화)
# ==============================================================================
resource "aws_ecr_lifecycle_policy" "this" {
  for_each   = toset(var.repository_names)
  repository = aws_ecr_repository.this[each.key].name
  lifecycle {
    precondition {
      condition     = length(lookup(var.protected_image_tags, each.key, [])) > 0
      error_message = "Supply at least the current desired SHA for each repository before enabling tagged image expiration."
    }
  }

  policy = jsonencode({
    rules = concat([
      # An exact immutable tag identifies at most one image. This higher-priority
      # rule never expires it and shields it from the generic count rule.
      for index, sha in sort(distinct(lookup(var.protected_image_tags, each.key, []))) : {
        rulePriority = index + 1
        description  = "Protect deployed/explicit rollback SHA ${sha}"
        selection = {
          tagStatus      = "tagged"
          tagPatternList = [sha]
          countType      = "imageCountMoreThan"
          countNumber    = 1
        }
        action = { type = "expire" }
      }
      ], [
      {
        rulePriority = 10
        description  = "태그가 없는 임시/빌드 실패 이미지는 3일 후 자동 파기"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 3
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 20
        description  = "Keep latest 30 tagged images plus explicitly protected deployed/rollback SHAs"
        selection = {
          tagStatus      = "tagged"
          tagPatternList = ["*"]
          countType      = "imageCountMoreThan"
          countNumber    = 30
        }
        action = { type = "expire" }
      }
    ])
  })
}
