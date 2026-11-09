#!/usr/bin/env bash
# Home directories belong to tools; only tracked dotfiles skills get links.
set -euo pipefail
DOTFILES="${DOTFILES:-$HOME/dotfiles}"
DOTFILES=$(cd "$DOTFILES" && pwd -P)
# shellcheck disable=SC1091
. "$(cd "$(dirname "$0")" && pwd)/lib/dotfiles-source.sh"
require_main_dotfiles agent-skills "$DOTFILES"
SKILLS="$DOTFILES/.agents/skills"
TEAM_SKILLS="$DOTFILES/templates/agent-team/.agents/skills"

bundled() { printf '%s\n' "$orca_bundled" | grep -qx -- "$1"; }

# Use the tracked inventory, never ignored tool installations (or synced plugins).
owned() {
  { [ -f "$SKILLS/$1/SKILL.md" ] &&
      git -C "$DOTFILES" ls-files --error-unmatch -- ".agents/skills/$1/SKILL.md" >/dev/null 2>&1; } ||
  { [ -f "$TEAM_SKILLS/$1/SKILL.md" ] &&
      git -C "$DOTFILES" ls-files --error-unmatch -- "templates/agent-team/.agents/skills/$1/SKILL.md" >/dev/null 2>&1; }
}

# Recognize ownership by source checkout, not just a colliding skill name.
dotfiles_skill() {
  local path="$1" name="$2" resolved old_root
  [ -f "$path/SKILL.md" ] || return 1
  resolved=$(cd "$path" && pwd -P) || return 1
  if old_root=$(cd "$resolved/../../.." 2>/dev/null && pwd -P) &&
     [ -f "$old_root/install.sh" ] &&
     [ "$resolved" = "$old_root/.agents/skills/$name" ] &&
     git -C "$old_root" ls-files --error-unmatch -- ".agents/skills/$name/SKILL.md" >/dev/null 2>&1; then
    return 0
  fi
  if old_root=$(cd "$resolved/../../../../.." 2>/dev/null && pwd -P) &&
     [ -f "$old_root/install.sh" ] &&
     [ "$resolved" = "$old_root/templates/agent-team/.agents/skills/$name" ]; then
    return 0
  fi
  return 1
}

copy_skills() {
  local src="$1" dst="$2" entry name
  mkdir -p "$dst"
  for entry in "$src"/* "$src"/.[!.]* "$src"/..?*; do
    [ -e "$entry" ] || [ -L "$entry" ] || continue
    name=$(basename "$entry")
    if owned "$name" && dotfiles_skill "$entry" "$name"; then continue; fi
    cp -RP "$entry" "$dst/$name"
    echo "agent-skills: preserved $entry -> $dst/$name"
  done
}

# Build a replacement before unlinking: even ignored tool files stay intact.
materialize() {
  local path="$1" kind="$2" src stage entry name
  if [ -L "$path" ]; then
    src=$(cd "$path" && pwd -P) || { echo "agent-skills: broken directory link: $path" >&2; return 1; }
    stage=$(mktemp -d "${path}.migration.XXXXXX")
    if [ "$kind" = agents ]; then
      for entry in "$src"/* "$src"/.[!.]* "$src"/..?*; do
        [ -e "$entry" ] || [ -L "$entry" ] || continue
        name=$(basename "$entry")
        [ "$name" = skills ] && continue
        cp -RP "$entry" "$stage/$name"
      done
      copy_skills "$src/skills" "$stage/skills"
    else
      copy_skills "$src" "$stage"
    fi
    rm "$path"
    mv "$stage" "$path"
    echo "agent-skills: migrated $path from tree link to real directory (source retained: $src)"
  else
    mkdir -p "$path"
  fi
}

mkdir -p "$HOME/.claude"
materialize "$HOME/.agents" agents
materialize "$HOME/.agents/skills" skills
materialize "$HOME/.claude/skills" skills

# Orca owns its bundled skills: install them through orca, never link or copy them.
# Run after the migrations so a tree-linked home cannot route the install into the repo.
orca_bundled=
orca_bin=$(command -v orca 2>/dev/null || true)
[ -n "$orca_bin" ] || { [ -x "$HOME/.orca/cli/bin/orca" ] && orca_bin="$HOME/.orca/cli/bin/orca"; }
if [ -n "$orca_bin" ]; then
  orca_bundled=$("$orca_bin" skills list 2>/dev/null | sed -n 's/^\([A-Za-z0-9][A-Za-z0-9_-]*\):.*/\1/p')
  "$orca_bin" skills install --all || echo "agent-skills: orca skills install --all failed" >&2
else
  echo "agent-skills: orca not found, skipping bundled Orca skills"
fi

link_skill() {
  local entry="$1" name="$2" dst target
  bundled "$name" && return 0
  for dst in "$HOME/.agents/skills" "$HOME/.claude/skills"; do
    target="$dst/$name"
    if [ -L "$target" ] && [ "$(readlink "$target")" = "$entry" ]; then
      continue
    fi
    # Only replace a link into another dotfiles checkout, never a tool folder.
    if [ -e "$target" ] || [ -L "$target" ]; then
      if [ -L "$target" ] && dotfiles_skill "$target" "$name"; then
        rm "$target"
      else
        echo "agent-skills: kept existing $target (not a dotfiles link)"
        continue
      fi
    fi
    ln -s "$entry" "$target"
    echo "agent-skills: linked $target -> $entry"
  done
}

for src_root in "$SKILLS" "$TEAM_SKILLS"; do
  [ -d "$src_root" ] || continue
  for entry in "$src_root"/*; do
    [ -e "$entry" ] || continue
    name=$(basename "$entry")
    owned "$name" || continue
    link_skill "$entry" "$name"
  done
done
