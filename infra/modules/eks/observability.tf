# Platform tools have one owner: Terraform Helm. Application ArgoCD does not
# contain monitoring CRDs and remains deployable when this optional stack is off.
locals {
  observability_values  = yamldecode(file("${path.module}/observability/values.yaml"))
  observability_scrapes = concat(local.observability_values.prometheus.prometheusSpec.additionalScrapeConfigs, var.enable_central_logging ? yamldecode(file("${path.module}/logging/additional-scrapes.yaml")) : [])
}

resource "helm_release" "observability" {
  count = var.enable_oss_observability ? 1 : 0

  name             = "observability"
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "kube-prometheus-stack"
  version          = "92.7.0"
  namespace        = "monitoring"
  create_namespace = true
  timeout          = 600

  values = [yamlencode(merge(local.observability_values, {
    prometheus = merge(local.observability_values.prometheus, {
      prometheusSpec = merge(local.observability_values.prometheus.prometheusSpec, { nodeSelector = local.system_node_selector, additionalScrapeConfigs = local.observability_scrapes })
    })
    prometheusOperator = merge(local.observability_values.prometheusOperator, { nodeSelector = local.system_node_selector })
    kube-state-metrics = merge(local.observability_values["kube-state-metrics"], { nodeSelector = local.system_node_selector })
    grafana = merge(local.observability_values.grafana, {
      nodeSelector = local.system_node_selector
      dashboards = {
        default = {
          food-delivery-overview = {
            json = file("${path.module}/observability/food-delivery-overview.json")
          }
        }
      }
    })
  })), var.enable_central_logging ? file("${path.module}/logging/alerting-values.yaml") : "{}"]

  depends_on = [aws_eks_node_group.this, aws_eks_addon.coredns, helm_release.aws_lbc]
}
