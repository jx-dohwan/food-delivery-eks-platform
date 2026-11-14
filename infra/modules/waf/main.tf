# Regional Web ACL ownership belongs to this environment. The Kubernetes
# Load Balancer Controller owns the ALB association through the Ingress ARN.
locals {
  name = "${var.tag_header}${lookup(var.tags, "Project", "food-delivery")}-${lookup(var.tags, "Environment", "dev")}-waf"
  managed_rules = [
    { name = "AWSManagedRulesAmazonIpReputationList", priority = 20, metric = "ip-reputation" },
    { name = "AWSManagedRulesCommonRuleSet", priority = 30, metric = "common" },
    # Preserve the existing SQLi protection: CommonRuleSet is not a substitute.
    { name = "AWSManagedRulesSQLiRuleSet", priority = 40, metric = "sqli" }
  ]
}

resource "aws_wafv2_web_acl" "this" {
  count = var.enable ? 1 : 0
  name  = local.name
  scope = "REGIONAL"

  default_action {
    allow {}
  }

  # Evaluate the coarse request budget before terminating managed rules.
  rule {
    name     = "IngressIpRateLimit"
    priority = 10
    action {
      dynamic "count" {
        for_each = var.count_mode ? [1] : []
        content {}
      }
      dynamic "block" {
        for_each = var.count_mode ? [] : [1]
        content {}
      }
    }
    statement {
      rate_based_statement {
        aggregate_key_type    = "IP"
        limit                 = var.rate_limit
        evaluation_window_sec = 300
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      sampled_requests_enabled   = true
      metric_name                = "${local.name}-rate-limit"
    }
  }

  dynamic "rule" {
    for_each = local.managed_rules
    content {
      name     = rule.value.name
      priority = rule.value.priority
      override_action {
        dynamic "count" {
          for_each = var.count_mode ? [1] : []
          content {}
        }
        dynamic "none" {
          for_each = var.count_mode ? [] : [1]
          content {}
        }
      }
      statement {
        managed_rule_group_statement {
          name        = rule.value.name
          vendor_name = "AWS"
          # The app accepts multipart uploads up to NGINX's 20MB limit. The
          # Common 8KB size rule would block them even after observation mode.
          # Keep this one size signal in Count; other managed actions remain.
          dynamic "rule_action_override" {
            for_each = rule.value.name == "AWSManagedRulesCommonRuleSet" ? ["SizeRestrictions_BODY"] : []
            content {
              name = rule_action_override.value
              action_to_use {
                count {}
              }
            }
          }
        }
      }
      visibility_config {
        cloudwatch_metrics_enabled = true
        sampled_requests_enabled   = true
        metric_name                = "${local.name}-${rule.value.metric}"
      }
    }
  }

  # Sampling also captures request data. Protect credentials before WAF exports
  # samples; full request logging/Firehose/S3 destinations are not configured.
  data_protection_config {
    data_protection {
      action                     = "SUBSTITUTION"
      exclude_rate_based_details = false
      exclude_rule_match_details = false
      field {
        field_type = "SINGLE_HEADER"
        field_keys = ["authorization", "cookie", "set-cookie", "x-api-key", "referer"]
      }
    }
    dynamic "data_protection" {
      for_each = ["BODY", "QUERY_STRING"]
      content {
        action                     = "SUBSTITUTION"
        exclude_rate_based_details = false
        exclude_rule_match_details = false
        field {
          field_type = data_protection.value
        }
      }
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    sampled_requests_enabled   = true
    metric_name                = local.name
  }
  tags = merge(var.tags, { Name = local.name, Purpose = "application-ingress-protection" })
}
