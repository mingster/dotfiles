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
mkdir -p "$TARGET_DIR/.agents/skills/crew"
mkdir -p "$TARGET_DIR/.claude/skills"

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

# 4. Install crew skill
if [ -f "$TEMPLATES/.agents/skills/crew/SKILL.md" ]; then
  copy_file "$TEMPLATES/.agents/skills/crew/SKILL.md" "$TARGET_DIR/.agents/skills/crew/SKILL.md"
  if [ ! -e "$TARGET_DIR/.claude/skills/crew" ]; then
    ln -s "../../.agents/skills/crew" "$TARGET_DIR/.claude/skills/crew"
    echo "  symlinked .claude/skills/crew"
  fi
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

# 6c. Install the worker watch script and its test
if [ "$DRY_RUN" -eq 0 ]; then
  mkdir -p "$TARGET_DIR/.agents/skills/orchestration"
  for f in worker-watch.sh worker-watch.test.sh; do
    cp "$TEMPLATES/.agents/skills/orchestration/$f" "$TARGET_DIR/.agents/skills/orchestration/$f"
    chmod +x "$TARGET_DIR/.agents/skills/orchestration/$f"
  done
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
