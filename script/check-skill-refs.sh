#!/usr/bin/env bash
# Report each /<skill> a project doc names that has no skill behind it (#1476).
# Usage: check-skill-refs.sh <project-dir>
# Scans AGENTS.md, docs/ and .claude/ (Markdown). A name counts when a skill of that name sits under the
# project, the user or the dotfiles trees. Built in commands, URL paths and file paths are not names.
# A name needs two letters (so sed's /g is skipped). An unknown name counts only when written as the command (right after run/use/invoke/type, or right before "skill"), because a web route such as /account looks the same.
# Exit: 0 clean, 1 a name has no skill, 2 usage.
set -uo pipefail

dir=${1:-}
[ -d "$dir" ] || { echo "Usage: $0 <project-dir>" >&2; exit 2; }
dir=${dir%/}
dotfiles=${DOTFILES:-$(cd "$(dirname "$0")/.." && pwd)}

# Retired team skills and what replaced them (CHANGELOG: they repeated pstack).
retired_replacement() {
  case "$1" in
    staging-review) echo "pstack swarm with the staging overlay" ;;
    crew) echo "/elon (pstack Orchestrate)" ;;
    team-grill-backlog) echo "/grill-backlog" ;;
    wrap-up) echo "pstack worktree-cleanup (script/wrap-up.sh stays)" ;;
    *) return 1 ;;
  esac
}

# skill-name is the placeholder the docs use for any skill.
builtin_command() {
  case "$1" in
    help|clear|compact|config|cost|doctor|exit|init|login|logout|mcp|memory|model|permissions|pr-comments|review|status|\
    terminal-setup|vim|agents|bug|add-dir|resume|rewind|hooks|ide|install-github-app|loop|plan|fast|usage|context|\
    copy|rename|theme|todos|feedback|release-notes|security-review|statusline|upgrade|fork|batch|effort|skills|plugin|\
    schedule|btw|subtask|skill-name) return 0 ;;
  esac
  return 1
}

skill_exists() {
  local root
  for root in "$dir/.claude/skills" "$dir/.agents/skills" "$dir/.cursor/skills" "$HOME/.claude/skills" \
    "$HOME/.agents/skills" "$dotfiles/.agents/skills" "$dotfiles/templates/agent-team/.agents/skills"; do
    [ -e "$root/$1" ] && return 0
  done
  return 1
}

files=()
[ -f "$dir/AGENTS.md" ] && files+=("$dir/AGENTS.md")
for sub in docs .claude; do
  [ -d "$dir/$sub" ] || continue
  while IFS= read -r f; do files+=("$f"); done < <(find "$dir/$sub" -name '*.md' -type f -not -path "$dir/$sub/skills/*" -not -path "$dir/.claude/skills/*" | sort)
done

# Doubled blanks keep a leading blank for the next name after a match eats its trailing one.
# A name follows a space, quote, backtick or bracket (not a word, so a path like <owner>/repo is skipped).
ref_re="(^|[[:space:]\`\"'(\\[])/[a-z][a-z0-9-]+([^[:alnum:]_/.:-]|[.,;!?]+([^[:alnum:]_/.:-]|\$)|\$)"
status=0
for f in ${files[@]+"${files[@]}"}; do
  while IFS=: read -r line match; do
    name=${match#*/}
    name=${name%%[^a-z0-9-]*}
    builtin_command "$name" && continue
    { [ -e "/$name" ] || [ -e "$dir/$name" ]; } && continue
    skill_exists "$name" && continue
    if repl=$(retired_replacement "$name"); then
      echo "agent-team: ${f#"$dir"/}:$line: /$name is a retired skill, use $repl" >&2
    else
      # An unknown name could be a web route (/account, /api). Report it only where the line talks about a skill or a command to run.
      # Only when the name is written as the command: right after run/use/invoke/type, or right before "skill" (#1546).
      sed -n "${line}p" "$f" | grep -qiE "\\b(run|use|invoke|type)[[:space:]]+[\`\"'(]*/$name\\b|/$name[\`\"')]*[[:space:]]+skill\\b" || continue
      echo "agent-team: ${f#"$dir"/}:$line: /$name names no skill under the project, user or dotfiles trees" >&2
    fi
    status=1
  done < <(sed 's/[[:space:]]/  /g' "$f" | grep -noE "$ref_re")
done
exit "$status"
