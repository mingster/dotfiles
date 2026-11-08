#!/usr/bin/env bash
# agent-team.sh: Single entrypoint for machine and project Agent Team setup, migration, sync, and drift check.
#
# Usage:
#   ~/dotfiles/script/agent-team.sh machine [--dry-run]
#   ~/dotfiles/script/agent-team.sh project [<dir>] [--project-name <name>] [--dry-run] [--labels]
#   ~/dotfiles/script/agent-team.sh sync    [<dir>] [--project-name <name>] [--dry-run] [--labels]
#   ~/dotfiles/script/agent-team.sh check   [<dir> ...]
#   ~/dotfiles/script/agent-team.sh all     [<dir>] [--project-name <name>] [--dry-run] [--labels]
set -euo pipefail

export DOTFILES="${DOTFILES:-$(cd "$(dirname "$0")/.." && pwd)}"
TEMPLATE_DIR="$DOTFILES/templates/agent-team"
SEEDS_DIR="$DOTFILES/.agents/skills/setup-matt-pocock-skills"

SHARED_BINS=(
  env-peek.py
  state-of-play.sh
)

usage() {
  sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

die() {
  echo "agent-team: $*" >&2
  exit "${2:-1}"
}

require_templates() {
  [ -d "$TEMPLATE_DIR" ] || die "templates directory not found: $TEMPLATE_DIR" 1
  [ -d "$SEEDS_DIR" ] || die "seeds directory not found: $SEEDS_DIR" 1
}

link_one() {
  local src=$1 dst=$2 dry=$3
  if [ -L "$dst" ] && [ "$(readlink "$dst")" = "$src" ]; then
    return 0
  fi
  if [ "$dry" -eq 1 ]; then
    echo "would link $dst -> $src"
    return 0
  fi
  rm -rf "$dst"
  ln -s "$src" "$dst"
  echo "linked $dst -> $src"
}

ensure_dir() {
  local dir=$1 dry=$2
  [ -d "$dir" ] && return 0
  if [ "$dry" -eq 1 ]; then
    echo "would create dir $dir"
  else
    mkdir -p "$dir"
  fi
}

merge_machine_settings() {
  local tpl=$1 dst=$2 dry=$3
  if [ ! -f "$dst" ]; then
    if [ "$dry" -eq 1 ]; then
      echo "would write $dst"
    else
      python3 - "$tpl" "$dst" <<'PY'
import json, re, sys
tpl_path, dst_path = sys.argv[1], sys.argv[2]
with open(tpl_path) as f:
    tpl = json.load(f)
for event, groups in tpl.get("hooks", {}).items():
    for g in groups:
        for h in g.get("hooks", []):
            if "command" in h:
                h["command"] = re.sub(
                    r"\$CLAUDE_PROJECT_DIR/\.claude/(hooks|bin)/",
                    r"$HOME/.claude/\1/",
                    h["command"],
                )
with open(dst_path, "w") as f:
    json.dump(tpl, f, indent=2)
    f.write("\n")
PY
      echo "wrote $dst"
    fi
    return 0
  fi

  python3 - "$tpl" "$dst" "$dry" <<'PY'
import json, re, sys

tpl_path, dst_path, dry = sys.argv[1], sys.argv[2], int(sys.argv[3])
with open(tpl_path) as f:
    tpl = json.load(f)
try:
    with open(dst_path) as f:
        cur = json.load(f)
except Exception as exc:
    sys.stderr.write(f"error: {dst_path} is not valid JSON: {exc}\n")
    sys.exit(1)
if not isinstance(cur, dict):
    sys.stderr.write(f"error: {dst_path} root must be a JSON object\n")
    sys.exit(1)

orig = json.dumps(cur, sort_keys=True)


def rewrite_cmd(cmd):
    return re.sub(
        r"\$CLAUDE_PROJECT_DIR/\.claude/(hooks|bin)/",
        r"$HOME/.claude/\1/",
        cmd,
    )


perms = cur.setdefault("permissions", {})
tpl_perms = tpl.get("permissions", {})
if "defaultMode" in tpl_perms:
    perms["defaultMode"] = tpl_perms["defaultMode"]
for key in ("allow", "deny", "ask"):
    existing = list(perms.get(key, []))
    for item in tpl_perms.get(key, []):
        if item not in existing:
            existing.append(item)
    if existing or key in perms:
        perms[key] = existing

denied_mcp = list(cur.get("deniedMcpServers", []))
for srv in tpl.get("deniedMcpServers", []):
    if srv not in denied_mcp:
        denied_mcp.append(srv)
if denied_mcp:
    cur["deniedMcpServers"] = denied_mcp

hooks = cur.setdefault("hooks", {})
for event, groups in tpl.get("hooks", {}).items():
    cur_groups = list(hooks.get(event, []))
    seen = set()
    for g in cur_groups:
        m = g.get("matcher", "")
        for h in g.get("hooks", []):
            seen.add((m, h.get("command", "")))
    for g in groups:
        m = g.get("matcher", "")
        new_hooks = []
        for h in g.get("hooks", []):
            nh = dict(h)
            if "command" in nh:
                nh["command"] = rewrite_cmd(nh["command"])
            key = (m, nh.get("command", ""))
            if key not in seen:
                seen.add(key)
                new_hooks.append(nh)
        if new_hooks:
            entry = {"hooks": new_hooks}
            if "matcher" in g:
                entry["matcher"] = m
            cur_groups.append(entry)
    hooks[event] = cur_groups

if json.dumps(cur, sort_keys=True) == orig:
    sys.exit(0)
if dry:
    print(f"would merge {dst_path}")
    sys.exit(0)
with open(dst_path, "w") as f:
    json.dump(cur, f, indent=2)
    f.write("\n")
print(f"merged {dst_path}")
PY
}

cmd_machine() {
  local dry=0
  for arg in "$@"; do
    case "$arg" in
      --dry-run) dry=1 ;;
      -h|--help) usage 0 ;;
      *) die "unknown machine option: $arg" 2 ;;
    esac
  done
  require_templates

  ensure_dir "$HOME/.claude/agents" "$dry"
  ensure_dir "$HOME/.claude/hooks" "$dry"
  ensure_dir "$HOME/.claude/bin" "$dry"
  ensure_dir "$HOME/.claude/skills" "$dry"
  ensure_dir "$HOME/.agents/skills" "$dry"
  ensure_dir "$HOME/.cursor/skills" "$dry"

  local f name d s
  for f in "$TEMPLATE_DIR/.claude/agents/"*.md; do
    [ -f "$f" ] || continue
    link_one "$f" "$HOME/.claude/agents/$(basename "$f")" "$dry"
  done

  for name in guard-bash.py strikes.py worker-budget.py session-start.md; do
    [ -f "$TEMPLATE_DIR/.claude/hooks/$name" ] || continue
    link_one "$TEMPLATE_DIR/.claude/hooks/$name" "$HOME/.claude/hooks/$name" "$dry"
  done

  for name in "${SHARED_BINS[@]}"; do
    [ -f "$TEMPLATE_DIR/.claude/bin/$name" ] || continue
    link_one "$TEMPLATE_DIR/.claude/bin/$name" "$HOME/.claude/bin/$name" "$dry"
  done

  if [ -f "$TEMPLATE_DIR/.claude/model-routing.md" ]; then
    link_one "$TEMPLATE_DIR/.claude/model-routing.md" "$HOME/.claude/model-routing.md" "$dry"
  fi

  for d in "$DOTFILES/.agents/skills"/*/; do
    [ -d "$d" ] || continue
    s=$(basename "$d")
    link_one "${d%/}" "$HOME/.agents/skills/$s" "$dry"
    link_one "../../.agents/skills/$s" "$HOME/.claude/skills/$s" "$dry"
    link_one "../../.agents/skills/$s" "$HOME/.cursor/skills/$s" "$dry"
  done

  for d in "$TEMPLATE_DIR/.agents/skills"/*/; do
    [ -d "$d" ] || continue
    s=$(basename "$d")
    if [ -d "$DOTFILES/.agents/skills/$s" ]; then
      die "skill collision between Tier 1 and Tier 2 in dotfiles: $s" 1
    fi
    link_one "${d%/}" "$HOME/.agents/skills/$s" "$dry"
    link_one "../../.agents/skills/$s" "$HOME/.claude/skills/$s" "$dry"
    link_one "../../.agents/skills/$s" "$HOME/.cursor/skills/$s" "$dry"
  done

  merge_machine_settings "$TEMPLATE_DIR/.claude/settings.json" "$HOME/.claude/settings.json" "$dry"
}

validate_target_dir() {
  local raw=$1
  [ -d "$raw" ] || die "target directory does not exist: $raw" 2
  local target dotfiles_real home_real
  target=$(cd "$raw" && pwd -P)
  dotfiles_real=$(cd "$DOTFILES" && pwd -P)
  home_real=$(cd "$HOME" && pwd -P)
  if [ "$target" = "$dotfiles_real" ] || [ "$target" = "$home_real" ]; then
    die "refusing dotfiles or home as target: $raw" 2
  fi
  git -C "$target" rev-parse --git-dir >/dev/null 2>&1 || die "not a git repository: $raw" 2
  printf '%s\n' "$target"
}

check_safe_paths() {
  local target=$1
  local rel path cur resolved
  local managed_paths=(
    AGENTS.md
    CLAUDE.md
    .gitignore
    .claude
    .claude/agents
    .claude/hooks
    .claude/hooks/guard-config.json
    .claude/bin
    .claude/skills
    .claude/settings.json
    .claude/settings.project.json
    .claude/model-routing.md
    .cursor
    .cursor/skills
    .cursor/changelog-hook.json
    .agents
    .agents/skills
    docs
    docs/agents
    docs/agents/issue-tracker.md
    docs/agents/triage-labels.md
    docs/agents/domain.md
    docs/agents/team.md
    docs/agents/team-facts.md
    docs/agents/deploy-facts.md
    docs/agents/elon-dispatch.md
    docs/agents/release-manager-work.md
    bin
    bin/changelog-compile.sh
    bin/changelog-compile.test.sh
    changelog.d
    changelog.d/README.md
  )
  for rel in "${managed_paths[@]}"; do
    path="$target/$rel"
    if [ -L "$path" ]; then
      die "refused symlinked managed destination $rel" 2
    fi
    cur="$path"
    while [ ! -e "$cur" ] && [ "$cur" != "$target" ]; do
      cur=$(dirname "$cur")
    done
    if [ -d "$cur" ]; then
      resolved=$(cd "$cur" && pwd -P)
    else
      resolved=$(cd "$(dirname "$cur")" && pwd -P)/$(basename "$cur")
    fi
    case "$resolved" in
      "$target"|"$target"/*) ;;
      *) die "managed destination $rel resolves outside $target ($resolved)" 2 ;;
    esac
  done
}

detect_project_name() {
  local target=$1 explicit=${2:-}
  if [ -n "$explicit" ]; then
    printf '%s\n' "$explicit"
    return 0
  fi
  if [ -f "$target/docs/agents/team-facts.md" ]; then
    local h
    # shellcheck disable=SC2016
    h=$(sed -n 's/^\* `team \([^`]*\)`\..*/\1/p' "$target/docs/agents/team-facts.md" | head -n 1)
    if [ -n "$h" ] && [ "$h" != "{{PROJECT_NAME}}" ]; then
      printf '%s\n' "$h"
      return 0
    fi
  fi
  if [ -f "$target/.claude/agent-team-project-name" ]; then
    local n
    n=$(head -n 1 "$target/.claude/agent-team-project-name" | tr -d '\r\n')
    if [ -n "$n" ]; then
      printf '%s\n' "$n"
      return 0
    fi
  fi
  if [ -f "$target/AGENTS.md" ]; then
    local a
    a=$(sed -n '1s/^# //p' "$target/AGENTS.md")
    if [ -n "$a" ]; then
      printf '%s\n' "$a"
      return 0
    fi
  fi
  basename "$target"
}

detect_tracker() {
  local repo=$1 url
  url=$(git -C "$repo" remote get-url origin 2>/dev/null || true)
  case "$url" in
    *github.com*) echo github ;;
    *gitlab*)     echo gitlab ;;
    *)            echo local ;;
  esac
}

github_slug() {
  local repo=$1 url
  url=$(git -C "$repo" remote get-url origin 2>/dev/null || true)
  echo "$url" | sed -E 's#^.*github\.com[:/]##; s#\.git$##'
}

create_github_labels() {
  local target=$1 dry=$2
  local tracker slug name color desc
  tracker=$(detect_tracker "$target")
  if [ "$tracker" != "github" ]; then
    echo "agent-team: $target is $tracker, skipping --labels"
    return 0
  fi
  slug=$(github_slug "$target")
  [ -n "$slug" ] || { echo "agent-team: cannot parse github slug for $target" >&2; return 1; }
  while IFS='|' read -r name color desc; do
    [ -n "$name" ] || continue
    if [ "$dry" -eq 1 ]; then
      echo "would create label $name ($color) on $slug"
    else
      gh label create --repo "$slug" "$name" --color "$color" --description "$desc" --force >/dev/null
      echo "label $name on $slug"
    fi
  done <<'EOF'
needs-triage|d4c5f9|New issue awaiting triage
needs-info|fef2c0|Waiting on reporter for reproduction or detail
ready-for-agent|0e8a16|Scoped and ready for an autonomous agent
ready-for-human|1d76db|Needs a human decision or change
wontfix|ffffff|Out of scope or declined
EOF
}

# Python helper that performs:
#   mode="project": extraction, removal, seeding, settings compilation, and template sync (or dry-run report)
#   mode="check":   read-only verification of all drift rules
run_project_engine() {
  local mode=$1 target=$2 project_name=$3 dry=$4
  AGENT_TEAM_SYNC=1 python3 - "$mode" "$target" "$project_name" "$dry" "$DOTFILES" "$TEMPLATE_DIR" "$SEEDS_DIR" <<'PY'
import ast
import fnmatch
import json
import os
import re
import shutil
import stat
import sys

mode, target, project_name, dry_str, dotfiles, template_dir, seeds_dir = sys.argv[1:8]
dry = int(dry_str)

CANONICAL_ROLES = [
    "elon.md",
    "architect-pm.md",
    "fullstack-dev.md",
    "qa-sdet.md",
    "secops-finops.md",
    "release-manager.md",
    "sales-marketing.md",
    "support-csm.md",
]

SHARED_HOOKS = [
    "guard-bash.py",
    "strikes.py",
    "worker-budget.py",
    "session-start.md",
    "production-hosts.txt",
]

SHARED_BINS = [
    "env-peek.py",
    "state-of-play.sh",
]

TIER2_SKILLS = sorted(
    {
        "ceo",
        "crew",
        "deploy",
        "elon",
        "poteto-mode",
        "staging-review",
        "team-audit",
        "tl",
    }
    | (
        set(os.listdir(os.path.join(template_dir, ".agents", "skills")))
        if os.path.isdir(os.path.join(template_dir, ".agents", "skills"))
        else set()
    )
)

TEMPLATE_SYNC_FILES = [
    ".claude/model-routing.md",
    "docs/agents/team.md",
    "docs/agents/elon-dispatch.md",
    "docs/agents/release-manager-work.md",
    "bin/changelog-compile.sh",
    "bin/changelog-compile.test.sh",
    "changelog.d/README.md",
]

GITIGNORE_ENTRIES = [
    "active_run.md",
    ".claude/state/",
    ".claude/release-reports/",
]

PROTECTED_HOOK_SCRIPTS = {
    "guard-bash.py",
    "strikes.py",
    "worker-budget.py",
    "session-start.md",
    "production-hosts.txt",
    "env-peek.py",
    "state-of-play.sh",
    "usage-gate-hook.py",
}

GUARD_DEFAULTS = {
    "production_hosts": [],
    "stage_branches": ["stage", "staging"],
    "stage_branch_components": [],
    "promote_scripts": [],
    "rollback_scripts": [],
    "apply_scripts": [],
    "schema_override": [
        "--accept-data-loss",
        "--force-reset",
        "migrate reset",
        "db push --force",
    ],
    "approval_namespace": "",
    "approval_file": "",
    "blocked_scripts": [],
    "secrets_dir": ".secrets",
    "sign_in_script": "",
    "secrets_stdin_ok": [],
    "worktree_env_allow": [".env.example", ".env.sample", ".env.template"],
}

GUARD_CONST_MAP = {
    "PRODUCTION_HOSTS": "production_hosts",
    "STAGE_BRANCHES": "stage_branches",
    "STAGE_BRANCH_COMPONENTS": "stage_branch_components",
    "PROMOTE_RULES": "promote_scripts",
    "PROMOTE_SCRIPTS": "promote_scripts",
    "ROLLBACK_SCRIPTS": "rollback_scripts",
    "APPLY_SCRIPTS": "apply_scripts",
    "SCHEMA_OVERRIDE": "schema_override",
    "APPROVAL_NAMESPACE": "approval_namespace",
    "APPROVAL_FILE": "approval_file",
    "BLOCKED_SCRIPTS": "blocked_scripts",
    "SECRETS_DIR": "secrets_dir",
    "SIGN_IN_SCRIPT": "sign_in_script",
    "SECRETS_STDIN_OK": "secrets_stdin_ok",
    "WORKTREE_ENV_ALLOW": "worktree_env_allow",
}


def read_text(path):
    with open(path, "r", encoding="utf-8") as f:
        return f.read()


def write_text(rel, content, executable=False):
    full = os.path.join(target, rel)
    existed = os.path.exists(full)
    if existed and not os.path.islink(full):
        try:
            old = read_text(full)
        except Exception:
            old = None
        if old == content:
            if executable:
                st = os.stat(full).st_mode
                if not (st & stat.S_IXUSR):
                    if dry:
                        print(f"would chmod +x {rel}")
                    else:
                        os.chmod(full, st | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
            return False
    if dry:
        action = "would update" if existed else "would write"
        print(f"{action} {rel}")
        return True
    os.makedirs(os.path.dirname(full), exist_ok=True)
    with open(full, "w", encoding="utf-8") as f:
        f.write(content)
    if executable:
        st = os.stat(full).st_mode
        os.chmod(full, st | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
    print(f"{'updated' if existed else 'wrote'} {rel}")
    return True


def detect_tracker_py():
    import subprocess
    res = subprocess.run(
        ["git", "-C", target, "remote", "get-url", "origin"],
        capture_output=True,
        text=True,
    )
    url = (res.stdout or "").strip()
    if "github.com" in url:
        return "github"
    if "gitlab" in url:
        return "gitlab"
    return "local"


def extract_guard_config():
    guard_cfg_path = os.path.join(target, ".claude/hooks/guard-config.json")
    existing = {}
    if os.path.isfile(guard_cfg_path):
        try:
            loaded = json.loads(read_text(guard_cfg_path))
            if isinstance(loaded, dict):
                existing = loaded
        except Exception:
            pass

    extracted = {}
    guard_py = os.path.join(target, ".claude/hooks/guard-bash.py")
    tpl_guard_py = os.path.join(template_dir, ".claude/hooks/guard-bash.py")

    if os.path.isfile(guard_py) and not os.path.islink(guard_py):
        src = read_text(guard_py)
        tpl_src = read_text(tpl_guard_py) if os.path.isfile(tpl_guard_py) else ""
        if src != tpl_src:
            try:
                tree = ast.parse(src)
                for node in tree.body:
                    names = []
                    val_node = None
                    if isinstance(node, ast.Assign):
                        names = [t.id for t in node.targets if isinstance(t, ast.Name)]
                        val_node = node.value
                    elif isinstance(node, ast.AnnAssign) and isinstance(node.target, ast.Name):
                        names = [node.target.id]
                        val_node = node.value
                    if not names or val_node is None:
                        continue
                    for cname in names:
                        if cname not in GUARD_CONST_MAP:
                            continue
                        key = GUARD_CONST_MAP[cname]
                        try:
                            val = ast.literal_eval(val_node)
                        except Exception:
                            continue
                        if key == "promote_scripts":
                            norm = []
                            for item in val or []:
                                if isinstance(item, (list, tuple)) and len(item) >= 3:
                                    norm.append(
                                        {
                                            "script": str(item[0]),
                                            "branch": str(item[1]),
                                            "requires_approval": bool(item[2]),
                                        }
                                    )
                                elif isinstance(item, dict):
                                    norm.append(item)
                            if norm:
                                extracted[key] = norm
                        elif isinstance(val, (set, tuple, list)):
                            lst = [str(x) for x in val]
                            if key == "production_hosts":
                                lst = sorted(set(lst))
                            if lst and lst != GUARD_DEFAULTS.get(key):
                                extracted[key] = lst
                        elif isinstance(val, str):
                            if val and val != GUARD_DEFAULTS.get(key):
                                extracted[key] = val
            except Exception:
                pass

    hosts_txt = os.path.join(target, ".claude/hooks/production-hosts.txt")
    if os.path.isfile(hosts_txt) and not os.path.islink(hosts_txt):
        hosts = []
        for line in read_text(hosts_txt).splitlines():
            h = line.split("#", 1)[0].strip()
            if h and h not in hosts:
                hosts.append(h)
        if hosts:
            merged_hosts = list(extracted.get("production_hosts", []))
            for h in hosts:
                if h not in merged_hosts:
                    merged_hosts.append(h)
            extracted["production_hosts"] = merged_hosts

    merged = dict(existing)
    newly_extracted = {}
    for k, v in extracted.items():
        if isinstance(v, list) and isinstance(merged.get(k), list):
            cur_list = list(merged[k])
            added = []
            for item in v:
                if item not in cur_list:
                    cur_list.append(item)
                    added.append(item)
            if added:
                merged[k] = cur_list
                newly_extracted[k] = added
        elif k not in merged or merged[k] != v:
            merged[k] = v
            newly_extracted[k] = v

    for k, v in newly_extracted.items():
        print(f"extract .claude/hooks/guard-config.json: {k}={json.dumps(v)}")

    if newly_extracted or not os.path.isfile(guard_cfg_path):
        write_text(".claude/hooks/guard-config.json", json.dumps(merged, indent=2) + "\n")


def is_legacy_template_hook_cmd(cmd):
    for script in PROTECTED_HOOK_SCRIPTS:
        if (
            f"/.claude/hooks/{script}" in cmd
            or f"/.claude/bin/{script}" in cmd
            or f".claude/hooks/{script}" in cmd
            or f".claude/bin/{script}" in cmd
            or f"script/{script}" in cmd
        ):
            return True
    return False


def extract_settings_project():
    proj_settings_path = os.path.join(target, ".claude/settings.project.json")
    settings_path = os.path.join(target, ".claude/settings.json")
    tpl_settings = json.loads(read_text(os.path.join(template_dir, ".claude/settings.json")))

    existing = {"permissions": {"allow": [], "deny": []}, "hooks": {}}
    if os.path.isfile(proj_settings_path):
        try:
            loaded = json.loads(read_text(proj_settings_path))
            if isinstance(loaded, dict):
                existing = loaded
                existing.setdefault("permissions", {})
                existing["permissions"].setdefault("allow", [])
                existing["permissions"].setdefault("deny", [])
                existing.setdefault("hooks", {})
        except Exception:
            pass

    changed = False
    if os.path.isfile(settings_path) and not os.path.islink(settings_path):
        try:
            cur = json.loads(read_text(settings_path))
        except Exception:
            cur = {}
        if isinstance(cur, dict):
            tpl_allow = set(tpl_settings.get("permissions", {}).get("allow", []))
            tpl_deny = set(tpl_settings.get("permissions", {}).get("deny", []))
            cur_perms = cur.get("permissions", {})
            if isinstance(cur_perms, dict):
                for item in cur_perms.get("allow", []):
                    if item not in tpl_allow and item not in existing["permissions"]["allow"]:
                        existing["permissions"]["allow"].append(item)
                        print(f"extract .claude/settings.project.json permissions.allow: {item}")
                        changed = True
                for item in cur_perms.get("deny", []):
                    if item not in tpl_deny and item not in existing["permissions"]["deny"]:
                        existing["permissions"]["deny"].append(item)
                        print(f"extract .claude/settings.project.json permissions.deny: {item}")
                        changed = True

            tpl_hook_cmds = {
                th.get("command", "")
                for tgroups in tpl_settings.get("hooks", {}).values()
                for tg in tgroups
                for th in tg.get("hooks", [])
                if isinstance(th, dict)
            }
            cur_hooks = cur.get("hooks", {})
            if isinstance(cur_hooks, dict):
                for event, groups in cur_hooks.items():
                    if not isinstance(groups, list):
                        continue
                    for g in groups:
                        if not isinstance(g, dict):
                            continue
                        matcher = g.get("matcher", "")
                        kept_hooks = []
                        for h in g.get("hooks", []):
                            if not isinstance(h, dict):
                                continue
                            cmd = h.get("command", "")
                            if not cmd or cmd in tpl_hook_cmds or is_legacy_template_hook_cmd(cmd):
                                continue
                            kept_hooks.append(dict(h))
                        if kept_hooks:
                            ev_list = existing["hooks"].setdefault(event, [])
                            seen_cmds = {
                                (eg.get("matcher", ""), eh.get("command", ""))
                                for eg in ev_list
                                for eh in eg.get("hooks", [])
                            }
                            to_add = [
                                kh for kh in kept_hooks if (matcher, kh.get("command", "")) not in seen_cmds
                            ]
                            if to_add:
                                entry = {"hooks": to_add}
                                if "matcher" in g:
                                    entry["matcher"] = matcher
                                ev_list.append(entry)
                                for kh in to_add:
                                    print(
                                        f"extract .claude/settings.project.json hooks.{event}: {kh.get('command', '')}"
                                    )
                                changed = True

    if changed or not os.path.isfile(proj_settings_path):
        write_text(".claude/settings.project.json", json.dumps(existing, indent=2) + "\n")
    return existing


def strip_frontmatter(md):
    lines = md.splitlines()
    if lines and lines[0].strip() == "---":
        for i in range(1, len(lines)):
            if lines[i].strip() == "---":
                return lines[i + 1 :]
    return lines


def norm_role_line(line):
    s = line.strip()
    s = re.sub(r"\s*\(until step \d+ ships[^)]*\)", "", s)
    s = re.sub(r"^[-*]\s+", "", s)
    return s.strip()


def extract_role_facts():
    extracted_by_role = {}
    for role_file in CANONICAL_ROLES:
        proj_role_path = os.path.join(target, ".claude/agents", role_file)
        if not os.path.isfile(proj_role_path) or os.path.islink(proj_role_path):
            continue
        tpl_role_path = os.path.join(template_dir, ".claude/agents", role_file)
        if not os.path.isfile(tpl_role_path):
            continue
        tpl_rendered = read_text(tpl_role_path).replace("{{PROJECT_NAME}}", project_name)
        tpl_norms = {norm_role_line(l) for l in strip_frontmatter(tpl_rendered) if norm_role_line(l)}

        base_role_path = os.path.join(
            target, ".claude/agent-team-baseline/.claude/agents", role_file
        )
        if os.path.isfile(base_role_path):
            base_rendered = read_text(base_role_path).replace("{{PROJECT_NAME}}", project_name)
            tpl_norms |= {norm_role_line(l) for l in strip_frontmatter(base_rendered) if norm_role_line(l)}

        proj_lines = strip_frontmatter(read_text(proj_role_path))
        role_name = role_file[:-3]
        custom = []
        for raw in proj_lines:
            s = raw.strip()
            if not s or s.startswith("#"):
                continue
            if re.match(r"^You are on the \*\*.*\*\* agent team\.$", s):
                continue
            nl = norm_role_line(s)
            if not nl or nl in tpl_norms:
                continue
            bullet = s if s.startswith(("- ", "* ")) else f"- {s}"
            if bullet not in custom:
                custom.append(bullet)
        if custom:
            extracted_by_role[role_name] = custom

    team_facts_rel = "docs/agents/team-facts.md"
    team_facts_path = os.path.join(target, team_facts_rel)
    if os.path.isfile(team_facts_path):
        content = read_text(team_facts_path)
    else:
        tpl_tf = read_text(os.path.join(template_dir, "docs/agents/team-facts.md"))
        content = tpl_tf.replace("{{PROJECT_NAME}}", project_name)

    if "## Role facts" not in content:
        content = content.rstrip("\n") + "\n\n## Role facts\n"

    for role_name, bullets in extracted_by_role.items():
        new_bullets = [b for b in bullets if b not in content]
        for b in new_bullets:
            print(f"extract docs/agents/team-facts.md (## Role facts / ### {role_name}): {b}")
        if not new_bullets:
            continue
        header = f"### {role_name}"
        if header in content:
            idx = content.index(header) + len(header)
            rest = content[idx:]
            next_h = re.search(r"\n##+ ", rest)
            insert_pos = idx + (next_h.start() if next_h else len(rest))
            block = "\n" + "\n".join(new_bullets)
            content = content[:insert_pos].rstrip("\n") + block + "\n\n" + content[insert_pos:].lstrip("\n")
        else:
            rf_idx = content.index("## Role facts") + len("## Role facts")
            rf_rest = content[rf_idx:]
            next_h2 = re.search(r"\n## ", rf_rest)
            insert_pos = rf_idx + (next_h2.start() if next_h2 else len(rf_rest))
            block = f"\n\n{header}\n\n" + "\n".join(new_bullets)
            content = content[:insert_pos].rstrip("\n") + block + "\n\n" + content[insert_pos:].lstrip("\n")

    if extracted_by_role or not os.path.isfile(team_facts_path) or "## Role facts" not in read_text(team_facts_path):
        write_text(team_facts_rel, content.rstrip("\n") + "\n")


def remove_path(rel):
    full = os.path.join(target, rel)
    if not os.path.exists(full) and not os.path.islink(full):
        return
    if dry:
        print(f"would remove {rel}")
        return
    if os.path.isdir(full) and not os.path.islink(full):
        shutil.rmtree(full)
    else:
        os.unlink(full)
    print(f"removed {rel}")


def prune_empty_dir(rel):
    if dry:
        return
    full = os.path.join(target, rel)
    if os.path.isdir(full) and not os.path.islink(full):
        try:
            if not os.listdir(full):
                os.rmdir(full)
        except OSError:
            pass


def remove_legacy_copies():
    for role_file in CANONICAL_ROLES:
        remove_path(f".claude/agents/{role_file}")
    prune_empty_dir(".claude/agents")

    remove_path(".claude/agent-team-baseline")
    remove_path(".claude/agent-team-project-name")

    for hook in SHARED_HOOKS:
        remove_path(f".claude/hooks/{hook}")

    for b in SHARED_BINS:
        remove_path(f".claude/bin/{b}")
    prune_empty_dir(".claude/bin")

    for skill in TIER2_SKILLS:
        remove_path(f".agents/skills/{skill}")
        remove_path(f".claude/skills/{skill}")
        remove_path(f".cursor/skills/{skill}")

    prune_empty_dir(".claude/skills")
    prune_empty_dir(".cursor/skills")
    prune_empty_dir(".agents/skills")
    prune_empty_dir(".agents")

    remove_path("bin/team-audit-metrics.ts")


def parse_perm_rule(rule):
    m = re.match(r"^([A-Za-z0-9_]+)\((.*)\)$", rule.strip())
    if m:
        return m.group(1), m.group(2)
    return rule.strip(), ""


def validate_and_compile_settings(proj_override=None):
    tpl_path = os.path.join(template_dir, ".claude/settings.json")
    tpl = json.loads(read_text(tpl_path))
    proj_path = os.path.join(target, ".claude/settings.project.json")

    if proj_override is not None:
        proj = proj_override
    elif not os.path.isfile(proj_path):
        proj = {"permissions": {"allow": [], "deny": []}, "hooks": {}}
    else:
        try:
            proj = json.loads(read_text(proj_path))
        except Exception as exc:
            return None, [f".claude/settings.project.json is not valid JSON: {exc}"]

    errors = []
    if not isinstance(proj, dict):
        return None, [".claude/settings.project.json root must be a JSON object"]

    allowed_top = {"permissions", "hooks"}
    extra_top = set(proj.keys()) - allowed_top
    if extra_top:
        errors.append(
            f".claude/settings.project.json has non-additive top-level keys: {sorted(extra_top)}"
        )

    perms = proj.get("permissions", {})
    if not isinstance(perms, dict):
        errors.append(".claude/settings.project.json permissions must be a JSON object")
        perms = {}
    else:
        extra_perm_keys = set(perms.keys()) - {"allow", "deny"}
        if extra_perm_keys:
            errors.append(
                f".claude/settings.project.json permissions has disallowed keys: {sorted(extra_perm_keys)}"
            )

    p_allow = perms.get("allow", [])
    p_deny = perms.get("deny", [])
    if not isinstance(p_allow, list) or not all(isinstance(x, str) and x.strip() for x in p_allow):
        errors.append(".claude/settings.project.json permissions.allow must be a list of strings")
        p_allow = []
    if not isinstance(p_deny, list) or not all(isinstance(x, str) and x.strip() for x in p_deny):
        errors.append(".claude/settings.project.json permissions.deny must be a list of strings")
        p_deny = []

    tpl_deny = tpl.get("permissions", {}).get("deny", [])
    tpl_deny_parsed = [parse_perm_rule(r) for r in tpl_deny]

    for entry in p_allow:
        if entry.startswith("!"):
            errors.append(f".claude/settings.project.json permissions.allow cannot negate rules: {entry}")
            continue
        if entry in tpl_deny:
            errors.append(
                f".claude/settings.project.json permissions.allow weakens template deny rule: {entry}"
            )
            continue
        t_tool, t_arg = parse_perm_rule(entry)
        t_arg_rel = re.sub(r"^\*\*/", "", t_arg)
        for d_tool, d_arg in tpl_deny_parsed:
            d_arg_rel = re.sub(r"^\*\*/", "", d_arg)
            if t_tool == d_tool and (
                fnmatch.fnmatchcase(t_arg, d_arg)
                or fnmatch.fnmatchcase(d_arg, t_arg)
                or fnmatch.fnmatchcase(t_arg_rel, d_arg_rel)
                or fnmatch.fnmatchcase(d_arg_rel, t_arg_rel)
            ):
                errors.append(
                    f".claude/settings.project.json permissions.allow ({entry}) weakens template deny ({d_tool}({d_arg}))"
                )
                break

    for entry in p_deny:
        if entry.startswith("!"):
            errors.append(
                f".claude/settings.project.json permissions.deny cannot negate or remove template rules: {entry}"
            )

    p_hooks = proj.get("hooks", {})
    if not isinstance(p_hooks, dict):
        errors.append(".claude/settings.project.json hooks must be a JSON object")
        p_hooks = {}
    else:
        for event, groups in p_hooks.items():
            if not isinstance(groups, list):
                errors.append(f".claude/settings.project.json hooks.{event} must be a list")
                continue
            if event in tpl.get("hooks", {}) and len(groups) == 0:
                errors.append(
                    f".claude/settings.project.json hooks.{event} cannot be an empty list (weakens template hooks)"
                )
                continue
            for g in groups:
                if not isinstance(g, dict):
                    errors.append(
                        f".claude/settings.project.json hooks.{event} entry must be an object"
                    )
                    continue
                extra_g_keys = set(g.keys()) - {"matcher", "hooks"}
                if extra_g_keys:
                    errors.append(
                        f".claude/settings.project.json hooks.{event} entry has disallowed keys: {sorted(extra_g_keys)}"
                    )
                hlist = g.get("hooks")
                if not isinstance(hlist, list) or not hlist:
                    errors.append(
                        f".claude/settings.project.json hooks.{event} entry must have non-empty hooks list"
                    )
                    continue
                for h in hlist:
                    if not isinstance(h, dict):
                        errors.append(
                            f".claude/settings.project.json hooks.{event} hook must be an object"
                        )
                        continue
                    extra_h_keys = set(h.keys()) - {"type", "command", "timeout"}
                    if extra_h_keys:
                        errors.append(
                            f".claude/settings.project.json hooks.{event} hook has disallowed keys: {sorted(extra_h_keys)}"
                        )
                    if h.get("type") != "command" or not isinstance(h.get("command"), str) or not h.get("command").strip():
                        errors.append(
                            f".claude/settings.project.json hooks.{event} hook must have type='command' and non-empty command"
                        )
                        continue
                    cmd = h["command"]
                    if is_legacy_template_hook_cmd(cmd):
                        errors.append(
                            f".claude/settings.project.json hooks.{event} cannot override or redefine shared template hook: {cmd}"
                        )

    if errors:
        return None, errors

    compiled = json.loads(json.dumps(tpl))
    c_allow = list(compiled.get("permissions", {}).get("allow", []))
    for item in p_allow:
        if item not in c_allow:
            c_allow.append(item)
    c_deny = list(compiled.get("permissions", {}).get("deny", []))
    for item in p_deny:
        if item not in c_deny:
            c_deny.append(item)
    compiled["permissions"]["allow"] = c_allow
    compiled["permissions"]["deny"] = c_deny

    c_hooks = compiled.setdefault("hooks", {})
    for event, groups in p_hooks.items():
        cur_groups = list(c_hooks.get(event, []))
        seen = {
            (cg.get("matcher", ""), ch.get("command", ""))
            for cg in cur_groups
            for ch in cg.get("hooks", [])
        }
        for g in groups:
            matcher = g.get("matcher", "")
            new_h = []
            for h in g.get("hooks", []):
                key = (matcher, h.get("command", ""))
                if key not in seen:
                    seen.add(key)
                    new_h.append(dict(h))
            if new_h:
                entry = {"hooks": new_h}
                if "matcher" in g:
                    entry["matcher"] = matcher
                cur_groups.append(entry)
        c_hooks[event] = cur_groups

    return json.dumps(compiled, indent=2) + "\n", []


def parse_h2_sections(md):
    sections = []
    cur_title = None
    cur_lines = []
    for line in md.splitlines():
        if line.startswith("## "):
            if cur_title is not None:
                sections.append((cur_title, "\n".join(cur_lines).strip()))
            cur_title = line[3:].strip()
            cur_lines = [line]
        elif cur_title is not None:
            cur_lines.append(line)
    if cur_title is not None:
        sections.append((cur_title, "\n".join(cur_lines).strip()))
    return sections


def replace_or_append_h2(doc, title, section_text):
    pattern = re.compile(
        r"(^## " + re.escape(title) + r"[ \t]*\n.*?)(?=^## |\Z)",
        re.MULTILINE | re.DOTALL,
    )
    if pattern.search(doc):
        return pattern.sub(section_text.rstrip() + "\n\n", doc, count=1)
    return doc.rstrip() + "\n\n" + section_text.rstrip() + "\n"


def build_agents_md(existing_content, tracker):
    doc = existing_content
    doc = re.sub(
        r"\n*<!-- agent-team:start -->.*?<!-- agent-team:end -->\n*",
        "\n\n",
        doc,
        flags=re.DOTALL,
    )
    budget_md = read_text(os.path.join(template_dir, "AGENTS.token-budget.md"))
    for title, sec in parse_h2_sections(budget_md):
        doc = replace_or_append_h2(doc, title, sec)

    if tracker == "github":
        summary = "GitHub issues in this repo, via the `gh` CLI"
    elif tracker == "gitlab":
        summary = "GitLab issues in this repo, via the `glab` CLI"
    else:
        summary = "Local markdown files under `.scratch/<feature>/`"

    skills_block = (
        "## Agent skills\n\n"
        "### Issue tracker\n\n"
        f"{summary}. See `docs/agents/issue-tracker.md`.\n\n"
        "### Triage labels\n\n"
        "The five canonical triage roles, label strings unchanged. See `docs/agents/triage-labels.md`.\n\n"
        "### Domain docs\n\n"
        "Single context: `CONTEXT.md` plus `docs/adr/` at the repo root. See `docs/agents/domain.md`. "
        "All docs live under `docs/`; component docs go in `docs/<component>/`.\n\n"
        "### Invoking skills\n\n"
        "Invoke a skill by name: `/to-tickets` in Claude Code, Cursor and Antigravity, or read "
        "`~/.agents/skills/<name>/SKILL.md` and follow it. Skills marked `disable-model-invocation` "
        "(grill-me, grill-with-docs, handoff, implement, improve-codebase-architecture, retro, to-spec, "
        "to-tickets, triage, wayfinder) run only when named: Antigravity hides them until the prompt "
        "names them, and a Claude Code agent can neither invoke them nor preload them from `skills:`, "
        "so a worker spec names the file to read."
    )
    if not re.search(r"^## Agent skills[ \t]*$", doc, re.MULTILINE):
        doc = doc.rstrip() + "\n\n" + skills_block + "\n"

    doc = re.sub(r"\n{3,}", "\n\n", doc).rstrip() + "\n"
    return doc


def seed_and_sync_project(proj_settings_mem=None):
    tracker = detect_tracker_py()
    seed_map = [
        ("docs/agents/issue-tracker.md", os.path.join(seeds_dir, f"issue-tracker-{tracker}.md"), False),
        ("docs/agents/triage-labels.md", os.path.join(seeds_dir, "triage-labels.md"), False),
        ("docs/agents/domain.md", os.path.join(seeds_dir, "domain.md"), False),
        ("docs/agents/deploy-facts.md", os.path.join(template_dir, "docs/agents/deploy-facts.md"), True),
    ]
    for rel, src_path, render_name in seed_map:
        full = os.path.join(target, rel)
        if not os.path.isfile(full):
            text = read_text(src_path)
            if render_name:
                text = text.replace("{{PROJECT_NAME}}", project_name)
            write_text(rel, text)

    changelog_hook = os.path.join(target, ".cursor/changelog-hook.json")
    if not os.path.isfile(changelog_hook):
        write_text(
            ".cursor/changelog-hook.json",
            json.dumps({"changelog": "CHANGELOG.md", "fragments": "changelog.d/"}, indent=2) + "\n",
        )

    agents_path = os.path.join(target, "AGENTS.md")
    claude_path = os.path.join(target, "CLAUDE.md")
    if not os.path.isfile(agents_path) and os.path.isfile(claude_path):
        c_text = read_text(claude_path).strip()
        if c_text != "@AGENTS.md":
            write_text("AGENTS.md", read_text(claude_path))
            write_text("CLAUDE.md", "@AGENTS.md\n")

    if os.path.isfile(agents_path):
        a_cur = read_text(agents_path)
    else:
        a_cur = f"# {project_name}\n"
    write_text("AGENTS.md", build_agents_md(a_cur, tracker))

    if not os.path.isfile(claude_path):
        write_text("CLAUDE.md", "@AGENTS.md\n")
    else:
        c_cur = read_text(claude_path)
        if "<!-- agent-team:start -->" in c_cur:
            c_clean = re.sub(
                r"\n*<!-- agent-team:start -->.*?<!-- agent-team:end -->\n*",
                "\n",
                c_cur,
                flags=re.DOTALL,
            ).strip()
            write_text("CLAUDE.md", (c_clean or "@AGENTS.md") + "\n")

    gitignore_path = os.path.join(target, ".gitignore")
    gi_cur = read_text(gitignore_path) if os.path.isfile(gitignore_path) else ""
    gi_lines = gi_cur.splitlines()
    missing_gi = [e for e in GITIGNORE_ENTRIES if e not in gi_lines]
    if missing_gi:
        prefix = gi_cur.rstrip("\n") + ("\n" if gi_cur.strip() else "")
        write_text(".gitignore", prefix + "\n".join(missing_gi) + "\n")

    compiled_settings, errs = validate_and_compile_settings(proj_settings_mem if dry else None)
    if errs:
        for e in errs:
            sys.stderr.write(f"agent-team: {e}\n")
        sys.exit(1)
    write_text(".claude/settings.json", compiled_settings)

    for rel in TEMPLATE_SYNC_FILES:
        src = os.path.join(template_dir, rel)
        is_exec = rel.endswith(".sh")
        write_text(rel, read_text(src), executable=is_exec)


def run_check():
    drifts = []

    for role_file in CANONICAL_ROLES:
        rel = f".claude/agents/{role_file}"
        full = os.path.join(target, rel)
        if os.path.exists(full) or os.path.islink(full):
            drifts.append(f"canonical role file in project: {rel}")

    if os.path.exists(os.path.join(target, ".claude/agent-team-baseline")) or os.path.islink(
        os.path.join(target, ".claude/agent-team-baseline")
    ):
        drifts.append("legacy baseline directory present: .claude/agent-team-baseline")

    for hook in SHARED_HOOKS:
        rel = f".claude/hooks/{hook}"
        full = os.path.join(target, rel)
        if os.path.exists(full) or os.path.islink(full):
            drifts.append(f"shared hook copy or link in project: {rel}")

    for b in SHARED_BINS:
        rel = f".claude/bin/{b}"
        full = os.path.join(target, rel)
        if os.path.exists(full) or os.path.islink(full):
            drifts.append(f"shared bin copy or link in project: {rel}")

    if os.path.exists(os.path.join(target, "bin/team-audit-metrics.ts")) or os.path.islink(
        os.path.join(target, "bin/team-audit-metrics.ts")
    ):
        drifts.append("per-project metrics script present: bin/team-audit-metrics.ts")

    for skill in TIER2_SKILLS:
        for prefix in (".agents/skills", ".claude/skills", ".cursor/skills"):
            rel = f"{prefix}/{skill}"
            full = os.path.join(target, rel)
            if os.path.exists(full) or os.path.islink(full):
                drifts.append(f"Tier 2 skill copy or link in project: {rel}")

    guard_cfg = os.path.join(target, ".claude/hooks/guard-config.json")
    if not os.path.isfile(guard_cfg):
        drifts.append("missing .claude/hooks/guard-config.json")
    else:
        try:
            gdata = json.loads(read_text(guard_cfg))
            if not isinstance(gdata, dict):
                drifts.append(".claude/hooks/guard-config.json root must be a JSON object")
        except Exception as exc:
            drifts.append(f".claude/hooks/guard-config.json invalid JSON: {exc}")

    proj_settings = os.path.join(target, ".claude/settings.project.json")
    if not os.path.isfile(proj_settings):
        drifts.append("missing .claude/settings.project.json")

    compiled_settings, errs = validate_and_compile_settings()
    if errs:
        drifts.extend(errs)
    else:
        settings_full = os.path.join(target, ".claude/settings.json")
        if not os.path.isfile(settings_full):
            drifts.append("missing .claude/settings.json")
        else:
            cur_settings = read_text(settings_full)
            if cur_settings != compiled_settings:
                drifts.append(".claude/settings.json differs from compiled merge")

    for rel in TEMPLATE_SYNC_FILES:
        full = os.path.join(target, rel)
        src = os.path.join(template_dir, rel)
        if not os.path.isfile(full):
            drifts.append(f"missing template-managed file: {rel}")
        else:
            if read_text(full) != read_text(src):
                drifts.append(f"template-managed file drifted: {rel}")
            if rel.endswith(".sh") and not os.access(full, os.X_OK):
                drifts.append(f"template-managed script not executable: {rel}")

    if not os.path.isfile(os.path.join(target, ".cursor/changelog-hook.json")):
        drifts.append("missing .cursor/changelog-hook.json")

    claude_md = os.path.join(target, "CLAUDE.md")
    if not os.path.isfile(claude_md) or "@AGENTS.md" not in read_text(claude_md):
        drifts.append("CLAUDE.md missing or does not include @AGENTS.md")

    agents_md = os.path.join(target, "AGENTS.md")
    if not os.path.isfile(agents_md):
        drifts.append("missing AGENTS.md")
    else:
        a_text = read_text(agents_md)
        if "<!-- agent-team:start -->" in a_text:
            drifts.append("AGENTS.md still contains legacy agent-team marker block")
        if not re.search(r"^## Agent skills[ \t]*$", a_text, re.MULTILINE):
            drifts.append("AGENTS.md missing '## Agent skills' section")
        a_sections = dict(parse_h2_sections(a_text))
        for title, expected_sec in parse_h2_sections(
            read_text(os.path.join(template_dir, "AGENTS.token-budget.md"))
        ):
            if a_sections.get(title) != expected_sec:
                drifts.append(f"AGENTS.md section '## {title}' drifted from template")

    required_headings = {
        "docs/agents/issue-tracker.md": ["# Issue tracker"],
        "docs/agents/triage-labels.md": ["# Triage Labels"],
        "docs/agents/domain.md": ["# Domain Docs"],
        "docs/agents/team-facts.md": [
            "# Team facts",
            "## Repository",
            "## Worker start",
            "## Checks",
            "## Review",
            "## Changelog",
            "## Role facts",
            "## Terminal shortcut",
        ],
        "docs/agents/deploy-facts.md": [
            "# Deploy facts",
            "## Repository",
            "## Components",
            "## Production window",
            "## local",
            "## staging",
            "## production",
            "## Owner approval",
            "## Host status",
            "## Rollback",
        ],
    }
    for rel, headings in required_headings.items():
        full = os.path.join(target, rel)
        if not os.path.isfile(full):
            drifts.append(f"missing {rel}")
            continue
        text = read_text(full)
        for h in headings:
            if h not in text:
                drifts.append(f"{rel} missing required heading '{h}'")

    gi_path = os.path.join(target, ".gitignore")
    if not os.path.isfile(gi_path):
        drifts.append("missing .gitignore")
    else:
        gi_lines = read_text(gi_path).splitlines()
        for e in GITIGNORE_ENTRIES:
            if e not in gi_lines:
                drifts.append(f".gitignore missing '{e}'")

    if drifts:
        for d in drifts:
            sys.stderr.write(f"DRIFT {target}: {d}\n")
        sys.exit(1)


if mode == "project":
    extract_guard_config()
    proj_settings_mem = extract_settings_project()
    extract_role_facts()
    remove_legacy_copies()
    seed_and_sync_project(proj_settings_mem)
elif mode == "check":
    run_check()
else:
    sys.stderr.write(f"unknown engine mode: {mode}\n")
    sys.exit(2)
PY
}

cmd_project() {
  local dry=0 labels=0 name="" target_raw=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run) dry=1; shift ;;
      --labels) labels=1; shift ;;
      --project-name)
        [ $# -ge 2 ] || die "--project-name requires a value" 2
        name=$2
        shift 2
        ;;
      -h|--help) usage 0 ;;
      -*) die "unknown option: $1" 2 ;;
      *)
        [ -z "$target_raw" ] || die "unexpected extra argument: $1" 2
        target_raw=$1
        shift
        ;;
    esac
  done

  require_templates
  local target project_name
  target=$(validate_target_dir "${target_raw:-.}")
  check_safe_paths "$target"
  project_name=$(detect_project_name "$target" "$name")

  run_project_engine project "$target" "$project_name" "$dry"

  if [ "$labels" -eq 1 ]; then
    create_github_labels "$target" "$dry"
  fi
}

cmd_check() {
  local targets=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --check) shift ;;
      -h|--help) usage 0 ;;
      -*) die "unknown check option: $1" 2 ;;
      *) targets+=("$1"); shift ;;
    esac
  done
  [ "${#targets[@]}" -gt 0 ] || targets=(".")
  require_templates

  local status=0 raw target project_name
  for raw in "${targets[@]}"; do
    target=$(validate_target_dir "$raw") || { status=$?; continue; }
    check_safe_paths "$target" || { status=$?; continue; }
    project_name=$(detect_project_name "$target" "")
    if ! run_project_engine check "$target" "$project_name" 0; then
      status=1
    fi
    if [ -d "$target/.agents/skills" ] || [ -d "$target/.claude/skills" ] || [ -d "$target/.cursor/skills" ]; then
      if ! bash "$DOTFILES/script/check-skill-collisions.sh" "$target"; then
        status=1
      fi
    fi
  done
  return "$status"
}

cmd_all() {
  local dry_args=()
  local arg
  for arg in "$@"; do
    [ "$arg" = "--dry-run" ] && dry_args=(--dry-run)
  done
  cmd_machine ${dry_args[@]+"${dry_args[@]}"}
  cmd_project "$@"
}

sub=${1:-}
[ -n "$sub" ] || usage 2
shift || true

case "$sub" in
  machine) cmd_machine "$@" ;;
  project|sync) cmd_project "$@" ;;
  check) cmd_check "$@" ;;
  all) cmd_all "$@" ;;
  -h|--help) usage 0 ;;
  *) die "unknown subcommand: $sub" 2 ;;
esac
