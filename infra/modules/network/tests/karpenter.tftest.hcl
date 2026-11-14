mock_provider "aws" { override_during = plan }
variables {
  vpc_cidr     = "10.0.0.0/16"
  region       = "ap-northeast-2"
  cluster_name = "platform-test"
  subnet_map = {
    public-a  = { type = "public", az = "ap-northeast-2a", cidr = "10.0.0.0/24" }
    private-a = { type = "private", az = "ap-northeast-2a", cidr = "10.0.1.0/24" }
    private-b = { type = "private", az = "ap-northeast-2b", cidr = "10.0.2.0/24" }
    db-a      = { type = "db", az = "ap-northeast-2a", cidr = "10.0.3.0/24" }
  }
}
run "private_discovery_only" {
  command = plan
  variables { enable_karpenter = true }
  assert {
    condition     = alltrue([for s in aws_subnet.this : lookup(s.tags, "karpenter.sh/discovery", "") == (s.tags.Type == "private" ? "platform-test" : "")])
    error_message = "Karpenter discovers private worker subnets only, never public or isolated DB subnets."
  }
  assert {
    condition     = alltrue([for s in aws_subnet.this : !s.map_public_ip_on_launch if s.tags.Type == "private"])
    error_message = "Private worker nodes must not acquire public IPs."
  }
}
run "disabled_discovery" {
  command = plan
  assert {
    condition     = alltrue([for s in aws_subnet.this : !contains(keys(s.tags), "karpenter.sh/discovery")])
    error_message = "Disabled Karpenter adds no discovery tags."
  }
}
