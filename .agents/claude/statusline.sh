#!/bin/bash

# Read JSON input once
input=$(cat)

# Save the weekly rate limits for script/usage-gate.py (Claude Code sends them to subscribers)
rl=$(echo "$input" | jq -c '.rate_limits // empty' 2>/dev/null)
if [ -n "$rl" ]; then
  mkdir -p "$HOME/.claude/state/usage-gate"
  echo "$rl" | jq -c --argjson t "$(date +%s)" '. + {_written_at: $t}' \
    > "$HOME/.claude/state/usage-gate/claude-rate-limits.json.tmp" 2>/dev/null \
    && mv "$HOME/.claude/state/usage-gate/claude-rate-limits.json.tmp" "$HOME/.claude/state/usage-gate/claude-rate-limits.json"
fi

# Extract current directory
cwd=$(echo "$input" | jq -r '.workspace.current_dir')

# Extract model name
model=$(echo "$input" | jq -r '.model.display_name // empty')

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

printf '\033[90m[%s]\033[00m \033[01;36m%s\033[00m%s | ctx: %b%s%%\033[00m' \
  "$model" "$dir" "$git_part" "$ctx_color" "$ctx_pct"
