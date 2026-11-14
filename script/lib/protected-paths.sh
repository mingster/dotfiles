# shellcheck shell=bash disable=SC2154
# Shared protected-path, Owner-approved trailer, and Countersign checks for ship.sh.
# Expects caller to provide: $files (JSON array of filenames), $diff (PR diff text), $info (PR JSON with .comments, .baseRefOid),
# $head (40-hex SHA), field(), refuse(), die(), and verdict_carry().

check_owner_only_paths() {
  local f
  while IFS= read -r f; do
    case "$f" in
      .claude/hooks/*|.claude/settings.json|bin/owner-approve.sh|*.rules|templates/agent-team/.claude/hooks/*|templates/agent-team/.claude/settings.json)
        refuse "PR touches $f, which waits for the owner through Elon" ;;
    esac
  done < <(jq -r '.[]' <<<"$files")
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
# owner_receipt_missing is the first sha with no non-whitespace Owner-approved value.
# It stays empty when every listed commit has a non-whitespace value.
load_owner_receipts() { # <rev-range> <path>...
  local range=$1 raw record sha values
  shift
  owner_receipt_count=0
  owner_receipt_missing=""
  raw=$(git log --format='%H%x1f%(trailers:key=Owner-approved,valueonly)%x1e' "$range" -- "$@" 2>/dev/null) || return 1
  while IFS= read -r -d $'\x1e' record || [ -n "$record" ]; do
    record=${record//$'\n'/}
    [ -n "$record" ] || continue
    sha=${record%%$'\x1f'*}
    values=${record#*$'\x1f'}
    [ -n "$sha" ] || continue
    owner_receipt_count=$((owner_receipt_count + 1))
    values=${values//[[:space:]]/}
    if [ -z "$values" ] && [ -z "$owner_receipt_missing" ]; then
      owner_receipt_missing=$sha
    fi
  done <<<"$raw"
}

# An intent that the diff marks Accepted passes only when every commit in the PR range that
# touches that file carries an Owner-approved value with a non-whitespace character.
intent_acceptance_receipt() {
  local accepted f ancestor
  accepted=$(awk '/^\+\+\+ /{intent = ($2 ~ /^b\/docs\/intent\//); path = substr($2, 3)} intent && /^\+Status:.*Accepted/ && !(path in s){s[path]=1; print path}' <<<"$diff")
  [ -n "$accepted" ] || return 0
  local msg="PR accepts an intent under docs/intent/ without an Owner-approved: trailer on every commit that touches it; the owner adds the trailer once they have accepted it"
  git cat-file -e "$head^{commit}" 2>/dev/null || git fetch origin "$head" >&2 || refuse "$msg"
  ancestor=$(git merge-base "$(field .baseRefOid)" "$head" 2>/dev/null) || refuse "$msg"
  while IFS= read -r f; do
    load_owner_receipts "$ancestor..$head" "$f" || refuse "$msg"
    [ "$owner_receipt_count" -gt 0 ] || refuse "$msg"
    [ -z "$owner_receipt_missing" ] || refuse "$msg"
  done <<<"$accepted"
}

text_lane_role_path() { # <path>
  case "$1" in
    docs/agents/elon-dispatch.md|docs/agents/team.md) return 0 ;;
  esac
  [[ "$1" == */.claude/agents/* || "$1" == .claude/agents/* ]] && return 0
  [[ "$1" == *AGENTS.md ]] && return 0
  [[ "$1" == *model-routing.md ]] && return 0
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
  local ancestor
  git cat-file -e "$head^{commit}" 2>/dev/null || git fetch origin "$head" >&2 || die "cannot read head $head for owner receipt"
  ancestor=$(git merge-base "$(field .baseRefOid)" "$head") || die "cannot find merge base for owner receipt"
  load_owner_receipts "$ancestor..$head" "${owner_receipt_paths[@]}" \
    || die "cannot list commits for owner receipt"
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
