output "cluster_endpoint" {
  description = "Aurora Cluster 엔드포인트 (직접 접근용)"
  value       = aws_rds_cluster.this.endpoint
}

output "reader_endpoint" {
  description = "Aurora Reader 엔드포인트"
  value       = aws_rds_cluster.this.reader_endpoint
}

output "proxy_endpoint" {
  description = "RDS Proxy 엔드포인트 (EKS 파드가 실제 접속해야 하는 주소)"
  value       = aws_db_proxy.this.endpoint

  # 연결정보는 Aurora target 등록까지 완료된 Proxy를 가리킨다.
  depends_on = [aws_db_proxy_target.cluster]
}

output "cluster_id" {
  description = "Aurora DB cluster identifier"
  value       = aws_rds_cluster.this.id
}

output "cluster_arn" {
  description = "Aurora DB cluster ARN"
  value       = aws_rds_cluster.this.arn
  # Initial rotation may run when its Terraform resource is created.
  depends_on = [aws_rds_cluster_instance.instances]
}

output "writer_instance_identifier" {
  description = "Aurora 인스턴스 1번 identifier (CloudWatch DBInstanceIdentifier)"
  value       = aws_rds_cluster_instance.instances[0].identifier
}

output "proxy_target_id" {
  description = "Registered Proxy target; supplies a dependency for second-stage rotation activation."
  value       = aws_db_proxy_target.cluster.id
}
