#!/bin/bash

# Read JSON input once
input=$(cat)

# Extract current directory
cwd=$(echo "$input" | jq -r '.workspace.current_dir')

# Extract context percentage
ctx_pct=$(echo "$input" | jq -r '.context_window.used_percentage // 0' | cut -d. -f1)

# Directory, with $HOME shortened to ~ (like the shell prompt)
dir="${cwd/#$HOME/~}"

# Color the context percentage based on usage
if [ "$ctx_pct" -ge 60 ]; then
  ctx_color='\033[01;31m' # red
elif [ "$ctx_pct" -ge 40 ]; then
  ctx_color='\033[01;33m' # yellow
else
  ctx_color='\033[01;32m' # green
fi

# Git branch and dirty marker (skip optional locks)
git_part=""
if GIT_OPTIONAL_LOCKS=0 git -C "$cwd" rev-parse --git-dir > /dev/null 2>&1; then
  branch=$(GIT_OPTIONAL_LOCKS=0 git -C "$cwd" symbolic-ref --short HEAD 2>/dev/null \
    || GIT_OPTIONAL_LOCKS=0 git -C "$cwd" rev-parse --short HEAD 2>/dev/null)
  dirty=""
  if [ -n "$(GIT_OPTIONAL_LOCKS=0 git -C "$cwd" status --porcelain 2>/dev/null | head -n 1)" ]; then
    dirty="*"
  fi
  git_part=$(printf ' \033[01;32m%s%s\033[00m' "$branch" "$dirty")
fi

printf '\033[01;36m%s\033[00m%s | ctx: %b%s%%\033[00m' \
  "$dir" "$git_part" "$ctx_color" "$ctx_pct"
