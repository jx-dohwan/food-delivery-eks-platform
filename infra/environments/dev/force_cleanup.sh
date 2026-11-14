#!/usr/bin/env bash
# Legacy hardcoded-VPC cleanup is deliberately disabled.
set -euo pipefail
printf '%s\n' 'Legacy force cleanup is disabled. Use scripts/safe-teardown.sh --dry-run and review project ownership.' >&2
exit 1
