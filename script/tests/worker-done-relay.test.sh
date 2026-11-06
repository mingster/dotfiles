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
grep -q "terminal send" "$ORCA_LOG" && bad "no owner: nothing is typed into any terminal" || ok

# 2b. an owner that is the coordinator itself is not typed into either
printf 'term_coord\n' > "$tmp/owners/disp_selfowned"
run relay --dispatch disp_selfowned --branch b --sha "$sha" --payload /tmp/p.md --coordinator term_coord
grep -q -- "orchestration send --to term_coord " "$ORCA_LOG" && ok || bad "coordinator-owned relay is sent as a message"
grep -q "terminal send" "$ORCA_LOG" && bad "coordinator terminal must not be typed into" || ok

# 2c. a failed nudge to the lead still counts as sent (exit 0, message went out)
cat > "$tmp/bin/orca" <<'EOS'
#!/usr/bin/env bash
echo "$*" >> "$ORCA_LOG"
case "$*" in *"terminal send"*) exit 1 ;; esac
echo '{"ok":true}'
EOS
run relay --dispatch disp_owned --branch b --sha "$sha" --payload /tmp/p.md --coordinator term_coord
[ "$(cat "$tmp/rc")" = 0 ] && ok || bad "nudge failure after a delivered message exits 0"
grep -q "nudge" "$tmp/err" && ok || bad "nudge failure is reported on stderr"
# 2d. a failed send is a failure and is not nudged
cat > "$tmp/bin/orca" <<'EOS'
#!/usr/bin/env bash
echo "$*" >> "$ORCA_LOG"
case "$*" in *"orchestration send"*) exit 1 ;; esac
echo '{"ok":true}'
EOS
run relay --dispatch disp_owned --branch b --sha "$sha" --payload /tmp/p.md --coordinator term_coord
[ "$(cat "$tmp/rc")" != 0 ] && ok || bad "failed send exits nonzero"
grep -q "terminal send" "$ORCA_LOG" && bad "no nudge after a failed send" || ok
cat > "$tmp/bin/orca" <<'EOS'
#!/usr/bin/env bash
echo "$*" >> "$ORCA_LOG"
echo '{"ok":true}'
EOS

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
    if [ -f "$SW_ROOT/show-$d.json" ]; then cat "$SW_ROOT/show-$d.json"; else
      printf '{"ok":true,"result":{"dispatchId":"%s","state":"succeeded","terminal":"term_x","workspace":"0000::%s/wt/%s"}}\n' "$d" "$SW_ROOT" "$d"
    fi ;;
  *"terminal send"*) [ -z "${SW_FAIL_NUDGE:-}" ] || exit 1; echo '{"ok":true}' ;;
  *"orchestration send"*) [ -z "${SW_FAIL_SEND:-}" ] || exit 1; echo '{"ok":true}' ;;
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
printf '{"ok":true,"result":{"dispatchId":"f1","state":"failed","workspace":"0000::%s/wt/f1"}}\n' "$swp" > "$swp/show-f1.json"
sweep
[ "$(released f1)" = 0 ] && ok || bad "failed outcome is not released"
[ "$(lines_for f1)" = 1 ] && grep -q "outcome is failed" "$swp/out" && ok || bad "failed outcome is named in the digest line"

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


# S10 (finding 1): a message that went out counts as relayed even when the nudge fails; no repeat on later passes
builder_wt n1 feat-n push > /dev/null
inbox n1:succeeded
record n1 term_lead_L kind=builder repo=o/n branch=feat-n
SW_FAIL_NUDGE=1 sweep
[ "$(sent_to term_lead_L)" = 1 ] && ok || bad "n1 relayed once"
[ "$(cat "$swp/owners/n1.relayed")" = sent ] && ok || bad "nudge failure still marks sent: $(cat "$swp/owners/n1.relayed")"
SW_FAIL_NUDGE=1 sweep
[ "$(sent_to term_lead_L)" = 0 ] && ok || bad "a failed nudge does not cause a second relay"

# S11: a failed send is not marked and is retried on the next pass
inbox n2:succeeded
builder_wt n2 feat-n2 > /dev/null
record n2 term_lead_L kind=builder repo=o/n branch=feat-n2
SW_FAIL_SEND=1 sweep
[ ! -e "$swp/owners/n2.relayed" ] && ok || bad "failed send leaves no marker"
sweep
[ "$(sent_to term_lead_L)" = 1 ] && [ "$(cat "$swp/owners/n2.relayed")" = sent ] && ok || bad "send retried and marked after the failure"

# S12: crash after the marker: 'sending' is taken before the send, so at most one repeat
builder_wt n3 feat-n3 > /dev/null
inbox n3:succeeded
record n3 term_lead_L kind=builder repo=o/n branch=feat-n3
SW_FAIL_SEND=1 sweep   # stores done.json, no marker
echo sending > "$swp/owners/n3.relayed"   # a pass that died after taking the marker
sweep
[ "$(sent_to term_lead_L)" = 1 ] && ok || bad "a crashed 'sending' is repeated once"
[ "$(cat "$swp/owners/n3.relayed")" = sent ] && ok || bad "repeat ends as sent"
echo resending > "$swp/owners/n3.relayed"   # the repeat died too
sweep
[ "$(sent_to term_lead_L)" = 0 ] && [ "$(cat "$swp/owners/n3.relayed")" = sent ] && ok || bad "a second crash is not repeated again"
# the marker is on disk while the send runs
cat > "$swp/bin/orca-peek" <<'EOS'
#!/usr/bin/env bash
case "$*" in *"orchestration send"*) cat "$SW_ROOT/owners/$SW_WHO.relayed" > "$SW_ROOT/seen-during-send" ;; esac
exec "$SW_ROOT/bin/orca" "$@"
EOS
chmod +x "$swp/bin/orca-peek"
builder_wt n4 feat-n4 > /dev/null
inbox n4:succeeded
record n4 term_lead_L kind=builder repo=o/n branch=feat-n4
ORCA_CLI_COMMAND="$swp/bin/orca-peek" SW_WHO=n4 sweep
[ "$(cat "$swp/seen-during-send" 2>/dev/null)" = sending ] && ok || bad "marker says sending while the send runs: $(cat "$swp/seen-during-send" 2>/dev/null)"

# S13 (finding 2): the waiter reads first. The drain records the message, a sweep with an empty inbox still relays and releases
builder_wt w1 feat-w push > /dev/null
inbox w1:succeeded
record w1 term_lead_L kind=builder repo=o/n branch=feat-w
export FLEET_WATCH_CONFIG="$swp/none.json" COORDINATOR_DRAIN_STATE="$swp/drain.log" WORKER_DONE_OWNER_DIR="$swp/owners"
drain() { bash "$here/../coordinator-drain.sh" --run run_1 "$@" > "$swp/drain.out" 2>/dev/null; }
drain --wait
grep -q msg_w1 "$swp/drain.out" && ok || bad "the waiter still receives the worker_done"
[ -f "$swp/owners/w1.done.json" ] && ok || bad "drain recorded worker_done in the done.json store"
inbox   # the waiter marked it read: nothing unread now
sweep
[ "$(sent_to term_lead_L)" = 1 ] && ok || bad "read-first message is relayed by the sweep"
[ "$(released w1)" = 1 ] && ok || bad "read-first message is released on proof"
inbox w1:succeeded
drain
grep -q msg_w1 "$swp/drain.out" && bad "relayed worker_done is dropped by the drain" || ok
[ ! -e "$swp/owners/w1.done.json" ] && ok || bad "a released dispatch is not recorded again"

# S13b: drain records only owned dispatches, and does not overwrite
inbox w2:succeeded nobody2:succeeded
record w2 term_lead_L kind=builder repo=o/n branch=feat-w2
drain
[ -f "$swp/owners/w2.done.json" ] && [ ! -e "$swp/owners/nobody2.done.json" ] && ok || bad "only owned dispatches are recorded"
printf '{"marker":1}' > "$swp/owners/w2.done.json"
drain
grep -q marker "$swp/owners/w2.done.json" && ok || bad "an existing record is not overwritten"
rm -f "$swp/owners/w2.done.json"

# S13c: a 'sending' marker does not make the drain drop the message
inbox w3:succeeded
record w3 term_lead_L kind=builder repo=o/n branch=feat-w3
echo sending > "$swp/owners/w3.relayed"
drain
grep -q msg_w3 "$swp/drain.out" && ok || bad "an unfinished relay is not dropped"

# S13d: payload as an object (the real shape) works
python3 - "$SW_INBOX" <<'EOP'
import json, sys
json.dump({'ok': True, 'result': {'messages': [{'id': 'msg_o1', 'type': 'worker_done', 'subject': 's', 'body': 'b',
           'payload': {'taskId': 't', 'dispatchId': 'o1'}}]}}, open(sys.argv[1], 'w'))
EOP
builder_wt o1 feat-o push > /dev/null
record o1 term_lead_L kind=builder repo=o/n branch=feat-o
sweep
[ "$(grep -c 'dispatch=o1 ' "$SW_LOG")" = 1 ] && [ "$(released o1)" = 1 ] && ok || bad "real payload (object, no outcome) is relayed and released on worker-show state"

# S13e: a dispatch that is not settled yet (worker-show state ready) is not released
builder_wt u1 feat-u push > /dev/null
inbox u1:succeeded
record u1 term_lead_L kind=builder repo=o/n branch=feat-u
printf '{"ok":true,"result":{"dispatchId":"u1","state":"ready","workspace":"0000::%s/wt/u1"}}\n' "$swp" > "$swp/show-u1.json"
sweep
[ "$(released u1)" = 0 ] && grep -q "outcome is ready" "$swp/out" && ok || bad "unsettled dispatch keeps the seat"

# S14 (finding 4): worker-show has the real shape (result.workspace = "<id>::<path>").
# The path must belong to the record's branch and repo; a stray worktreePath key is never used.
good=$(builder_wt p1 feat-p push)
builder_wt p1x feat-pother > /dev/null
git -C "$swp/wt/p1x" push -q origin feat-pother
inbox p1:succeeded
record p1 term_lead_L kind=builder repo=o/n branch=feat-p
printf '{"ok":true,"result":{"dispatchId":"p1","workspace":"0000::%s/wt/p1","note":{"worktreePath":"%s/wt/p1x"},"worktreePath":"%s/wt/p1x"}}\n' "$swp" "$swp" "$swp" > "$swp/show-p1.json"
sweep
[ "$(released p1)" = 1 ] && ok || bad "proof comes from the workspace path, not a stray worktreePath: $(cat "$swp/out")"

# the path in worktreePath (a decoy at the branch tip) is used instead of the workspace: must not prove
builder_wt q1x feat-qother > /dev/null
git -C "$swp/wt/q1x" push -q origin feat-qother
qsha=$(git -C "$swp/wt/q1x" rev-parse HEAD)
builder_wt q1 feat-q > /dev/null     # q1's own worktree is not pushed
git -C "$swp/remote/o/n" update-ref refs/heads/feat-q "$qsha"
inbox q1:succeeded
record q1 term_lead_L kind=builder repo=o/n branch=feat-q
printf '{"ok":true,"result":{"dispatchId":"q1","workspace":"0000::%s/wt/q1x","worktreePath":"%s/wt/q1x"}}\n' "$swp" "$swp" > "$swp/show-q1.json"
sweep
[ "$(released q1)" = 0 ] && ok || bad "a worktree on another branch is no proof"
[ "$(lines_for q1)" = 1 ] && ok || bad "seat kept with one digest line"

# a worktree of another repo on the same branch name is not proof
rm -rf "$swp/remote/o/m"; git init -q --bare "$swp/remote/o/m"
builder_wt r9 feat-r > /dev/null
git -C "$swp/wt/r9" remote set-url origin "$swp/remote/o/m"
git -C "$swp/wt/r9" push -q origin feat-r
git -C "$swp/wt/r9" push -q "$swp/remote/o/n" feat-r
inbox r9:succeeded
record r9 term_lead_L kind=builder repo=o/n branch=feat-r
sweep
[ "$(released r9)" = 0 ] && ok || bad "a worktree of another repo is no proof"

# a path that is not on this machine keeps the seat
inbox s9:succeeded
record s9 term_lead_L kind=builder repo=o/n branch=feat-s
printf '{"ok":true,"result":{"dispatchId":"s9","workspace":"0000::/nonexistent/path/here"}}\n' > "$swp/show-s9.json"
sweep
[ "$(released s9)" = 0 ] && ok || bad "unreadable path keeps the seat"

echo "worker-done-relay: $pass passed, $fail failed"
[ "$fail" = 0 ]
