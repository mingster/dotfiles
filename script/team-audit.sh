#!/usr/bin/env bash
# team-audit.sh: deterministic checks of the agent team files. The judgement part is the team-audit skill.
#
# Usage: ~/dotfiles/script/team-audit.sh [<project-root> ...]   (default: ~/projects/riben.life ~/pstv)
#
# Checks, each printed as "FINDING <check>: <detail>":
#   sync      sync-team-skills.sh --check passes for each project
#   budget    every role file (.claude/agents/*.md, project and template) is at most ROLE_WORD_BUDGET words (800)
#   wording   no banned wording in team files: someone other than Elon merges, pushes or opens PRs,
#             task_plan.md or progress.md ledgers, the old orca claude-teams layout
#   skill     every SKILL.md has name and description frontmatter
#   lock      the skill lock does not track a locally customized skill (LOCAL_SKILLS, default orchestration)
#   helpers   the orchestration helper scripts exist
#
# Exit 0 when clean, 1 on any finding, 2 on a usage error. Env: DOTFILES (default ~/dotfiles).
set -uo pipefail

DOTFILES="${DOTFILES:-$HOME/dotfiles}"
BUDGET="${ROLE_WORD_BUDGET:-800}"
LOCAL_SKILLS="${LOCAL_SKILLS:-orchestration}"
HELPERS="worker-panes.sh worker-pane.sh worker-pane-close.sh worker-watch.sh role-colors.tsv"
TEMPLATE="$DOTFILES/templates/agent-team"

case "${1:-}" in -h|--help) sed -n '2,16p' "$0"; exit 0 ;; -*) echo "team-audit: unknown flag $1" >&2; exit 2 ;; esac
PROJECTS=("$@")
[ ${#PROJECTS[@]} -eq 0 ] && PROJECTS=("$HOME/projects/riben.life" "$HOME/pstv")
[ -d "$TEMPLATE" ] || { echo "team-audit: missing $TEMPLATE (set DOTFILES)" >&2; exit 2; }

findings=0
finding() { echo "FINDING $1: $2"; findings=$((findings + 1)); }

# Banned wording, as extended regexes. A line may opt out with "team-audit: allow".
BANNED=(
  '(Tech Lead|[Tt]he lead|`lead`) (merges|pushes the branch|opens (the|a) PR)'
  'direct(s)? the Tech Lead to merge'
  '(release-manager|fullstack-dev|qa-sdet|support-csm|teammate)s? (merges (the |a |its |team )?PRs?|opens (the|a|its) PR)'
  'open a PR and merge it'
  'task_plan\.md'
  '(^|[^_[:alnum:]])progress\.md'
  'orca claude-teams'
)

# Team files of one root: role files, model routing, team skills, team docs.
team_files() {
  local root="$1"
  for f in "$root"/.claude/agents/*.md "$root"/.claude/model-routing.md \
           "$root"/.agents/skills/*/*.md "$root"/docs/agents/*.md "$root"/fileServer/docs/agents/*.md; do
    [ -f "$f" ] && echo "$f"
  done
}

for proj in "${PROJECTS[@]}"; do
  if [ ! -d "$proj" ]; then finding sync "$proj: no such project"; continue; fi
  out=$(DOTFILES="$DOTFILES" "$DOTFILES/script/sync-team-skills.sh" --check "$proj" 2>&1) \
    || finding sync "$proj: $(echo "$out" | head -3 | tr '\n' ' ')"
done

ROOTS=("$TEMPLATE" "${PROJECTS[@]}")

for root in "${ROOTS[@]}"; do
  for f in "$root"/.claude/agents/*.md; do
    [ -f "$f" ] || continue
    n=$(wc -w < "$f" | tr -d ' ')
    [ "$n" -le "$BUDGET" ] || finding budget "$f: $n words (budget $BUDGET)"
  done
done

wording_files() {
  for root in "${ROOTS[@]}"; do [ -d "$root" ] && team_files "$root"; done
  [ -f "$DOTFILES/docs/agents/agent-team-architecture.md" ] && echo "$DOTFILES/docs/agents/agent-team-architecture.md"
}
hits=$(while IFS= read -r f; do
  for re in "${BANNED[@]}"; do
    grep -nE -- "$re" "$f" | grep -v 'team-audit: allow' | sed "s|^|$f:|" | cut -c1-220
  done
done < <(wording_files))
if [ -n "$hits" ]; then
  while IFS= read -r h; do finding wording "$h"; done <<< "$hits"
fi

for root in "$DOTFILES" "$TEMPLATE" "${PROJECTS[@]}"; do
  for f in "$root"/.agents/skills/*/SKILL.md; do
    [ -f "$f" ] || continue
    front=$(awk 'NR==1 && $0!="---"{exit} NR>1 && $0=="---"{exit} NR>1{print}' "$f")
    echo "$front" | grep -qE '^name: *[^ ]' || finding skill "$f: no name in frontmatter"
    echo "$front" | grep -qE '^description: *[^ ]' || finding skill "$f: no description in frontmatter"
  done
done

LOCK="$DOTFILES/.agents/.skill-lock.json"
if [ -f "$LOCK" ]; then
  for s in $LOCAL_SKILLS; do
    python3 -c 'import json,sys; sys.exit(0 if sys.argv[2] in json.load(open(sys.argv[1])).get("skills",{}) else 1)' "$LOCK" "$s" \
      && finding lock "$LOCK tracks $s, so npx skills update would overwrite it (remove the entry)"
  done
fi

for h in $HELPERS; do
  [ -f "$DOTFILES/.agents/skills/orchestration/$h" ] || finding helpers "missing $DOTFILES/.agents/skills/orchestration/$h"
done

if [ "$findings" -eq 0 ]; then echo "team-audit: clean"; exit 0; fi
echo "team-audit: $findings finding(s)"
exit 1
