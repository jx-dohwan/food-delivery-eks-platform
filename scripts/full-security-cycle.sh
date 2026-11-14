#!/usr/bin/env bash
# Retired: the old automatic apply/WAF-toggle flow bypassed runtime bindings,
# TLS/identity preflight and current controller-owned WAF association.
set -euo pipefail
printf '%s\n' 'STOP: legacy security-cycle entrypoint is disabled.' \
  'Run scripts/pre-full-deploy.py with verified Terraform outputs before application sync.' >&2
exit 1
