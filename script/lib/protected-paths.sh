# shellcheck shell=bash disable=SC2154
# Shared protected-path, Owner-approved trailer, and Countersign checks for lead-merge.sh and ship.sh.
# Expects caller to provide: $files (JSON array of filenames), $diff (PR diff text), $info (PR JSON with .comments, .baseRefOid),
# $head (40-hex SHA), field(), refuse(), die(), and verdict_carry().

check_owner_only_paths() {
  local f
  while IFS= read -r f; do
    case "$f" in
      .claude/hooks/*|.claude/settings.json|bin/owner-approve.sh|*.rules)
        refuse "PR touches $f, which waits for the owner through Elon" ;;
    esac
  done < <(jq -r '.[]' <<<"$files")
  if awk '/^\+\+\+ /{intent = ($2 ~ /^b\/docs\/intent\//)} intent && /^\+Status:.*Accepted/{found=1} END{exit !found}' <<<"$diff"; then
    refuse "PR accepts an intent under docs/intent/, which waits for the owner through Elon"
  fi
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
      .agents/head-checks.conf|*/.agents/head-checks.conf|script/lead-merge.sh|*/script/lead-merge.sh)
        gate_lines=$(awk -v path="$f" '/^\+\+\+ / {active=($0 == "+++ b/" path)} active && /^[+-]/ && !/^\+\+\+ / && !/^--- / {print path ":" $0}' <<<"$diff")
        triggers="${triggers}${triggers:+$'\n'}${gate_lines:-gate definition changed: $f}" ;;
    esac
  done < <(jq -r '.[]' <<<"$files")
  if [ -n "$triggers" ]; then
    if [ "${PROTECTED_PATHS_QUIET_TRIGGERS:-0}" != 1 ]; then
      echo "lead-merge: countersign triggers:" >&2
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
