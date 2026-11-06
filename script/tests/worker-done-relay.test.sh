#!/usr/bin/env bash
# Tests for worker-done-relay.sh: route a builder worker_done to the owning lead, release the committer once.
here=$(cd "$(dirname "$0")" && pwd)
script="$here/../worker-done-relay.sh"
pass=0 fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL: $1"; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/bin" "$tmp/owners"
cat > "$tmp/bin/orca" <<'EOS'
#!/usr/bin/env bash
echo "$*" >> "$ORCA_LOG"
echo '{"ok":true}'
EOS
chmod +x "$tmp/bin/orca"
export ORCA_LOG="$tmp/orca.log" ORCA_CLI_COMMAND="$tmp/bin/orca" WORKER_DONE_OWNER_DIR="$tmp/owners"
sha=0123456789abcdef0123456789abcdef01234567
printf 'term_lead_L\n' > "$tmp/owners/disp_owned"
run() { : > "$ORCA_LOG"; bash "$script" "$@" >"$tmp/out" 2>"$tmp/err"; echo $? >"$tmp/rc"; }

# 1. owned dispatch: message goes to the lead with branch, sha and payload, and to no one else
run relay --dispatch disp_owned --branch mingster/x-1 --sha "$sha" --payload /tmp/p.md --coordinator term_coord
[ "$(cat "$tmp/rc")" = 0 ] && ok || bad "owned relay exit 0"
grep -q -- "orchestration send --to term_lead_L .*--body .*mingster/x-1.*$sha.*/tmp/p.md" "$ORCA_LOG" && ok || bad "lead gets branch, sha, payload"
grep -q -- "terminal send --terminal term_lead_L " "$ORCA_LOG" && ok || bad "lead is nudged"
grep -q term_coord "$ORCA_LOG" && bad "coordinator must not be contacted when owned" || ok

# 2. no recorded owner: coordinator gets it
run relay --dispatch disp_orphan --branch b --sha "$sha" --payload /tmp/p.md --coordinator term_coord
[ "$(cat "$tmp/rc")" = 0 ] && ok || bad "orphan relay exit 0"
grep -q -- "orchestration send --to term_coord .*disp_orphan" "$ORCA_LOG" && ok || bad "orphan reaches coordinator"
grep -q term_lead_L "$ORCA_LOG" && bad "orphan must not reach a lead" || ok

# 3. empty owner file counts as no owner
: > "$tmp/owners/disp_empty"
run relay --dispatch disp_empty --branch b --sha "$sha" --payload /tmp/p.md --coordinator term_coord
grep -q -- "orchestration send --to term_coord " "$ORCA_LOG" && ok || bad "empty owner file goes to coordinator"

# 4. committer release happens once; second is a no-op
run release --dispatch disp_owned
[ "$(cat "$tmp/rc")" = 0 ] && ok || bad "release exit 0"
[ "$(grep -c -- 'orchestration worker-release --dispatch disp_owned' "$ORCA_LOG")" = 1 ] && ok || bad "first release calls worker-release once"
run release --dispatch disp_owned
[ "$(cat "$tmp/rc")" = 0 ] && ok || bad "second release exit 0"
[ ! -s "$ORCA_LOG" ] && ok || bad "second release calls nothing"

# 5. failed release is not marked, so it can be retried
cat > "$tmp/bin/orca" <<'EOS'
#!/usr/bin/env bash
echo "$*" >> "$ORCA_LOG"
exit 1
EOS
run release --dispatch disp_retry
[ "$(cat "$tmp/rc")" != 0 ] && ok || bad "failed release exits nonzero"
run release --dispatch disp_retry
grep -q "worker-release --dispatch disp_retry" "$ORCA_LOG" && ok || bad "failed release is retried"

# 6. bad input refuses
run relay --dispatch "../x" --branch b --sha "$sha" --payload p --coordinator c
[ "$(cat "$tmp/rc")" = 2 ] && ok || bad "unsafe dispatch id exits 2"
run relay --dispatch disp_owned --branch b --sha "$sha" --payload p
[ "$(cat "$tmp/rc")" = 2 ] && ok || bad "missing coordinator exits 2"


# ---- sweep: relay and release by proof, once per fleet-watch pass ----
swp=$tmp/sweep; mkdir -p "$swp/bin" "$swp/owners" "$swp/remote/o" "$swp/wt"
cat > "$swp/bin/orca" <<'EOS'
#!/usr/bin/env bash
echo "$*" >> "$SW_LOG"
case "$*" in
  *"orchestration check"*) cat "$SW_INBOX" ;;
  *"worker-show --dispatch "*)
    d=$4
    printf '{"ok":true,"result":{"worker":{"dispatchId":"%s","worktreeId":"repo::%s/wt/%s"}}}\n' "$d" "$SW_ROOT" "$d" ;;
  *) echo '{"ok":true}' ;;
esac
EOS
cat > "$swp/bin/gh" <<'EOS'
#!/usr/bin/env bash
echo "gh $*" >> "$SW_LOG"
case "$*" in
  *rate_limit*) cat "$SW_RATE" ;;
  "pr view "*) cat "$SW_ROOT/pr-$3.json" ;;
  *) exit 1 ;;
esac
EOS
chmod +x "$swp/bin/orca" "$swp/bin/gh"
export SW_LOG="$swp/log" SW_ROOT="$swp" SW_INBOX="$swp/inbox.json" SW_RATE="$swp/rate"
echo 4000 > "$SW_RATE"
git init -q --bare "$swp/remote/o/n"
export ORCA_CLI_COMMAND="$swp/bin/orca" GH_COMMAND="$swp/bin/gh" WORKER_DONE_REMOTE_PREFIX="$swp/remote/"
gitc() { git -c user.email=t@t -c user.name=t "$@"; }
# builder_wt DISPATCH BRANCH [push]: a worktree with one commit; prints its head sha
builder_wt() {
  mkdir -p "$swp/wt/$1"; git -C "$swp/wt/$1" init -q -b "$2"
  gitc -C "$swp/wt/$1" commit -q --allow-empty -m "c-$1"
  git -C "$swp/wt/$1" remote add origin "$swp/remote/o/n"
  [ "${3:-}" != push ] || git -C "$swp/wt/$1" push -q origin "$2"
  git -C "$swp/wt/$1" rev-parse HEAD
}
# inbox DISPATCH:OUTCOME ...: the coordinator's unread worker_done messages
inbox() {
  python3 - "$SW_INBOX" "$@" <<'PY'
import json, sys
path, *pairs = sys.argv[1:]
messages = [{'id': 'msg_' + d, 'type': 'worker_done', 'subject': 'done', 'body': 'free text without fields',
             'payload': json.dumps({'taskId': 't_' + d, 'dispatchId': d, 'outcome': o})}
            for d, o in (pair.split(':') for pair in pairs)]
json.dump({'ok': True, 'result': {'messages': messages}}, open(path, 'w'))
PY
}
record() { local id=$1; shift; printf '%s\n' "$@" > "$swp/owners/$id"; }
sweep() { : > "$SW_LOG"; WORKER_DONE_OWNER_DIR="$swp/owners" bash "$script" sweep --coordinator term_coord --run run_1 >"$swp/out" 2>"$swp/err"; echo $? > "$swp/rc"; }
sent_to() { grep -c -- "orchestration send --to $1 " "$SW_LOG"; }
released() { grep -c -- "worker-release --dispatch $1" "$SW_LOG"; }
lines_for() { grep -c -- "$1" "$swp/out"; }
pr_json() { # N HEAD [verdict comment first lines...]
  python3 - "$swp/pr-$1.json" "$2" "${@:3}" <<'PY'
import json, sys
path, head, *comments = sys.argv[1:]
json.dump({'headRefOid': head, 'comments': [{'id': 'c%d' % i, 'body': c + '\nnotes'} for i, c in enumerate(comments)]}, open(path, 'w'))
PY
}

# S1: the owner lead gets the relay once, from a peek; the coordinator is not contacted
b1sha=$(builder_wt b1 feat-1)
inbox b1:succeeded
record b1 term_lead_L kind=builder repo=o/n branch=feat-1
sweep
[ "$(cat "$swp/rc")" = 0 ] && ok || bad "sweep exits 0: $(cat "$swp/err")"
grep -q -- "orchestration check .*--peek" "$SW_LOG" && ok || bad "sweep reads with --peek"
grep -q -- "--ack" "$SW_LOG" && bad "sweep must not ack" || ok
[ "$(sent_to term_lead_L)" = 1 ] && ok || bad "owner lead gets one relay"
grep -q "branch=feat-1 sha=$b1sha" "$SW_LOG" && ok || bad "relay carries the record branch and the worktree head"
[ -f "$swp/owners/b1.relayed" ] && ok || bad "relayed marker written"
[ "$(sent_to term_coord)" = 0 ] && ok || bad "coordinator not contacted"
[ "$(lines_for b1)" = 1 ] && ok || bad "no proof gives one digest line: $(cat "$swp/out")"
sweep
[ "$(sent_to term_lead_L)" = 0 ] && ok || bad "a second pass does not relay again"

# S2: no proof (branch not on the remote): seat stays, one digest line, no repeat; after the push it is released once
[ "$(released b1)" = 0 ] && ok || bad "no release without proof"
[ "$(lines_for b1)" = 0 ] && ok || bad "second pass repeats the digest line"
git -C "$swp/wt/b1" push -q origin feat-1
inbox
sweep
[ "$(released b1)" = 1 ] && ok || bad "released once the remote is at the head"
[ -f "$swp/owners/b1.released" ] && ok || bad "released marker written"
sweep
[ "$(released b1)" = 0 ] && ok || bad "released only once"

# S3: no owner record: nothing happens
inbox nobody:succeeded
sweep
[ "$(grep -c . "$SW_LOG")" = 1 ] && ok || bad "no record: only the check runs: $(cat "$SW_LOG")"
[ ! -e "$swp/owners/nobody.relayed" ] && ok || bad "no record: no marker"

# S4: a record without kind is relayed but never released, and is listed once
builder_wt k1 feat-k push > /dev/null
inbox k1:succeeded
record k1 term_lead_L repo=o/n branch=feat-k
sweep; sweep
[ "$(released k1)" = 0 ] && ok || bad "record without kind is never released"
[ "$(lines_for k1)" = 0 ] && ok || bad "kindless digest line is not repeated"

# S5: a failed outcome is not released
builder_wt f1 feat-f push > /dev/null
inbox f1:failed
record f1 term_lead_L kind=builder repo=o/n branch=feat-f
sweep
[ "$(released f1)" = 0 ] && ok || bad "failed outcome is not released"

# S6: a correction seat on the same branch has its own record; one dispatch is released at a time
builder_wt c1 feat-c push > /dev/null
git clone -q "$swp/remote/o/n" "$swp/wt/c2" 2>/dev/null; git -C "$swp/wt/c2" checkout -q feat-c
gitc -C "$swp/wt/c2" commit -q --allow-empty -m correction
inbox c1:succeeded c2:succeeded
record c1 term_lead_L kind=builder repo=o/n branch=feat-c
record c2 term_lead_L kind=builder repo=o/n branch=feat-c
sweep
[ "$(released c1)" = 1 ] && ok || bad "the seat whose head is on the remote is released"
[ "$(released c2)" = 0 ] && ok || bad "the correction seat waits for its own head"
git -C "$swp/wt/c2" push -q origin feat-c
sweep
[ "$(released c2)" = 1 ] && [ "$(released c1)" = 0 ] && ok || bad "correction released once pushed, first not again"

# S7: reviewer proof: Verdict with the head and this dispatch on every PR it reviewed
r_head=1111111111111111111111111111111111111111
r_head2=2222222222222222222222222222222222222222
inbox r1:succeeded
record r1 term_lead_L kind=reviewer repo=o/n pr=7 pr=8
pr_json 7 "$r_head" "Verdict: PASS head=$r_head verifier=r1 author=x"
pr_json 8 "$r_head2" "Verdict: PASS head=$r_head2 verifier=other author=x"
sweep
[ "$(released r1)" = 0 ] && ok || bad "one PR without its Verdict keeps the seat"
[ "$(lines_for r1)" = 1 ] && ok || bad "reviewer without proof gets one digest line"
pr_json 8 "$r_head2" "Verdict: PASS head=$r_head2 verifier=r1 author=x"
sweep
[ "$(released r1)" = 1 ] && ok || bad "all Verdicts present: released"
grep -q "worker_done r1" "$SW_LOG" && bad "reviewer relay is not repeated" || ok

# S8: a Verdict for an older head is no proof
inbox r2:succeeded
record r2 term_lead_L kind=reviewer repo=o/n pr=9
pr_json 9 "$r_head2" "Verdict: PASS head=$r_head verifier=r2 author=x"
sweep
[ "$(released r2)" = 0 ] && ok || bad "stale head is no proof"
pr_json 9 "$r_head2" "Verdict: PASS head=$r_head verifier=r2 author=x" "Verdict: FAIL+NOTES head=$r_head2 verifier=r2 author=x"
sweep
[ "$(released r2)" = 0 ] && ok || bad "a malformed Verdict word is no proof"
pr_json 9 "$r_head2" "Verdict: PASS+NOTES head=$r_head2 verifier=r2 author=x"
sweep
[ "$(released r2)" = 1 ] && ok || bad "PASS+NOTES at the head is proof"

# S9: GitHub budget below 500: skip without a digest line, try again next pass
inbox r3:succeeded
record r3 term_lead_L kind=reviewer repo=o/n pr=10
pr_json 10 "$r_head" "Verdict: PASS head=$r_head verifier=r3 author=x"
echo 499 > "$SW_RATE"
sweep
[ "$(released r3)" = 0 ] && ok || bad "low budget skips the release"
grep -q "gh pr view" "$SW_LOG" && bad "low budget makes no PR call" || ok
[ "$(lines_for r3)" = 0 ] && ok || bad "low budget adds no digest line"
echo 500 > "$SW_RATE"
sweep
[ "$(released r3)" = 1 ] && ok || bad "budget back: released"

echo "worker-done-relay: $pass passed, $fail failed"
[ "$fail" = 0 ]
