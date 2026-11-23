#!/usr/bin/env bash
# T21 (spec #286, R6): post-verdict.sh output is what ship.sh parses, for PASS, PASS+NOTES and FAIL.
# Real git, fake gh and orca from the shared fixture; nothing leaves the temp dir.
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=lib/merge-fixture.sh
. "$here/tests/lib/merge-fixture.sh"
mf_setup; trap mf_teardown EXIT
# shellcheck source=lib/asdf-pin.sh
. "$here/tests/lib/asdf-pin.sh"
export HOME="$MF_DIR/home" ORCA_CLI_COMMAND="$MF_BIN/orca" MF_TOPLEVEL="$MF_DIR/home/orca/workspaces/proj/lead-x"
mkdir -p "$MF_TOPLEVEL"
printf '#!/usr/bin/env bash\nexit 0\n' > "$MF_BIN/cleanup"; chmod +x "$MF_BIN/cleanup"
mf_orca_add_run run_a; mf_orca_add_worker run_a ctx_verify completed /w/v; mf_orca_add_worker run_a ctx_author completed /w/a
cd "$MF_REPO" || exit 1

pass=0 fail=0
ok() { echo "ok   $1"; pass=$((pass+1)); }
bad() { echo "FAIL $1"; fail=$((fail+1)); }
say() { if [ "$1" = 0 ]; then ok "$2"; else bad "$2${3:+ ($3)}"; fi; }

body=$'## Verification\n- Passed.'
new_pr() {
  mf_pr_add "$1" "pv$1" "$body" "script/pv$1.sh"
  local h f="$MF_GH_DIR/pr-$1.json"
  h=$(jq -r .headRefOid "$f")
  jq '.body += "\n\nBuilder: agent=cursor model=grok-4.7-high\n\n## Self-check\n$ bash script/checks-local.sh\nexit 0\n" | .statusCheckRollup = [{"name":"t","status":"COMPLETED","conclusion":"SUCCESS"}]' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
  printf '%s' "$h"
}
post_checks() { gh pr comment "$1" --repo example/repo --body "Checks: PASS head=$2" >/dev/null; }
verdict() { bash "$here/post-verdict.sh" --repo example/repo --pr "$@" 2>&1; }
merge() { bash "$here/ship.sh" --repo example/repo --pr "$1" "${@:3}" 2>&1; }
first_line() { jq -r '[.comments[] | select(.body | startswith("Verdict:"))][-1].body | split("\n")[0]' "$MF_GH_DIR/pr-$1.json"; }

# PASS
h=$(new_pr 41); post_checks 41 "$h"
out=$(verdict 41 --result PASS --head "$h" --verifier ctx_verify --author ctx_author --agent claude --model opus); code=$?
say "$code" "PASS: helper posts" "$out"
[ "$(first_line 41)" = "Verdict: PASS head=$h verifier=ctx_verify author=ctx_author agent=claude model=opus" ] && ok "PASS: first line is exactly the parsed form" || bad "PASS line: $(first_line 41)"
grep -Fq "gh api -X POST repos/example/repo/statuses/$h -f state=success -f context=review" "$MF_GH_LOG" && ok "PASS: posts review success commit status" || bad "PASS review status missing"
out=$(merge 41 "$h"); code=$?
[ "$code" -eq 0 ] && grep -q '^shipped' <<<"$out" && ok "PASS: ship accepts it" || bad "PASS merge: $out"

# PASS+NOTES with a Command line and free text below the first line
h=$(new_pr 42); post_checks 42 "$h"
verdict 42 --result PASS+NOTES --head "$h" --verifier ctx_verify --author ctx_author --agent claude --model opus --command "bun test a.test.ts" --notes "Unchecked paths covered by hand." >/dev/null
[ "$(first_line 42)" = "Verdict: PASS+NOTES head=$h verifier=ctx_verify author=ctx_author agent=claude model=opus" ] && ok "PASS+NOTES: first line parsed form" || bad "NOTES line: $(first_line 42)"
jq -r '.comments[-1].body' "$MF_GH_DIR/pr-42.json" | grep -qx 'Command: bun test a.test.ts' && ok "PASS+NOTES: Command line present" || bad "no Command line"
out=$(merge 42 "$h"); code=$?
[ "$code" -eq 0 ] && grep -q '^shipped' <<<"$out" && ok "PASS+NOTES: ship accepts it" || bad "NOTES merge: $out"

# FAIL is read as a FAIL: alone it blocks, and a newer PASS decides
h=$(new_pr 43); post_checks 43 "$h"
verdict 43 --result FAIL --head "$h" --verifier ctx_other --author ctx_author --command "bash script/tests/post-verdict.test.sh" --notes "- [ ] name the failing command" >/dev/null
grep -Fq "gh api -X POST repos/example/repo/statuses/$h -f state=failure -f context=review" "$MF_GH_LOG" && ok "FAIL: posts review failure commit status" || bad "FAIL review status missing"
mf_orca_add_worker run_a ctx_other completed /w/o
out=$(merge 43 "$h"); code=$?
[ "$code" -eq 1 ] && ! grep -q 'ignored Verdict' <<<"$out" && ok "FAIL: parsed, not named as ignored" || bad "FAIL alone: $out"
verdict 43 --result PASS --head "$h" --verifier ctx_verify --author ctx_author --agent claude --model opus >/dev/null
out=$(merge 43 "$h"); code=$?
[ "$code" -eq 0 ] && grep -q '^shipped' <<<"$out" && ok "FAIL: a newer PASS decides" || bad "FAIL+PASS: $out"

# 1027: a FAIL without --command, or without a "- [ ]" fix line, posts nothing
h=$(new_pr 54); before=$(jq '.comments|length' "$MF_GH_DIR/pr-54.json")
out=$(verdict 54 --result FAIL --head "$h" --verifier ctx_verify --author ctx_author); code=$?
[ "$code" -ne 0 ] && [[ "$out" == *"FAIL needs --command"* ]] && [ "$(jq '.comments|length' "$MF_GH_DIR/pr-54.json")" = "$before" ] && ok "FAIL without --command posts nothing" || bad "FAIL no command: $out"
out=$(verdict 54 --result FAIL --head "$h" --verifier ctx_verify --author ctx_author --command "   " --notes "- [ ] fix it"); code=$?
[ "$code" -ne 0 ] && [[ "$out" == *"FAIL needs --command"* ]] && [ "$(jq '.comments|length' "$MF_GH_DIR/pr-54.json")" = "$before" ] && ok "FAIL with a blank --command posts nothing" || bad "FAIL blank command: $out"
out=$(verdict 54 --result FAIL --head "$h" --verifier ctx_verify --author ctx_author --command "bash script/tests/post-verdict.test.sh" --notes "prose only"); code=$?
[ "$code" -ne 0 ] && [[ "$out" == *"FAIL needs a - [ ] fix line"* ]] && [ "$(jq '.comments|length' "$MF_GH_DIR/pr-54.json")" = "$before" ] && ok "FAIL without a fix line posts nothing" || bad "FAIL no fix line: $out"
out=$(verdict 54 --result FAIL --head "$h" --verifier ctx_verify --author ctx_author --command "bash script/tests/post-verdict.test.sh" --notes "- [ ]" ); code=$?
[ "$code" -ne 0 ] && [[ "$out" == *"FAIL needs a - [ ] fix line"* ]] && [ "$(jq '.comments|length' "$MF_GH_DIR/pr-54.json")" = "$before" ] && ok "FAIL with an empty checkbox posts nothing" || bad "FAIL empty box: $out"
out=$(verdict 54 --result FAIL --head "$h" --verifier ctx_verify --author ctx_author --command "bash script/tests/post-verdict.test.sh" --notes $'- [x] already done\n- [ ] fix the missing command' --print); code=$?
[ "$code" -eq 0 ] && [[ "$out" == *"Command: bash script/tests/post-verdict.test.sh"* ]] && [[ "$out" == *"- [ ] fix the missing command"* ]] && [ "$(jq '.comments|length' "$MF_GH_DIR/pr-54.json")" = "$before" ] && ok "FAIL --print shows the command and the fix line and posts nothing" || bad "FAIL print: $out"
out=$(verdict 54 --result FAIL --head "$h" --verifier ctx_verify --author ctx_author --command "bash script/tests/post-verdict.test.sh" --notes $'- [ ] fix the missing command'); code=$?
say "$code" "FAIL with --command and a fix line posts" "$out"
body=$(jq -r '.comments[-1].body' "$MF_GH_DIR/pr-54.json")
[[ "$body" == *"Command: bash script/tests/post-verdict.test.sh"* ]] && [[ "$body" == *"- [ ] fix the missing command"* ]] && ok "FAIL comment carries the command and the fix line" || bad "FAIL body: $body"

# Bad flags post nothing
h=$(new_pr 44); before=$(jq '.comments|length' "$MF_GH_DIR/pr-44.json")
for args in "--result MAYBE --head $h --verifier ctx_verify --author ctx_author" \
            "--result PASS --head abc123 --verifier ctx_verify --author ctx_author" \
            "--result PASS --head $h --verifier ctx_verify --author ctx_verify" \
            "--result PASS --head $h --verifier bad\$id --author ctx_author" \
            "--result PASS --head $h --verifier ctx_verify"; do
  # shellcheck disable=SC2086
  out=$(verdict 44 $args); code=$?
  [ "$code" -ne 0 ] && [ "$(jq '.comments|length' "$MF_GH_DIR/pr-44.json")" = "$before" ] && ok "refuses: ${args%% --head*}${args##*--head $h}" || bad "bad flags posted or exited 0: $args"
done

# --correction links a prior comment
h=$(new_pr 46); post_checks 46 "$h"
out=$(verdict 46 --result PASS --head "$h" --verifier ctx_verify --author ctx_author --correction "https://example.test/pull/46#issuecomment-99" --notes "Resolved findings."); code=$?
say "$code" "--correction posts successfully" "$out"
[ "$(first_line 46)" = "Verdict: PASS head=$h verifier=ctx_verify author=ctx_author" ] && ok "--correction: first line parsed form" || bad "correction line: $(first_line 46)"
jq -r '.comments[-1].body' "$MF_GH_DIR/pr-46.json" | grep -qx 'Correction: https://example.test/pull/46#issuecomment-99' && ok "--correction line present" || bad "missing Correction line"

# --print builds the body without posting
h=$(new_pr 45)
out=$(verdict 45 --result PASS --head "$h" --verifier ctx_verify --author ctx_author --print); code=$?
[ "$code" -eq 0 ] && [ "$(head -1 <<<"$out")" = "Verdict: PASS head=$h verifier=ctx_verify author=ctx_author" ] && [ "$(jq '.comments|length' "$MF_GH_DIR/pr-45.json")" = 0 ] && ok "--print shows the body and posts nothing" || bad "--print: $out"

# T544: --author must be a dispatch id (ctx_...), unknown, or a configured coordinator id
h=$(new_pr 47); before=$(jq '.comments|length' "$MF_GH_DIR/pr-47.json")
out=$(verdict 47 --result PASS --head "$h" --verifier ctx_verify --author term_59f754da-570d-4e18-a384-083e793d930c); code=$?
[ "$code" -ne 0 ] && [ "$(jq '.comments|length' "$MF_GH_DIR/pr-47.json")" = "$before" ] && ok "T544: a terminal id author is refused, nothing posted" || bad "T544 terminal id: $out"
out=$(verdict 47 --result PASS --head "$h" --verifier ctx_verify --author ctx_author); code=$?
say "$code" "T544: a dispatch id author is accepted" "$out"
h=$(new_pr 48)
out=$(verdict 48 --result PASS --head "$h" --verifier ctx_verify --author unknown); code=$?
say "$code" "T544: author=unknown is accepted" "$out"
cfg="$MF_DIR/pvcfg"; mkdir -p "$cfg"; cp "$here/post-verdict.sh" "$here/apply-local-overlay.py" "$here/ship.config.example.json" "$cfg/"
h=$(new_pr 49)
out=$(bash "$cfg/post-verdict.sh" --repo example/repo --pr 49 --result PASS --head "$h" --verifier ctx_verify --author term_coord 2>&1); code=$?
[ "$code" -ne 0 ] && ok "T544: a coordinator id is refused when none is configured" || bad "T544 unconfigured coordinator: $out"
printf '{"coordinator_ids":["term_coord"]}\n' > "$cfg/ship.local.json"
out=$(bash "$cfg/post-verdict.sh" --repo example/repo --pr 49 --result PASS --head "$h" --verifier ctx_verify --author term_coord 2>&1); code=$?
say "$code" "T544: a configured coordinator id is accepted" "$out"

# Issue 866: --agent and --model record the verifier's agent and model on the Verdict line, together or not at all
h=$(new_pr 50)
out=$(verdict 50 --result PASS --head "$h" --verifier ctx_verify --author ctx_author --agent claude --model opus --print); code=$?
[ "$code" -eq 0 ] && [ "$(head -1 <<<"$out")" = "Verdict: PASS head=$h verifier=ctx_verify author=ctx_author agent=claude model=opus" ] && ok "--agent and --model go on the Verdict line" || bad "agent/model line: $out"
out=$(verdict 50 --result PASS --head "$h" --verifier ctx_verify --author ctx_author --agent claude --print); code=$?
[ "$code" -ne 0 ] && ok "--agent without --model is refused" || bad "agent without model: $out"
out=$(verdict 50 --result PASS --head "$h" --verifier ctx_verify --author ctx_author --agent 'cl aude' --model opus --print); code=$?
[ "$code" -ne 0 ] && ok "--agent with a space is refused" || bad "agent with space: $out"

# Issue 1386: a Verdict for a head the PR has moved past is refused and nothing is posted
h=$(new_pr 51)
old=$(printf '%040d' 1)
before=$(jq '.comments|length' "$MF_GH_DIR/pr-51.json")
out=$(verdict 51 --result PASS --head "$old" --verifier ctx_verify --author ctx_author); code=$?
[ "$code" -ne 0 ] && [[ "$out" == *"stale head: PR is at $h"* ]] && [ "$(jq '.comments|length' "$MF_GH_DIR/pr-51.json")" = "$before" ] && ok "a stale head is refused, nothing posted" || bad "stale head: $out"

before=$(jq '.comments|length' "$MF_GH_DIR/pr-51.json")
out=$(bash "$here/post-verdict.sh" --help 2>&1); code=$?
[ "$code" -eq 0 ] && [[ "$out" == *--corrects* && "$out" == *--supersedes* ]] && [ "$(jq '.comments|length' "$MF_GH_DIR/pr-51.json")" = "$before" ] \
  && ok "--help prints the Usage block with the aliases and posts nothing" || bad "--help: $code $out"

# Issue 1679: --ship runs ship.sh after a PASS at the current head, no bypass flags. Fake ship.sh and a fake dotfiles checkout.
ship_log="$MF_DIR/ship.log"; : > "$ship_log"
fake_ship="$MF_DIR/fake-ship.sh"
printf '#!/usr/bin/env bash\necho "ship $*" >> "%s"\n[ -z "${FAKE_SHIP_REFUSE:-}" ] || { echo "ship: refused: $FAKE_SHIP_REFUSE" >&2; exit 1; }\n' "$ship_log" > "$fake_ship"
df_origin="$MF_DIR/df-origin.git"; df="$MF_DIR/df"
git init -q --bare "$df_origin"; git clone -q "$df_origin" "$df" 2>/dev/null
mkdir -p "$df/script"; printf '#!/usr/bin/env bash\necho fleet-pull >> "%s"\n' "$ship_log" > "$df/script/fleet-pull.sh"
git -C "$df" add -A >/dev/null; git -C "$df" -c user.email=t@t -c user.name=t commit -qm init
git -C "$df" push -q origin HEAD:main 2>/dev/null; git -C "$df" branch -u origin/main >/dev/null 2>&1
export POST_VERDICT_SHIP_SH="$fake_ship" POST_VERDICT_DOTFILES="$df"
h=$(new_pr 60)
out=$(verdict 60 --result PASS --head "$h" --verifier ctx_verify --author ctx_author --agent claude --model opus --ship); code=$?
[ "$code" -eq 0 ] && grep -qx 'ship --repo example/repo --pr 60' "$ship_log" && ! grep -q fleet-pull "$ship_log" && ok "--ship: PASS at head runs ship.sh with only --repo and --pr, no fleet-pull for another repo" || bad "--ship PASS: $out / $(cat "$ship_log")"
: > "$ship_log"; h=$(new_pr 61)
out=$(FAKE_SHIP_REFUSE="Checks on main is red" verdict 61 --result PASS --head "$h" --verifier ctx_verify --author ctx_author --agent claude --model opus --ship); code=$?
[ "$code" -eq 0 ] && [[ "$out" == *"SHIP REFUSED"*"Checks on main is red"* ]] && [ "$(grep -c '^ship ' "$ship_log")" = 1 ] && ok "--ship: a refusal is printed with ship.sh's reason, once, verdict stays posted" || bad "--ship refusal: $code $out"
: > "$ship_log"; h=$(new_pr 62); old=$(printf '%040d' 2)
out=$(verdict 62 --result PASS --head "$old" --verifier ctx_verify --author ctx_author --ship); code=$?
[ "$code" -ne 0 ] && [ ! -s "$ship_log" ] && ok "--ship: PASS at an old head posts nothing and ships nothing" || bad "--ship old head: $code $out"
out=$(verdict 62 --result FAIL --head "$h" --verifier ctx_verify --author ctx_author --command c --notes "- [ ] x" --ship); code=$?
[ "$code" -ne 0 ] && [ ! -s "$ship_log" ] && ok "--ship: a FAIL Verdict never ships" || bad "--ship FAIL: $code $out"
# dotfiles repo: pull and fleet-pull follow a successful ship
: > "$ship_log"; h=$(new_pr 63)
out=$(bash "$here/post-verdict.sh" --repo example/dotfiles --pr 63 --result PASS --head "$h" --verifier ctx_verify --author ctx_author --agent claude --model opus --ship 2>&1); code=$?
grep -qx 'fleet-pull' "$ship_log" && ok "--ship: dotfiles runs git pull then fleet-pull.sh" || bad "--ship dotfiles ($code): $out / $(cat "$ship_log")"
unset POST_VERDICT_SHIP_SH POST_VERDICT_DOTFILES

echo "passed $pass, failed $fail"
[ "$fail" -eq 0 ]
