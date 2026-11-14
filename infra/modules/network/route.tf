# ==============================================================================
# 1. NAT IP & Gateway (Public 서브넷 1곳에 배치)
# ==============================================================================
resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = { Name = "${var.tag_header}nat-eip" }
}

resource "aws_nat_gateway" "this" {
  allocation_id = aws_eip.nat.id
  subnet_id     = [for k, v in aws_subnet.this : v.id if v.tags["Type"] == "public"][0]
  depends_on    = [aws_internet_gateway.this]

  tags = { Name = "${var.tag_header}natgw" }
}

# ==============================================================================
# 2. Route Tables
# ==============================================================================

# [Public] 1개 (인터넷 게이트웨이 연결)
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = { Name = "${var.tag_header}public-rt" }
}

# [Private (EKS)] AZ별 3개 분리 (a, b, c)
# 현재는 1개의 NAT GW를 공유하며, 향후 Multi-NAT 확장 시 타깃 분기 가능
resource "aws_route_table" "private" {
  for_each = toset(["a", "b", "c"])
  vpc_id   = aws_vpc.this.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.this.id
  }

  tags = { Name = "${var.tag_header}private-rt-${each.key}" }
}

# [DB] 1개 (외부 경로가 없는 완전 격리망)
resource "aws_route_table" "db" {
  vpc_id = aws_vpc.this.id

  tags = { Name = "${var.tag_header}db-rt" }
}

# ==============================================================================
# 3. Route Table Associations
# ==============================================================================

# Public 서브넷 3개 -> public-rt
resource "aws_route_table_association" "public" {
  for_each       = { for k, v in aws_subnet.this : k => v if v.tags["Type"] == "public" }
  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

# Private 서브넷 3개 -> 각 AZ 끝자리(a, b, c)에 맞춰 개별 라우팅 테이블 1:1 바인딩
resource "aws_route_table_association" "private" {
  for_each       = { for k, v in aws_subnet.this : k => v if v.tags["Type"] == "private" }
  subnet_id      = each.value.id
  route_table_id = aws_route_table.private[substr(each.value.availability_zone, -1, 1)].id
}

# DB 서브넷 3개 -> db-rt
resource "aws_route_table_association" "db" {
  for_each       = { for k, v in aws_subnet.this : k => v if v.tags["Type"] == "db" }
  subnet_id      = each.value.id
  route_table_id = aws_route_table.db.id
}
