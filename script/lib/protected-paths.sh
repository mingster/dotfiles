# shellcheck shell=bash disable=SC2154
# Shared protected-path, Owner-approved trailer, and Countersign checks for ship.sh.
# Expects caller to provide: $files (JSON array of filenames), $diff (PR diff text), $info (PR JSON with .comments, .baseRefOid),
# $head (40-hex SHA), field(), refuse(), die(), and verdict_carry().

owner_only_path() { # <path>
  case "$1" in
    .claude/hooks/*|.claude/settings.json|bin/owner-approve.sh|*.rules|templates/agent-team/.claude/hooks/*|templates/agent-team/.claude/settings.json) return 0 ;;
  esac
  return 1
}

# Pre go-live waiver date: config key go_live_date (ship.config.example.json merged with ship.local.json),
# else $SHIP_GO_LIVE_DATE, else 2026-11-30. Today is read in Asia/Taipei; $SHIP_TODAY overrides it for tests.
go_live_date() {
  local dir=${ship_dir:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)} d=""
  if [ -f "$dir/ship.config.example.json" ]; then
    d=$(python3 "$dir/apply-local-overlay.py" "$dir/ship.config.example.json" "$dir/ship.local.json" 2>/dev/null \
      | jq -r '.go_live_date // empty' 2>/dev/null) || d=""
  fi
  printf '%s\n' "${d:-${SHIP_GO_LIVE_DATE:-2026-11-30}}"
}

# The newest unedited Verdict PASS with a recorded agent and model must come from another model family than the Builder line.
# The same-family-different-model tag does not count here.
waiver_families_differ() {
  local dir=${ship_dir:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)} line v_agent v_model b_agent b_model vf bf
  line=$(jq -r '[.comments[]? | select((.includesCreatedEdit // false | not) and (.isMinimized // false | not)) | (.body // "" | split("\n")[0])
      | select(test("^Verdict: (PASS\\+NOTES|PASS) head=[0-9a-f]{40} verifier=[a-zA-Z0-9_-]+ author=[a-zA-Z0-9_-]+ agent=[A-Za-z0-9._-]+ model=[A-Za-z0-9._:-]+$"))] | last // empty' <<<"$info")
  [[ "$line" =~ agent=([A-Za-z0-9._-]+)\ model=([A-Za-z0-9._:-]+)$ ]] || return 1
  v_agent=${BASH_REMATCH[1]} v_model=${BASH_REMATCH[2]}
  line=$(grep -E '^Builder: agent=[A-Za-z0-9._-]+ model=[A-Za-z0-9._:-]+[[:space:]]*$' <<<"$(jq -r '.body // ""' <<<"$info")" | tail -n 1) || true
  [[ "$line" =~ ^Builder:\ agent=([A-Za-z0-9._-]+)\ model=([A-Za-z0-9._:-]+) ]] || return 1
  b_agent=${BASH_REMATCH[1]} b_model=${BASH_REMATCH[2]}
  vf=$(python3 "$dir/usage-gate.py" family --agent "$v_agent" --model "$v_model" 2>/dev/null) || return 1
  bf=$(python3 "$dir/usage-gate.py" family --agent "$b_agent" --model "$b_model" 2>/dev/null) || return 1
  [ -n "$vf" ] && [ "$vf" != unknown ] && [ -n "$bf" ] && [ "$vf" != "$bf" ]
}

# A cold Review: PASS (newest Review at the head) and a Verdict PASS both name the head.
waiver_review_and_verdict() {
  jq -e --arg h "$head" '
    [.comments[]? | select((.includesCreatedEdit // false | not) and (.isMinimized // false | not)) | (.body // "" | split("\n")[0])] as $l
    | ($l | map(select(test("^Review: (PASS|FAIL) head=" + $h + "( main=[0-9a-f]{40})?($| )")) | capture("^Review: (?<r>PASS|FAIL)").r) | last) == "PASS"
      and ($l | any(.[]; test("^Verdict: (PASS|PASS\\+NOTES) head=" + $h + " ")))' <<<"$info" >/dev/null
}

# Before go_live_date an owner-only path passes when Review PASS and Verdict PASS cover the head, the verifier is
# another model family, and every commit touching these paths has a non-empty Owner-approved value.
owner_waiver_applies() { # <path>...
  local date today base_sha ancestor
  date=$(go_live_date)
  today=${SHIP_TODAY:-$(TZ=Asia/Taipei date +%F)}
  [[ "$date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || return 1
  [[ "$today" < "$date" ]] || return 1
  waiver_review_and_verdict || return 1
  waiver_families_differ || return 1
  base_sha=$(field .baseRefOid)
  ensure_commit_in_store "$head" && ensure_commit_in_store "$base_sha" || return 1
  ancestor=$(git merge-base "$base_sha" "$head" 2>/dev/null) || return 1
  load_owner_receipts owner "$ancestor..$head" "$@" || return 1
  { [ "$owner_receipt_count" -gt 0 ] && [ -z "$owner_receipt_missing" ]; } || return 1
  echo "ship: owner-only path waived until $date (pre go-live rule)" >&2
}

check_owner_only_paths() {
  local f owner_paths=()
  while IFS= read -r f; do
    if owner_only_path "$f"; then
      [ "$f" != bin/owner-approve.sh ] || refuse "PR touches $f, which waits for the owner through Elon"
      owner_paths+=("$f")
    fi
  done < <(jq -r '.[]' <<<"$files")
  if [ "${#owner_paths[@]}" -gt 0 ] && ! owner_waiver_applies "${owner_paths[@]}"; then
    refuse "PR touches ${owner_paths[0]}, which waits for the owner through Elon"
  fi
  intent_acceptance_receipt
}

# True for a path that waits for the owner or an owner receipt: hooks, settings, rules, role files, intents.
protected_path() { # <path>
  case "$1" in
    .claude/hooks/*|*/.claude/hooks/*|.claude/settings.json|bin/owner-approve.sh|*.rules|docs/intent/*) return 0 ;;
  esac
  text_lane_role_path "$1"
}

# %(trailers) puts each value on its own line, so %x1e ends the commit and keeps those lines together.
# owner_receipt_missing is the first sha with no Owner-approved value that counts, and owner_receipt_reason
# says why when a cited intent failed. In owner mode a value in the intent form never counts (hooks,
# settings, rules and intent acceptance keep the owner's own trailer). In intent mode it counts only when
# the cited intent covers the commit's files (intent_receipt_covers); a failing one refuses the commit.
load_owner_receipts() { # <owner|intent> <rev-range> <path>...
  local mode=$1 range=$2 raw record sha values v approved why
  shift 2
  owner_receipt_count=0
  owner_receipt_missing=""
  owner_receipt_reason=""
  raw=$(git log --format='%H%x1f%(trailers:key=Owner-approved,valueonly)%x1e' "$range" -- "$@" 2>/dev/null) || return 1
  while IFS= read -r -d $'\x1e' record || [ -n "$record" ]; do
    sha=${record%%$'\x1f'*}
    sha=${sha//[[:space:]]/}
    [ -n "$sha" ] || continue
    values=${record#*$'\x1f'}
    owner_receipt_count=$((owner_receipt_count + 1))
    approved=false why=""
    while IFS= read -r v; do
      v=$(printf '%s' "$v" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
      [ -n "$v" ] || continue
      if [[ "$v" =~ $intent_trailer_re ]]; then
        [ "$mode" = intent ] || continue
        if why=$(intent_receipt_covers "$sha" "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" "$@"); then
          approved=true
        else
          break
        fi
      else
        approved=true
      fi
    done <<<"$values"
    [ -z "$why" ] || approved=false
    if [ "$approved" = false ] && [ -z "$owner_receipt_missing" ]; then
      owner_receipt_missing=$sha
      owner_receipt_reason=$why
    fi
  done <<<"$raw"
}

# Owner-approved: intent <owner/repo>#<pr> accepted <YYYY-MM-DD> cites the merged PR that added an accepted intent.md.
intent_trailer_re='^intent ([A-Za-z0-9._-]+/[A-Za-z0-9._-]+)#([0-9]+) accepted ([0-9]{4}-[0-9]{2}-[0-9]{2})$'

# The cited repo's default branch, never this PR's head, so a PR cannot widen its own Owner steps.
cited_repo_file() { # <owner/repo> <path>
  local out
  out=$(gh api -H "Accept: application/vnd.github.raw+json" "repos/$1/contents/$2" 2>/dev/null) || return 1
  printf '%s\n' "$out"
}

# Passes when the cited PR is merged, its intent.md says Accepted <date>, and every gated file the
# commit touches is a backticked path under "## Owner steps" in the spec.md beside that intent.
# Otherwise prints the reason and fails.
intent_receipt_covers() { # <sha> <owner/repo> <pr> <date> <path>...
  local sha=$1 r=$2 n=$3 d=$4 pr_json intent spec steps f
  shift 4
  pr_json=$(gh pr view "$n" --repo "$r" --json state,files 2>/dev/null) || { echo "cannot read $r#$n"; return 1; }
  [ "$(jq -r '.state // empty' <<<"$pr_json")" = MERGED ] || { echo "$r#$n is not merged"; return 1; }
  intent=$(jq -r '[.files[]?.path | select(test("(^|/)intent\\.md$"))][0] // empty' <<<"$pr_json")
  [ -n "$intent" ] || { echo "$r#$n adds no intent.md"; return 1; }
  grep -Eq "^Status:.*Accepted ${d}([^0-9]|$)" <<<"$(cited_repo_file "$r" "$intent")" \
    || { echo "$intent in $r is not Accepted $d"; return 1; }
  spec=${intent%intent.md}spec.md
  # shellcheck disable=SC2016 # the backticks are literal Markdown
  steps=$(cited_repo_file "$r" "$spec" | awk '/^## /{on=($0 ~ /^## Owner steps[[:space:]]*$/); next} on' | grep -o '`[^`]*`' | tr -d '`') || true
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    grep -Fxq -- "$f" <<<"$steps" || { echo "$f is not listed under Owner steps in $spec of $r"; return 1; }
  done < <(git diff-tree --no-commit-id --name-only -r --root "$sha" -- "$@")
}

ensure_commit_in_store() { # <sha>
  local sha=$1
  [ -n "$sha" ] || return 1
  git cat-file -e "$sha^{commit}" 2>/dev/null && return 0
  git fetch origin "$sha" >&2 2>/dev/null && git cat-file -e "$sha^{commit}" 2>/dev/null && return 0
  if [ -n "${pr:-}" ]; then
    git fetch origin "pull/$pr/head" >&2 2>/dev/null && git cat-file -e "$sha^{commit}" 2>/dev/null && return 0
  fi
  git fetch origin main >&2 2>/dev/null && git cat-file -e "$sha^{commit}" 2>/dev/null && return 0
  return 1
}

# An intent that the diff marks Accepted passes only when every commit in the PR range that
# touches that file carries an Owner-approved value with a non-whitespace character.
intent_acceptance_receipt() {
  local accepted f ancestor base_sha
  accepted=$(awk '/^\+\+\+ /{intent = ($2 ~ /^b\/docs\/intent\//); path = substr($2, 3)} intent && /^\+Status:.*Accepted/ && !(path in s){s[path]=1; print path}' <<<"$diff")
  [ -n "$accepted" ] || return 0
  local msg="PR accepts an intent under docs/intent/ without an Owner-approved: trailer on every commit that touches it; the owner adds the trailer once they have accepted it"
  base_sha=$(field .baseRefOid)
  ensure_commit_in_store "$head" || die "cannot read head $head for intent acceptance receipt"
  ensure_commit_in_store "$base_sha" || die "cannot read base $base_sha for intent acceptance receipt"
  ancestor=$(git merge-base "$base_sha" "$head" 2>/dev/null) || die "cannot find merge base for intent acceptance receipt"
  while IFS= read -r f; do
    load_owner_receipts owner "$ancestor..$head" "$f" || die "cannot list commits for intent acceptance receipt"
    [ "$owner_receipt_count" -gt 0 ] || refuse "$msg"
    [ -z "$owner_receipt_missing" ] || refuse "$msg"
  done <<<"$accepted"
}

text_lane_role_path() { # <path>
  case "$1" in
    docs/agents/elon-dispatch.md|docs/agents/team.md) return 0 ;;
  esac
  [[ "$1" == */.claude/agents/* || "$1" == .claude/agents/* ]] && return 0
  case "${1##*/}" in
    AGENTS.md|model-routing.md) return 0 ;;
  esac
  return 1
}

collect_owner_receipt_paths() {
  local f
  owner_receipt_paths=()
  while IFS= read -r f; do
    if text_lane_role_path "$f"; then owner_receipt_paths+=("$f"); fi
  done < <(jq -r '.[]' <<<"$files")
}

text_lane_owner_receipt() {
  [ "${#owner_receipt_paths[@]}" -gt 0 ] || return 0
  local ancestor base_sha
  base_sha=$(field .baseRefOid)
  ensure_commit_in_store "$head" || die "cannot read head $head for owner receipt"
  ensure_commit_in_store "$base_sha" || die "cannot read base $base_sha for owner receipt"
  ancestor=$(git merge-base "$base_sha" "$head") || die "cannot find merge base for owner receipt"
  load_owner_receipts intent "$ancestor..$head" "${owner_receipt_paths[@]}" \
    || die "cannot list commits for owner receipt"
  [ -z "$owner_receipt_reason" ] || refuse "commit ${owner_receipt_missing:0:12} cites an intent that does not cover it: $owner_receipt_reason"
  [ -z "$owner_receipt_missing" ] || refuse "commit ${owner_receipt_missing:0:12} touches owner-gated paths without Owner-approved trailer"
}

countersigned() { # <head>
  jq -e --arg prefix "Countersign: Elon head=$1 reason=" \
    'any(.comments[].body; startswith($prefix) and (.[($prefix|length):] | test("[^[:space:]]") and (startswith("supersedes ") | not)))' <<<"$info" >/dev/null
}

check_countersign_gate() {
  local f gate_lines triggers candidate_head countersign_ok
  triggers=$(awk '/^\+[^+]/ && /\.skip\(|\.only\(|test\.todo([^A-Za-z0-9_]|$)|(^|[^A-Za-z0-9_.])xit\(|eslint-disable|biome-ignore|@ts-ignore|@ts-expect-error/ {print}' <<<"$diff")
  while IFS= read -r f; do
    case "$f" in
      .agents/head-checks.conf|*/.agents/head-checks.conf|script/ship.sh|*/script/ship.sh)
        gate_lines=$(awk -v path="$f" '/^\+\+\+ / {active=($0 == "+++ b/" path)} active && /^[+-]/ && !/^\+\+\+ / && !/^--- / {print path ":" $0}' <<<"$diff")
        triggers="${triggers}${triggers:+$'\n'}${gate_lines:-gate definition changed: $f}" ;;
    esac
  done < <(jq -r '.[]' <<<"$files")
  if [ -n "$triggers" ]; then
    if [ "${PROTECTED_PATHS_QUIET_TRIGGERS:-0}" != 1 ]; then
      echo "ship: countersign triggers:" >&2
      printf '%s\n' "$triggers" >&2
    fi
    if ! countersigned "$head"; then
      countersign_ok=false
      while IFS= read -r candidate_head; do
        [ "$candidate_head" != "$head" ] || continue
        [ "${main_fetched:-false}" = true ] || { git fetch origin main >&2 || die "cannot fetch main to carry a countersign"; main_fetched=true; }
        if countersigned "$candidate_head" && verdict_carry "$candidate_head" "$head"; then countersign_ok=true; break; fi
      done < <(jq -r '.comments[].body | split("\n")[0] | capture("^Countersign: Elon head=(?<h>[0-9a-f]{40}) reason=").h?' <<<"$info" | awk '!seen[$0]++')
      [ "$countersign_ok" = true ] || refuse "missing Countersign: Elon for current head or clean merge of main"
    fi
  fi
}

check_protected_paths() {
  check_owner_only_paths
  collect_owner_receipt_paths
  text_lane_owner_receipt
  check_countersign_gate
}
