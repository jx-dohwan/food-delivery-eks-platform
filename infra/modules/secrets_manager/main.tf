# ==============================================================================
# 1. 무작위 패스워드 및 JWT 비밀키 생성
# ==============================================================================
# 1-1. Aurora MySQL 마스터 패스워드 생성 (특수문자 필터링)
resource "random_password" "master_password" {
  length           = 20
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?" # MySQL 파싱 충돌 문자(/, @, ", ') 제외
}

# 1-2. JWT Access Token 서명용 64자리 무작위 난수 키 생성 (알파벳+숫자)
resource "random_password" "jwt_access_secret" {
  length  = 64
  special = false
}

# 1-3. JWT Refresh Token 서명용 64자리 무작위 난수 키 생성 (알파벳+숫자)
resource "random_password" "jwt_refresh_secret" {
  length  = 64
  special = false
}

# ==============================================================================
# 2. Secrets Manager Secret 본체 생성
# ==============================================================================
resource "aws_secretsmanager_secret" "db_secret" {
  name                    = "${var.tag_header}${var.secret_name}"
  description             = "Application Credentials (Aurora MySQL, Redis, JWT Secrets)"
  recovery_window_in_days = 0 # 빠른 재배포 및 destroy를 위해 즉시 삭제 허용

  tags = merge(var.tags, { Name = "${var.tag_header}app-credentials" })
}

# ==============================================================================
# 3. 통합 JSON 자격 증명 주입 (DB + Redis + JWT)
# ==============================================================================
resource "aws_secretsmanager_secret_version" "db_secret_val" {
  secret_id = aws_secretsmanager_secret.db_secret.id

  # 인증값은 로테이션이 관리한다. 앱 DB_HOST는 아래 db_connection_val에서 읽는다.
  secret_string = jsonencode({
    # DB 접속 정보
    port     = var.db_port
    username = var.db_username
    password = random_password.master_password.result
    dbname   = var.db_name

    # Redis 접속 정보
    redis_host = var.redis_host
    redis_port = var.redis_port

    # 테라폼이 자동 생성한 JWT 비밀키 2종
    jwt_access_secret  = random_password.jwt_access_secret.result
    jwt_refresh_secret = random_password.jwt_refresh_secret.result
  })

  # Lambda 로테이션이 활성화되면 Terraform이 password를 덮어쓰지 않도록 보호
  lifecycle {
    ignore_changes = [secret_string]
  }
}

# ==============================================================================
# 4. 앱 DB 연결정보 (로테이션된 인증값을 덮어쓰지 않고 호스트 갱신)
# ==============================================================================
resource "aws_secretsmanager_secret" "db_connection" {
  name                    = "${var.tag_header}${var.secret_name}-connection"
  description             = "Application DB connection endpoint (RDS Proxy; no credentials)"
  recovery_window_in_days = 0

  tags = merge(var.tags, { Name = "${var.tag_header}app-db-connection" })
}

resource "aws_secretsmanager_secret_version" "db_connection_val" {
  secret_id = aws_secretsmanager_secret.db_connection.id
  secret_string = jsonencode({
    host       = var.db_host
    redis_host = var.redis_host
    redis_port = var.redis_port
  })
}

# ==============================================================================
# 5. 7일 주기 자동 로테이션 — rotation.tf (enable_rotation=true 시)
