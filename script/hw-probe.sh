#!/usr/bin/env bash
# Inspect hardware; calibrate only at a quiet time with a local workload command.
set -euo pipefail
exec python3 "$(dirname "${BASH_SOURCE[0]}")/heavy-gate.py" probe "$@"
