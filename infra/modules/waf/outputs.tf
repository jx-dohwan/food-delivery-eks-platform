output "web_acl_arn" {
  description = "WAFv2 WebACL ARN (enable=false 이면 null)"
  value       = try(aws_wafv2_web_acl.this[0].arn, null)
}

output "web_acl_id" {
  description = "WAFv2 WebACL ID"
  value       = try(aws_wafv2_web_acl.this[0].id, null)
}
