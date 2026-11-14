# Workload identity is separate from WAS S3/SES and both node roles.
resource "aws_iam_role" "adot_collector" {
  name = "${var.cluster_name}-${var.was_environment}-adot"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRoleWithWebIdentity"
      Principal = { Federated = aws_iam_openid_connect_provider.this.arn }
      Condition = { StringEquals = {
        "${replace(aws_iam_openid_connect_provider.this.url, "https://", "")}:aud" = "sts.amazonaws.com"
        "${replace(aws_iam_openid_connect_provider.this.url, "https://", "")}:sub" = "system:serviceaccount:${local.was_namespace}:adot-collector"
      } }
    }]
  })
  tags = merge(var.tags, { Environment = var.was_environment })
}

resource "aws_iam_role_policy" "adot_collector" {
  name = "trace-export"
  role = aws_iam_role.adot_collector.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "ExportTraceSegments"
      Effect = "Allow"
      Action = ["xray:PutTraceSegments"]
      # This write API has no resource-level scope. Exporter telemetry and remote
      # sampling are off, so no PutTelemetryRecords or GetSampling* permissions.
      Resource = "*"
    }]
  })
}

output "tracing_irsa_config" {
  description = "Non-secret output for scripts/render-tracing-irsa.py; no copied ARNs."
  value = {
    environment     = var.was_environment
    namespace       = local.was_namespace
    service_account = "adot-collector"
    account_id      = data.aws_caller_identity.was.account_id
    region          = var.region
    role_arn        = aws_iam_role.adot_collector.arn
  }
}
