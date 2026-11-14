locals {
  loki_values  = yamldecode(file("${path.module}/logging/loki-values.yaml"))
  alloy_values = yamldecode(file("${path.module}/logging/alloy-values.yaml"))
  csi_values   = yamldecode(file("${path.module}/logging/ebs-csi-values.yaml"))
  alloy_config = replace(file("${path.module}/logging/config.alloy"), "\"app\"", jsonencode(local.was_namespace))
  logging_trust_subjects = {
    loki = "system:serviceaccount:monitoring:loki"
    ebs  = "system:serviceaccount:kube-system:ebs-csi-controller-sa"

  }
}
resource "aws_iam_role" "logging" {
  for_each = var.enable_central_logging ? local.logging_trust_subjects : {}
  name     = "${var.cluster_name}-${each.key}"
  assume_role_policy = jsonencode({ Version = "2012-10-17", Statement = [{
    Effect = "Allow", Action = "sts:AssumeRoleWithWebIdentity",
    Principal = { Federated = aws_iam_openid_connect_provider.this.arn
    },
    Condition = { StringEquals = {
      "${replace(aws_iam_openid_connect_provider.this.url, "https://", "")}:aud" = "sts.amazonaws.com",
      "${replace(aws_iam_openid_connect_provider.this.url, "https://", "")}:sub" = each.value

      }
    }

    }]
  })
  tags = var.tags
}
resource "aws_iam_role_policy" "loki_s3" {
  count = var.enable_central_logging ? 1 : 0
  role  = aws_iam_role.logging["loki"].id
  policy = jsonencode({ Version = "2012-10-17", Statement = [
    { Effect = "Allow", Action = ["s3:ListBucket", "s3:GetBucketLocation"], Resource = "arn:aws:s3:::${var.loki_bucket_name}"
    },
    { Effect = "Allow", Action = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"], Resource = "arn:aws:s3:::${var.loki_bucket_name}/*"
    }
    ]
  })
}
resource "aws_iam_role_policy" "ebs" {
  count = var.enable_central_logging ? 1 : 0
  role  = aws_iam_role.logging["ebs"].id
  policy = jsonencode({ Version = "2012-10-17", Statement = [
    { Effect = "Allow", Action = ["ec2:DescribeAvailabilityZones", "ec2:DescribeInstances", "ec2:DescribeInstanceTypes", "ec2:DescribeVolumes", "ec2:DescribeVolumesModifications", "ec2:DescribeTags"], Resource = "*", Condition = { StringEquals = { "aws:RequestedRegion" = var.region } } },
    { Effect = "Allow", Action = ["ec2:CreateVolume"], Resource = "arn:aws:ec2:${var.region}:${data.aws_caller_identity.was.account_id}:volume/*", Condition = { StringEquals = { "aws:RequestTag/ebs.csi.aws.com/cluster" = "true", "aws:RequestTag/Project" = "food-delivery", "aws:RequestTag/Environment" = var.was_environment, "aws:RequestTag/Cluster" = var.cluster_name } } },
    { Effect = "Allow", Action = ["ec2:CreateTags"], Resource = "arn:aws:ec2:${var.region}:${data.aws_caller_identity.was.account_id}:volume/*", Condition = { StringEquals = { "ec2:CreateAction" = "CreateVolume" } } },
    { Effect = "Allow", Action = ["ec2:AttachVolume", "ec2:DetachVolume", "ec2:DeleteVolume", "ec2:ModifyVolume"], Resource = "arn:aws:ec2:${var.region}:${data.aws_caller_identity.was.account_id}:volume/*", Condition = { StringEquals = { "ec2:ResourceTag/ebs.csi.aws.com/cluster" = "true", "ec2:ResourceTag/Project" = "food-delivery", "ec2:ResourceTag/Environment" = var.was_environment, "ec2:ResourceTag/Cluster" = var.cluster_name } } },
    { Effect = "Allow", Action = ["ec2:AttachVolume", "ec2:DetachVolume"], Resource = "arn:aws:ec2:${var.region}:${data.aws_caller_identity.was.account_id}:instance/*" }
  ] })
}
resource "helm_release" "ebs_csi" {
  count      = var.enable_central_logging ? 1 : 0
  name       = "ebs-csi"
  repository = "https://kubernetes-sigs.github.io/aws-ebs-csi-driver"
  chart      = "aws-ebs-csi-driver"
  version    = "2.67.2"
  namespace  = "kube-system"
  timeout    = 600
  values = [yamlencode(merge(local.csi_values, { controller = merge(local.csi_values.controller, {
    region          = var.region, nodeSelector = local.system_node_selector,
    extraVolumeTags = merge(local.csi_values.controller.extraVolumeTags, { Environment = var.was_environment, Cluster = var.cluster_name }),
    serviceAccount = { name = "ebs-csi-controller-sa", annotations = { "eks.amazonaws.com/role-arn" = aws_iam_role.logging["ebs"].arn
      }
    }

    })
  }))]
  depends_on = [aws_eks_node_group.this, aws_eks_addon.coredns, aws_iam_role_policy.ebs]
}
resource "helm_release" "loki" {
  count      = var.enable_central_logging ? 1 : 0
  name       = "loki"
  repository = "https://grafana-community.github.io/helm-charts"
  chart      = "loki"
  version    = "20.0.2"
  namespace  = "monitoring"
  timeout    = 600
  values = [yamlencode(merge(local.loki_values, {
    singleBinary = merge(local.loki_values.singleBinary, { nodeSelector = local.system_node_selector
    }),
    serviceAccount = merge(local.loki_values.serviceAccount, { annotations = { "eks.amazonaws.com/role-arn" = aws_iam_role.logging["loki"].arn
      }
    }),
    loki = merge(local.loki_values.loki, { storage = merge(local.loki_values.loki.storage, {
      bucketNames = { chunks = var.loki_bucket_name, ruler = var.loki_bucket_name, admin = var.loki_bucket_name
      },
      s3 = { region = var.region, s3ForcePathStyle = false, insecure = false
      }

      })
    })

  }))]
  lifecycle {
    precondition {
      condition     = startswith(var.loki_bucket_name, "food-delivery-loki-") && var.instance_type == "t3.large" && var.was_environment == "dev" && var.enable_oss_observability && can(regex("^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$", var.loki_bucket_name))
      error_message = "Central logging dev preset requires t3.large nodes, observability and a separately protected dedicated S3 archive."

    }
  }
  depends_on = [helm_release.observability, helm_release.ebs_csi, aws_iam_role_policy.loki_s3, kubernetes_config_map_v1.loki_rules]
}
resource "helm_release" "alloy" {
  count      = var.enable_central_logging ? 1 : 0
  name       = "alloy"
  repository = "https://grafana.github.io/helm-charts"
  chart      = "alloy"
  version    = "1.14.3"
  namespace  = "monitoring"
  timeout    = 600
  values = [yamlencode(merge(local.alloy_values, {
    controller = merge(local.alloy_values.controller, {
      podAnnotations = { "checksum/config" = sha256(local.alloy_config) }
    }),
    alloy = merge(local.alloy_values.alloy, {
      extraEnv = [
        { name = "LOG_NAMESPACE", value = local.was_namespace },
        { name = "CLUSTER_NAME", value = var.cluster_name }
      ]

    })

  }))]
  # No API discovery/RBAC or pre-existing app namespace dependency.
  depends_on = [helm_release.loki, kubernetes_config_map_v1.alloy]
}
resource "kubernetes_network_policy_v1" "loki" {
  count = var.enable_central_logging ? 1 : 0
  metadata {
    name      = "loki-private"
    namespace = "monitoring"

  }
  spec {
    pod_selector {
      match_labels = { "app.kubernetes.io/instance" = "loki"
      }
    }
    policy_types = ["Ingress", "Egress"]
    ingress {
      from {
        pod_selector {
          match_labels = { "app.kubernetes.io/name" = "grafana"
          }
        }
      }
      from {
        pod_selector {
          match_labels = { "app.kubernetes.io/name" = "alloy"
          }
        }
      }
      from {
        pod_selector {
          match_labels = { "app.kubernetes.io/name" = "prometheus"
          }
        }
      }
      ports {
        port     = "3100"
        protocol = "TCP"

      }

    }
    egress {
      to {
        pod_selector { match_labels = { "app.kubernetes.io/name" = "alertmanager" } }
      }
      ports { port = "9093" }
    }
    egress {
      ports {
        port     = "443"
        protocol = "TCP"

      }
    } # S3 / regional STS; IAM constrains the dedicated bucket. No egress proxy in dev.
    egress {
      to {
        namespace_selector {
          match_labels = { "kubernetes.io/metadata.name" = "kube-system"
          }
        }
        pod_selector {
          match_labels = { "k8s-app" = "kube-dns"
          }
        }

      }
      ports {
        port     = "53"
        protocol = "UDP"

      }
      ports {
        port     = "53"
        protocol = "TCP"

      }

    }

  }
  depends_on = [helm_release.observability]
}

resource "kubernetes_network_policy_v1" "alloy" {
  count = var.enable_central_logging ? 1 : 0
  metadata {
    name      = "alloy-private"
    namespace = "monitoring"
  }
  spec {
    pod_selector { match_labels = { "app.kubernetes.io/name" = "alloy" } }
    policy_types = ["Ingress", "Egress"]
    ingress {
      from {
        pod_selector {
          match_labels = { "app.kubernetes.io/name" = "prometheus" }
        }
      }
      ports { port = "12345" }
    }
    egress {
      to {
        pod_selector {
          match_labels = { "app.kubernetes.io/instance" = "loki" }
        }
      }
      ports { port = "3100" }
    }
    egress {
      to {
        namespace_selector { match_labels = { "kubernetes.io/metadata.name" = "kube-system" } }
        pod_selector { match_labels = { "k8s-app" = "kube-dns" } }
      }
      ports {
        port     = "53"
        protocol = "UDP"
      }
      ports { port = "53" }
    }
  }
  depends_on = [helm_release.observability]
}

resource "kubernetes_config_map_v1" "alloy" {
  count = var.enable_central_logging ? 1 : 0
  metadata {
    name      = "alloy-config"
    namespace = "monitoring"
  }
  data       = { "config.alloy" = local.alloy_config }
  depends_on = [helm_release.observability]
}

resource "kubernetes_config_map_v1" "loki_rules" {
  count = var.enable_central_logging ? 1 : 0
  metadata {
    name      = "loki-alert-rules"
    namespace = "monitoring"
  }
  data       = { "dependencies.yaml" = file("${path.module}/logging/loki-rules.yaml") }
  depends_on = [helm_release.observability]
}
