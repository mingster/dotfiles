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

# An intent that the diff marks Accepted passes only when every commit in the PR range that
# touches that file carries a non-empty Owner-approved trailer (the owner accepted it in chat).
intent_acceptance_receipt() {
  local accepted f ancestor rows sha trailer seen
  accepted=$(awk '/^\+\+\+ /{intent = ($2 ~ /^b\/docs\/intent\//); path = substr($2, 3)} intent && /^\+Status:.*Accepted/ && !(path in s){s[path]=1; print path}' <<<"$diff")
  [ -n "$accepted" ] || return 0
  local msg="PR accepts an intent under docs/intent/ without an Owner-approved: trailer on every commit that touches it; the owner adds the trailer once they have accepted it"
  git cat-file -e "$head^{commit}" 2>/dev/null || git fetch origin "$head" >&2 || refuse "$msg"
  ancestor=$(git merge-base "$(field .baseRefOid)" "$head" 2>/dev/null) || refuse "$msg"
  while IFS= read -r f; do
    rows=$(git log --format='%H%x1f%(trailers:key=Owner-approved,valueonly)' "$ancestor..$head" -- "$f" 2>/dev/null) || refuse "$msg"
    seen=0
    while IFS=$'\x1f' read -r sha trailer; do
      [ -n "$sha" ] || continue
      seen=1
      [ -n "$trailer" ] || refuse "$msg"
    done <<<"$rows"
    [ "$seen" = 1 ] || refuse "$msg"
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
  local ancestor rows sha trailer
  git cat-file -e "$head^{commit}" 2>/dev/null || git fetch origin "$head" >&2 || die "cannot read head $head for owner receipt"
  ancestor=$(git merge-base "$(field .baseRefOid)" "$head") || die "cannot find merge base for owner receipt"
  rows=$(git log --format='%H%x1f%(trailers:key=Owner-approved,valueonly)' "$ancestor..$head" -- "${owner_receipt_paths[@]}" 2>/dev/null) \
    || die "cannot list commits for owner receipt"
  while IFS=$'\x1f' read -r sha trailer; do
    [ -n "$sha" ] || continue
    [ -n "$trailer" ] || refuse "commit ${sha:0:12} touches owner-gated paths without Owner-approved trailer"
  done <<<"$rows"
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
