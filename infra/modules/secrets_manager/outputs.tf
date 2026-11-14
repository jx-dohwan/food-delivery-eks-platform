output "secret_arn" {
  description = "Secrets Manager Secret ARN"
  value       = aws_secretsmanager_secret.db_secret.arn

  # Proxy 인증에는 빈 Secret 본체가 아니라 실제 인증값이 먼저 필요하다.
  depends_on = [aws_secretsmanager_secret_version.db_secret_val]
}

output "secret_name" {
  description = "Secrets Manager Secret Name"
  value       = aws_secretsmanager_secret.db_secret.name
}

output "connection_secret_name" {
  value = aws_secretsmanager_secret.db_connection.name
}

output "db_username" {
  description = "데이터베이스 마스터 유저명"
  value       = var.db_username
}

output "db_password" {
  description = "데이터베이스 초기 마스터 패스워드"
  value       = random_password.master_password.result
  sensitive   = true

  # 초기 Aurora 생성도 동일한 인증 Secret이 준비된 뒤 시작한다.
  depends_on = [aws_secretsmanager_secret_version.db_secret_val]
}

output "ops_alerts_topic_arn" {
  description = "Ops SNS topic ARN (CloudWatch alarms / rotation). Empty if Slack webhook unset"
  value       = try(aws_sns_topic.ops_alerts[0].arn, "")
}

output "rotation_schedule_enabled" {
  description = "Rotation schedule activation status, separate from Lambda preparation."
  value       = length(aws_secretsmanager_secret_rotation.db) == 1
}
