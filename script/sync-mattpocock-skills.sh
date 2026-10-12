#!/usr/bin/env bash
# sync-mattpocock-skills.sh: refresh the vendored Matt Pocock skills from upstream main.
#
# Usage: ~/dotfiles/script/sync-mattpocock-skills.sh [--dry-run]
#
# Reads .agents/skills/.mattpocock-upstream (sha=, skills=). For each listed skill it copies the
# upstream folder over the local one, then re-applies the intentional local edits:
#   * GLOSSARY becomes CONTEXT in every copied file and GLOSSARY-FORMAT.md is renamed CONTEXT-FORMAT.md
#   * .agents/skills/.mattpocock-local.patch (the to-tickets "Machine-checkable contract" sections)
# If the patch no longer applies, nothing is changed and the script exits 1 (update the patch by hand).
# A skill that exists only locally is never touched, and no local skill is ever deleted.
# Upstream is cloned shallow into a mktemp directory that is removed on exit. Prints the diff stat.
# Env: DOTFILES (default ~/dotfiles), MP_REPO (default https://github.com/mattpocock/skills).
set -euo pipefail

DOTFILES="${DOTFILES:-$HOME/dotfiles}"
MP_REPO="${MP_REPO:-https://github.com/mattpocock/skills}"
SKILLS="$DOTFILES/.agents/skills"
STATE="$SKILLS/.mattpocock-upstream"
PATCH="$SKILLS/.mattpocock-local.patch"
DRY=0

case "${1:-}" in
  --dry-run) DRY=1 ;;
  -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
  "") ;;
  *) echo "sync-mattpocock-skills: unknown flag $1" >&2; exit 2 ;;
esac
[ -f "$STATE" ] || { echo "sync-mattpocock-skills: missing $STATE" >&2; exit 2; }
names=$(sed -n 's/^skills=//p' "$STATE")

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
git clone -q --depth 1 "$MP_REPO" "$tmp/up"
new=$(git -C "$tmp/up" rev-parse HEAD)
mkdir "$tmp/stage"

for n in $names; do
  src=$(find "$tmp/up/skills" -mindepth 2 -maxdepth 2 -type d -name "$n" | head -1)
  if [ -z "$src" ]; then echo "WARN $n: not in upstream any more, left as is"; continue; fi
  cp -R "$src" "$tmp/stage/$n"
  [ -f "$tmp/stage/$n/GLOSSARY-FORMAT.md" ] && mv "$tmp/stage/$n/GLOSSARY-FORMAT.md" "$tmp/stage/$n/CONTEXT-FORMAT.md"
  { grep -rl GLOSSARY "$tmp/stage/$n" || true; } | while IFS= read -r f; do sed -i.bak 's/GLOSSARY/CONTEXT/g' "$f"; rm -f "$f.bak"; done
done

if [ -f "$PATCH" ] && ! (cd "$tmp/stage" && patch -s -p1 -f < "$PATCH"); then
  echo "sync-mattpocock-skills: $PATCH no longer applies to upstream $new; nothing changed" >&2
  exit 1
fi
find "$tmp/stage" \( -name '*.orig' -o -name '*.rej' \) -delete

if [ "$DRY" -eq 1 ]; then
  echo "sync-mattpocock-skills: dry run against upstream $new"
  for n in $(cd "$tmp/stage" && echo *); do diff -rq "$tmp/stage/$n" "$SKILLS/$n" || true; done
  exit 0
fi
for n in $(cd "$tmp/stage" && echo *); do rm -rf "${SKILLS:?}/$n"; cp -R "$tmp/stage/$n" "$SKILLS/$n"; done
sed -i.bak "s/^sha=.*/sha=$new/" "$STATE"; rm -f "$STATE.bak"

echo "sync-mattpocock-skills: upstream $new"
git -C "$DOTFILES" diff --stat -- .agents/skills
