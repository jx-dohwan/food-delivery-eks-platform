#!/usr/bin/env bash
# Update both app images (and the WAS migration image) using the base image names.
# Git records only the immutable SHA tag. The account-specific ECR registry is injected at
# deploy time by the ArgoCD Application (scripts/render-argocd-application.py), never committed.
set -euo pipefail

: "${SOURCE_SHA:?SOURCE_SHA is required}"
if [[ ! "$SOURCE_SHA" =~ ^[0-9a-f]{40}$ ]]; then
  echo "SOURCE_SHA must be a full Git commit SHA" >&2
  exit 1
fi

overlay="${1:-k8s/overlays/dev}"
kustomize_bin="${KUSTOMIZE_BIN:-kustomize}"
(
  cd "$overlay"
  "$kustomize_bin" edit set image \
    "food-delivery-was=ecr-registry.invalid/was:${SOURCE_SHA}" \
    "food-delivery-web=ecr-registry.invalid/web:${SOURCE_SHA}"
)
"$kustomize_bin" build "$overlay"
