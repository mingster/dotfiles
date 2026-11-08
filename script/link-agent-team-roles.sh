#!/usr/bin/env bash
# Create absolute symlinks for the eight team roles under .claude/agents/ and seed gitignore lines.
# Usage: link-agent-team-roles.sh [--dry-run] [--quiet] [<project-root>]
set -euo pipefail

TEAM_ROLES=(
  elon.md architect-pm.md fullstack-dev.md qa-sdet.md release-manager.md
  sales-marketing.md secops-finops.md support-csm.md
)

DOTFILES="${DOTFILES:-$HOME/dotfiles}"
TARGET="${1:-$PWD}"
DRY_RUN=0
QUIET=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --quiet) QUIET=1; shift ;;
    -h|--help)
      sed -n '2,3p' "$0"
      exit 0
      ;;
    -*)
      echo "link-agent-team-roles: unknown flag $1" >&2
      exit 2
      ;;
    *)
      TARGET="$1"
      shift
      break
      ;;
  esac
done

TARGET="$(cd "$TARGET" && pwd -P)"
CANON_ROOT="$(cd "$DOTFILES" && pwd -P)"
AGENTS_DIR="$CANON_ROOT/templates/agent-team/.claude/agents"
[ -d "$AGENTS_DIR" ] || { echo "link-agent-team-roles: missing $AGENTS_DIR (set DOTFILES)" >&2; exit 2; }

say() { [ "$QUIET" -eq 0 ] && echo "$@" || :; }

seed_gitignore() {
  local line gi="$TARGET/.gitignore" added=0
  for base in "${TEAM_ROLES[@]}"; do
    line=".claude/agents/$base"
    if [ -f "$gi" ] && grep -qxF "$line" "$gi" 2>/dev/null; then
      continue
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
      say "  [dry-run] would add $line to .gitignore"
    else
      [ -f "$gi" ] || touch "$gi"
      echo "$line" >> "$gi"
      added=$((added + 1))
    fi
  done
  [ "$added" -gt 0 ] && say "  seeded $added gitignore line(s)" || true
}

link_roles() {
  local base rel dest canonical rc=0
  [ "$DRY_RUN" -eq 1 ] || mkdir -p "$TARGET/.claude/agents"
  for base in "${TEAM_ROLES[@]}"; do
    rel=".claude/agents/$base"
    dest="$TARGET/$rel"
    canonical="$AGENTS_DIR/$base"
    [ -f "$canonical" ] || { echo "link-agent-team-roles: missing canonical $canonical" >&2; exit 2; }
    if [ -e "$dest" ] && [ ! -L "$dest" ]; then
      echo "link-agent-team-roles: refused regular file at $rel (remove it and re-run)" >&2
      rc=2
      continue
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
      say "  [dry-run] would link $rel -> $canonical"
      continue
    fi
    ln -sf "$canonical" "$dest"
    say "  linked $rel"
  done
  return "$rc"
}

seed_gitignore
link_roles
