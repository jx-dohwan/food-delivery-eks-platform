# Initial dev budgets, not measured capacity or production sizing.
locals {
  platform_resources = {
    "lbc" : {
      "requests" : {
        "cpu" : "50m",
        "memory" : "64Mi"
      },
      "limits" : {
        "cpu" : "300m",
        "memory" : "256Mi"
      }
    },
    "argocd_controller" : {
      "requests" : {
        "cpu" : "100m",
        "memory" : "256Mi"
      },
      "limits" : {
        "cpu" : "1000m",
        "memory" : "768Mi"
      }
    },
    "argocd_repo" : {
      "requests" : {
        "cpu" : "50m",
        "memory" : "128Mi"
      },
      "limits" : {
        "cpu" : "500m",
        "memory" : "512Mi"
      }
    },
    "argocd_server" : {
      "requests" : {
        "cpu" : "25m",
        "memory" : "64Mi"
      },
      "limits" : {
        "cpu" : "250m",
        "memory" : "256Mi"
      }
    },
    "argocd_small" : {
      "requests" : {
        "cpu" : "25m",
        "memory" : "64Mi"
      },
      "limits" : {
        "cpu" : "200m",
        "memory" : "192Mi"
      }
    },
    "argocd_notify" : {
      "requests" : {
        "cpu" : "10m",
        "memory" : "32Mi"
      },
      "limits" : {
        "cpu" : "100m",
        "memory" : "128Mi"
      }
    },
    "eso" : {
      "requests" : {
        "cpu" : "50m",
        "memory" : "64Mi"
      },
      "limits" : {
        "cpu" : "300m",
        "memory" : "256Mi"
      }
    },
    "eso_webhook" : {
      "requests" : {
        "cpu" : "25m",
        "memory" : "32Mi"
      },
      "limits" : {
        "cpu" : "200m",
        "memory" : "128Mi"
      }
    },
    "eso_cert" : {
      "requests" : {
        "cpu" : "10m",
        "memory" : "32Mi"
      },
      "limits" : {
        "cpu" : "100m",
        "memory" : "128Mi"
      }
    },
    "reloader" : {
      "requests" : {
        "cpu" : "10m",
        "memory" : "32Mi"
      },
      "limits" : {
        "cpu" : "100m",
        "memory" : "128Mi"
      }
    },
    "metrics_server" : {
      "requests" : {
        "cpu" : "100m",
        "memory" : "200Mi"
      },
      "limits" : {
        "cpu" : "300m",
        "memory" : "384Mi"
      }
    }
  }
}
