mock_provider "aws" { override_during = plan }
variables {
  vpc_id                  = "vpc-00000000000000001"
  db_subnet_ids           = ["subnet-00000000000000001", "subnet-00000000000000002"]
  rds_security_group_id   = "sg-00000000000000001"
  proxy_security_group_id = "sg-00000000000000002"
  master_username         = "mockuser"
  master_password         = "MOCK_ONLY_password123!"
  secret_arn              = "arn:aws:secretsmanager:ap-northeast-2:123456789012:secret:mock-auth-123456"
}
run "proxy_requires_tls_and_only_auth_secret" {
  command = plan
  assert {
    condition     = aws_db_proxy.this.require_tls && !aws_db_proxy.this.debug_logging && one(aws_db_proxy.this.auth).secret_arn == var.secret_arn
    error_message = "Application and Migration must use a TLS-required Proxy with the authentication Secret only."
  }
  assert {
    condition     = aws_db_proxy.this.vpc_security_group_ids == toset([var.proxy_security_group_id]) && aws_rds_cluster.this.vpc_security_group_ids == toset([var.rds_security_group_id])
    error_message = "Do not merge Node/Proxy/Aurora security boundaries."
  }
}
