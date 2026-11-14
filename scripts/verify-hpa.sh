#!/usr/bin/env bash
set -euo pipefail
NS="${NS:-app}"
# Read-only evidence only. Never create accounts or start load implicitly.
if [[ "$NS" != "app" && "$NS" != "app-prod" ]]; then
  echo "Unsupported application namespace" >&2
  exit 2
fi
echo "== HPA and resource metrics =="
kubectl get hpa was-hpa -n "$NS"
kubectl describe hpa was-hpa -n "$NS"
kubectl get apiservice v1beta1.metrics.k8s.io
kubectl top pods -n "$NS" -l app=was
echo "== Deployment, Pod readiness and Service endpoints =="
kubectl get deploy was-deployment -n "$NS"
kubectl get pods -n "$NS" -l app=was -o wide
kubectl get endpointslice -n "$NS" -l kubernetes.io/service-name=nest
echo "No load was started. Review HPA metrics before running a separate load test."
