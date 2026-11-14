#!/usr/bin/env bash
# Legacy launcher fails closed before AWS or cluster calls.
set -euo pipefail
root_dir="$(cd "$(dirname "$0")/.." && pwd)"
exec bash "$root_dir/scripts/full-security-cycle.sh"
