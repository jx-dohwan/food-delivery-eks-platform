# ==============================================================================
# 1. AWS Load Balancer Controller IAM Policy
# ==============================================================================
locals {
  lbc_version = "3.5.0"
}

data "http" "lbc_iam_policy" {
  url = "https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v${local.lbc_version}/docs/install/iam_policy.json"
}

resource "aws_iam_policy" "lbc_policy" {
  name        = "${var.tag_header}AWSLoadBalancerControllerIAMPolicy"
  description = "IAM Policy for AWS Load Balancer Controller"
  policy      = data.http.lbc_iam_policy.response_body
}

# ==============================================================================
# 2. IRSA Role (ServiceAccount: kube-system:aws-load-balancer-controller)
# ==============================================================================
data "aws_iam_policy_document" "lbc_assume_role" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.this.url, "https://", "")}:sub"
      values   = ["system:serviceaccount:kube-system:aws-load-balancer-controller"]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.this.url, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }

    principals {
      identifiers = [aws_iam_openid_connect_provider.this.arn]
      type        = "Federated"
    }
  }
}

resource "aws_iam_role" "lbc_role" {
  name               = "${var.tag_header}aws-load-balancer-controller-role"
  assume_role_policy = data.aws_iam_policy_document.lbc_assume_role.json
}

resource "aws_iam_role_policy_attachment" "lbc_attach" {
  role       = aws_iam_role.lbc_role.name
  policy_arn = aws_iam_policy.lbc_policy.arn
}

# ==============================================================================
# 3. AWS Load Balancer Controller Helm 설치
# ==============================================================================
resource "helm_release" "aws_lbc" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = local.lbc_version
  namespace  = "kube-system"
  wait       = true

  values = [
    yamlencode({
      clusterName  = aws_eks_cluster.this.name
      resources    = local.platform_resources.lbc
      nodeSelector = local.system_node_selector
      region       = var.region
      vpcId        = var.vpc_id
      serviceAccount = {
        create = true
        name   = "aws-load-balancer-controller"
        annotations = {
          "eks.amazonaws.com/role-arn" = aws_iam_role.lbc_role.arn
        }
      }
    })
  ]

  depends_on = [
    aws_eks_cluster.this,
    aws_eks_node_group.this,
    aws_eks_addon.coredns,
    aws_iam_role_policy_attachment.lbc_attach
  ]
}

# ==============================================================================
# 4. ArgoCD Helm 설치 (ClusterIP — 퍼블릭 NLB 없음, port-forward 전용)
# ==============================================================================
resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = "10.10.5"
  namespace        = "argocd"
  create_namespace = true

  # ClusterIP: 퍼블릭 NLB 제거. 관리자는 kubectl port-forward svc/argocd-server -n argocd 8080:443
  values = [
    yamlencode({
      global         = { nodeSelector = local.system_node_selector }
      controller     = { resources = local.platform_resources.argocd_controller }
      repoServer     = { resources = local.platform_resources.argocd_repo }
      applicationSet = { resources = local.platform_resources.argocd_small }
      notifications  = { resources = local.platform_resources.argocd_notify }
      redis          = { resources = local.platform_resources.argocd_small }
      dex            = { resources = local.platform_resources.argocd_small }
      server = {
        resources = local.platform_resources.argocd_server
        extraArgs = ["--insecure"]
        service = {
          type = "ClusterIP"
        }
      }
    })
  ]

  depends_on = [
    aws_eks_cluster.this,
    aws_eks_node_group.this,
    helm_release.aws_lbc
  ]
}

# ==============================================================================
# 5. External Secrets Operator IAM Policy & IRSA Role
# ==============================================================================
locals {
  eso_secret_names = length(var.eso_secret_names) == 2 ? var.eso_secret_names : [
    "${var.tag_header}rds-aurora-credentials",
    "${var.tag_header}rds-aurora-credentials-connection"
  ]
}

resource "aws_iam_policy" "eso_policy" {
  name        = "${var.tag_header}ExternalSecretsPolicy"
  description = "IAM Policy for External Secrets Operator to read Secrets Manager"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
      # Secrets Manager appends exactly six random characters to a secret ARN.
      # Scope to the two configured names, never the account's other secrets.
      Resource = [for name in local.eso_secret_names :
        "arn:aws:secretsmanager:${var.region}:${data.aws_caller_identity.was.account_id}:secret:${name}-??????"
      ]
    }]
  })
}

resource "aws_iam_role" "eso_role" {
  name = "${var.tag_header}external-secrets-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow", Action = "sts:AssumeRoleWithWebIdentity"
      Principal = { Federated = aws_iam_openid_connect_provider.this.arn }
      Condition = { StringEquals = {
        "${replace(aws_iam_openid_connect_provider.this.url, "https://", "")}:sub" = "system:serviceaccount:${local.was_namespace}:eso-service-account"
        "${replace(aws_iam_openid_connect_provider.this.url, "https://", "")}:aud" = "sts.amazonaws.com"
      } }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "eso_attach" {
  role       = aws_iam_role.eso_role.name
  policy_arn = aws_iam_policy.eso_policy.arn
}

# ==============================================================================
# 6. External Secrets Operator Helm 설치 (CRD 포함)
# ==============================================================================
resource "helm_release" "external_secrets" {
  name             = "external-secrets"
  repository       = "https://charts.external-secrets.io"
  chart            = "external-secrets"
  version          = "2.12.0"
  namespace        = "external-secrets"
  create_namespace = true
  values = [yamlencode({
    resources      = local.platform_resources.eso
    nodeSelector   = local.system_node_selector
    webhook        = { nodeSelector = local.system_node_selector, resources = local.platform_resources.eso_webhook }
    certController = { nodeSelector = local.system_node_selector, resources = local.platform_resources.eso_cert }
  })]

  set {
    name  = "installCRDs"
    value = "true"
  }

  depends_on = [
    aws_eks_cluster.this,
    aws_eks_node_group.this,
    aws_iam_role_policy_attachment.eso_attach,
    helm_release.aws_lbc
  ]
}

# ==============================================================================
# 7. Stakater Reloader Helm 설치 (Secret 갱신 시 자동 롤링 재시작)
# ==============================================================================
resource "helm_release" "reloader" {
  name       = "reloader"
  repository = "https://stakater.github.io/stakater-charts"
  chart      = "reloader"
  version    = "2.2.18"
  namespace  = "kube-system"

  values = [
    yamlencode({
      reloader = {
        autoSearch = true
        deployment = { nodeSelector = local.system_node_selector, resources = local.platform_resources.reloader }
      }
    })
  ]

  depends_on = [
    aws_eks_cluster.this,
    aws_eks_node_group.this
  ]
}

# ==============================================================================
# 8. Metrics Server Helm 설치 (HPA 오토스케일링용)
# ==============================================================================
resource "helm_release" "metrics_server" {
  name       = "metrics-server"
  repository = "https://kubernetes-sigs.github.io/metrics-server/"
  chart      = "metrics-server"
  version    = "3.14.0"
  namespace  = "kube-system"

  values = [
    yamlencode({
      resources    = local.platform_resources.metrics_server
      nodeSelector = local.system_node_selector
      # Chart 3.14.0 otherwise adds a second preferred-address flag including
      # ExternalIP/Hostname. Keep one explicit, evidence-checked address policy.
      defaultArgs = ["--cert-dir=/tmp", "--kubelet-use-node-status-port", "--metric-resolution=15s"]
      args = concat([
        "--kubelet-preferred-address-types=InternalIP",
        ], var.metrics_server_kubelet_tls_verified ? [
        "--kubelet-certificate-authority=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
        ] : [
        "--kubelet-insecure-tls"
      ])
    })
  ]

  depends_on = [
    aws_eks_cluster.this,
    aws_eks_node_group.this,
    helm_release.aws_lbc
  ]
}

# ==============================================================================
# Output (K8s ServiceAccount 연동용)
# ==============================================================================
output "eso_role_arn" {
  description = "IAM Role ARN for External Secrets Operator"
  value       = aws_iam_role.eso_role.arn
}

output "eso_irsa_config" {
  value = {
    role_arn                   = aws_iam_role.eso_role.arn
    service_account            = "eso-service-account"
    authentication_secret_name = local.eso_secret_names[0]
    connection_secret_name     = local.eso_secret_names[1]
  }
}
