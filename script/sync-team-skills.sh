#!/usr/bin/env bash
# sync-team-skills.sh: write the tier 2 team skills into a project as committed, generated copies.
#
# Source: $DOTFILES/templates/agent-team/.agents/skills/<name>/ (every directory there with a SKILL.md is a tier 2 skill).
# Target: <project>/.agents/skills/<name>/, plus relative links .claude/skills/<name> and
# .cursor/skills/<name> -> ../../.agents/skills/<name>, so a fresh clone or cloud session has them.
# Each copied SKILL.md gets a "generated, do not edit" comment after its frontmatter with a hash
# of the source skill directory. Product facts never go in these skills: each skill reads them
# from a project file under docs/agents/ (see docs/agents/skills-inventory.md in dotfiles).
#
# Usage:
#   ~/dotfiles/script/sync-team-skills.sh [--check] [--force] [<project-root> ...]   (default: $PWD)
#
#   --check   write nothing; exit 1 when a project copy is missing, hand edited, out of date
#             with dotfiles, has an extra file, or a link is missing.
#   --force   replace a hand written skill directory (no generated stamp) or a real directory
#             where a link belongs. Move its product facts out first.
set -euo pipefail

DOTFILES="${DOTFILES:-$HOME/dotfiles}"
SRC_REL="templates/agent-team/.agents/skills"
SRC="$DOTFILES/$SRC_REL"
CHECK=0
FORCE=0
PROJECTS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --check) CHECK=1 ;;
    --force) FORCE=1 ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
    -*) echo "sync-team-skills: unknown flag $1" >&2; exit 2 ;;
    *) PROJECTS+=("$1") ;;
  esac
  shift
done
[ ${#PROJECTS[@]} -eq 0 ] && PROJECTS=("$PWD")

if [ ! -d "$SRC" ]; then
  echo "sync-team-skills: missing $SRC (clone dotfiles to ~/dotfiles or set DOTFILES)" >&2
  exit 2
fi

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -d' ' -f1; else shasum -a 256 | cut -d' ' -f1; fi
}

# Hash of every file path and content in a skill directory, so any source change shows.
source_hash() {
  (cd "$1" && find . -type f | LC_ALL=C sort | while IFS= read -r f; do
    printf '%s %s\n' "$(sha256 < "$f")" "$f"
  done) | sha256
}

# Copy one source skill into $2 and stamp its SKILL.md right after the frontmatter.
render() {
  local name="$1" out="$2" stamp
  stamp="<!-- Generated from dotfiles $SRC_REL/$name by script/sync-team-skills.sh, do not edit. Edit the dotfiles source and re-run the sync. source-sha256: $(source_hash "$SRC/$name") -->"
  mkdir -p "$out"
  cp -R "$SRC/$name/." "$out/"
  if [ -f "$out/SKILL.md" ]; then
    awk -v stamp="$stamp" '
      NR == 1 && $0 != "---" { print stamp; done = 1 }
      NR == 1 && $0 == "---" { fm = 1; print; next }
      fm && $0 == "---" { print; print stamp; fm = 0; done = 1; next }
      { print }
    ' "$out/SKILL.md" > "$out/SKILL.md.tmp"
    mv "$out/SKILL.md.tmp" "$out/SKILL.md"
  fi
}

files_in() { (cd "$1" && find . -type f | sed 's|^\./||' | LC_ALL=C sort); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

NAMES=()
for d in "$SRC"/*/; do
  [ -f "$d/SKILL.md" ] || continue
  name="$(basename "$d")"
  NAMES+=("$name")
  render "$name" "$TMP/$name"
done
if [ ${#NAMES[@]} -eq 0 ]; then
  echo "sync-team-skills: no skills in $SRC" >&2
  exit 2
fi

is_name() {
  local n
  for n in "${NAMES[@]}"; do [ "$n" = "$1" ] && return 0; done
  return 1
}

DOTFILES_REAL="$(cd "$DOTFILES" && pwd -P)"
HOME_REAL="$(cd "$HOME" 2>/dev/null && pwd -P || echo "$HOME")"

status=0
for proj in "${PROJECTS[@]}"; do
  if [ ! -d "$proj" ]; then
    echo "sync-team-skills: $proj is not a directory" >&2
    status=1
    continue
  fi
  proj="$(cd "$proj" && pwd)"
  real="$(cd "$proj" && pwd -P)"
  problems=()

  # Never write into the home folder or the dotfiles checkout, or through a skills folder that
  # links out of the project (as ~/.agents and ~/.claude/skills link into dotfiles).
  case "$real/" in
    "$DOTFILES_REAL/"*) problems+=("refused: target is inside the dotfiles checkout") ;;
  esac
  [ "$real" = "$HOME_REAL" ] && problems+=("refused: target is the home folder")
  for tool in .agents .claude .cursor; do
    [ -d "$proj/$tool/skills" ] || continue
    sk="$(cd "$proj/$tool/skills" && pwd -P)"
    case "$sk/" in
      "$real/"*) ;;
      *) problems+=("refused: $tool/skills resolves outside the project ($sk)") ;;
    esac
  done
  if [ ${#problems[@]} -gt 0 ]; then
    status=1
    for p in "${problems[@]}"; do echo "sync-team-skills: $proj: $p" >&2; done
    continue
  fi

  # Generated skills that dotfiles no longer has: flag them, and remove them on sync.
  for d in "$proj/.agents/skills"/*/; do
    [ -f "$d/SKILL.md" ] || continue
    name="$(basename "$d")"
    is_name "$name" && continue
    grep -q "Generated from dotfiles $SRC_REL/$name by script/sync-team-skills.sh" "$d/SKILL.md" || continue
    if [ "$CHECK" -eq 1 ]; then
      problems+=("stale .agents/skills/$name: generated from dotfiles, which no longer has it")
    else
      rm -rf "$proj/.agents/skills/$name"
      for tool in .claude .cursor; do
        link="$proj/$tool/skills/$name"
        [ -L "$link" ] && [ "$(readlink "$link")" = "../../.agents/skills/$name" ] && rm -f "$link"
      done
      echo "sync-team-skills: $proj: removed $name (no longer in dotfiles)"
    fi
  done

  for name in "${NAMES[@]}"; do
    want="$TMP/$name"
    have="$proj/.agents/skills/$name"
    rel=".agents/skills/$name"

    if [ "$CHECK" -eq 1 ]; then
      if [ ! -d "$have" ] || [ -L "$have" ]; then
        problems+=("missing $rel")
      else
        while IFS= read -r f; do
          if [ ! -f "$have/$f" ]; then problems+=("missing $rel/$f")
          elif ! cmp -s "$want/$f" "$have/$f"; then problems+=("differs $rel/$f (hand edited or out of date)")
          fi
        done < <(files_in "$want")
        while IFS= read -r f; do
          [ -f "$want/$f" ] || problems+=("extra $rel/$f")
        done < <(files_in "$have")
      fi
      for tool in .claude .cursor; do
        link="$proj/$tool/skills/$name"
        [ -L "$link" ] && [ "$(readlink "$link")" = "../../$rel" ] \
          || problems+=("missing link $tool/skills/$name -> ../../$rel")
      done
      continue
    fi

    # Sync: never overwrite a hand written copy or a real directory unless --force.
    if [ -d "$have" ] && [ ! -L "$have" ] && [ "$FORCE" -eq 0 ] \
      && ! grep -q 'source-sha256:' "$have/SKILL.md" 2>/dev/null; then
      problems+=("refused $rel: hand written copy (no generated stamp). Move its product facts to docs/agents/, then re-run with --force")
      continue
    fi
    blocked=0
    for tool in .claude .cursor; do
      link="$proj/$tool/skills/$name"
      if [ -e "$link" ] && [ ! -L "$link" ] && [ "$FORCE" -eq 0 ]; then
        problems+=("refused $tool/skills/$name: real directory where a link belongs. Re-run with --force to replace it")
        blocked=1
      fi
    done
    [ "$blocked" -eq 1 ] && continue

    rm -rf "$have"
    mkdir -p "$(dirname "$have")"
    cp -R "$want" "$have"
    for tool in .claude .cursor; do
      link="$proj/$tool/skills/$name"
      mkdir -p "$proj/$tool/skills"
      if [ ! -L "$link" ] || [ "$(readlink "$link")" != "../../$rel" ]; then
        rm -rf "$link"
        ln -s "../../$rel" "$link"
      fi
    done
  done

  if [ ${#problems[@]} -gt 0 ]; then
    status=1
    for p in "${problems[@]}"; do echo "sync-team-skills: $proj: $p" >&2; done
    [ "$CHECK" -eq 1 ] && echo "sync-team-skills: $proj: run ~/dotfiles/script/sync-team-skills.sh $proj to restore the generated copies" >&2
  elif [ "$CHECK" -eq 1 ]; then
    echo "sync-team-skills: $proj: OK (${NAMES[*]})"
  else
    echo "sync-team-skills: $proj: synced ${NAMES[*]}"
  fi
done

exit "$status"
