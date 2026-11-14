# ==============================================================================
# Route53 — app Ingress ALB Alias (수동 콘솔 설정을 IaC로 동기화)
# ==============================================================================
# NOTE: Ingress ALB를 먼저 지운 뒤 destroy 하면 data.aws_lb 가 0건으로 실패합니다.
# teardown 시에는 -var='manage_ingress_alb_alias=false' 로 끄세요.

data "aws_route53_zone" "app" {
  count        = var.manage_ingress_alb_alias ? 1 : 0
  name         = var.route53_zone_name
  private_zone = false
}

data "aws_lbs" "app_ingress" {
  count = var.manage_ingress_alb_alias ? 1 : 0

  tags = {
    "ingress.k8s.aws/stack" = var.alb_ingress_stack_tag
    "elbv2.k8s.aws/cluster" = local.cluster_name
  }
  lifecycle {
    postcondition {
      condition     = length(self.arns) == 1
      error_message = "DNS stage requires exactly one verified dev Ingress ALB. Keep alias management disabled during initial infrastructure creation."
    }
  }
}

locals {
  # manage_ingress_alb_alias=false 이면 data 자체가 count=0 → [0] 참조 금지
  ingress_alb_arn = length(data.aws_lbs.app_ingress) > 0 ? one(tolist(data.aws_lbs.app_ingress[0].arns)) : null
}

data "aws_lb" "app_ingress" {
  count = var.manage_ingress_alb_alias ? 1 : 0
  arn   = local.ingress_alb_arn
  lifecycle {
    postcondition {
      condition     = self.vpc_id == module.network.vpc_id && self.load_balancer_type == "application"
      error_message = "Only the single controller ALB in this dev VPC may own the DNS alias."
    }
  }
}

resource "aws_route53_record" "dev_app" {
  count   = var.manage_ingress_alb_alias ? 1 : 0
  zone_id = data.aws_route53_zone.app[0].zone_id
  name    = var.dev_domain_name
  type    = "A"
  # A stale alias from an earlier (destroyed) ALB may remain; this project owns the name.
  allow_overwrite = true

  alias {
    name                   = data.aws_lb.app_ingress[0].dns_name
    zone_id                = data.aws_lb.app_ingress[0].zone_id
    evaluate_target_health = true
  }
}

resource "aws_route53_record" "www_app" {
  count   = var.manage_ingress_alb_alias && var.manage_www_record ? 1 : 0
  zone_id = data.aws_route53_zone.app[0].zone_id
  name    = var.www_domain_name
  type    = "A"
  # A stale alias from an earlier (destroyed) ALB may remain; this project owns the name.
  allow_overwrite = true

  alias {
    name                   = data.aws_lb.app_ingress[0].dns_name
    zone_id                = data.aws_lb.app_ingress[0].zone_id
    evaluate_target_health = true
  }
}
