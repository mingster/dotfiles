#!/usr/bin/env bash
# Shared machine budget. Sensor override: HEAVY_GATE_READER <sample|hardware>.
# Commands default to a 1200-second (20-minute) wall clock limit after admission.
# HEAVY_GATE_TIMEOUT_SECONDS overrides it; 0 or "none" disables it. Timeout stops
# the process group (TERM, then KILL after 3 seconds), releases slots, and exits 124.
# --max-wait SECONDS (or HEAVY_GATE_WAIT_CAP_SECONDS) caps the wait for admission: past it the gate exits 75 and the
# command never runs. Once admitted the gate prints `heavy-gate: waited Ns for admission` on stderr.
set -euo pipefail
exec python3 "$(dirname "${BASH_SOURCE[0]}")/heavy-gate.py" gate "$@"
