# =============================================================================
# [용도] ops 관측 — CloudWatch 네이티브 메트릭 알람 (비용·보안 우선)
# =============================================================================
# 설계 의도 (적합성 / 비용절감 / 보안):
#   - OSS Prometheus/Grafana는 EKS Helm 소유; 이 모듈은 AWS Alarm만 담당
#   - Container Insights / managed metrics ingestion은 추가하지 않음
#   - ALB·Aurora·Redis 가 이미 내보내는 CloudWatch 메트릭만 사용 (에이전트 0)
#   - 알람 → 기존 SNS(ops-alerts) → Slack Lambda (시크릿 로테이션과 동일 파이프)
#   - Fluent Bit / 로그 중앙화는 옵션(미포함). 필요 시 retention 짧게 별도 추가
#
# HPA 는 Metrics Server 가 담당 (이 모듈 범위 밖)
# =============================================================================

locals {
  # count 는 plan 시점에 확정되어야 함.
  # SNS/RDS/Redis id 는 apply 후 알 수 있으므로 != "" 체크로 count 하지 말 것.
  # enable 은 root 에서 (ops_monitoring && slack_webhook 설정) 으로 넘긴다.
  enabled     = var.enable
  alb_enabled = var.enable && var.enable_alb_alarms
  env         = lookup(var.tags, "Environment", "dev")
  project     = lookup(var.tags, "Project", "food-delivery")
}

# --- ALB: 5xx (타겟) ----------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "alb_target_5xx" {
  count               = local.alb_enabled ? 1 : 0
  alarm_name          = "${var.tag_header}alb-target-5xx"
  alarm_description   = "Ingress ALB target 5xx — 앱/업스트림 오류 급증"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "HTTPCode_Target_5XX_Count"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Sum"
  threshold           = var.alb_5xx_threshold
  treat_missing_data  = "notBreaching"

  dimensions = {
    LoadBalancer = var.alb_arn_suffix
  }

  alarm_actions = [var.sns_topic_arn]
  ok_actions    = [var.sns_topic_arn]

  tags = merge(var.tags, {
    Environment = local.env
    Project     = local.project
    Purpose     = "ops-monitoring"
  })
}

# --- ALB: ELB 자체 5xx (게이트웨이/인증서 등) --------------------------------
resource "aws_cloudwatch_metric_alarm" "alb_elb_5xx" {
  count               = local.alb_enabled ? 1 : 0
  alarm_name          = "${var.tag_header}alb-elb-5xx"
  alarm_description   = "Ingress ALB ELB 5xx — 로드밸런서 측 오류"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "HTTPCode_ELB_5XX_Count"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Sum"
  threshold           = var.alb_5xx_threshold
  treat_missing_data  = "notBreaching"

  dimensions = {
    LoadBalancer = var.alb_arn_suffix
  }

  alarm_actions = [var.sns_topic_arn]
  ok_actions    = [var.sns_topic_arn]

  tags = merge(var.tags, {
    Environment = local.env
    Project     = local.project
    Purpose     = "ops-monitoring"
  })
}

# --- ALB Target Group: UnHealthyHostCount (TG 있을 때만) ----------------------
resource "aws_cloudwatch_metric_alarm" "alb_unhealthy_hosts" {
  count               = local.alb_enabled && var.enable_alb_unhealthy_alarm ? 1 : 0
  alarm_name          = "${var.tag_header}alb-unhealthy-hosts"
  alarm_description   = "Ingress target unhealthy hosts > 0"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "UnHealthyHostCount"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Maximum"
  threshold           = 0
  treat_missing_data  = "notBreaching"

  dimensions = {
    LoadBalancer = var.alb_arn_suffix
    TargetGroup  = var.alb_target_group_arn_suffix
  }

  alarm_actions = [var.sns_topic_arn]
  ok_actions    = [var.sns_topic_arn]

  tags = merge(var.tags, {
    Environment = local.env
    Project     = local.project
    Purpose     = "ops-monitoring"
  })
}

# --- Aurora MySQL: Writer CPU -------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "rds_cpu" {
  count               = local.enabled ? 1 : 0
  alarm_name          = "${var.tag_header}rds-cpu-high"
  alarm_description   = "Aurora instance CPU > threshold"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/RDS"
  period              = 300
  statistic           = "Average"
  threshold           = var.rds_cpu_threshold
  treat_missing_data  = "notBreaching"

  dimensions = {
    DBInstanceIdentifier = var.rds_instance_identifier
  }

  alarm_actions = [var.sns_topic_arn]
  ok_actions    = [var.sns_topic_arn]

  tags = merge(var.tags, {
    Environment = local.env
    Project     = local.project
    Purpose     = "ops-monitoring"
  })
}

# --- Aurora: FreeableMemory (낮으면 알람) -------------------------------------
resource "aws_cloudwatch_metric_alarm" "rds_freeable_memory" {
  count               = local.enabled ? 1 : 0
  alarm_name          = "${var.tag_header}rds-freeable-memory-low"
  alarm_description   = "Aurora FreeableMemory below threshold (bytes)"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 2
  metric_name         = "FreeableMemory"
  namespace           = "AWS/RDS"
  period              = 300
  statistic           = "Average"
  threshold           = var.rds_freeable_memory_bytes
  treat_missing_data  = "notBreaching"

  dimensions = {
    DBInstanceIdentifier = var.rds_instance_identifier
  }

  alarm_actions = [var.sns_topic_arn]
  ok_actions    = [var.sns_topic_arn]

  tags = merge(var.tags, {
    Environment = local.env
    Project     = local.project
    Purpose     = "ops-monitoring"
  })
}

# --- Redis: CPU ---------------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "redis_cpu" {
  count               = local.enabled ? 1 : 0
  alarm_name          = "${var.tag_header}redis-cpu-high"
  alarm_description   = "ElastiCache Redis CPU > threshold"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/ElastiCache"
  period              = 300
  statistic           = "Average"
  threshold           = var.redis_cpu_threshold
  treat_missing_data  = "notBreaching"

  dimensions = {
    CacheClusterId = var.redis_cache_cluster_id
  }

  alarm_actions = [var.sns_topic_arn]
  ok_actions    = [var.sns_topic_arn]

  tags = merge(var.tags, {
    Environment = local.env
    Project     = local.project
    Purpose     = "ops-monitoring"
  })
}

# --- Redis: Evictions (캐시 압박) ---------------------------------------------
resource "aws_cloudwatch_metric_alarm" "redis_evictions" {
  count               = local.enabled ? 1 : 0
  alarm_name          = "${var.tag_header}redis-evictions"
  alarm_description   = "ElastiCache Redis evictions > 0 (memory pressure)"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "Evictions"
  namespace           = "AWS/ElastiCache"
  period              = 300
  statistic           = "Sum"
  threshold           = 0
  treat_missing_data  = "notBreaching"

  dimensions = {
    CacheClusterId = var.redis_cache_cluster_id
  }

  alarm_actions = [var.sns_topic_arn]
  ok_actions    = [var.sns_topic_arn]

  tags = merge(var.tags, {
    Environment = local.env
    Project     = local.project
    Purpose     = "ops-monitoring"
  })
}
