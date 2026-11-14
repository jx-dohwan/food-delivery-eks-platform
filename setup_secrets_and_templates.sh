#!/usr/bin/env bash
# Retired: this helper overwrote the current SHA/IRSA/WAF/network overlay.
set -euo pipefail
printf '%s\n' 'STOP: legacy manifest setup is disabled.' \
  'Use Terraform outputs with scripts/render-*-irsa.py and scripts/render-runtime-bindings.py.' \
  'Follow docs/pre-full-deploy.md; existing manifests are left unchanged.' >&2
exit 1
