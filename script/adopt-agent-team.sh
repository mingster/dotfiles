#!/usr/bin/env bash
# adopt-agent-team.sh: Installs or updates the standard Agent Team in any target project repository.
# Usage: ~/dotfiles/script/adopt-agent-team.sh [--project-name <name>] [<target-dir>]
# Flags:
#   --project-name   Short project identifier (defaults to directory name)
#   --dry-run        Print actions without writing files
#   --reset          Refresh template files, preserving customized roles and product facts
#   --check-paths    Validate managed destinations without adopting
#
set -euo pipefail

DOTFILES="${DOTFILES:-$HOME/dotfiles}"
TEMPLATES="$DOTFILES/templates/agent-team"
TARGET_DIR="${1:-$PWD}"
PROJECT_NAME=""
DRY_RUN=0
RESET=0
CHECK_PATHS=0; LINK_ROLES_ONLY=0; LINK_SKIP_REGULAR=0

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
    --link-roles-only) LINK_ROLES_ONLY=1; shift ;;
    --skip-regular) LINK_SKIP_REGULAR=1; shift ;;
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

link_team_roles() {
  local rel dest canon resolved rc=0 gi="$TARGET_DIR/.gitignore"
  canon="$(cd "$DOTFILES" && pwd -P)/templates/agent-team/.claude/agents"
  [ -d "$canon" ] || { echo "adopt-agent-team: missing $canon (set DOTFILES)" >&2; return 2; }
  [ "$DRY_RUN" -eq 1 ] || mkdir -p "$TARGET_DIR/.claude/agents"
  for src in "$canon"/*.md; do
    rel=".claude/agents/$(basename "$src")"; dest="$TARGET_DIR/$rel"
    if [ -e "$dest" ] && [ ! -L "$dest" ]; then
      [ "$LINK_SKIP_REGULAR" -eq 1 ] && continue
      echo "adopt-agent-team: refused regular file at $rel" >&2; rc=2; continue
    fi
    if [ -L "$dest" ]; then
      resolved=$(readlink "$dest" || true)
      [ "${resolved#/}" = "$resolved" ] && resolved="$(cd "$(dirname "$dest")" && pwd -P)/$resolved"
      [ "$resolved" = "$src" ] && continue
    fi
    [ "$DRY_RUN" -eq 1 ] && continue
    ln -sf "$src" "$dest"
  done
  [ "$DRY_RUN" -eq 1 ] || for src in "$canon"/*.md; do
    rel=".claude/agents/$(basename "$src")"
    [ -L "$TARGET_DIR/$rel" ] || continue
    grep -qxF "$rel" "$gi" 2>/dev/null || { [ -f "$gi" ] || touch "$gi"; echo "$rel" >> "$gi"; }
  done
  return "$rc"
}
[ "$LINK_ROLES_ONLY" -eq 1 ] && { link_team_roles; exit $?; }

# Refuse redirected destinations before any mkdir/copy or skill sync.
safe_path() {
  local p="$1" path="$TARGET_DIR/$1"
  case "$p" in .claude/agents/*.md) return 0 ;; esac
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

[ "$DRY_RUN" -eq 1 ] || mkdir -p "$TARGET_DIR/.claude"
if [ "$DRY_RUN" -eq 0 ]; then
  printf '%s\n' "$PROJECT_NAME" > "$TARGET_DIR/.claude/agent-team-project-name"
fi
[ "$RESET" -eq 1 ] && LINK_SKIP_REGULAR=1
link_team_roles || exit $?

if [ "$RESET" -eq 1 ] || [ ! -f "$TARGET_DIR/.claude/settings.json" ]; then
  if [ -f "$TEMPLATES/.claude/settings.json" ]; then
    copy_file "$TEMPLATES/.claude/settings.json" "$TARGET_DIR/.claude/settings.json"
  fi
fi

if [ "$DRY_RUN" -eq 1 ]; then
  echo "  [dry-run] sync team skills into $TARGET_DIR/.agents/skills"
else
  "$DOTFILES/script/sync-team-skills.sh" "$TARGET_DIR" \
    || { echo "  team skills not synced, see the message above" >&2; exit 1; }
fi

if [ "$DRY_RUN" -eq 0 ] && [ -d "$TARGET_DIR/.agents/skills" ] && [ ! -e "$TARGET_DIR/.agent/skills" ]; then
  mkdir -p "$TARGET_DIR/.agent"
  ln -s ../.agents/skills "$TARGET_DIR/.agent/skills"
fi

for f in team-facts.md deploy-facts.md; do
  if [ ! -f "$TARGET_DIR/docs/agents/$f" ]; then
    copy_file "$TEMPLATES/docs/agents/$f" "$TARGET_DIR/docs/agents/$f"
  fi
done

for src in "$TEMPLATES/.claude/hooks"/*.py; do
  copy_file "$src" "$TARGET_DIR/.claude/hooks/$(basename "$src")"
done
copy_file "$TEMPLATES/.claude/hooks/session-start.md" "$TARGET_DIR/.claude/hooks/session-start.md"

for src in "$TEMPLATES/.claude/bin"/*; do
  copy_file "$src" "$TARGET_DIR/.claude/bin/$(basename "$src")"
done
copy_file "$TEMPLATES/.claude/model-routing.md" "$TARGET_DIR/.claude/model-routing.md"

for f in changelog-compile.sh changelog-compile.test.sh; do
  copy_file "$TEMPLATES/bin/$f" "$TARGET_DIR/bin/$f"
done
copy_file "$TEMPLATES/changelog.d/README.md" "$TARGET_DIR/changelog.d/README.md"

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
  for pat in "active_run.md" ".claude/state/" ".claude/release-reports/"; do
    grep -qxF "$pat" "$TARGET_DIR/.gitignore" 2>/dev/null || echo "$pat" >> "$TARGET_DIR/.gitignore"
  done
fi

echo "Agent team successfully adopted for $PROJECT_NAME!"
echo "Run /crew <objective> in $TARGET_DIR to begin."
