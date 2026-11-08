#!/usr/bin/env bash
# Public CLI regression: coordinator dispatches own remote terminals too.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd -P)
# shellcheck source=lib/asdf-pin.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/asdf-pin.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
mkdir -p "$HOME" "$tmp/bin"
export PATH="$tmp/bin:$PATH" FAKE_DIR="$tmp"
export WRAP_UP_SCRATCH_ROOT="$tmp/no-scratch" WRAP_UP_LOOSE_ROOT="$tmp/no-loose"
export WRAP_UP_CLONE_ROOT="$tmp/no-clones" ORCA_TERMINAL_HANDLE=t-own
cat > "$tmp/bin/gh" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  'repo view --json defaultBranchRef') echo '{"defaultBranchRef":{"name":"main"}}'; exit 0 ;;
  'api repos/{owner}/{repo}/pages') echo '{"source":null}'; exit 0 ;;
  'api --paginate repos/{owner}/{repo}/branches?protected=true&per_page=100') echo '[]'; exit 0 ;;
esac
echo '[]'
STUB
cat > "$tmp/bin/orca" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_DIR/calls"
case "$*" in
  'environment list --json') echo '{"ok":true,"result":{"environments":[{"id":"env-a"}]}}' ;;
  'terminal list --json') echo '{"ok":true,"result":{"terminals":[]}}' ;;
  'terminal list --environment env-a --json') cat "$FAKE_DIR/terminals" ;;
  'terminal close --environment env-a --terminal '*) echo "${*: -1}" >> "$FAKE_DIR/closed" ;;
  'orchestration run-list --environment '*)
    if [ -e "$FAKE_DIR/env-run-fail" ]; then exit 1; fi
    echo '{"ok":true,"result":{"runs":[{"id":"run-env"}]}}' ;;
  'orchestration run-list --cursor r2 '*) echo '{"ok":true,"result":{"runs":[{"id":"run-two"}]}}' ;;
  'orchestration run-list '*)
    if [ -e "$FAKE_DIR/run-fail" ]; then exit 1; fi
    if [ -e "$FAKE_DIR/two-runs" ]; then echo '{"ok":true,"result":{"runs":[{"id":"run-one"}],"nextCursor":"r2"}}'
    else echo '{"ok":true,"result":{"runs":[{"id":"run-one","coordinator_handle":"t-coord"}]}}'; fi ;;
  'orchestration worker-list --environment '*)
    if [ -e "$FAKE_DIR/env-page" ]; then cat "$FAKE_DIR/env-page"
    else echo '{"ok":true,"result":{"workers":[],"page":{"hasMore":false}}}'; fi ;;
  'orchestration worker-list '*)
    if [[ "$*" == *'--cursor c2'* ]] && [ -e "$FAKE_DIR/fail-page" ]; then exit 1; fi
    if [[ "$*" != *--run* ]]; then
      case "$*" in
        *'--cursor l2'*) echo '{"ok":true,"result":{"workers":[],"scope":{},"warnings":[]}}' ;;
        *) if [ -e "$FAKE_DIR/local-page" ]; then cat "$FAKE_DIR/local-page"
           else echo '{"ok":true,"result":{"workers":[],"page":{"hasMore":false}}}'; fi ;;
      esac
    else
      case "$*" in
        *'--run run-two'*) cat "$FAKE_DIR/run-two-page" ;;
        *'--cursor c2'*) cat "$FAKE_DIR/page2" ;;
        *'--cursor c3'*) cat "$FAKE_DIR/page3" ;;
        *) cat "$FAKE_DIR/page1" ;;
      esac
    fi ;;
  'worktree list --json') echo '{"ok":true,"result":{"worktrees":[]}}' ;;
  'worktree rm --worktree path:'*) exit 0 ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$tmp/bin/gh" "$tmp/bin/orca"
export ORCA_CLI_COMMAND="$tmp/bin/orca"
git init -q --bare "$tmp/origin"
git init -q -b main "$tmp/repo"
git -C "$tmp/repo" -c user.name=Test -c user.email=test@example.invalid commit -qm initial --allow-empty
git -C "$tmp/repo" remote add origin "$tmp/origin"
git -C "$tmp/repo" push -qu origin main
term() {
  jq -n --arg h "$1" --arg p "$2" --argjson agent "${3:-null}" \
    '{handle:$h,worktreePath:$p,connected:true,writable:true,agentIdentity:$agent,lastOutputAt:1}'
}
worker() {
  jq -n --arg h "$1" --arg p "$2" --arg s "$3" \
    '{agentTerminalHandle:$h,dispatchStatus:$s,projection:{workspace:{id:("repo::"+$p)}}}'
}
{
  term t-path /fixture/settled
  term t-handle /fixture/handle
  term t-live /fixture/live
  term t-own /fixture/own
  term t-lead /fixture/lead-work
  term t-agent /fixture/agent '"agent"'
  term t-unknown /fixture/unknown
} | jq -s '{ok:true,result:{terminals:.}}' > "$tmp/terminals"
{
  worker '' /fixture/settled released
  worker t-handle /fixture/other completed
  worker '' /fixture/live completed
  worker '' /fixture/live dispatched
  worker t-own /fixture/own completed
  worker '' /fixture/lead-work completed
  worker '' /fixture/agent released
} | jq -s '{ok:true,result:{workers:.,page:{hasMore:false}}}' > "$tmp/page1"
run() { bash "$root/script/wrap-up.sh" --repo "$tmp/repo" "$@" > "$tmp/output" 2> "$tmp/errors" || true; }
expect() { grep -Fxq "$1" "$tmp/output" || { echo "FAIL missing: $1"; cat "$tmp/output"; exit 1; }; }
run --dry-run
expect 'Close terminal t-path (env-a, settled dispatch on this path)'
expect 'Close terminal t-handle (env-a, settled dispatch)'
expect 'Close terminal t-agent (env-a, settled dispatch on this path)'
for pair in 't-live|live dispatch' 't-own|own terminal' 't-lead|lead worktree' 't-unknown|unknown owner, still running'; do
  expect "Kept terminal ${pair%|*} (env-a, ${pair#*|})"
done
test ! -e "$tmp/closed"
echo 'ok coordinator dispatches classify remote handles and paths while preserving keep rules'
run --apply
printf '%s\n' t-agent t-handle t-path > "$tmp/expected"
sort "$tmp/closed" | cmp - "$tmp/expected"
echo 'ok apply closes only the eligible remote terminals through their environment'
# Newest-first pages: the live owner is older than a settled attempt on the same path.
cp "$tmp/page1" "$tmp/original"
jq '.result.page={hasMore:true,nextCursor:"c2"}' "$tmp/original" > "$tmp/page1"
echo '{"ok":true,"result":{"workers":[],"page":{"hasMore":true,"nextCursor":"c3"}}}' > "$tmp/page2"
{
  worker '' /fixture/settled dispatched
  worker '' /fixture/unknown completed
} | jq -s '{ok:true,result:{workers:.,page:{hasMore:false}}}' > "$tmp/page3"
rm "$tmp/closed"
WRAP_UP_WORKER_PAGES=1 run --dry-run
expect 'Kept terminal t-path (env-a, live dispatch)'
expect 'Close terminal t-unknown (env-a, settled dispatch on this path)'
test ! -e "$tmp/closed"
echo 'ok every page is read before planning: third-page live owner wins and settled path closes'
run --apply
printf '%s\n' t-agent t-handle t-unknown > "$tmp/expected"
sort "$tmp/closed" | cmp - "$tmp/expected"
rm "$tmp/closed"
echo 'ok apply uses all pages and keeps the older live owner'
echo '{"ok":true,"result":{"workers":[],"page":{"hasMore":true}}}' > "$tmp/page2"
run --apply
test ! -e "$tmp/closed" || { echo 'FAIL incomplete pagination authorized closure'; exit 1; }
grep -Fq 'closing no terminals' "$tmp/errors"
echo 'ok missing continuation cursor closes no terminals'
for bad_page in \
  '{"ok":false,"result":{"workers":[],"page":{"hasMore":false}}}' \
  '{"ok":true,"result":{"workers":{},"page":{"hasMore":false}}}' \
  '{"ok":true,"result":{"workers":[],"page":{"hasMore":true,"nextCursor":"c2"}}}'; do
  printf '%s\n' "$bad_page" > "$tmp/page2"
  run --apply
  test ! -e "$tmp/closed" || { echo 'FAIL bad page authorized closure'; exit 1; }
  grep -Fq 'closing no terminals' "$tmp/errors"
  echo 'ok failed, malformed or repeated-cursor page closes no terminals'
done
touch "$tmp/fail-page"
run --apply
test ! -e "$tmp/closed"
grep -Fq 'closing no terminals' "$tmp/errors"
echo 'ok CLI failure on a later page closes no terminals'
# Current Orca worker-list rows are flat: state/stage/liveness, terminal handle and workspace, no dispatchStatus.
rm -f "$tmp/fail-page"
flat() { # handle path state liveness
  jq -n --arg h "$1" --arg p "$2" --arg s "$3" --arg l "$4" \
    '{state:$s,liveness:$l,workspace:("repo::"+$p)} + (if $h == "" then {} else {terminal:$h} end)'
}
{
  flat '' /fixture/settled succeeded exited
  flat t-handle /fixture/other succeeded exited
  flat '' /fixture/live succeeded exited
  flat '' /fixture/live ready live
  flat t-own /fixture/own succeeded exited
  flat '' /fixture/lead-work failed exited
  flat '' /fixture/agent ready unverifiable | jq '.stage = "released"'
} | jq -s '{ok:true,result:{workers:.,page:{hasMore:false}}}' > "$tmp/page1"
run --dry-run
expect 'Close terminal t-path (env-a, settled dispatch on this path)'
expect 'Close terminal t-handle (env-a, settled dispatch)'
expect 'Close terminal t-agent (env-a, settled dispatch on this path)'
for pair in 't-live|live dispatch' 't-own|own terminal' 't-lead|lead worktree' 't-unknown|unknown owner, still running'; do
  expect "Kept terminal ${pair%|*} (env-a, ${pair#*|})"
done
echo 'ok flat worker-list rows classify remote terminals like the old shape'
# Live rows: stopped state and terminalState released (no stage) are settled.
{
  flat '' /fixture/settled stopped unverifiable
  flat t-handle /fixture/other ready unverifiable | jq '.terminalState = "released"'
  flat '' /fixture/live succeeded exited
  flat '' /fixture/live ready live
  flat t-own /fixture/own succeeded exited
  flat '' /fixture/lead-work failed exited
  flat '' /fixture/agent ready unverifiable | jq '.stage = "released"'
} | jq -s '{ok:true,result:{workers:.,page:{hasMore:false}}}' > "$tmp/page1"
run --dry-run
expect 'Close terminal t-path (env-a, settled dispatch on this path)'
expect 'Close terminal t-handle (env-a, settled dispatch)'
echo 'ok stopped and terminalState released rows are settled'
# #536: current Orca has no page object. nextCursor is top level and absent on the last page.
current() { jq -s --argjson rest "$1" '{ok:true,result:({workers:.,scope:{run:"run-1",source:"flag"},warnings:[]} + $rest)}'; }
{
  flat '' /fixture/settled succeeded exited
  flat t-handle /fixture/other succeeded exited
} | current '{"nextCursor":"c2","warnings":["Showing 2 of 3 Dispatches, newest first; more are on later pages."]}' > "$tmp/page1"
current '{"nextCursor":"c3"}' < /dev/null > "$tmp/page2"
flat '' /fixture/settled ready live | current '{}' > "$tmp/page3"
rm -f "$tmp/closed"
run --dry-run
expect 'Kept terminal t-path (env-a, live dispatch)'
expect 'Close terminal t-handle (env-a, settled dispatch)'
test ! -e "$tmp/closed"
run --apply
echo t-handle | cmp - "$tmp/closed"
echo 'ok current worker-list shape: nextCursor is followed to the last page before closing'
rm "$tmp/closed"
current '{"nextCursor":7}' < /dev/null > "$tmp/bad-number"
current '{"nextCursor":""}' < /dev/null > "$tmp/bad-empty"
current '{"nextCursor":"c2"}' < /dev/null > "$tmp/bad-repeat"
jq -n '{state:"succeeded",liveness:"exited"} | range(100) as $n | .' | current '{}' > "$tmp/bad-full"
for bad in number empty repeat full; do
  cp "$tmp/bad-$bad" "$tmp/page2"
  run --apply
  test ! -e "$tmp/closed" || { echo "FAIL $bad page authorized closure"; exit 1; }
  grep -Fq 'closing no terminals' "$tmp/errors"
done
echo 'ok bad, repeated or unproven last page in the current shape closes no terminals'
current '{}' < /dev/null > "$tmp/page2"
current '{"nextCursor":"l2"}' < /dev/null > "$tmp/local-page"
rm -f "$tmp/calls"
run --dry-run
grep -Fxq 'orchestration worker-list --cursor l2 --json' "$tmp/calls"
echo 'ok worktree check follows nextCursor too'
cp "$tmp/bad-full" "$tmp/local-page"
run --dry-run
grep -Fq 'worker-list paging incomplete; retaining all worktrees' "$tmp/errors"
echo 'ok worktree check keeps everything when a full page proves no end'
# A bound caller sees only its own Run: wrap-up must read every Run, here and on each environment, before closing.
rm -f "$tmp/local-page"
flat t-handle /fixture/other succeeded exited | current '{}' > "$tmp/page1"
flat '' /fixture/handle ready live | current '{}' > "$tmp/run-two-page"
touch "$tmp/two-runs"
run --dry-run
expect 'Kept terminal t-handle (env-a, live dispatch)'
rm "$tmp/two-runs"
echo 'ok live dispatch in a second Run keeps the terminal'
cp "$tmp/run-two-page" "$tmp/env-page"
run --dry-run
expect 'Kept terminal t-handle (env-a, live dispatch)'
rm "$tmp/env-page"
echo 'ok live dispatch in a Run on an environment keeps the terminal'
for unread in run-fail env-run-fail; do
  touch "$tmp/$unread"
  rm -f "$tmp/closed"
  run --apply
  test ! -e "$tmp/closed" || { echo "FAIL $unread authorized closure"; exit 1; }
  grep -Fq 'closing no terminals' "$tmp/errors"
  rm "$tmp/$unread"
done
echo 'ok an unread Run list on any Orca closes no terminals'
# A coordinator's terminal stays even on a path where every dispatch is settled.
jq '.result.terminals += [{handle:"t-coord",worktreePath:"/fixture/handle",connected:true,writable:true,agentIdentity:"agent"}]' "$tmp/terminals" > "$tmp/terminals.new"
mv "$tmp/terminals.new" "$tmp/terminals"
flat '' /fixture/handle succeeded exited | current '{}' > "$tmp/page1"
run --dry-run
expect 'Kept terminal t-coord (env-a, coordinator)'
echo 'ok coordinator terminal kept'
# A correction pass runs on a settled dispatch: recent output, or an agent with no output time, keeps the terminal.
jq --argjson t "$(($(date +%s) * 1000))" '.result.terminals += [
  {handle:"t-busy",worktreePath:"/fixture/handle",connected:true,writable:true,agentIdentity:"agent",lastOutputAt:$t},
  {handle:"t-untimed",worktreePath:"/fixture/handle",connected:true,writable:true,agentIdentity:"agent"},
  {handle:"t-gone",worktreePath:"/fixture/handle",connected:false,writable:false,agentIdentity:"agent",lastOutputAt:$t}]' "$tmp/terminals" > "$tmp/terminals.new"
mv "$tmp/terminals.new" "$tmp/terminals"
run --dry-run
expect 'Kept terminal t-busy (env-a, recent output)'
expect 'Kept terminal t-untimed (env-a, recent output)'
expect 'Close terminal t-gone (env-a, exited)'
echo 'ok a working agent on a settled path stays'
