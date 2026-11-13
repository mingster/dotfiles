#!/usr/bin/env bash
# Install the pinned codegraph, wire it into Claude Code, Cursor and Antigravity, and index a project.
# Idempotent: a second run changes nothing. agent-team.sh calls it behind --codegraph.
# Usage:
#   codegraph-setup.sh machine [--dry-run]       install the pin, link it, turn telemetry off, wire the three agents
#   codegraph-setup.sh project <dir> [--dry-run] index <dir> and keep .codegraph/ out of git
#   codegraph-setup.sh uninstall [--dry-run]     remove the hook, the three MCP entries, the permission and the link
#   codegraph-setup.sh version                   print the pinned version
# The pin is script/codegraph/package.json plus package-lock.json (npm ci checks every tarball hash).
# machine also keeps one UserPromptSubmit hook in ~/.claude/settings.json that runs the pinned binary
# (owner decision 2026-11-13) and drops the CLAUDE.md section codegraph install adds.
# Env: CODEGRAPH_HOME (default ~/.local/share/codegraph).
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
pin_dir="$here/codegraph"
data_home=${CODEGRAPH_HOME:-$HOME/.local/share/codegraph}
bin_dir=$HOME/.local/bin

die() { echo "codegraph-setup: $*" >&2; exit "${2:-1}"; }

pinned_version() {
  python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1]))["dependencies"]["@colbymchenry/codegraph"])' "$pin_dir/package.json"
}

# Run or, with --dry-run, announce.
act() { # <dry> <message> <command...>
  local dry=$1 msg=$2
  shift 2
  if [ "$dry" -eq 1 ]; then echo "would $msg"; else "$@"; fi
}

installed_bin() { echo "$data_home/$(pinned_version)/node_modules/.bin/codegraph"; }

install_pin() { # <dry>
  local dry=$1 ver dest
  ver=$(pinned_version)
  dest="$data_home/$ver"
  if [ -x "$dest/node_modules/.bin/codegraph" ] && [ "$("$dest/node_modules/.bin/codegraph" version 2>/dev/null)" = "$ver" ]; then
    return 0
  fi
  if [ "$dry" -eq 1 ]; then echo "would install codegraph $ver into $dest (npm ci --ignore-scripts)"; return 0; fi
  command -v npm >/dev/null 2>&1 || die "npm not found; cannot install codegraph $ver"
  mkdir -p "$dest"
  cp "$pin_dir/package.json" "$pin_dir/package-lock.json" "$dest/"
  (cd "$dest" && npm ci --ignore-scripts --no-audit --no-fund >/dev/null)
  echo "installed codegraph $ver into $dest"
}

link_pin() { # <dry>
  local dry=$1 want cur
  want=$(installed_bin)
  [ "$dry" -eq 0 ] || [ -x "$want" ] || { echo "would link $bin_dir/codegraph -> $want"; return 0; }
  cur=$(readlink "$bin_dir/codegraph" 2>/dev/null || true)
  if [ "$cur" != "$want" ]; then
    act "$dry" "link $bin_dir/codegraph -> $want" bash -c 'mkdir -p "$1" && ln -sfn "$2" "$1/codegraph"' _ "$bin_dir" "$want"
    [ "$dry" -eq 1 ] || echo "linked $bin_dir/codegraph -> $want"
  fi
  # The installer may have put its own launcher link on PATH; keep it on the pin too.
  local other=${DOTFILES:-$HOME/dotfiles}/mac/bin/codegraph
  if [ -L "$other" ] && [ "$(readlink "$other")" != "$want" ]; then
    act "$dry" "repoint $other -> $want" ln -sfn "$want" "$other"
  fi
}

telemetry_off() { # <dry>
  local dry=$1 st
  [ -x "$(installed_bin)" ] || { [ "$dry" -eq 0 ] || echo "would turn codegraph telemetry off"; return 0; }
  st=$("$(installed_bin)" telemetry 2>&1 || true)
  case "$st" in
    *"Telemetry: disabled"*) return 0 ;;
  esac
  act "$dry" "turn codegraph telemetry off" "$(installed_bin)" telemetry off >/dev/null
}

has_mcp() { # <json file> <key path as dotted keys>
  [ -f "$1" ] && python3 -I -c '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except ValueError:
    sys.exit(1)
sys.exit(0 if "codegraph" in (d.get("mcpServers") or {}) else 1)' "$1"
}

# The hook runs the pinned link, never whatever codegraph is first on PATH.
hook_cmd='$HOME/.local/bin/codegraph prompt-hook'

# Make ~/.claude/settings.json hold exactly one codegraph hook (the pinned command), or none with "remove".
set_hook() { # <ensure|remove>
  local settings=$HOME/.claude/settings.json
  [ -f "$settings" ] || [ "$1" = ensure ] || return 0
  [ -f "$settings" ] || { mkdir -p "$HOME/.claude"; echo '{}' > "$settings"; }
  python3 -I - "$settings" "$1" "$hook_cmd" <<'PY'
import json, sys
p, mode, cmd = sys.argv[1:4]
try:
    d = json.load(open(p))
except ValueError:
    print("codegraph-setup: skipped %s (not valid JSON)" % p, file=sys.stderr)
    sys.exit(0)
hooks = d.setdefault("hooks", {})
found = [(e, h.get("command")) for e, gs in hooks.items() for g in gs for h in g.get("hooks", []) if "codegraph" in h.get("command", "")]
if mode == "ensure" and found == [("UserPromptSubmit", cmd)]:
    sys.exit(0)
for event in list(hooks):
    groups = []
    for g in hooks[event]:
        inner = g.get("hooks", [])
        keep = [h for h in inner if "codegraph" not in h.get("command", "")]
        if keep or not inner:
            g["hooks"] = keep if inner else inner
            groups.append(g)
    hooks[event] = groups
groups = hooks.setdefault("UserPromptSubmit", [])
if mode == "ensure":
    groups.append({"hooks": [{"type": "command", "command": cmd}]})
for event in [e for e in hooks if not hooks[e]]:
    del hooks[event]
if not hooks:
    del d["hooks"]
out = json.dumps(d, indent=2) + "\n"
if out != open(p).read():
    open(p, "w").write(out)
    print("codegraph-setup: hook %s in %s" % ("set" if mode == "ensure" else "removed", p))
PY
}

strip_claude_md() { # remove the marker section codegraph install adds to CLAUDE.md
  local claude_md=$HOME/.claude/CLAUDE.md
  if [ -f "$claude_md" ] && grep -q '<!-- CODEGRAPH_START -->' "$claude_md"; then
    python3 -I - "$claude_md" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p).read()
open(p, "w").write(re.sub(r"\n?<!-- CODEGRAPH_START -->.*?<!-- CODEGRAPH_END -->\n?", "", s, flags=re.S))
PY
    echo "codegraph-setup: removed the codegraph section from $claude_md"
  fi
}

# Antigravity reads ~/.gemini/config once migrated (marker .migrated, or the file already there, as codegraph itself checks), else ~/.gemini/antigravity.
agy_mcp() {
  if [ -e "$HOME/.gemini/config/.migrated" ] || [ -e "$HOME/.gemini/config/mcp_config.json" ]; then echo "$HOME/.gemini/config/mcp_config.json"
  else echo "$HOME/.gemini/antigravity/mcp_config.json"; fi
}

wire_agents() { # <dry>
  local dry=$1 targets=() t
  has_mcp "$HOME/.claude.json" || targets+=(claude)
  has_mcp "$HOME/.cursor/mcp.json" || targets+=(cursor)
  has_mcp "$(agy_mcp)" || targets+=(antigravity)
  [ "${#targets[@]}" -gt 0 ] || return 0
  t=$(IFS=,; echo "${targets[*]}")
  if [ "$dry" -eq 1 ]; then echo "would run codegraph install --target=$t --location=global (then drop its CLAUDE.md section)"; return 0; fi
  PATH="$bin_dir:$PATH" "$(installed_bin)" install --target="$t" --location=global --yes >/dev/null
  echo "wired codegraph into: $t"
}

cmd_machine() {
  local dry=0 a
  for a in "$@"; do
    case "$a" in
      --dry-run) dry=1 ;;
      *) die "unknown machine option: $a" 2 ;;
    esac
  done
  install_pin "$dry"
  link_pin "$dry"
  telemetry_off "$dry"
  wire_agents "$dry"
  if [ "$dry" -eq 1 ]; then
    echo "would keep the codegraph prompt hook ($hook_cmd) in ~/.claude/settings.json"
  else
    set_hook ensure
    strip_claude_md
  fi
}

cmd_uninstall() {
  local dry=0 a f
  for a in "$@"; do
    case "$a" in
      --dry-run) dry=1 ;;
      *) die "unknown uninstall option: $a" 2 ;;
    esac
  done
  if [ "$dry" -eq 1 ]; then echo "would remove the codegraph hook, MCP entries, permission and $bin_dir/codegraph"; return 0; fi
  set_hook remove
  for f in "$HOME/.claude.json" "$HOME/.cursor/mcp.json" "$HOME/.gemini/config/mcp_config.json" "$HOME/.gemini/antigravity/mcp_config.json"; do
    [ -f "$f" ] || continue
    python3 -I - "$f" <<'PY'
import json, sys
p = sys.argv[1]
try:
    d = json.load(open(p))
except ValueError:
    print("codegraph-setup: skipped %s (not valid JSON)" % p, file=sys.stderr)
    sys.exit(0)
if "codegraph" in (d.get("mcpServers") or {}):
    del d["mcpServers"]["codegraph"]
    open(p, "w").write(json.dumps(d, indent=2) + "\n")
    print("codegraph-setup: removed the codegraph MCP entry from %s" % p)
PY
  done
  if [ -f "$HOME/.claude/settings.json" ]; then
    python3 -I - "$HOME/.claude/settings.json" <<'PY'
import json, sys
p = sys.argv[1]
try:
    d = json.load(open(p))
except ValueError:
    print("codegraph-setup: skipped %s (not valid JSON)" % p, file=sys.stderr)
    sys.exit(0)
allow = (d.get("permissions") or {}).get("allow") or []
if "mcp__codegraph__*" in allow:
    allow.remove("mcp__codegraph__*")
    open(p, "w").write(json.dumps(d, indent=2) + "\n")
    print("codegraph-setup: removed the mcp__codegraph__ permission from %s" % p)
PY
  fi
  strip_claude_md
  if [ -L "$bin_dir/codegraph" ]; then rm "$bin_dir/codegraph"; echo "codegraph-setup: removed $bin_dir/codegraph"; fi
}

cmd_project() {
  local dry=0 dir="" a git_dir common exclude
  for a in "$@"; do
    case "$a" in
      --dry-run) dry=1 ;;
      -*) die "unknown project option: $a" 2 ;;
      *) dir=$a ;;
    esac
  done
  [ -d "$dir" ] || die "project needs an existing directory" 2
  dir=$(cd "$dir" && pwd -P)
  if git -C "$dir" rev-parse --git-dir >/dev/null 2>&1; then
    git_dir=$(git -C "$dir" rev-parse --absolute-git-dir)
    common=$(cd "$dir" && cd "$(git rev-parse --git-common-dir)" && pwd -P)
    if [ "$git_dir" != "$common" ]; then
      echo "codegraph-setup: $dir is a linked worktree; index it on demand (codegraph init), not here"
      return 0
    fi
    exclude=$(git -C "$dir" rev-parse --path-format=absolute --git-path info/exclude)
    if ! grep -qxF '.codegraph/' "$exclude" 2>/dev/null; then
      act "$dry" "add .codegraph/ to $exclude" bash -c 'mkdir -p "$(dirname "$1")" && echo ".codegraph/" >> "$1"' _ "$exclude"
    fi
  fi
  if [ -f "$dir/.codegraph/codegraph.db" ]; then
    return 0
  fi
  if [ "$dry" -eq 1 ]; then echo "would index $dir (codegraph init)"; return 0; fi
  [ -x "$(installed_bin)" ] || die "codegraph is not installed; run: codegraph-setup.sh machine"
  (cd "$dir" && "$(installed_bin)" init >/dev/null)
  echo "indexed $dir"
}

sub=${1:-}
[ -n "$sub" ] || { sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
shift
case "$sub" in
  machine) cmd_machine "$@" ;;
  project) cmd_project "$@" ;;
  uninstall) cmd_uninstall "$@" ;;
  version) pinned_version ;;
  *) die "unknown subcommand: $sub" 2 ;;
esac
