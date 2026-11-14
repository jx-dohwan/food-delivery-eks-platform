output "alarm_names" {
  description = "생성된 CloudWatch Alarm 이름 목록"
  value = compact(concat(
    try([aws_cloudwatch_metric_alarm.alb_target_5xx[0].alarm_name], []),
    try([aws_cloudwatch_metric_alarm.alb_elb_5xx[0].alarm_name], []),
    try([aws_cloudwatch_metric_alarm.alb_unhealthy_hosts[0].alarm_name], []),
    try([aws_cloudwatch_metric_alarm.rds_cpu[0].alarm_name], []),
    try([aws_cloudwatch_metric_alarm.rds_freeable_memory[0].alarm_name], []),
    try([aws_cloudwatch_metric_alarm.redis_cpu[0].alarm_name], []),
    try([aws_cloudwatch_metric_alarm.redis_evictions[0].alarm_name], []),
  ))
}
