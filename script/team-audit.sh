#!/usr/bin/env bash
# team-audit.sh: deterministic checks of the agent team files. The judgement part is the team-audit skill.
#
# Usage:
#   ~/dotfiles/script/team-audit.sh [<project-root> ...]   (default: one project root per line in script/team-audit.local.conf, untracked)
#   ~/dotfiles/script/team-audit.sh --report [<project-root> ...]
#   ~/dotfiles/script/team-audit.sh --log <finding> <evidence>
#   TEAM_AUDIT_RUN_METRICS=1 ~/dotfiles/script/team-audit.sh   (also prints script/team-audit-metrics.ts --repo <owner/name> per project)
#
# Six checks, each printed as "FINDING <check>: <detail>":
#   sync      agent-team.sh check passes for each project (a project that is DOTFILES itself is skipped)
#   budget    every role file (.claude/agents/*.md, project and template) is at most ROLE_WORD_BUDGET words (800)
#   wording   no banned wording in team files: implementation workers and release-manager
#             merge PRs, the phrase "open a PR and merge it",
#             task_plan.md or progress.md ledgers, the old orca claude-teams layout, the retired
#             gpt-6-luna model (400 since 2026-10-21), a coordinator wait whose --types omit status
#   skills    every SKILL.md has name and description frontmatter; the skill lock does not track a
#             locally customized skill (LOCAL_SKILLS, default orca-team); the orca-team helper scripts
#             exist; every role file `skills:` entry is a skill in dotfiles, the template, the project
#             or ORCA_SKILLS (Orca bundled, default "orchestration orca-cli")
#   labels    no open issue of a project (repo read from its origin remote) carries ready-for-agent
#             together with a CONFLICT_LABELS label (default: blocked needs-info needs-triage
#             ready-for-human wontfix). One gh issue list per project; a gh or network failure prints
#             "WARN labels" and is not a finding.
#   receipt   every non-merge commit touching role files (templates/agent-team/.claude/agents/ in
#             DOTFILES, .claude/agents/ in each project) carries an "Owner-approved:" trailer (owner
#             rule 2026-11-02). Only commits after the baseline count: ROLE_RECEIPT_BASE holds the shas
#             recorded at the last audit, space separated, and each repo uses the first one it contains.
#             A repo with none falls back to commits since 2026-11-03.
#
# --report runs the checks, then script/team-audit-metrics.ts per project (two gh calls each, stage
# times from the dispatch log TEAM_AUDIT_DISPATCHES, default ~/agent-state/team-dispatches.tsv) and
# prints three sections: problems with evidence (FINDING and WARN lines plus the observation log),
# proposals with a recommended option, and stage times (median, p75, max, samples, fully verified).
# --log appends or bumps a row of the observation log TEAM_AUDIT_LOG (default
# ~/agent-state/team-observations.tsv: date, finding, evidence, count, fix ticket, status) and
# prints "promote: open a fix ticket for <finding>" from count 2.
#
# Exit 0 when clean, 1 on any finding (also for --report), 2 on a usage error. Env: DOTFILES (default ~/dotfiles).
set -uo pipefail

DOTFILES="${DOTFILES:-$HOME/dotfiles}"
BUDGET="${ROLE_WORD_BUDGET:-800}"
LOCAL_SKILLS="${LOCAL_SKILLS:-orca-team}"
HELPERS="worker-panes.sh worker-pane.sh worker-pane-close.sh worker-pane-retry.sh worker-watch.sh role-colors.tsv"
TEMPLATE="$DOTFILES/templates/agent-team"
HERE=$(cd "$(dirname "$0")" && pwd)

LOG_FILE="${TEAM_AUDIT_LOG:-$HOME/agent-state/team-observations.tsv}"

if [ "${1:-}" = "--log" ]; then
  if [ $# -ne 3 ] || [ -z "${2:-}" ] || [ -z "${3:-}" ]; then
    echo "team-audit: usage: team-audit.sh --log <finding> <evidence>" >&2
    exit 2
  fi
  mkdir -p "$(dirname "$LOG_FILE")"
  python3 - "$LOG_FILE" "$2" "$3" "${TEAM_AUDIT_DATE:-$(date +%Y-%m-%d)}" <<'PY'
import os, sys

path, finding, evidence, today = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
rows = []
if os.path.exists(path):
    with open(path, "r", encoding="utf-8") as fh:
        for raw in fh:
            line = raw.rstrip("\r\n")
            if not line:
                continue
            parts = line.split("\t")
            while len(parts) < 6:
                parts.append("")
            rows.append(parts[:6])

bumped = 0
for row in rows:
    if row[0] == "date" and row[1] == "finding":
        continue
    if row[1] == finding:
        try:
            cnt = int(row[3]) + 1
        except ValueError:
            cnt = 2
        row[0] = today
        ev_items = [x.strip() for x in row[2].split(",") if x.strip()]
        if evidence not in ev_items:
            ev_items.append(evidence)
        row[2] = ", ".join(ev_items)
        row[3] = str(cnt)
        if not row[4]:
            row[4] = "-"
        if not row[5]:
            row[5] = "open"
        bumped = cnt
        break

if not bumped:
    rows.append([today, finding, evidence, "1", "-", "open"])
    bumped = 1

with open(path, "w", encoding="utf-8") as fh:
    for row in rows:
        fh.write("\t".join(row) + "\n")

if bumped >= 2:
    print(f"promote: open a fix ticket for {finding}")
PY
  exit $?
fi

report=0
case "${1:-}" in
  -h|--help) sed -n '2,39p' "$0"; exit 0 ;;
  --report) report=1; shift ;;
esac
case "${1:-}" in -*) echo "team-audit: unknown flag $1" >&2; exit 2 ;; esac
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

repo_of() { # <project root>: owner/name of its GitHub origin, or nothing
  local url repo
  url=$(git -C "$1" remote get-url origin 2>/dev/null) || return 0
  repo=$(echo "$url" | sed -nE 's#^(https://([^@/]+@)?|ssh://git@|git@)github\.com[:/]([^/]+/[^/]+)$#\3#p')
  echo "${repo%.git}"
}

if [ "$report" -eq 1 ]; then
  checks=$(bash "$0" "${PROJECTS[@]}" 2>&1); rc=$?
  [ "$rc" -le 1 ] || { echo "$checks" >&2; exit "$rc"; }
  mdir=$(mktemp -d); trap 'rm -rf "$mdir"' EXIT
  dispatches="${TEAM_AUDIT_DISPATCHES:-$HOME/agent-state/team-dispatches.tsv}"
  i=0
  for proj in "${PROJECTS[@]}"; do
    repo=$(repo_of "$proj"); [ -n "$repo" ] || continue
    i=$((i + 1)); echo "$repo" > "$mdir/$i.repo"
    if ! command -v bun >/dev/null 2>&1; then echo "bun unavailable" > "$mdir/$i.err"; continue; fi
    args=(--repo "$repo" --json); [ -f "$dispatches" ] && args+=(--dispatches "$dispatches")
    bun "$HERE/team-audit-metrics.ts" "${args[@]}" > "$mdir/$i.json" 2> "$mdir/$i.err" || true
  done
  printf '%s\n' "$checks" > "$mdir/checks.txt"
  python3 - "$LOG_FILE" "$mdir" <<'REPORT' || exit 2
import glob, json, os, sys

log_path, mdir = sys.argv[1], sys.argv[2]
lines = open(os.path.join(mdir, "checks.txt"), encoding="utf-8").read().splitlines()
found = [l[len("FINDING "):] for l in lines if l.startswith("FINDING ")]
gaps = [l[len("WARN "):] for l in lines if l.startswith("WARN ")]
obs = []
if os.path.isfile(log_path):
    for raw in open(log_path, encoding="utf-8"):
        parts = raw.rstrip("\r\n").split("\t")
        if len(parts) < 2 or parts[:2] == ["date", "finding"]:
            continue
        obs.append((parts + [""] * 6)[:6])

# Recommended option A, then option B, per check.
FIX = {
    "sync": ("run agent-team.sh sync on the project and commit the result", "edit the dotfiles source, then sync"),
    "budget": ("move area detail out of the role file into a docs page it points to", "raise ROLE_WORD_BUDGET with the owner's approval"),
    "wording": ("reword the line to the current rule", "mark the line team-audit: allow when it quotes the old rule on purpose"),
    "skills": ("fix the skill or role file named in the finding", "add the name to ORCA_SKILLS when Orca ships that skill"),
    "labels": ("remove ready-for-agent until the conflicting label is cleared", "remove the conflicting label when the issue is ready"),
    "receipt": ("ask the owner for an Owner-approved: trailer on the commit", "revert the role file change"),
}

print("## Problems with evidence")
for f in found:
    print(f"- {f}")
for g in gaps:
    print(f"- gap, not checked: {g}")
print("- gap, not checked: transcripts of hosts other than the coordinator (workflow-from-chats reads only this host)")
for d, finding, evidence, count, ticket, status in obs:
    print(f"- {finding} (logged {d}, count {count}, evidence {evidence}, ticket {ticket or '-'}, status {status or 'open'})")

print("\n## Proposals with a recommended option")
for f in found:
    a, b = FIX.get(f.split(":", 1)[0], ("fix the file named in the finding", "record why it is a false positive"))
    print(f"- {f}\n  Recommended: A, {a}. B, {b}.")
for d, finding, evidence, count, ticket, status in obs:
    if count.isdigit() and int(count) >= 2:
        print(f"- {finding}: Recommended: A, open a fix ticket and hand the class to /correct. B, keep observing.")
    else:
        print(f"- {finding}: Recommended: A, keep observing until the count reaches 2. B, open a fix ticket now.")
if not (found or obs):
    print("- none: Recommended: A, keep the current rules. B, none.")

print("\n## Stage times")
repos = sorted(glob.glob(os.path.join(mdir, "*.repo")), key=lambda p: int(os.path.basename(p).split(".")[0]))
if not repos:
    print("No project with a GitHub origin. Samples: 0, fully verified: 0")
for rp in repos:
    base = rp[: -len(".repo")]
    print(f"\n### {open(rp).read().strip()}")
    try:
        m = json.load(open(base + ".json"))
    except (OSError, ValueError):
        err = open(base + ".err").read().strip() if os.path.exists(base + ".err") else ""
        print(f"Metrics unavailable ({err.splitlines()[-1] if err else 'no output'}). Samples: unknown, fully verified: unknown")
        continue
    print(f"Samples: {m['stage_samples']}, fully verified: {m['stage_samples_verified']}")
    print("| stage | median | p75 | max | samples | verified |")
    print("| --- | --- | --- | --- | --- | --- |")
    for st in ("queue", "build", "merge"):
        print(f"| {st} | {m[f'median_stage_{st}_minutes']} | {m[f'p75_stage_{st}_minutes']} | {m[f'max_stage_{st}_minutes']}"
              f" | {m[f'median_stage_{st}_minutes_n']} | {m[f'stage_{st}_verified']} |")
    keys = ("median_ticket_start_to_merge_minutes", "first_pass_checks_fail_rate", "reopened_or_hotfix_rate",
            "p0_filed_this_month", "p1_filed_this_month")
    print("Delivery: " + ", ".join(f"{k}={m.get(k, 'unknown')}" for k in keys))
REPORT
  bases=""
  for d in "$DOTFILES" "${PROJECTS[@]}"; do
    sha=$(git -C "$d" rev-parse --short HEAD 2>/dev/null) || continue
    case " $bases " in *" $sha "*) ;; *) bases="$bases $sha" ;; esac
  done
  echo "ROLE_RECEIPT_BASE=\"${bases# }\""
  exit "$rc"
fi

findings=0
finding() { echo "FINDING $1: $2"; findings=$((findings + 1)); }

# Banned wording, as extended regexes. A line may opt out with "team-audit: allow".
BANNED=(
  '(fullstack-dev|qa-sdet|support-csm|sales|architect-pm|teammate)s? merges (the |a |its |team )?PRs?'
  'release-manager merges (the |a |its |team )?PRs?'
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
  # dotfiles is the template source, not a consumer: skip the sync check, keep the other checks
  [ "$(cd "$proj" 2>/dev/null && pwd -P)" = "$(cd "$DOTFILES" 2>/dev/null && pwd -P)" ] && continue
  # shellcheck disable=SC2097,SC2098
  out=$(DOTFILES="$DOTFILES" bash "$DOTFILES/script/agent-team.sh" check "$proj" 2>&1) \
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
    echo "$front" | grep -qE '^name: *[^ ]' || finding skills "$f: no name in frontmatter"
    echo "$front" | grep -qE '^description: *[^ ]' || finding skills "$f: no description in frontmatter"
  done
done

LOCK="$DOTFILES/.agents/.skill-lock.json"
if [ -f "$LOCK" ]; then
  for s in $LOCAL_SKILLS; do
    python3 -c 'import json,sys; sys.exit(0 if sys.argv[2] in json.load(open(sys.argv[1])).get("skills",{}) else 1)' "$LOCK" "$s" \
      && finding skills "$LOCK tracks $s, so npx skills update would overwrite it (remove the entry)"
  done
fi

for h in $HELPERS; do
  [ -f "$DOTFILES/.agents/skills/orca-team/$h" ] || finding skills "missing $DOTFILES/.agents/skills/orca-team/$h"
done

ORCA_SKILLS="${ORCA_SKILLS:-orchestration orca-cli}"
for root in "$TEMPLATE" "${PROJECTS[@]}"; do
  for f in "$root"/.claude/agents/*.md; do
    [ -f "$f" ] || continue
    list=$(awk 'NR==1 && $0!="---"{exit} NR>1 && $0=="---"{exit} /^skills:/{print}' "$f" | sed -E 's/^skills: *\[?//; s/\] *$//; s/,/ /g')
    for n in $list; do
      case " $ORCA_SKILLS " in *" $n "*) continue ;; esac
      for d in "$DOTFILES" "$TEMPLATE" "$root"; do [ -f "$d/.agents/skills/$n/SKILL.md" ] && continue 2; done
      finding skills "$f: skills: names $n, which is not a skill in dotfiles, the template or the project"
    done
  done
done

# receipt: commits touching role files carry the Owner-approved: trailer.
receipt_check() { # <repo root> <role path inside it>
  local top rows sha receipt subject base range=() b
  top=$(git -C "$1" rev-parse --show-toplevel 2>/dev/null) || return 0
  [ "$(cd "$top" && pwd -P)" = "$(cd "$1" && pwd -P)" ] || return 0
  for b in ${ROLE_RECEIPT_BASE:-}; do
    base=$(git -C "$1" rev-parse -q --verify "$b^{commit}" 2>/dev/null) && { range=("$base..HEAD"); break; }
  done
  [ ${#range[@]} -gt 0 ] || range=(--since="2026-11-03 00:00")
  rows=$(git -C "$1" log --no-merges "${range[@]}" \
    --format='%h%x1f%(trailers:key=Owner-approved,valueonly,separator=%x2C)%x1f%s' -- "$2" 2>/dev/null)
  while IFS=$'\x1f' read -r sha receipt subject; do
    [ -n "$sha" ] && [ -z "$receipt" ] && finding receipt "$1: $sha touches $2 without an Owner-approved: trailer ($subject)"
  done <<< "$rows"
}
receipt_check "$DOTFILES" templates/agent-team/.claude/agents
for proj in "${PROJECTS[@]}"; do [ -d "$proj" ] && receipt_check "$proj" .claude/agents; done

# labels: an open ready-for-agent issue must not also carry a label that says it is not ready.
CONFLICT_LABELS="${CONFLICT_LABELS:-blocked needs-info needs-triage ready-for-human wontfix}"
for proj in "${PROJECTS[@]}"; do
  [ -d "$proj" ] || continue
  repo=$(repo_of "$proj"); [ -n "$repo" ] || continue
  if ! rows=$(gh issue list --repo "$repo" --label ready-for-agent --state open --limit 500 --json number,labels 2>/dev/null \
      | python3 -c 'import json, sys; [print(i["number"], *[l["name"] for l in i["labels"]], sep="\t") for i in json.load(sys.stdin)]'); then
    echo "WARN labels: could not list ready-for-agent issues for $repo (gh or network); skipped"
    continue
  fi
  while IFS= read -r line; do
    num="${line%%$'\t'*}"; names=" ${line//$'\t'/ } "
    [ -n "$num" ] || continue
    hit=""
    for l in $CONFLICT_LABELS; do case "$names" in *" $l "*) hit="$hit $l" ;; esac; done
    [ -n "$hit" ] && finding labels "$repo#$num has ready-for-agent and$hit"
  done <<< "$rows"
done

if [ "${TEAM_AUDIT_RUN_METRICS:-0}" = "1" ]; then
  if ! command -v bun >/dev/null 2>&1; then
    echo "WARN metrics: bun unavailable; skipped"
  else
    for proj in "${PROJECTS[@]}"; do
      [ -d "$proj" ] || continue
      repo=$(repo_of "$proj"); [ -n "$repo" ] || continue
      echo "metrics $repo:"
      bun "$HERE/team-audit-metrics.ts" --repo "$repo" 2>&1 | sed 's/^/  /' \
        || echo "WARN metrics: failed for $repo"
    done
  fi
fi

if [ "$findings" -eq 0 ]; then echo "team-audit: clean"; exit 0; fi
echo "team-audit: $findings finding(s)"
exit 1
