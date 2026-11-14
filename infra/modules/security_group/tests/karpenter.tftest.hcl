mock_provider "aws" { override_during = plan }
variables { vpc_id = "vpc-00000000000000001" }
run "node_boundary_reused" {
  command = plan
  variables { karpenter_discovery_cluster_name = "platform-test" }
  assert {
    condition     = aws_security_group.node_sg.tags["karpenter.sh/discovery"] == "platform-test" && !contains(keys(aws_security_group.rds_sg.tags), "karpenter.sh/discovery") && !contains(keys(aws_security_group.proxy_sg.tags), "karpenter.sh/discovery") && !contains(keys(aws_security_group.redis_sg.tags), "karpenter.sh/discovery") && !contains(keys(aws_security_group.alb_sg.tags), "karpenter.sh/discovery")
    error_message = "Only existing node SG is discovered; never attach ALB/DB/Proxy/Redis SGs to nodes."
  }
}
run "no_discovery_by_default" {
  command = plan
  assert {
    condition     = !contains(keys(aws_security_group.node_sg.tags), "karpenter.sh/discovery")
    error_message = "No Karpenter discovery when disabled."
  }
}

run "configured_cluster_identity_is_used_for_node_ownership" {
  command = plan
  variables {
    cluster_name = "custom-cluster"
    tag_header   = "owner-"
  }
  assert {
    condition     = aws_security_group.node_sg.tags["kubernetes.io/cluster/custom-cluster"] == "owned" && !contains(keys(aws_security_group.node_sg.tags), "kubernetes.io/cluster/owner-cluster")
    error_message = "Node ownership must follow the configured cluster, not a historical naming convention."
  }
}
