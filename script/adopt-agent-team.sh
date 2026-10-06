#!/usr/bin/env bash
# adopt-agent-team.sh: Installs or updates the standard Agent Team in any target project repository.
#
# Usage:
#   ~/dotfiles/script/adopt-agent-team.sh [--project-name <name>] [<target-dir>]
#
# Flags:
#   --project-name   Short project identifier (defaults to directory name)
#   --dry-run        Print actions without writing files
#
set -euo pipefail

DOTFILES="${DOTFILES:-$HOME/dotfiles}"
TEMPLATES="$DOTFILES/templates/agent-team"
TARGET_DIR="${1:-$PWD}"
PROJECT_NAME=""
DRY_RUN=0

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

if [ -z "$PROJECT_NAME" ]; then
  PROJECT_NAME="$(basename "$(cd "$TARGET_DIR" && pwd)")"
fi

TARGET_DIR="$(cd "$TARGET_DIR" && pwd)"
echo "Adopting Agent Team for '$PROJECT_NAME' at $TARGET_DIR..."

copy_file() {
  local src="$1"
  local dest="$2"
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "  [dry-run] write $dest"
  else
    mkdir -p "$(dirname "$dest")"
    sed "s/{{PROJECT_NAME}}/$PROJECT_NAME/g" "$src" > "$dest"
    echo "  installed $dest"
  fi
}

# 1. Ensure directories exist
mkdir -p "$TARGET_DIR/.claude/agents"

# 2. Install standard roles
ROLES=(elon tech-lead architect-pm fullstack-dev qa-sdet secops-finops sales-marketing release-manager)
for role in "${ROLES[@]}"; do
  if [ -f "$TEMPLATES/.claude/agents/$role.md" ]; then
    copy_file "$TEMPLATES/.claude/agents/$role.md" "$TARGET_DIR/.claude/agents/$role.md"
  elif [ -f "$DOTFILES/../projects/riben.life/.claude/agents/$role.md" ]; then
    copy_file "$DOTFILES/../projects/riben.life/.claude/agents/$role.md" "$TARGET_DIR/.claude/agents/$role.md"
  fi
done

# 3. Install settings.json with default sonnet/medium
if [ ! -f "$TARGET_DIR/.claude/settings.json" ]; then
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
    || echo "  team skills not synced, see the message above" >&2
fi

# 5. Install persistent memory protocol
if [ -f "$TEMPLATES/docs/agents/persistent-memory-protocol.md" ]; then
  copy_file "$TEMPLATES/docs/agents/persistent-memory-protocol.md" "$TARGET_DIR/docs/agents/persistent-memory-protocol.md"
fi

# 6. Install hooks (settings.json points at them; without them Bash calls fail)
for h in guard-bash.py strikes.py; do
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "  [dry-run] write $TARGET_DIR/.claude/hooks/$h"
  else
    mkdir -p "$TARGET_DIR/.claude/hooks"
    cp "$TEMPLATES/.claude/hooks/$h" "$TARGET_DIR/.claude/hooks/$h"
    echo "  installed $TARGET_DIR/.claude/hooks/$h"
  fi
done
copy_file "$TEMPLATES/.claude/hooks/session-start.md" "$TARGET_DIR/.claude/hooks/session-start.md"

# 6b. Install the state of play script and the model routing tiers
if [ "$DRY_RUN" -eq 0 ]; then
  mkdir -p "$TARGET_DIR/.claude/bin"
  cp "$TEMPLATES/.claude/bin/state-of-play.sh" "$TARGET_DIR/.claude/bin/state-of-play.sh"
  chmod +x "$TARGET_DIR/.claude/bin/state-of-play.sh"
  copy_file "$TEMPLATES/.claude/model-routing.md" "$TARGET_DIR/.claude/model-routing.md"
fi

# 6d. Install the changelog fragments convention (compile script, its test, and the README)
if [ "$DRY_RUN" -eq 0 ]; then
  mkdir -p "$TARGET_DIR/bin" "$TARGET_DIR/changelog.d"
  for f in changelog-compile.sh changelog-compile.test.sh; do
    cp "$TEMPLATES/bin/$f" "$TARGET_DIR/bin/$f"
    chmod +x "$TARGET_DIR/bin/$f"
  done
  copy_file "$TEMPLATES/changelog.d/README.md" "$TARGET_DIR/changelog.d/README.md"
fi

# 7. Token budget block that the role files point to, added only when missing
if [ "$DRY_RUN" -eq 0 ]; then
  touch "$TARGET_DIR/AGENTS.md"
  if ! grep -q "^## Token budget" "$TARGET_DIR/AGENTS.md"; then
    cat "$TEMPLATES/AGENTS.token-budget.md" >> "$TARGET_DIR/AGENTS.md"
    echo "  appended Token budget to AGENTS.md"
  fi
  # 8. Keep the ledger and hook state out of git
  for pat in "active_run.md" ".claude/state/"; do
    grep -qxF "$pat" "$TARGET_DIR/.gitignore" 2>/dev/null || echo "$pat" >> "$TARGET_DIR/.gitignore"
  done
fi

echo "Agent team successfully adopted for $PROJECT_NAME!"
echo "Run /crew <objective> in $TARGET_DIR to begin."
