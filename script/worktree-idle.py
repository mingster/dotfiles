#!/usr/bin/env python3
"""Exit zero only when Orca positively lists no terminal in this worktree."""
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys


def idle(path, receipt):
    result = receipt.get('result') or {}
    if receipt.get('ok') is False or result.get('truncated') or not isinstance(result.get('terminals'), list):
        return False
    root = Path(path).resolve()
    for terminal in result['terminals']:
        cwd = terminal.get('cwd') or terminal.get('worktreePath')
        if not cwd:  # Unknown ownership cannot prove this worktree idle.
            return False
        location = Path(cwd).resolve()
        if location == root or root in location.parents:
            return False
    return True


if __name__ == '__main__':
    try:
        command = shlex.split(os.environ.get('ORCA_CLI_COMMAND', 'orca'))
        output = subprocess.run(command + ['terminal', 'list', '--limit', '500', '--json'], capture_output=True, text=True, check=True, timeout=10)
        safe = idle(sys.argv[1], json.loads(output.stdout))
    except (ValueError, OSError, subprocess.SubprocessError, IndexError):
        safe = False
    if not safe:
        print('worktree-idle: retaining worktree; terminal inventory is live or unverifiable', file=sys.stderr)
    sys.exit(0 if safe else 1)
