#!/usr/bin/env bash
# Merge the existing usage gate and worker budget hooks into global Claude settings.
set -euo pipefail
DOTFILES="${DOTFILES:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)}"
# --render only prints; every other run writes ~/.claude/settings.json (#1536).
if [ "${1:-}" != "--render" ]; then
  . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/dotfiles-source.sh"
  require_main_dotfiles setup-agent-hooks "$DOTFILES"
fi
python3 - "$DOTFILES" "$@" <<'PY'
import copy
import datetime
import json
import pathlib
import re
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
            # agent-team.sh machine writes the same hook as $HOME/dotfiles/...; one entry only (#1313).
            if path.name == 'usage-gate-hook.py' and any(
                    path.name in h.get('command', '') for g in hooks.get(event, []) for h in g.get('hooks', [])
                    if g.get('matcher') == group['matcher']):
                continue
            selected.append({'type': 'command', 'command': 'python3 ' + shlex.quote(str(path))})
        if selected:
            entry = {'matcher': group['matcher'], 'hooks': selected}
            entries = hooks.setdefault(event, [])
            if entry not in entries:
                entries.append(entry)
# An older run left an absolute path copy beside the $HOME/dotfiles one; keep a single usage gate hook (#1313).
gate = [h.get('command', '') for g in hooks.get('PreToolUse', []) if g.get('matcher') == 'Bash'
        for h in g.get('hooks', []) if 'usage-gate-hook.py' in h.get('command', '')]
if len(gate) > 1:
    keep = next((c for c in gate if c.startswith('f="$HOME/')), gate[0])
    for g in hooks['PreToolUse']:
        if g.get('matcher') == 'Bash':
            g['hooks'] = [h for h in g.get('hooks', [])
                          if 'usage-gate-hook.py' not in h.get('command', '') or h.get('command') == keep]
    hooks['PreToolUse'] = [g for g in hooks['PreToolUse'] if g.get('hooks')]
# A managed hook whose absolute script path is gone (a removed worktree) only adds an error per call.
for event in hooks:
    for g in hooks[event]:
        g['hooks'] = [h for h in g.get('hooks', [])
                      if not (re.fullmatch(r'python3 (/\S+/(usage-gate-hook|worker-budget)\.py)', h.get('command', ''))
                              and not pathlib.Path(h['command'][8:]).exists())]
    hooks[event] = [g for g in hooks[event] if g.get('hooks')]
# One worker-budget and one guard-bash registration per event and tool (#1797). A tool covered twice
# (an absolute path copy beside the $HOME one, or overlapping matchers) runs the hook twice and shows a deny twice.
# The widest matcher wins, then the $HOME form, so a moved checkout keeps working. A matcher that is not a plain
# tool list (a regex) is left alone.
for event in hooks:
    for name in ('worker-budget.py', 'guard-bash.py'):
        owners = []
        for gi, g in enumerate(hooks[event]):
            matcher = g.get('matcher')
            if matcher is None or not re.fullmatch(r'(\.\*|\w+)(\|\w+)*', matcher):
                continue
            for hi, h in enumerate(g['hooks']):
                if name in h.get('command', ''):
                    tools = ['*' if t == '.*' else t for t in matcher.split('|')]
                    owners.append((-len(tools), '$HOME' not in h['command'], gi, hi, tools))
        seen, drop, split = set(), set(), []
        for _, _, gi, hi, tools in sorted(owners):
            fresh = [t for t in tools if t not in seen]
            seen.update(tools)
            if not fresh:
                drop.add((gi, hi))
            elif len(fresh) < len(tools):
                drop.add((gi, hi))
                split.append({'matcher': '|'.join('.*' if t == '*' else t for t in fresh),
                              'hooks': [hooks[event][gi]['hooks'][hi]]})
        for gi, g in enumerate(hooks[event]):
            g['hooks'] = [h for hi, h in enumerate(g['hooks']) if (gi, hi) not in drop]
        hooks[event] = [g for g in hooks[event] if g['hooks']] + split
# The tracked Claude settings are the fleet defaults: their keys win over this machine's (#1395).
# Keys only this machine holds (env, mcpServers, feedbackDrafts, its own extras) are never touched.
# Hooks belong to Orca and agent-team.sh machine, and permissions.defaultMode to the team template.
# A skillOverrides key already set on this machine wins (#1313).
tracked = root / '.agents/claude/settings.json'
if tracked.is_file():
    for key, value in json.loads(tracked.read_text()).items():
        if key in ('hooks', 'env', 'mcpServers', 'feedbackDrafts'):
            continue
        if key == 'skillOverrides':
            data[key] = {**value, **data.get(key, {})}
        elif key == 'permissions':
            perms = data.setdefault('permissions', {})
            for rule in ('allow', 'deny', 'ask'):
                if rule in value:
                    have = perms.get(rule, [])
                    perms[rule] = have + [item for item in value[rule] if item not in have]
        elif isinstance(value, dict) and isinstance(data.get(key), dict):
            data[key] = {**data[key], **value}
        else:
            data[key] = value
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
