#!/usr/bin/env bash
# Detect skill-tree problems across the centralized dotfiles set and project-local sets.
#
# Central set : $DOTFILES/.agents/skills   (linked to ~/.claude/skills, so global to every session)
# Project sets: <project>/{.claude,.cursor,.agents}/skills
#
# Project-level skills take precedence over the central ones, so a name present in both means
# the central version is silently dead. That is the main thing this script catches.
#
# Entries are compared by resolved physical path, so a project's .claude/skills/x -> .cursor/skills/x
# symlink is recognised as one skill, not two.
#
# Usage:   script/check-skill-collisions.sh [project-root ...]
# Default: ~/projects
# Exit:    0 clean or warnings only, 1 problems found.
set -uo pipefail

DOTFILES="${DOTFILES:-$HOME/dotfiles}"
GLOBAL_SKILLS="$DOTFILES/.agents/skills"

if [ ! -d "$GLOBAL_SKILLS" ]; then
  echo "check-skill-collisions: missing $GLOBAL_SKILLS" >&2
  exit 2
fi

if [ "$#" -gt 0 ]; then
  ROOTS=("$@")
else
  ROOTS=("$HOME/projects")
fi

problems=0
warnings=0

note() { printf '  %s\n' "$1"; }
fail() { problems=$((problems + 1)); printf '  FAIL  %s\n' "$1"; }
warn() { warnings=$((warnings + 1)); printf '  WARN  %s\n' "$1"; }

# Physical path of a directory, following every symlink.
resolve() { (cd "$1" 2>/dev/null && pwd -P) || echo "$1"; }

# --- central skill names -----------------------------------------------------
global_names=()
while IFS= read -r d; do
  global_names+=("$(basename "$d")")
done < <(find "$GLOBAL_SKILLS" -mindepth 1 -maxdepth 1 -type d | sort)

has_global() {
  local n="$1" g
  for g in "${global_names[@]}"; do
    [ "$g" = "$n" ] && return 0
  done
  return 1
}

# --- project skill directories ----------------------------------------------
skill_dirs=()
for root in "${ROOTS[@]}"; do
  if [ ! -d "$root" ]; then
    warn "root does not exist: $root"
    continue
  fi
  while IFS= read -r d; do
    skill_dirs+=("$d")
  done < <(find "$root" -maxdepth 4 -type d -name skills \
             \( -path '*/.claude/skills' -o -path '*/.cursor/skills' -o -path '*/.agents/skills' \) \
             -not -path '*/node_modules/*' 2>/dev/null | sort)
done

echo "Central skills: ${#global_names[@]} in $GLOBAL_SKILLS"
echo "Project skill directories: ${#skill_dirs[@]}"
echo

# name -> first location and its resolved physical path
seen_names=()
seen_locs=()
seen_reals=()

for dir in "${skill_dirs[@]}"; do
  echo "$dir"
  entries=()
  while IFS= read -r e; do
    entries+=("$e")
  done < <(find "$dir" -mindepth 1 -maxdepth 1 \( -type d -o -type l \) 2>/dev/null | sort)

  if [ "${#entries[@]}" -eq 0 ]; then
    note "(empty)"
    echo
    continue
  fi

  for entry in "${entries[@]}"; do
    name="$(basename "$entry")"

    # Broken symlink.
    if [ -L "$entry" ] && [ ! -e "$entry" ]; then
      fail "$name -> $(readlink "$entry") (broken symlink)"
      continue
    fi

    # Shadowing: the central version can never load while this exists.
    if has_global "$name"; then
      fail "$name shadows $GLOBAL_SKILLS/$name"
    fi

    if [ ! -f "$entry/SKILL.md" ]; then
      fail "$name has no SKILL.md"
      continue
    fi

    real="$(resolve "$entry")"

    # Have we seen this name already?
    idx=0
    found=-1
    for s in ${seen_names[@]+"${seen_names[@]}"}; do
      if [ "$s" = "$name" ]; then
        found=$idx
        break
      fi
      idx=$((idx + 1))
    done

    if [ "$found" -ge 0 ]; then
      if [ "$real" = "${seen_reals[$found]}" ]; then
        # Same physical skill reached by a second path: the intended alias layout.
        note "$name (alias of ${seen_locs[$found]})"
      else
        warn "$name also exists at ${seen_locs[$found]} (separate copies, will drift)"
      fi
    else
      seen_names+=("$name")
      seen_locs+=("$entry")
      seen_reals+=("$real")
      note "$name"
    fi
  done
  echo
done

echo "----"
if [ "$problems" -eq 0 ] && [ "$warnings" -eq 0 ]; then
  echo "OK: no shadowed skills, no broken links, no cross-project duplicates."
  exit 0
fi
echo "$problems problem(s), $warnings warning(s)."
[ "$problems" -gt 0 ] && exit 1
exit 0
