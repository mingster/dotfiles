#!/usr/bin/env bash
# Phase-aware contract tests for run-coordinator-publication-red-green.sh (stub gate only; no inner heavy-gate/fixture).
set -u
export GIT_ALLOW_PROTOCOL=file
here=$(cd "$(dirname "$0")/.." && pwd)
runner="$here/tests/run-coordinator-publication-red-green.sh"
pass=0 fail=0

ok() { echo "ok   $1"; pass=$((pass+1)); }
bad() { echo "FAIL $1"; fail=$((fail+1)); }

CONTRACT_DIR=$(mktemp -d "${TMPDIR:-/tmp}/cp-rg-contract.XXXXXX")
trap 'rm -rf "$CONTRACT_DIR"' EXIT

write_stub_test() {
  local path=$1 body=$2
  cat > "$path" <<'EOS'
#!/usr/bin/env bash
EOS
  cat >> "$path" <<EOS
$body
EOS
  chmod +x "$path"
}

cat > "$CONTRACT_DIR/stub-gate.sh" <<'EOS'
#!/usr/bin/env bash
shift 3
exec "$@"
EOS
chmod +x "$CONTRACT_DIR/stub-gate.sh"

cat > "$CONTRACT_DIR/fail-gate.sh" <<'EOS'
#!/usr/bin/env bash
shift 3
exit 1
EOS
chmod +x "$CONTRACT_DIR/fail-gate.sh"

write_stub_test "$CONTRACT_DIR/empty.test.sh" 'exit 1'

stub_common='echo "coordinator-publication-fixture-helper=${COORDINATOR_PUBLICATION_HELPER:-missing}"'

write_stub_test "$CONTRACT_DIR/red1-green0.test.sh" \
  "$stub_common
case \${COORDINATOR_PUBLICATION_RED_GREEN_PHASE:-} in
  RED) echo \"passed 1, failed 1\"; exit 1 ;;
  GREEN) echo \"passed 2, failed 0\"; exit 0 ;;
  *) echo \"passed 0, failed 1\"; exit 2 ;;
esac"

write_stub_test "$CONTRACT_DIR/marker-only.test.sh" \
  "$stub_common
exit 1"

write_stub_test "$CONTRACT_DIR/zero-fail.test.sh" \
  "$stub_common
echo \"passed 3, failed 0\"
exit 1"

write_stub_test "$CONTRACT_DIR/tooling-exit2.test.sh" \
  "$stub_common
echo \"passed 1, failed 1\"
exit 2"

write_stub_test "$CONTRACT_DIR/green-fail.test.sh" \
  "$stub_common
case \${COORDINATOR_PUBLICATION_RED_GREEN_PHASE:-} in
  RED) echo \"passed 0, failed 2\"; exit 1 ;;
  GREEN) echo \"passed 1, failed 1\"; exit 1 ;;
  *) echo \"passed 0, failed 1\"; exit 2 ;;
esac"

run_expect_fail_green_phase() {
  local name=$1
  shift
  set +e
  out=$("$@" 2>&1)
  ec=$?
  set -e
  if [ "$ec" -eq 0 ] || [[ "$out" == *"run-coordinator-publication-red-green: OK"* ]]; then
    bad "$name should refuse overall (ec=$ec)"
    return
  fi
  if [[ "$out" != *"=== GREEN"* ]]; then
    bad "$name should reach GREEN phase before refusing (missing GREEN visit)"
    return
  fi
  if [[ "$out" != *"GREEN expected failed 0"* ]] && [[ "$out" != *"GREEN expected exit 0"* ]]; then
    bad "$name should report GREEN-specific validation failure"
    return
  fi
  ok "$name refuses overall after GREEN phase"
}

run_expect_fail() {
  local name=$1
  shift
  set +e
  out=$("$@" 2>&1)
  ec=$?
  set -e
  if [ "$ec" -eq 0 ] || [[ "$out" == *"run-coordinator-publication-red-green: OK"* ]]; then
    bad "$name should refuse overall (ec=$ec)"
  else
    ok "$name refuses overall"
  fi
}

run_expect_ok() {
  local name=$1
  shift
  set +e
  out=$("$@" 2>&1)
  ec=$?
  set -e
  if [ "$ec" -eq 0 ] && [[ "$out" == *"run-coordinator-publication-red-green: OK"* ]] \
    && [[ "$out" == *"RED summary:"* ]] && [[ "$out" == *"GREEN summary:"* ]]; then
    ok "$name accepted"
  else
    bad "$name should succeed with both phase summaries (ec=$ec)"
  fi
}

stub_env() {
  local tag=$1
  shift
  mkdir -p "$CONTRACT_DIR/proof-$tag"
  env HEAVY_GATE="$CONTRACT_DIR/stub-gate.sh" \
    COORDINATOR_PUBLICATION_RED_GREEN_LOG_DIR="$CONTRACT_DIR/proof-$tag" \
    "$@"
}

run_expect_fail "gate-no-launch" \
  env HEAVY_GATE="$CONTRACT_DIR/fail-gate.sh" bash "$runner"

run_expect_fail "RED missing marker and summary" \
  stub_env empty COORDINATOR_PUBLICATION_RED_GREEN_TEST="$CONTRACT_DIR/empty.test.sh" bash "$runner"

run_expect_fail "RED marker without summary" \
  stub_env marker-sum COORDINATOR_PUBLICATION_RED_GREEN_TEST="$CONTRACT_DIR/marker-only.test.sh" bash "$runner"

run_expect_fail "RED zero failed assertions" \
  stub_env zero COORDINATOR_PUBLICATION_RED_GREEN_TEST="$CONTRACT_DIR/zero-fail.test.sh" bash "$runner"

run_expect_fail "RED tooling exit 2 with summary" \
  stub_env tool2 COORDINATOR_PUBLICATION_RED_GREEN_TEST="$CONTRACT_DIR/tooling-exit2.test.sh" bash "$runner"

run_expect_fail_green_phase "GREEN phase failure after RED" \
  stub_env gfail COORDINATOR_PUBLICATION_RED_GREEN_TEST="$CONTRACT_DIR/green-fail.test.sh" bash "$runner"

run_expect_ok "stubbed RED1 GREEN0 reaches both phases" \
  stub_env pair COORDINATOR_PUBLICATION_RED_GREEN_TEST="$CONTRACT_DIR/red1-green0.test.sh" bash "$runner"

echo "passed $pass, failed $fail"
[ "$fail" -eq 0 ]
