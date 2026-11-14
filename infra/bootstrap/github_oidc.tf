# Persistent GitHub CI identity. Adopt the existing provider/role before apply;
# see github-iam-migration.md. This root is never used by safe-teardown.
resource "aws_iam_openid_connect_provider" "github_actions" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
  # Preserve the existing account provider's thumbprints during adoption.
  thumbprint_list = [
    "6938fd4d98bab03faadb97b34396831e3780aea1",
    "1c58a3a8518e8759bf075b76b750d4f8d7318a65"
  ]
  tags = { Name = "github-actions-oidc-provider" }

  lifecycle {
    prevent_destroy = true
  }
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

data "aws_iam_policy_document" "github_actions_assume_role" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github_actions.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      # Both refs trigger deploy.yml; no repository/owner wildcard.
      values = [
        "repo:jx-dohwan@79912056/food_delivery_eks@1376923361:ref:refs/heads/main",
        "repo:jx-dohwan@79912056/food_delivery_eks@1376923361:ref:refs/tags/v*"
      ]
    }
  }
}

resource "aws_iam_role" "github_actions_role" {
  name               = "github-actions-eks-deploy-role"
  assume_role_policy = data.aws_iam_policy_document.github_actions_assume_role.json
  tags               = { Name = "github-actions-eks-deploy-role" }

  lifecycle {
    prevent_destroy = true
  }
}

data "aws_iam_policy_document" "github_actions_ecr" {
  statement {
    sid       = "EcrLogin"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"] # This API does not support repository-level resources.
  }
  statement {
    sid = "PushAppImages"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:PutImage",
      "ecr:BatchGetImage"
    ]
    resources = [for repository in ["was", "web"] :
      "arn:${data.aws_partition.current.partition}:ecr:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:repository/${repository}"
    ]
  }
}

resource "aws_iam_role_policy" "github_actions_ecr" {
  name   = "github-actions-ecr-push"
  role   = aws_iam_role.github_actions_role.id
  policy = data.aws_iam_policy_document.github_actions_ecr.json
}

# Removing attachment resources from code alone leaves out-of-state policies
# attached in AWS. Import this resource too, so plan shows their removal.
resource "aws_iam_role_policy_attachments_exclusive" "github_actions" {
  role_name   = aws_iam_role.github_actions_role.name
  policy_arns = []
  depends_on  = [aws_iam_role_policy.github_actions_ecr]
}

output "github_actions_role_arn" {
  value = aws_iam_role.github_actions_role.arn
}
