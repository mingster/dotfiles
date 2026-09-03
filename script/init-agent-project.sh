#!/usr/bin/env bash
# init-agent-project.sh: scaffold the per-repo config the engineering skills read.
#
# Seeds docs/agents/{issue-tracker,triage-labels,domain}.md from the
# setup-matt-pocock-skills templates and adds an "## Agent skills" pointer block to
# the repo agent instruction file. Idempotent: files that already exist are left alone.
#
# Usage:
#   script/init-agent-project.sh [--labels] [--dry-run] [repo ...]
#
# With no repo argument it operates on the current working directory.
#   --labels   also create the five triage labels on the GitHub remote (needs gh)
#   --dry-run  print what would happen, write nothing
#
# This is the deterministic path. For a repo that needs judgement (monorepo layout,
# a tracker that is not GitHub or GitLab, existing conventions to merge with), run
# the /setup-matt-pocock-skills skill instead and let it interview you.
set -euo pipefail

DOTFILES="${DOTFILES:-$HOME/dotfiles}"
SEEDS="$DOTFILES/.agents/skills/setup-matt-pocock-skills"
LABELS="needs-triage needs-info ready-for-agent ready-for-human wontfix"

do_labels=0
dry_run=0
nrepos=0
repos=""

for arg in "$@"; do
  case "$arg" in
    --labels) do_labels=1 ;;
    --dry-run) dry_run=1 ;;
    -h|--help) sed -n "2,14p" "$0"; exit 0 ;;
    -*) echo "init-agent-project: unknown flag $arg" >&2; exit 2 ;;
    *) repos="$repos$arg"$'\n'; nrepos=$((nrepos + 1)) ;;
  esac
done

if [ "$nrepos" -eq 0 ]; then
  repos="$PWD"$'\n'
fi

if [ ! -d "$SEEDS" ]; then
  echo "init-agent-project: missing $SEEDS; is setup-matt-pocock-skills vendored?" >&2
  exit 1
fi

say() { printf "%s\n" "$*"; }

# github | gitlab | local, inferred from the origin remote
tracker_for() {
  local url
  url=$(git -C "$1" remote get-url origin 2>/dev/null || true)
  case "$url" in
    *github.com*) echo github ;;
    *gitlab*)     echo gitlab ;;
    *)            echo local ;;
  esac
}

# Local convention: AGENTS.md carries the content, CLAUDE.md is a one line pointer.
instruction_file() {
  if [ -f "$1/AGENTS.md" ]; then
    echo "$1/AGENTS.md"
  elif [ -f "$1/CLAUDE.md" ]; then
    echo "$1/CLAUDE.md"
  else
    echo "$1/AGENTS.md"
  fi
}

seed_file() {
  if [ -f "$2" ]; then
    say "  keep  ${2##*/} (already present)"
    return
  fi
  say "  seed  ${2##*/}"
  [ "$dry_run" -eq 1 ] && return 0
  cp "$1" "$2"
}

setup_repo() {
  local repo tracker docs target seed summary
  repo="$1"

  if [ ! -d "$repo" ]; then
    say "skip  $repo (no such directory)"
    return
  fi
  if [ ! -d "$repo/.git" ]; then
    say "skip  $repo (not a git repo)"
    return
  fi

  tracker=$(tracker_for "$repo")
  docs="$repo/docs/agents"
  target=$(instruction_file "$repo")
  say "repo  $repo  (tracker: $tracker)"

  [ "$dry_run" -eq 1 ] || mkdir -p "$docs"

  seed="$SEEDS/issue-tracker-$tracker.md"
  seed_file "$seed" "$docs/issue-tracker.md"
  seed_file "$SEEDS/triage-labels.md" "$docs/triage-labels.md"
  seed_file "$SEEDS/domain.md" "$docs/domain.md"

  case "$tracker" in
    github) summary="GitHub issues in this repo, via the \`gh\` CLI" ;;
    gitlab) summary="GitLab issues in this repo, via the \`glab\` CLI" ;;
    *)      summary="Local markdown files under \`.scratch/<feature>/\`" ;;
  esac

  if grep -q "^### Issue tracker" "$target" 2>/dev/null; then
    say "  keep  ${target##*/} (already has the Agent skills block)"
  else
    say "  write ${target##*/} (append Agent skills block)"
    if [ "$dry_run" -eq 0 ]; then
      [ -f "$target" ] || printf "# %s\n\nAgent guidance for this repo.\n" "$(basename "$repo")" > "$target"
      cat >> "$target" <<BLOCK

## Agent skills

### Issue tracker

$summary. See \`docs/agents/issue-tracker.md\`.

### Triage labels

The five canonical triage roles, label strings unchanged. See \`docs/agents/triage-labels.md\`.

### Domain docs

Single context: \`CONTEXT.md\` plus \`docs/adr/\` at the repo root. See \`docs/agents/domain.md\`.
BLOCK
    fi
  fi

  if [ "${target##*/}" = "AGENTS.md" ] && [ ! -f "$repo/CLAUDE.md" ]; then
    say "  write CLAUDE.md (pointer to AGENTS.md)"
    [ "$dry_run" -eq 0 ] && printf "@AGENTS.md\n" > "$repo/CLAUDE.md"
  fi

  if [ "$do_labels" -eq 1 ] && [ "$tracker" = "github" ]; then
    create_labels "$repo"
  fi
}

create_labels() {
  local repo label origin out
  repo="$1"
  if ! command -v gh >/dev/null 2>&1; then
    say "  warn  gh not found, skipping label creation"
    return
  fi
  origin=$(git -C "$repo" remote get-url origin 2>/dev/null || true)
  if [ -z "$origin" ]; then
    say "  warn  no origin remote, skipping label creation"
    return
  fi
  for label in $LABELS; do
    if [ "$dry_run" -eq 1 ]; then
      say "  would create label $label"
      continue
    fi
    if out=$(gh label create "$label" --repo "$origin" 2>&1); then
      say "  label $label created"
    elif printf "%s" "$out" | grep -qi "already exists"; then
      say "  label $label already exists"
    else
      say "  label $label FAILED: $(printf "%s" "$out" | head -1)"
    fi
  done
}

while IFS= read -r repo; do
  [ -n "$repo" ] || continue
  setup_repo "$repo"
done <<< "$repos"

say "init-agent-project: done"
