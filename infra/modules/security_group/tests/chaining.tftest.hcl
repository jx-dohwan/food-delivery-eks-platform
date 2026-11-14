mock_provider "aws" {
  override_during = plan
  mock_resource "aws_security_group" { defaults = { ingress = [] } }
}
override_resource {
  override_during = plan
  target          = aws_security_group.node_sg
  values          = { id = "sg-00000000000000001" }
}
override_resource {
  override_during = plan
  target          = aws_security_group.proxy_sg
  values          = { id = "sg-00000000000000002" }
}
override_resource {
  override_during = plan
  target          = aws_security_group.rds_sg
  values          = { id = "sg-00000000000000003" }
}
override_resource {
  override_during = plan
  target          = aws_security_group.alb_sg
  values          = { id = "sg-00000000000000004" }
}
override_resource {
  override_during = plan
  target          = aws_security_group.rotation_lambda_sg[0]
  values          = { id = "sg-00000000000000005" }
}
variables {
  vpc_id          = "vpc-00000000000000001"
  enable_rotation = true
}
run "database_chain" {
  command = plan
  assert {
    condition     = one(aws_security_group.proxy_sg.ingress).security_groups == toset([aws_security_group.node_sg.id]) && one(aws_security_group.proxy_sg.ingress).protocol == "tcp" && one(aws_security_group.proxy_sg.ingress).from_port == 3306 && one(aws_security_group.proxy_sg.ingress).to_port == 3306
    error_message = "Only node SG may enter Proxy at TCP 3306."
  }
  assert {
    condition     = toset(flatten([for r in aws_security_group.rds_sg.ingress : r.security_groups])) == toset([aws_security_group.proxy_sg.id, aws_security_group.rotation_lambda_sg[0].id]) && alltrue([for r in aws_security_group.rds_sg.ingress : r.from_port == 3306 && r.to_port == 3306 && r.protocol == "tcp" && length(coalesce(r.cidr_blocks, [])) == 0])
    error_message = "Aurora accepts only Proxy and rotation; never nodes or CIDR ingress."
  }
  assert {
    condition     = one(aws_security_group.redis_sg.ingress).security_groups == toset([aws_security_group.node_sg.id]) && one(aws_security_group.redis_sg.ingress).protocol == "tcp" && one(aws_security_group.redis_sg.ingress).from_port == 6379 && one(aws_security_group.redis_sg.ingress).to_port == 6379 && length(coalesce(one(aws_security_group.redis_sg.ingress).cidr_blocks, [])) == 0
    error_message = "Redis must accept node SG only, at TCP 6379."
  }
  assert {
    condition     = length(aws_security_group.node_sg.ingress) == 2 && length([for r in aws_security_group.node_sg.ingress : r if r.from_port == 80 && r.to_port == 80 && contains(coalesce(r.security_groups, []), aws_security_group.alb_sg.id)]) == 1 && length([for r in aws_security_group.node_sg.ingress : r if r.self == true && r.protocol == "-1"]) == 1
    error_message = "Only Web HTTP from ALB plus node self traffic; no NodePort or VPC-wide ingress."
  }
  assert {
    condition     = aws_security_group_rule.rotation_mysql_egress[0].source_security_group_id == aws_security_group.rds_sg.id && aws_security_group_rule.rotation_mysql_egress[0].security_group_id == aws_security_group.rotation_lambda_sg[0].id && length(aws_security_group.bastion.ingress) == 0
    error_message = "Keep the rotation validation exception and no default SSH."
  }
}
