#!/usr/bin/env bash
# Shared machine budget. Sensor override: HEAVY_GATE_READER <sample|hardware>.
set -euo pipefail
exec python3 "$(dirname "${BASH_SOURCE[0]}")/heavy-gate.py" gate "$@"
