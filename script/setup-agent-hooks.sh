#!/usr/bin/env bash
# Merge the existing usage gate and worker budget hooks into global Claude settings.
set -euo pipefail
DOTFILES="${DOTFILES:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)}"
python3 - "$DOTFILES" "$@" <<'PY'
import copy
import datetime
import json
import pathlib
import shlex
import sys

root = pathlib.Path(sys.argv[1])
render = len(sys.argv) == 4 and sys.argv[2] == '--render'
if len(sys.argv) != 2 and not render:
    sys.exit('Usage: setup-agent-hooks.sh [--render <settings-template>]')
settings = pathlib.Path.home() / '.claude/settings.json'
template = json.loads((root / 'templates/agent-team/.claude/settings.json').read_text())


def merge(base, extra):
    if isinstance(base, dict) and isinstance(extra, dict):
        out = dict(base)
        for key, value in extra.items():
            out[key] = merge(base[key], value) if key in base else value
        return out
    if isinstance(base, list) and isinstance(extra, list):
        return base + [item for item in extra if item not in base]
    return extra


# An untracked settings.local.json beside the template holds per machine values.
local = pathlib.Path(sys.argv[3]).with_name('settings.local.json') if render else None
data = json.loads(pathlib.Path(sys.argv[3]).read_text()) if render else (json.loads(settings.read_text()) if settings.exists() else {})
if local is not None and local.is_file():
    data = merge(data, json.loads(local.read_text()))
before = copy.deepcopy(data)
hooks = data.setdefault('hooks', {})
for event, groups in template['hooks'].items():
    for group in groups:
        selected = []
        for hook in group['hooks']:
            command = hook.get('command', '')
            if 'usage-gate-hook.py' in command:
                path = root / 'script/usage-gate-hook.py'
            elif 'worker-budget.py' in command:
                path = root / 'templates/agent-team/.claude/hooks/worker-budget.py'
            else:
                continue
            selected.append({'type': 'command', 'command': 'python3 ' + shlex.quote(str(path))})
        if selected:
            entry = {'matcher': group['matcher'], 'hooks': selected}
            entries = hooks.setdefault(event, [])
            if entry not in entries:
                entries.append(entry)
if render:
    print(json.dumps(data, indent=2))
    sys.exit(0)
if data != before:
    settings.parent.mkdir(parents=True, exist_ok=True)
    if settings.exists() or settings.is_symlink():
        backup = settings.with_name(settings.name + '.bak.' + datetime.datetime.now().strftime('%Y%m%dT%H%M%S%f'))
        settings.rename(backup)
        print('setup-agent-hooks: backed up differing settings to ' + str(backup))
    settings.write_text(json.dumps(data, indent=2) + '\n')
print('setup-agent-hooks: usage gate and worker budget configured')
PY
