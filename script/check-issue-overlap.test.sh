#!/usr/bin/env bash
# Tests for script/check-issue-overlap.sh (#1678). A fake gh answers from files in $FAKE.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/asdf-pin.sh
. "$ROOT/script/tests/lib/asdf-pin.sh"
SCRIPT="$ROOT/script/check-issue-overlap.sh"
TMP="$(cd -P "$(mktemp -d)" && pwd)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home" FAKE="$TMP/fake"; mkdir -p "$HOME" "$TMP/bin" "$FAKE"
pass=0 fail=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }

cat >"$TMP/bin/gh" <<'GH'
#!/usr/bin/env bash
case "$1 $2" in
  "issue view") cat "$FAKE/issue-$3.md" ;;
  "issue list") cat "$FAKE/inflight.json" ;;
  "pr list") cat "$FAKE/prs.json" ;;
  *) exit 1 ;;
esac
GH
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"

cat >"$FAKE/issue-10.md" <<'B'
Do the thing.

## Allowed files
- script/alpha.sh
- `script/tests/alpha.test.sh`

## Verify
bash script/checks-local.sh
B
echo '[]' >"$FAKE/inflight.json"
echo '[]' >"$FAKE/prs.json"
run() { out=$(bash "$SCRIPT" "$@" 2>&1); rc=$?; }

run 10
[ "$rc" -eq 0 ] && ok "no in-flight work: no overlap" || bad "clean (rc=$rc, $out)"

jq -n '[{number: 11, body: "x\n\n## Allowed files\n- script/other.sh\n- script/alpha.sh\n"}]' >"$FAKE/inflight.json"
run 10
if [ "$rc" -eq 1 ] && grep -qF "script/alpha.sh" <<<"$out" && grep -qF "#11" <<<"$out"; then ok "an in-progress issue on the same file overlaps and is named"; else bad "issue overlap (rc=$rc, $out)"; fi

jq -n '[{number: 10, body: "## Allowed files\n- script/alpha.sh\n"}]' >"$FAKE/inflight.json"
run 10
[ "$rc" -eq 0 ] && ok "the issue itself is not an overlap" || bad "self (rc=$rc, $out)"

echo '[]' >"$FAKE/inflight.json"
jq -n '[{number: 20, body: "Closes #99", files: [{path: "script/tests/alpha.test.sh"}]}]' >"$FAKE/prs.json"
run 10
if [ "$rc" -eq 1 ] && grep -qF "script/tests/alpha.test.sh" <<<"$out" && grep -qF "PR #20" <<<"$out"; then ok "an open PR touching an allowed file overlaps and is named"; else bad "PR overlap (rc=$rc, $out)"; fi

jq -n '[{number: 20, body: "Closes #10", files: [{path: "script/alpha.sh"}]}]' >"$FAKE/prs.json"
run 10
[ "$rc" -eq 0 ] && ok "the issue's own PR is not an overlap" || bad "own PR (rc=$rc, $out)"

jq -n '[{number: 21, body: "x", files: [{path: "docs/readme.md"}]}]' >"$FAKE/prs.json"
jq -n '[{number: 12, body: "## Allowed files\n- script/tests/\n"}]' >"$FAKE/inflight.json"
run 10
if [ "$rc" -eq 1 ] && grep -qF "#12" <<<"$out"; then ok "a directory entry covers the files under it"; else bad "dir overlap (rc=$rc, $out)"; fi

echo '[]' >"$FAKE/inflight.json"; echo '[]' >"$FAKE/prs.json"
printf 'Fix.\n\n## Allowed files\n- script/beta.sh\n' >"$TMP/brief.md"
jq -n '[{number: 13, body: "Allowed files: script/beta.sh"}]' >"$FAKE/inflight.json"
run --spec "$TMP/brief.md" 10
if [ "$rc" -eq 1 ] && grep -qF "script/beta.sh" <<<"$out"; then ok "--spec reads the Allowed files of the brief and the inline form of others"; else bad "--spec (rc=$rc, $out)"; fi

printf 'No allowed files here.\n' >"$FAKE/issue-14.md"
run 14
[ "$rc" -eq 0 ] && ok "an issue with no Allowed files cannot overlap" || bad "no allowed (rc=$rc, $out)"

# multi-line "Allowed files:" list, and a bold section after it is not a path list
echo '[]' >"$FAKE/prs.json"
jq -n '[{number: 15, body: "Allowed files:\n- script/gamma.sh\n\n**Out of scope:** do not edit script/zeta.sh\n"}]' >"$FAKE/inflight.json"
printf 'x\n\n## Allowed files\n- script/gamma.sh\n' >"$FAKE/issue-16.md"
run 16
[ "$rc" -eq 1 ] && grep -qF "#15" <<<"$out" && ok "a multi-line Allowed files: list is read" || bad "multi-line (rc=$rc, $out)"
printf 'x\n\n## Allowed files\n- script/q.sh\n\n**Out of scope:** do not edit script/zeta.sh\n' >"$FAKE/issue-17.md"
run 17
[ "$rc" -eq 0 ] && ok "text under a bold section after Allowed files is not a path" || bad "bold section (rc=$rc, $out)"

# the brief without Allowed files still checks the issue body
printf 'Fix.\n\n## Out of scope\nnothing\n' >"$TMP/brief2.md"
run --spec "$TMP/brief2.md" 16
[ "$rc" -eq 1 ] && ok "--spec without Allowed files falls back to the issue body" || bad "spec fallback (rc=$rc, $out)"

# owner-reviewed files mixed with code: a warning, not a refusal
echo '[]' >"$FAKE/inflight.json"; echo '[]' >"$FAKE/prs.json"
printf 'x\n\n## Allowed files\n- script/mix.sh\n- .claude/hooks/guard-bash.py\n' >"$FAKE/issue-30.md"
run 30
if [ "$rc" -eq 0 ] && grep -qF "mix owner-reviewed" <<<"$out" && grep -qF "two issues" <<<"$out"; then ok "a hook mixed with code warns and still exits 0"; else bad "mixed warn (rc=$rc, $out)"; fi
printf 'x\n\n## Allowed files\n- script/only.sh\n- script/tests/only.test.sh\n' >"$FAKE/issue-31.md"
run 31
if [ "$rc" -eq 0 ] && ! grep -qF "warning" <<<"$out"; then ok "code only: no warning"; else bad "code only (rc=$rc, $out)"; fi
printf 'x\n\n## Allowed files\n- templates/agent-team/docs/agents/team.md\n- changelog.d/1-x.md\n- docs/agents/team-reference.md\n' >"$FAKE/issue-32.md"
run 32
if [ "$rc" -eq 0 ] && ! grep -qF "warning" <<<"$out"; then ok "owner-reviewed docs only: no warning"; else bad "docs only (rc=$rc, $out)"; fi

printf 'x\n\n## Allowed files\n- script/foo.sh\n- templates/agent-team/docs/agents/elon-dispatch.md\n' >"$FAKE/issue-33.md"
run 33
if [ "$rc" -eq 0 ] && ! grep -qF "warning" <<<"$out"; then ok "a template docs/agents file mixed with code does not warn"; else bad "template docs (rc=$rc, $out)"; fi
printf 'x\n\n## Allowed files\n- script/foo.sh\n- .claude/agents/fullstack-dev.md\n- .claude/model-routing.md\n- docs/agents/team-facts.md\n' >"$FAKE/issue-35.md"
run 35
if [ "$rc" -eq 0 ] && ! grep -qF "warning" <<<"$out"; then ok "role file, model-routing.md and docs/agents mixed with code do not warn"; else bad "role file (rc=$rc, $out)"; fi
printf 'x\n\n## Allowed files\n- script/foo.sh\n- docs/intent/x/intent.md\n' >"$FAKE/issue-36.md"
run 36
if [ "$rc" -eq 0 ] && grep -qF "mix owner-reviewed" <<<"$out"; then ok "an intent file mixed with code warns"; else bad "intent (rc=$rc, $out)"; fi
printf 'x\n\n## Allowed files\n- AGENTS.md\n- docs/agents/\n' >"$FAKE/issue-34.md"
run 34
if [ "$rc" -eq 0 ] && ! grep -qF "warning" <<<"$out"; then ok "a directory entry is not code"; else bad "dir entry (rc=$rc, $out)"; fi

# shared append-only paths from the config key overlap_shared_paths (#2050)
export FLEET_WATCH_CONFIG="$TMP/fleet-watch.json"
echo '{"overlap_shared_paths": ["**/translation.json"]}' >"$FLEET_WATCH_CONFIG"
echo '[]' >"$FAKE/inflight.json"; echo '[]' >"$FAKE/prs.json"
printf 'x\n\n## Allowed files\n- locales/en/translation.json\n' >"$FAKE/issue-40.md"
jq -n '[{number: 41, body: "## Allowed files\n- locales/en/translation.json\n"}]' >"$FAKE/inflight.json"
run 40
if [ "$rc" -eq 0 ] && grep -qF "ignored shared path: locales/en/translation.json" <<<"$out"; then ok "a shared-path-only overlap with an in-progress issue is allowed and named"; else bad "shared in-flight (rc=$rc, $out)"; fi

echo '[]' >"$FAKE/inflight.json"
jq -n '[{number: 42, body: "x", files: [{path: "locales/en/translation.json"}]}]' >"$FAKE/prs.json"
run 40
if [ "$rc" -eq 0 ] && grep -qF "ignored shared path: locales/en/translation.json" <<<"$out"; then ok "a shared-path-only overlap with an open PR is allowed and named"; else bad "shared PR (rc=$rc, $out)"; fi

printf 'x\n\n## Allowed files\n- locales/en/translation.json\n- script/alpha.sh\n' >"$FAKE/issue-43.md"
jq -n '[{number: 44, body: "x", files: [{path: "locales/en/translation.json"}, {path: "script/alpha.sh"}]}]' >"$FAKE/prs.json"
run 43
if [ "$rc" -eq 1 ] && grep -qF "overlap: script/alpha.sh" <<<"$out" && grep -qF "ignored shared path: locales/en/translation.json" <<<"$out"; then ok "an overlap on a file that is not shared is still refused"; else bad "non-shared still refused (rc=$rc, $out)"; fi

printf 'x\n\n## Allowed files\n- locales/\n' >"$FAKE/issue-45.md"
jq -n '[{number: 46, body: "x", files: [{path: "locales/en/translation.json"}, {path: "locales/en/other.json"}]}]' >"$FAKE/prs.json"
run 45
if [ "$rc" -eq 1 ] && grep -qF "overlap: locales/en/other.json" <<<"$out"; then ok "a shared file does not stop the check on a later file under the same directory entry"; else bad "dir after shared (rc=$rc, $out)"; fi

echo '{"overlap_shared_paths": ["**/translation.json"]' >"$FLEET_WATCH_CONFIG"
printf 'x\n\n## Allowed files\n- locales/en/translation.json\n' >"$FAKE/issue-47.md"
run 47
[ "$rc" -eq 1 ] && ok "a bad config file ignores no path" || bad "bad config (rc=$rc, $out)"
unset FLEET_WATCH_CONFIG

run
[ "$rc" -eq 2 ] && ok "no arguments is a usage error" || bad "usage (rc=$rc)"

echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
