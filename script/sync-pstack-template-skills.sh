#!/usr/bin/env bash
# sync-pstack-template-skills.sh: refresh vendored pstack template skills from cursor/plugins.
#
# Usage: ~/dotfiles/script/sync-pstack-template-skills.sh [--dry-run]
#
# Reads script/.pstack-template-upstream (sha=, subpath=, skills=). Rsyncs listed skills into
# templates/agent-team/.agents/skills/. ORCA-ADAPTER.md is excluded from upstream deletes so local
# Orca translation files stay in place. Prints upstream sha on success.
#
# Env: DOTFILES, PLUGINS_REPO (default https://github.com/cursor/plugins).
set -euo pipefail

DOTFILES="${DOTFILES:-$HOME/dotfiles}"
DOTFILES=$(cd "$DOTFILES" && pwd -P)
PLUGINS_REPO="${PLUGINS_REPO:-https://github.com/cursor/plugins}"
STATE="$DOTFILES/script/.pstack-template-upstream"
TEMPLATE_SKILLS="$DOTFILES/templates/agent-team/.agents/skills"
DRY=0

case "${1:-}" in
  --dry-run) DRY=1 ;;
  -h|--help) sed -n '2,11p' "$0"; exit 0 ;;
  "") ;;
  *) echo "sync-pstack-template-skills: unknown flag $1" >&2; exit 2 ;;
esac

[ -f "$STATE" ] || { echo "sync-pstack-template-skills: missing $STATE" >&2; exit 2; }

subpath=$(sed -n 's/^subpath=//p' "$STATE")
names=$(sed -n 's/^skills=//p' "$STATE")
[ -n "$subpath" ] || { echo "sync-pstack-template-skills: state has no subpath" >&2; exit 2; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
git clone -q --depth 1 "$PLUGINS_REPO" "$tmp/up" || exit 1
new=$(git -C "$tmp/up" rev-parse HEAD)
src="$tmp/up/$subpath/skills"
if [ ! -d "$src" ]; then
  echo "sync-pstack-template-skills: upstream missing $subpath/skills" >&2
  exit 1
fi

for n in $names; do
  from="$src/$n"
  to="$TEMPLATE_SKILLS/$n"
  [ -d "$from" ] || { echo "sync-pstack-template-skills: WARN $n not in upstream, left as is"; continue; }
  if [ "$DRY" -eq 1 ]; then
    diff -rq "$from" "$to" 2>/dev/null || true
    continue
  fi
  mkdir -p "$to"
  rsync -a --delete --exclude ORCA-ADAPTER.md "$from/" "$to/"
done

if [ "$DRY" -eq 1 ]; then
  echo "sync-pstack-template-skills: dry run against upstream $new"
  exit 0
fi

sed -i.bak "s/^sha=.*/sha=$new/" "$STATE"
rm -f "$STATE.bak"
echo "sync-pstack-template-skills: upstream $new"
git -C "$DOTFILES" diff --stat -- templates/agent-team/.agents/skills script/.pstack-template-upstream
