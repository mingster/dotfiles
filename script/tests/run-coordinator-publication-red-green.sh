#!/usr/bin/env bash
# Sequential isolated RED (pinned historical helper tree) then GREEN (snapshotted worktree helper); every run through heavy-gate.
set -euo pipefail

OLD_SHA=${1:-${COORDINATOR_PUBLICATION_OLD_SHA:-69f03f4a4e73f0e7ed1d1590f9e9cbae9f45beb8}}
here=$(cd "$(dirname "$0")/.." && pwd)
repo_root=$(cd "$here/.." && pwd)
gate=${HEAVY_GATE:-$HOME/dotfiles/script/heavy-gate.sh}
test_sh=${COORDINATOR_PUBLICATION_RED_GREEN_TEST:-$here/tests/coordinator-publication.test.sh}
proof_root=${COORDINATOR_PUBLICATION_RED_GREEN_LOG_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/cp-rg-proof.XXXXXX")}
mkdir -p "$proof_root"

file_digest() {
  shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'
}

summary_failed_count() {
  local log=$1 line passed failed
  line=$(grep '^passed ' "$log" 2>/dev/null | tail -1 || true)
  [ -n "$line" ] || return 1
  passed=${line#passed }
  passed=${passed%%, failed *}
  failed=${line##*, failed }
  [[ "$failed" =~ ^[0-9]+$ ]] || return 1
  printf '%s' "$failed"
}

summary_passed_count() {
  local log=$1 line passed
  line=$(grep '^passed ' "$log" 2>/dev/null | tail -1 || true)
  [ -n "$line" ] || return 1
  passed=${line#passed }
  passed=${passed%%, failed *}
  [[ "$passed" =~ ^[0-9]+$ ]] || return 1
  printf '%s' "$passed"
}

validate_fixture_log() {
  local label=$1 log=$2 pub=$3 expect_fail=$4 ec=$5
  if ! grep -Fq "coordinator-publication-fixture-helper=$pub" "$log"; then
    echo "run-coordinator-publication-red-green: $label missing selected helper marker" >&2
    return 1
  fi
  if ! grep -q '^passed ' "$log"; then
    echo "run-coordinator-publication-red-green: $label missing numeric summary" >&2
    return 1
  fi
  local failed passed
  failed=$(summary_failed_count "$log") || {
    echo "run-coordinator-publication-red-green: $label summary failed count unreadable" >&2
    return 1
  }
  passed=$(summary_passed_count "$log") || {
    echo "run-coordinator-publication-red-green: $label summary passed count unreadable" >&2
    return 1
  }
  if [ "$expect_fail" = 1 ]; then
    if [ "$ec" -ne 1 ]; then
      echo "run-coordinator-publication-red-green: $label expected behavioral failure exit 1, got $ec" >&2
      return 1
    fi
    if [ "$failed" -eq 0 ]; then
      echo "run-coordinator-publication-red-green: $label expected failed assertions > 0" >&2
      return 1
    fi
  else
    if [ "$ec" -ne 0 ]; then
      echo "run-coordinator-publication-red-green: $label expected exit 0" >&2
      return 1
    fi
    if [ "$failed" -ne 0 ]; then
      echo "run-coordinator-publication-red-green: $label expected failed 0, got $failed" >&2
      return 1
    fi
  fi
  echo "$label summary: passed $passed, failed $failed exit=$ec"
  return 0
}

PROOF_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/cp-rg-snap.XXXXXX")
trap 'rm -rf "$PROOF_ROOT"' EXIT

RED_ROOT="$PROOF_ROOT/red"
GREEN_ROOT="$PROOF_ROOT/green"
mkdir -p "$RED_ROOT/lib" "$GREEN_ROOT/lib"

git -C "$repo_root" show "${OLD_SHA}:script/lib/validate-publication-body.sh" > "$RED_ROOT/lib/validate-publication-body.sh"
git -C "$repo_root" show "${OLD_SHA}:script/coordinator-publication.sh" > "$RED_ROOT/coordinator-publication.sh"
chmod +x "$RED_ROOT/coordinator-publication.sh"
red_pub="$RED_ROOT/coordinator-publication.sh"

GREEN_SHA=$(git -C "$repo_root" rev-parse HEAD)
cp "$here/coordinator-publication.sh" "$GREEN_ROOT/coordinator-publication.sh"
cp "$here/lib/validate-publication-body.sh" "$GREEN_ROOT/lib/validate-publication-body.sh"
chmod +x "$GREEN_ROOT/coordinator-publication.sh"
green_pub="$GREEN_ROOT/coordinator-publication.sh"

red_log="$proof_root/red-$(date -u +%Y%m%dT%H%M%SZ).log"
green_log="$proof_root/green-$(date -u +%Y%m%dT%H%M%SZ).log"
meta_log="$proof_root/meta-$(date -u +%Y%m%dT%H%M%SZ).log"
{
  echo "run-coordinator-publication-red-green proof_root=$proof_root"
  echo "OLD_SHA=$OLD_SHA OLD_helper_digest=$(file_digest "$red_pub")"
  echo "GREEN_SHA=$GREEN_SHA GREEN_helper_digest=$(file_digest "$green_pub")"
  echo "GREEN_validator_digest=$(file_digest "$GREEN_ROOT/lib/validate-publication-body.sh")"
  echo "red_log=$red_log"
  echo "green_log=$green_log"
} | tee "$meta_log"

run_fixture() {
  local label=$1 pub=$2 log=$3 ec phase
  case "$label" in
    RED*) phase=RED ;;
    GREEN*) phase=GREEN ;;
    *) phase=UNKNOWN ;;
  esac
  set +e
  "$gate" --weight 1 -- env GIT_ALLOW_PROTOCOL=file \
    COORDINATOR_PUBLICATION_RED_GREEN_PHASE="$phase" \
    COORDINATOR_PUBLICATION_HELPER="$pub" bash "$test_sh" >"$log" 2>&1
  ec=$?
  echo "=== $label (exit=$ec) log=$log ===" | tee -a "$meta_log"
  { grep -E '^(passed|FAIL |ok   )' "$log" | tail -25; } 2>/dev/null | tee -a "$meta_log" || true
  { tail -3 "$log"; } 2>/dev/null | tee -a "$meta_log" || true
  return "$ec"
}

set +e
run_fixture "RED old=$OLD_SHA" "$red_pub" "$red_log"
red_ec=$?
run_fixture "GREEN snap=$GREEN_SHA" "$green_pub" "$green_log"
green_ec=$?
set -e

if ! validate_fixture_log "RED" "$red_log" "$red_pub" 1 "$red_ec"; then
  exit 1
fi
if ! validate_fixture_log "GREEN" "$green_log" "$green_pub" 0 "$green_ec"; then
  exit 1
fi

echo "run-coordinator-publication-red-green: OK meta=$meta_log"
