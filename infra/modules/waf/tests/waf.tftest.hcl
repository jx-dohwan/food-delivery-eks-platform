# No AWS API calls: plan only, using the same native mock pattern as Rotation.
mock_provider "aws" {
  override_during = plan
  mock_resource "aws_wafv2_web_acl" {
    defaults = {
      arn = "arn:aws:wafv2:ap-northeast-2:123456789012:regional/webacl/food-delivery-dev-waf/11111111-1111-1111-1111-111111111111"
      id  = "11111111-1111-1111-1111-111111111111"
    }
  }
}

variables {
  enable = true
  tags   = { Project = "food-delivery", Environment = "dev" }
}

run "observe" {
  command = plan
  assert {
    condition     = length([for r in aws_wafv2_web_acl.this[0].rule : r if r.name == "IngressIpRateLimit" && r.priority == 10 && length(r.statement[0].rate_based_statement) == 1]) == 1
    error_message = "The rate rule must exist and run before managed terminating rules."
  }
  assert {
    condition     = aws_wafv2_web_acl.this[0].scope == "REGIONAL" && aws_wafv2_web_acl.this[0].name == "food-delivery-dev-waf"
    error_message = "Use one environment-specific Regional ACL."
  }
  assert {
    condition     = length(aws_wafv2_web_acl.this[0].default_action[0].allow) == 1
    error_message = "Default traffic must remain allowed."
  }
  assert {
    condition     = length(aws_wafv2_web_acl.this[0].rule) == 4 && length(distinct([for r in aws_wafv2_web_acl.this[0].rule : r.priority])) == 4
    error_message = "Four rules only, with distinct priorities (including preserved SQLi)."
  }
  assert {
    condition = toset(flatten([
      for r in aws_wafv2_web_acl.this[0].rule : [
        for s in r.statement : [for g in s.managed_rule_group_statement : g.name]
      ]
    ])) == toset(["AWSManagedRulesCommonRuleSet", "AWSManagedRulesAmazonIpReputationList", "AWSManagedRulesSQLiRuleSet"])
    error_message = "Use only basic Common/IP Reputation/SQLi managed groups; no premium groups."
  }
  assert {
    condition = alltrue([for r in aws_wafv2_web_acl.this[0].rule :
      length(r.action) == 0 ? length(r.override_action[0].count) == 1 : length(r.action[0].count) == 1
    ])
    error_message = "Initial observation must use Count for every rule."
  }
  assert {
    condition = alltrue([for r in aws_wafv2_web_acl.this[0].rule :
      r.visibility_config[0].cloudwatch_metrics_enabled && r.visibility_config[0].sampled_requests_enabled
    ]) && aws_wafv2_web_acl.this[0].visibility_config[0].cloudwatch_metrics_enabled && aws_wafv2_web_acl.this[0].visibility_config[0].sampled_requests_enabled
    error_message = "Enable metrics/sampling on the ACL and every rule."
  }
  assert {
    condition     = length(distinct([for r in aws_wafv2_web_acl.this[0].rule : r.visibility_config[0].metric_name])) == 4
    error_message = "Rule metrics must have distinct names."
  }
  assert {
    condition = alltrue(flatten([for r in aws_wafv2_web_acl.this[0].rule : [for s in r.statement : [
      for rate in s.rate_based_statement : rate.limit == 6000 && rate.evaluation_window_sec == 300 && rate.aggregate_key_type == "IP" && length(rate.forwarded_ip_config) == 0
    ]]]))
    error_message = "Use origin IP, explicit 300-second window and coarse 6000-request budget."
  }
  assert {
    condition = toset([for d in aws_wafv2_web_acl.this[0].data_protection_config[0].data_protection : d.field[0].field_type]) == toset(["BODY", "QUERY_STRING", "SINGLE_HEADER"]) && alltrue([
      for d in aws_wafv2_web_acl.this[0].data_protection_config[0].data_protection : d.action == "SUBSTITUTION" && !d.exclude_rule_match_details && !d.exclude_rate_based_details
    ])
    error_message = "Protect sensitive sampled request data and match details."
  }
  assert {
    condition = length(setsubtract(toset(["authorization", "cookie", "set-cookie", "x-api-key"]), toset(flatten([
      for d in aws_wafv2_web_acl.this[0].data_protection_config[0].data_protection : d.field[0].field_type == "SINGLE_HEADER" ? d.field[0].field_keys : []
    ])))) == 0
    error_message = "Authentication headers must be substituted in samples."
  }
}

run "enforce" {
  command = plan
  variables {
    count_mode = false
    rate_limit = 8000
  }
  assert {
    condition = length(flatten([for r in aws_wafv2_web_acl.this[0].rule : [for s in r.statement : [
      for g in s.managed_rule_group_statement : g.rule_action_override if g.name == "AWSManagedRulesCommonRuleSet"
    ]]])) == 1
    error_message = "Keep the known upload size exception in enforcement mode."
  }
  assert {
    condition = alltrue([for r in aws_wafv2_web_acl.this[0].rule :
      length(r.action) == 0 ? length(r.override_action[0].none) == 1 : length(r.action[0].block) == 1
    ])
    error_message = "Enforce restores managed actions and blocks rate violations."
  }
  assert {
    condition = alltrue(flatten([for r in aws_wafv2_web_acl.this[0].rule : [for s in r.statement : [
      for g in s.managed_rule_group_statement : alltrue([for o in g.rule_action_override : o.name == "SizeRestrictions_BODY" && length(o.action_to_use[0].count) == 1])
    ]]]))
    error_message = "Only the known upload body-size false positive may remain Count."
  }
}

run "disabled" {
  command = plan
  variables {
    enable = false
  }
  assert {
    condition     = length(aws_wafv2_web_acl.this) == 0 && output.web_acl_arn == null && output.web_acl_id == null
    error_message = "Disabled WAF must create no billable ACL."
  }
}

run "invalid_rate" {
  command = plan
  variables {
    rate_limit = 9
  }
  expect_failures = [var.rate_limit]
}
