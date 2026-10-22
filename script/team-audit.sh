#!/usr/bin/env bash
# team-audit.sh: deterministic checks of the agent team files. The judgement part is the team-audit skill.
#
# Usage: ~/dotfiles/script/team-audit.sh [<project-root> ...]   (default: one project root per line in script/team-audit.local.conf, untracked)
#
# Checks, each printed as "FINDING <check>: <detail>":
#   sync      sync-team-skills.sh --check passes for each project
#   budget    every role file (.claude/agents/*.md, project and template) is at most ROLE_WORD_BUDGET words (800)
#   wording   no banned wording in team files: implementation workers merge, push or open PRs,
#             task_plan.md or progress.md ledgers, the old orca claude-teams layout, the retired
#             gpt-6-luna model (400 since 2026-10-21), a coordinator wait whose --types omit status
#   skill     every SKILL.md has name and description frontmatter
#   lock      the skill lock does not track a locally customized skill (LOCAL_SKILLS, default orca-team)
#   helpers   the orca-team helper scripts exist
#   sdlc      every docs/intent/*/spec.md has a sibling intent.md (Plan before Design, owner rule
#             2026-10-21); a spec first committed before SPEC_INTENT_SINCE (2026-10-21) is grandfathered
#             and has a '## Test plan' section (owner rule 2026-10-21); a spec first committed before
#             TEST_PLAN_SINCE (2026-10-22) is grandfathered
#   mp-upstream  the vendored Matt Pocock skills (.agents/skills/.mattpocock-upstream) are not behind
#             upstream main, and every role file `skills:` entry naming one of them exists. A gh or
#             network failure prints "WARN mp-upstream" and is not a finding.
#   ready-brief  every open GitHub issue labeled ready-for-agent (repo read from the project's origin
#             remote) has one text, the body or a single comment, holding all four brief fields:
#             Acceptance criteria, Requirement owner, Done condition, Deleted (heading or "Field:" label,
#             case-insensitive). Prints "FINDING ready-brief <owner/repo>#<n> missing: <fields>", the
#             fields missing from the text with the most. Opt out with the label "team-audit: allow" or a
#             line containing "team-audit: allow" in the body or a comment. A gh or network failure
#             prints "WARN ready-brief" and is not a finding.
#
# Exit 0 when clean, 1 on any finding, 2 on a usage error. Env: DOTFILES (default ~/dotfiles).
set -uo pipefail

DOTFILES="${DOTFILES:-$HOME/dotfiles}"
BUDGET="${ROLE_WORD_BUDGET:-800}"
LOCAL_SKILLS="${LOCAL_SKILLS:-orca-team}"
HELPERS="worker-panes.sh worker-pane.sh worker-pane-close.sh worker-pane-retry.sh worker-watch.sh role-colors.tsv"
TEMPLATE="$DOTFILES/templates/agent-team"

case "${1:-}" in -h|--help) sed -n '2,30p' "$0"; exit 0 ;; -*) echo "team-audit: unknown flag $1" >&2; exit 2 ;; esac
PROJECTS=("$@")
CONF="${TEAM_AUDIT_CONF:-$DOTFILES/script/team-audit.local.conf}"
if [ ${#PROJECTS[@]} -eq 0 ] && [ -f "$CONF" ]; then
  while IFS= read -r line; do
    case "$line" in ''|'#'*) continue ;; esac
    PROJECTS+=("${line/#\~/$HOME}")
  done < "$CONF"
fi
[ ${#PROJECTS[@]} -eq 0 ] && { echo "team-audit: pass project roots or list them in $CONF" >&2; exit 2; }
[ -d "$TEMPLATE" ] || { echo "team-audit: missing $TEMPLATE (set DOTFILES)" >&2; exit 2; }

findings=0
finding() { echo "FINDING $1: $2"; findings=$((findings + 1)); }

# Banned wording, as extended regexes. A line may opt out with "team-audit: allow".
BANNED=(
  '(fullstack-dev|qa-sdet|support-csm|sales|architect-pm|teammate)s? pushes (the|a|its) branch'
  '(release-manager|fullstack-dev|qa-sdet|support-csm|teammate)s? (merges (the |a |its |team )?PRs?|opens (the|a|its) PR)'
  'open a PR and merge it'
  'task_plan\.md'
  '(^|[^_[:alnum:]])progress\.md'
  'orca claude-teams'
  'gpt-6-luna'
  '--types (worker_done|escalation|decision_gate|question|heartbeat)(,(worker_done|escalation|decision_gate|question|heartbeat))*([^,_[:alnum:]]|$)'
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

SPEC_INTENT_SINCE="${SPEC_INTENT_SINCE:-2026-10-21}"
TEST_PLAN_SINCE="${TEST_PLAN_SINCE:-2026-10-22}"
for proj in "${PROJECTS[@]}"; do
  for s in "$proj"/docs/intent/*/spec.md; do
    [ -f "$s" ] && [ ! -f "$(dirname "$s")/intent.md" ] || continue
    added=$(git -C "$proj" log --diff-filter=A --format=%cs -- "${s#"$proj"/}" 2>/dev/null | tail -1)
    [ -n "$added" ] && [[ "$added" < "$SPEC_INTENT_SINCE" ]] && continue
    finding sdlc "$s: no intent.md beside it (intent before spec)"
  done
  for s in "$proj"/docs/intent/*/spec.md; do
    [ -f "$s" ] && ! grep -q '^## Test plan' "$s" || continue
    added=$(git -C "$proj" log --diff-filter=A --format=%cs -- "${s#"$proj"/}" 2>/dev/null | tail -1)
    [ -n "$added" ] && [[ "$added" < "$TEST_PLAN_SINCE" ]] && continue
    finding sdlc "$s: no ## Test plan section (owner rule 2026-10-21)"
  done
done

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
  [ -f "$DOTFILES/.agents/skills/orca-team/$h" ] || finding helpers "missing $DOTFILES/.agents/skills/orca-team/$h"
done

MP_STATE="$DOTFILES/.agents/skills/.mattpocock-upstream"
if [ ! -f "$MP_STATE" ]; then
  finding mp-upstream "missing $MP_STATE (run script/sync-mattpocock-skills.sh after recording the synced sha)"
else
  mp_sha=$(sed -n 's/^sha=//p' "$MP_STATE"); mp_skills=$(sed -n 's/^skills=//p' "$MP_STATE")
  latest=$(gh api repos/mattpocock/skills/commits/main --jq .sha 2>/dev/null) || latest=""
  if [ -z "$latest" ]; then
    echo "WARN mp-upstream: could not read the latest upstream sha (gh or network); skipped the upstream comparison"
  elif [ "$latest" != "$mp_sha" ]; then
    files=$(gh api "repos/mattpocock/skills/compare/$mp_sha...$latest" --jq '.files[].filename' 2>/dev/null) || files="?"
    if [ "$files" = "?" ]; then
      echo "WARN mp-upstream: could not compare $mp_sha with $latest; skipped"
    else
      changed=""
      for n in $mp_skills; do
        echo "$files" | grep -qE "^skills/[^/]+/$n/" && changed="$changed $n"
      done
      [ -n "$changed" ] && finding mp-upstream "${mp_sha:0:7} behind ${latest:0:7}:${changed}"
    fi
  fi
  for root in "$TEMPLATE" "${PROJECTS[@]}"; do
    for f in "$root"/.claude/agents/*.md; do
      [ -f "$f" ] || continue
      list=$(awk 'NR==1 && $0!="---"{exit} NR>1 && $0=="---"{exit} /^skills:/{print}' "$f" | sed -E 's/^skills: *\[?//; s/\] *$//; s/,/ /g')
      for n in $list; do
        case " $mp_skills " in *" $n "*) [ -f "$DOTFILES/.agents/skills/$n/SKILL.md" ] || finding mp-upstream "$f: skills: names $n, missing from $DOTFILES/.agents/skills" ;; esac
      done
    done
  done
fi

# ready-brief: open ready-for-agent issues must carry the AGENT-BRIEF fields in one text.
BRIEF_PY='
import json, re, sys
FIELDS = ["Acceptance criteria", "Requirement owner", "Done condition", "Deleted"]
def has(text, f):
    f = re.escape(f)
    return re.search(r"^\s*#+\s*\**" + f + r"\b|^\s*(?:[-*]\s*)?\**" + f + r"(?:\**\s*:|\s*:\**)", text, re.I | re.M)
for i in json.load(sys.stdin):
    texts = [i.get("body") or ""] + [c.get("body") or "" for c in i.get("comments") or []]
    if any(l.get("name") == "team-audit: allow" for l in i.get("labels") or []): continue
    if any("team-audit: allow" in t for t in texts): continue
    best = min(([f for f in FIELDS if not has(t, f)] for t in texts), key=len)
    if best: print("%s\t%s" % (i["number"], ", ".join(best)))
'
for proj in "${PROJECTS[@]}"; do
  [ -d "$proj" ] || continue
  url=$(git -C "$proj" remote get-url origin 2>/dev/null) || continue
  repo=$(echo "$url" | sed -nE 's#^(https://([^@/]+@)?|ssh://git@|git@)github\.com[:/]([^/]+/[^/]+)$#\3#p'); repo="${repo%.git}"
  [ -n "$repo" ] || continue
  if ! issues=$(gh issue list --repo "$repo" --label ready-for-agent --state open --limit 200 --json number,body,labels,comments 2>/dev/null); then
    echo "WARN ready-brief: could not list ready-for-agent issues for $repo (gh or network); skipped"
    continue
  fi
  if ! rows=$(echo "$issues" | python3 -c "$BRIEF_PY" 2>/dev/null); then
    echo "WARN ready-brief: could not read the issue list for $repo; skipped"
    continue
  fi
  while IFS=$'\t' read -r num missing; do
    [ -n "$num" ] || continue
    echo "FINDING ready-brief $repo#$num missing: $missing"; findings=$((findings + 1))
  done <<< "$rows"
done

if [ "$findings" -eq 0 ]; then echo "team-audit: clean"; exit 0; fi
echo "team-audit: $findings finding(s)"
exit 1
