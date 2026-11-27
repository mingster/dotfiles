#!/usr/bin/env bash
# settle-orphan-task.sh --run <run_id> --task <task_id> [--dry-run]: settle a dispatched task whose dispatch record is gone on every server (#2022).
# Checks the local and every paired server first and refuses when any shows a dispatch. See script/settle-orphan-task.py.
set -u
exec python3 "$(cd "$(dirname "$0")" && pwd -P)/settle-orphan-task.py" "$@"
