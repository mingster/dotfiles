#!/usr/bin/env bash
# weekly-skill-impact.sh: report-only skill upstream impact (never edits roles).
#
# Usage: WEEKLY_SKILL_IMPACT_SLICE=mattpocock|pstack ~/dotfiles/script/weekly-skill-impact.sh
# (no arguments: -h and --help print this text and write nothing, any other argument exits 2)
#
# Writes docs/agents/drafts/weekly-skill-impact-<DATE_TAG>.md under DOTFILES.
set -euo pipefail

print_usage() { sed -n '/^# Usage:/,/^#$/{/^#$/d;s/^# \{0,1\}//;p;}' "${BASH_SOURCE[0]}"; }
case "${1-}" in -h|--help) print_usage; exit 0 ;; esac
if [ "$#" -ne 0 ]; then
  print_usage >&2
  exit 2
fi

DOTFILES="${DOTFILES:-$HOME/dotfiles}"
DOTFILES=$(cd "$DOTFILES" && pwd -P)
DATE_TAG="${DATE_TAG:-$(date '+%Y%m%d')}"
SLICE="${WEEKLY_SKILL_IMPACT_SLICE:-mattpocock}"
OUT="$DOTFILES/docs/agents/drafts/weekly-skill-impact-${DATE_TAG}.md"
CITATION_ROOTS=(
  docs/agents/sdlc-skill-map.md
  docs/agents/skills-inventory.md
  docs/agents/team-reference.md
  templates/agent-team/docs/agents/pstack-attribution.md
  .agents/claude/CLAUDE.md
)

case "$SLICE" in
  mattpocock|pstack) ;;
  *) echo "weekly-skill-impact: unknown slice $SLICE" >&2; exit 2 ;;
esac

mkdir -p "$(dirname "$OUT")"

for f in "${CITATION_ROOTS[@]}"; do
  [ -f "$DOTFILES/$f" ] || printf 'WARN weekly-skill-impact: citation root %s does not exist\n' "$f" >&2
done

cite_skill() {
  local name="$1" f
  for f in "${CITATION_ROOTS[@]}"; do
    [ -f "$DOTFILES/$f" ] || continue
    if grep -qwF -- "$name" "$DOTFILES/$f" 2>/dev/null; then
      printf '  - `%s` cites `%s`\n' "$f" "$name"
    fi
  done
  local agent
  for agent in "$DOTFILES"/templates/agent-team/.claude/agents/*.md; do
    [ -f "$agent" ] || continue
    if grep -qwF -- "$name" "$agent" 2>/dev/null; then
      printf '  - `%s` cites `%s`\n' "${agent#$DOTFILES/}" "$name"
    fi
  done
  for team in elon team-audit; do
    local sk="$DOTFILES/templates/agent-team/.agents/skills/$team/SKILL.md"
    [ -f "$sk" ] || continue
    if grep -qwF -- "$name" "$sk" 2>/dev/null; then
      printf '  - `templates/agent-team/.agents/skills/%s/SKILL.md` cites `%s`\n' "$team" "$name"
    fi
  done
}

write_mattpocock() {
  local state="$DOTFILES/.agents/skills/.mattpocock-upstream"
  {
    printf '# Weekly skill impact (%s)\n\n' "$DATE_TAG"
    printf 'Report only. No role or team file edits by this script.\n\n'
    printf '## Matt Pocock vendored skills\n\n'
    printf '### Diff stat\n\n```\n'
    git -C "$DOTFILES" diff --stat -- .agents/skills 2>/dev/null || true
    printf '```\n\n'
    printf '### Changed paths\n\n'
    git -C "$DOTFILES" diff --name-only -- .agents/skills 2>/dev/null | sed 's/^/  - /' || true
    printf '\n### Citation map\n\n'
    if [ -f "$state" ]; then
      local n
      for n in $(sed -n 's/^skills=//p' "$state"); do
        cite_skill "$n"
      done
    fi
    printf '\n### Gaps and conflicts\n\n'
    printf '  - `resolving-merge-conflicts` is vendored locally but is not in `.mattpocock-upstream` skills=; upstream sync never touches it.\n'
    printf '  - Upstream skills not vendored include `implement-spec` and `pr` (see skills-inventory.md).\n'
    printf '\n### Recommended owner actions\n\n'
    printf '  - Re-run team-audit on affected projects if behavior skills changed.\n'
    printf '  - Update `.mattpocock-local.patch` if apply fails on the next sync.\n'
  } >"$OUT"
}

pstack_section() {
  local state="$DOTFILES/script/.pstack-template-upstream"
  printf '## pstack template skills\n\n'
  printf '### Diff stat\n\n```\n'
  git -C "$DOTFILES" diff --stat -- templates/agent-team .agents/skills script/.pstack-template-upstream 2>/dev/null || true
  printf '```\n\n'
  if [ -f "$state" ]; then
    printf '### Skills in state\n\n'
    sed -n 's/^skills=//p' "$state" | tr ' ' '\n' | sed 's/^/  - /'
    printf '\n'
  fi
  printf '### Citation map\n\n'
  cite_skill poteto-mode
  cite_skill benchmark-checklist
  [ -f "$DOTFILES/templates/agent-team/.agents/skills/orca-adapter/ORCA-ADAPTER.md" ] \
    && printf '  - `templates/agent-team/.agents/skills/orca-adapter/ORCA-ADAPTER.md` (local Orca adapter)\n'
  printf '\n### Gaps and conflicts\n\n'
  printf '  - Playbook paths may still say `pstack/skills/...`; compare with ORCA-ADAPTER.md.\n'
  printf '\n### Recommended owner actions\n\n'
  printf '  - Run `agent-team.sh sync` on projects after merging the pstack PR.\n'
}

# One pstack section per report: a rerun on the same date replaces it instead of appending again.
write_pstack() {
  local kept
  kept=$(mktemp)
  if [ -f "$OUT" ]; then
    awk '/^## pstack template skills$/ { skip = 1; next } /^## / { skip = 0 } !skip' "$OUT" >"$kept"
  else
    {
      printf '# Weekly skill impact (%s)\n\n' "$DATE_TAG"
      printf 'Report only. No role or team file edits by this script.\n\n'
    } >"$kept"
  fi
  { cat "$kept"; pstack_section; } >"$OUT"
  rm -f "$kept"
}

case "$SLICE" in
  mattpocock) write_mattpocock ;;
  pstack) write_pstack ;;
  *) echo "weekly-skill-impact: unknown slice $SLICE" >&2; exit 2 ;;
esac

echo "weekly-skill-impact: wrote $OUT"
