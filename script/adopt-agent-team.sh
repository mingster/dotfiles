#!/usr/bin/env bash
# adopt-agent-team.sh: Installs or updates the standard Agent Team in any target project repository.
#
# Usage:
#   ~/dotfiles/script/adopt-agent-team.sh [--project-name <name>] [<target-dir>]
#
# Flags:
#   --project-name   Short project identifier (defaults to directory name)
#   --dry-run        Print actions without writing files
#   --reset          Refresh settings and AGENTS.md policy sections; re-link roles (skips regular files)
#   --check-paths    Validate managed destinations without adopting
#
set -euo pipefail

DOTFILES="${DOTFILES:-$HOME/dotfiles}"
TEMPLATES="$DOTFILES/templates/agent-team"
TEAM_ROLE_PATHS=(
  .claude/agents/elon.md .claude/agents/architect-pm.md .claude/agents/fullstack-dev.md
  .claude/agents/qa-sdet.md .claude/agents/release-manager.md .claude/agents/sales-marketing.md
  .claude/agents/secops-finops.md .claude/agents/support-csm.md
)
TARGET_DIR="${1:-$PWD}"
PROJECT_NAME=""
DRY_RUN=0
RESET=0
CHECK_PATHS=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-name)
      PROJECT_NAME="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --reset) RESET=1; shift ;;
    --check-paths) CHECK_PATHS=1; shift ;;
    -*)
      echo "Unknown flag: $1" >&2
      exit 1
      ;;
    *)
      TARGET_DIR="$1"
      shift
      ;;
  esac
done

TARGET_DIR="$(cd "$TARGET_DIR" && pwd -P)"
[ "$TARGET_DIR" != "$(cd "$DOTFILES" && pwd -P)" ] && [ "$TARGET_DIR" != "$(cd "$HOME" && pwd -P)" ] \
  || { echo 'adopt-agent-team: refusing dotfiles or home as target' >&2; exit 2; }
# Refuse redirected destinations before any mkdir/copy or skill sync. Never inspect
# arbitrary project files: only paths these composed scripts may write.
team_role_path() {
  local p="$1" x
  for x in "${TEAM_ROLE_PATHS[@]}"; do [ "$p" = "$x" ] && return 0; done
  return 1
}
safe_path() {
  team_role_path "$1" && return 0
  local path="$TARGET_DIR/$1"
  while [ "$path" != "$TARGET_DIR" ]; do
    if [ -L "$path" ]; then
      echo "adopt-agent-team: refused symlinked managed destination ${path#"$TARGET_DIR/"}" >&2
      exit 2
    fi
    path=$(dirname "$path")
  done
}
for path in .claude .agents .cursor .agent docs/agents bin changelog.d AGENTS.md CLAUDE.md .gitignore \
  .claude/agent-team-project-name \
  docs/agents/team-facts.md docs/agents/deploy-facts.md \
  docs/agents/issue-tracker.md docs/agents/triage-labels.md docs/agents/domain.md; do
  safe_path "$path"
done
while IFS= read -r src; do
  safe_path "${src#"$TEMPLATES/"}"
done < <(find "$TEMPLATES/.claude" "$TEMPLATES/.agents" "$TEMPLATES/bin" "$TEMPLATES/changelog.d" -type f \
  ! -path "$TEMPLATES/.claude/agents/*")
for path in .claude/skills .cursor/skills .agent; do safe_path "$path"; done
[ "$CHECK_PATHS" -eq 0 ] || exit 0
if [ -z "$PROJECT_NAME" ]; then
  if [ -f "$TARGET_DIR/.claude/agent-team-project-name" ]; then
    PROJECT_NAME=$(cat "$TARGET_DIR/.claude/agent-team-project-name")
  else
    PROJECT_NAME=$(basename "$TARGET_DIR")
  fi
fi
echo "Adopting Agent Team for '$PROJECT_NAME' at $TARGET_DIR..."
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
replacement=$(printf '%s' "$PROJECT_NAME" | sed 's/[\\&|]/\\&/g')

copy_file() {
  local src="$1"
  local dest="$2"
  local rel=${dest#"$TARGET_DIR/"}
  sed "s|{{PROJECT_NAME}}|$replacement|g" "$src" > "$tmp/rendered"
  if [ -f "$dest" ] && cmp -s "$dest" "$tmp/rendered" && { [ ! -x "$src" ] || [ -x "$dest" ]; }; then
    echo "  keep $rel (matches template)"
  elif [ "$DRY_RUN" -eq 1 ]; then
    echo "  [dry-run] drift $rel (would write)"
  else
    mkdir -p "$(dirname "$dest")"
    cp "$tmp/rendered" "$dest"
    [ ! -x "$src" ] || chmod +x "$dest"
    echo "  installed $dest"
  fi
}

# 1. Project marker and team role symlinks (canonical content stays in dotfiles).
if [ "$DRY_RUN" -eq 0 ]; then
  mkdir -p "$TARGET_DIR/.claude"
  printf '%s\n' "$PROJECT_NAME" > "$TARGET_DIR/.claude/agent-team-project-name"
fi
link_args=("$TARGET_DIR")
[ "$DRY_RUN" -eq 1 ] && link_args=(--dry-run "${link_args[@]}")
bash "$DOTFILES/script/link-agent-team-roles.sh" "${link_args[@]}"

# 2. Install settings.json with default sonnet/medium
if [ "$RESET" -eq 1 ] || [ ! -f "$TARGET_DIR/.claude/settings.json" ]; then
  if [ -f "$TEMPLATES/.claude/settings.json" ]; then
    copy_file "$TEMPLATES/.claude/settings.json" "$TARGET_DIR/.claude/settings.json"
  fi
fi

# 4. Team skills (crew, tl, deploy, elon, ceo): committed, generated copies from the template.
#    General skills (orchestration, tdd, ...) come from ~/.claude/skills, never a project copy.
if [ "$DRY_RUN" -eq 1 ]; then
  echo "  [dry-run] sync team skills into $TARGET_DIR/.agents/skills"
else
  "$DOTFILES/script/sync-team-skills.sh" "$TARGET_DIR" \
    || { echo "  team skills not synced, see the message above" >&2; exit 1; }
fi

# 4a. Antigravity reads workspace skills from .agent/skills (singular): relative link to .agents/skills.
if [ "$DRY_RUN" -eq 0 ] && [ -d "$TARGET_DIR/.agents/skills" ] && [ ! -e "$TARGET_DIR/.agent/skills" ]; then
  mkdir -p "$TARGET_DIR/.agent"
  ln -s ../.agents/skills "$TARGET_DIR/.agent/skills"
fi

# 4b. Project team facts. Owned by the project: written only when missing. Team docs live in $TEMPLATES/docs/agents/.
for f in team-facts.md deploy-facts.md; do
  if [ ! -f "$TARGET_DIR/docs/agents/$f" ]; then
    copy_file "$TEMPLATES/docs/agents/$f" "$TARGET_DIR/docs/agents/$f"
  fi
done

# 6. Install hooks (settings.json points at them; without them Bash calls fail)
for src in "$TEMPLATES/.claude/hooks"/*.py; do
  copy_file "$src" "$TARGET_DIR/.claude/hooks/$(basename "$src")"
done
copy_file "$TEMPLATES/.claude/hooks/session-start.md" "$TARGET_DIR/.claude/hooks/session-start.md"

# 6b. Install the state of play script and the model routing tiers
for src in "$TEMPLATES/.claude/bin"/*; do
  copy_file "$src" "$TARGET_DIR/.claude/bin/$(basename "$src")"
done
copy_file "$TEMPLATES/.claude/model-routing.md" "$TARGET_DIR/.claude/model-routing.md"

# 6d. Install the changelog fragments convention (compile script, its test, and the README)
for f in changelog-compile.sh changelog-compile.test.sh; do
  copy_file "$TEMPLATES/bin/$f" "$TARGET_DIR/bin/$f"
done
copy_file "$TEMPLATES/changelog.d/README.md" "$TARGET_DIR/changelog.d/README.md"

# 7. Refresh only named policy sections; other project instructions stay intact.
if [ "$RESET" -eq 1 ] && [ -f "$TARGET_DIR/AGENTS.md" ]; then
  python3 - "$TARGET_DIR/AGENTS.md" "$TEMPLATES/AGENTS.token-budget.md" "$tmp/agents" <<'PY'
import pathlib, re, sys
target, template, output = map(pathlib.Path, sys.argv[1:])
text = target.read_text()
source = template.read_text()
for heading in ('Token budget', 'Compact instructions', 'Owner context commands'):
    pattern = r'^## ' + re.escape(heading) + r'\n.*?(?=^## |\Z)'
    block = re.search(pattern, source, re.M | re.S).group(0)
    if re.search(pattern, text, re.M | re.S):
        text = re.sub(pattern, lambda _: block, text, flags=re.M | re.S)
    else:
        text = text.rstrip() + '\n\n' + block
output.write_text(text)
PY
  if ! cmp -s "$tmp/agents" "$TARGET_DIR/AGENTS.md"; then
    if [ "$DRY_RUN" -eq 1 ]; then
      echo '  [dry-run] drift AGENTS.md managed policy sections (would write)'
    else
      cp "$tmp/agents" "$TARGET_DIR/AGENTS.md"
      echo '  refreshed AGENTS.md managed policy sections'
    fi
  fi
fi
if [ "$DRY_RUN" -eq 0 ]; then
  touch "$TARGET_DIR/AGENTS.md"
  if ! grep -q "^## Token budget" "$TARGET_DIR/AGENTS.md"; then
    cat "$TEMPLATES/AGENTS.token-budget.md" >> "$TARGET_DIR/AGENTS.md"
    echo "  appended Token budget to AGENTS.md"
  fi
  # 8. Keep the ledger, hook state and release evidence out of git
  for pat in "active_run.md" ".claude/state/" ".claude/release-reports/"; do
    grep -qxF "$pat" "$TARGET_DIR/.gitignore" 2>/dev/null || echo "$pat" >> "$TARGET_DIR/.gitignore"
  done
fi

echo "Agent team successfully adopted for $PROJECT_NAME!"
echo "Run /crew <objective> in $TARGET_DIR to begin."
