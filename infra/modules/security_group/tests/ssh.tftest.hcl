mock_provider "aws" {
  override_during = plan
  mock_resource "aws_security_group" { defaults = { ingress = [] } }
}
variables { vpc_id = "vpc-0123456789abcdef0" }
run "closed_by_default" {
  command = plan
  assert {
    condition     = length(aws_security_group.bastion.ingress) == 0
    error_message = "Default Bastion must have no SSH ingress."
  }
}
run "administrator_only" {
  command = plan
  variables { bastion_ssh_cidr = "203.0.113.5/32" }
  assert {
    condition     = one(aws_security_group.bastion.ingress).cidr_blocks == tolist(["203.0.113.5/32"]) && one(aws_security_group.bastion.ingress).from_port == 22
    error_message = "Keep administrator /32 SSH valid."
  }
}
run "reject_public_ssh" {
  command = plan
  variables { bastion_ssh_cidr = "0.0.0.0/0" }
  expect_failures = [var.bastion_ssh_cidr]
}
run "reject_ipv6_public_ssh" {
  command = plan
  variables { bastion_ssh_cidr = "::/0" }
  expect_failures = [var.bastion_ssh_cidr]
}
