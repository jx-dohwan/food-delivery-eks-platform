#!/usr/bin/env bash
# Operator-only, default read-only inventory. No regional bulk cleanup.
set -euo pipefail
exec python3 "$(cd "$(dirname "$0")" && pwd)/safe_teardown.py" "$@"
