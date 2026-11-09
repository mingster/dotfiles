#!/usr/bin/env bash
# sync-pstack-template-skills.sh: copy whole upstream trees from cursor/plugins into the team template.
#
# Usage: ~/dotfiles/script/sync-pstack-template-skills.sh [--dry-run]
#
# Reads script/.pstack-template-upstream. One cursor/plugins clone feeds every entry, so sha= is the
# upstream sha of all of them. Hand edited keys:
#   tree=<upstream dir> <template dir>   every file of the dir: skills/* into .agents/skills/<name>,
#                                        the rest into templates/agent-team/<template dir>
#   skill=<upstream skill dir>           one skill into .agents/skills/<basename>
# Written by the script: sha= and skills= (the vendored skill names, used to prune skills gone upstream).
# Copies are exact (rsync --delete), so local files never live in a vendored directory. An upstream
# skill that shares a name with a Tier 1 skill in .agents/skills replaces it: the Tier 1 copy is deleted
# and dropped from .agents/skills/.mattpocock-upstream. An upstream skill named like a local template
# skill (elon, team-audit, ...) stops the sync. Scripts are copied as files only.
#
# Env: DOTFILES, PLUGINS_REPO (default https://github.com/cursor/plugins).
set -euo pipefail

DOTFILES="${DOTFILES:-$HOME/dotfiles}"
DOTFILES=$(cd "$DOTFILES" && pwd -P)
PLUGINS_REPO="${PLUGINS_REPO:-https://github.com/cursor/plugins}"
STATE="$DOTFILES/script/.pstack-template-upstream"
TEMPLATE="$DOTFILES/templates/agent-team"
TEMPLATE_SKILLS="$TEMPLATE/.agents/skills"
TIER1_SKILLS="$DOTFILES/.agents/skills"
MP_STATE="$TIER1_SKILLS/.mattpocock-upstream"
DRY=0

case "${1:-}" in
  --dry-run) DRY=1 ;;
  -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
  "") ;;
  *) echo "sync-pstack-template-skills: unknown flag $1" >&2; exit 2 ;;
esac

die() { echo "sync-pstack-template-skills: $*" >&2; exit "${2:-1}"; }

[ -f "$STATE" ] || die "missing $STATE" 2
trees=$(sed -n 's/^tree=//p' "$STATE")
skill_dirs=$(sed -n 's/^skill=//p' "$STATE")
old_names=$(sed -n 's/^skills=//p' "$STATE")
[ -n "$trees$skill_dirs" ] || die "state has no tree= or skill= entry" 2

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
git clone -q --depth 1 "$PLUGINS_REPO" "$tmp/up" || exit 1
new=$(git -C "$tmp/up" rev-parse HEAD)

# Collect <name> <source dir> pairs and <source> <dest> tree pairs before touching anything.
: >"$tmp/skills"
: >"$tmp/rest"
while read -r up dest; do
  [ -n "$up" ] || continue
  [ -n "$dest" ] || die "tree=$up has no template dir" 2
  [ -d "$tmp/up/$up" ] || die "upstream missing $up"
  printf '%s %s\n' "$up" "$dest" >>"$tmp/rest"
  if [ -d "$tmp/up/$up/skills" ]; then
    for d in "$tmp/up/$up/skills"/*/; do
      printf '%s %s\n' "$(basename "$d")" "${d%/}" >>"$tmp/skills"
    done
  fi
done <<<"$trees"
for up in $skill_dirs; do
  [ -d "$tmp/up/$up" ] || die "upstream missing $up"
  printf '%s %s\n' "$(basename "$up")" "$tmp/up/$up" >>"$tmp/skills"
done

dup=$(cut -d' ' -f1 "$tmp/skills" | sort | uniq -d | head -1)
[ -z "$dup" ] || die "two upstream entries ship skill $dup"
new_names=$(cut -d' ' -f1 "$tmp/skills" | sort | tr '\n' ' ' | sed 's/ $//')

for n in $new_names; do
  case " $old_names " in *" $n "*) continue ;; esac
  [ ! -e "$TEMPLATE_SKILLS/$n" ] || die "upstream skill $n would replace a local template skill"
done

if [ "$DRY" -eq 1 ]; then
  while read -r n from; do diff -rq "$from" "$TEMPLATE_SKILLS/$n" 2>/dev/null || true; done <"$tmp/skills"
  while read -r up dest; do
    diff -rq -x skills "$tmp/up/$up" "$TEMPLATE/$dest" 2>/dev/null || true
  done <"$tmp/rest"
  echo "sync-pstack-template-skills: dry run against upstream $new"
  exit 0
fi

while read -r up dest; do
  mkdir -p "$TEMPLATE/$dest"
  rsync -a --delete --exclude /skills/ "$tmp/up/$up/" "$TEMPLATE/$dest/"
done <"$tmp/rest"

while read -r n from; do
  mkdir -p "$TEMPLATE_SKILLS/$n"
  rsync -a --delete "$from/" "$TEMPLATE_SKILLS/$n/"
  if [ -e "$TIER1_SKILLS/$n" ]; then
    rm -rf "${TIER1_SKILLS:?}/$n"
    if [ -f "$MP_STATE" ]; then
      sed -i.bak -E "/^skills=/{s/(=| )$n( |\$)/\1\2/;s/  +/ /g;s/ \$//;s/= /=/;}" "$MP_STATE"
      rm -f "$MP_STATE.bak"
    fi
    echo "sync-pstack-template-skills: upstream $n replaces Tier 1 .agents/skills/$n"
  fi
done <"$tmp/skills"

for n in $old_names; do
  case " $new_names " in *" $n "*) continue ;; esac
  rm -rf "${TEMPLATE_SKILLS:?}/$n"
  echo "sync-pstack-template-skills: removed $n (gone upstream)"
done

sed -i.bak -e "s/^sha=.*/sha=$new/" -e "s/^skills=.*/skills=$new_names/" "$STATE"
rm -f "$STATE.bak"
grep -q '^skills=' "$STATE" || printf 'skills=%s\n' "$new_names" >>"$STATE"
echo "sync-pstack-template-skills: upstream $new"
git -C "$DOTFILES" diff --stat -- templates/agent-team .agents/skills script/.pstack-template-upstream
