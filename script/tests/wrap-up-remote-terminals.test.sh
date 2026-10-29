#!/usr/bin/env bash
# Public CLI regression: coordinator dispatches own remote terminals too.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd -P)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
mkdir -p "$HOME" "$tmp/bin"
export PATH="$tmp/bin:$PATH" FAKE_DIR="$tmp"
export WRAP_UP_SCRATCH_ROOT="$tmp/no-scratch" WRAP_UP_LOOSE_ROOT="$tmp/no-loose"
export WRAP_UP_CLONE_ROOT="$tmp/no-clones" ORCA_TERMINAL_HANDLE=t-own
cat > "$tmp/bin/gh" <<'STUB'
#!/usr/bin/env bash
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
  'orchestration worker-list --environment '*) echo '{"ok":true,"result":{"workers":[],"page":{"hasMore":false}}}' ;;
  'orchestration worker-list '*)
    if [[ "$*" == *'--cursor c2'* ]] && [ -e "$FAKE_DIR/fail-page" ]; then exit 1; fi
    if [[ "$*" != *--include-remote* ]]; then
      echo '{"ok":true,"result":{"workers":[],"page":{"hasMore":false}}}'
    else
      case "$*" in
        *'--cursor c2'*) cat "$FAKE_DIR/page2" ;;
        *'--cursor c3'*) cat "$FAKE_DIR/page3" ;;
        *) cat "$FAKE_DIR/page1" ;;
      esac
    fi ;;
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
    '{handle:$h,worktreePath:$p,connected:true,writable:true,agentIdentity:$agent}'
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
run() { bash "$root/script/wrap-up.sh" --repo "$tmp/repo" "$@" > "$tmp/output" 2> "$tmp/errors"; }
expect() { grep -Fxq "$1" "$tmp/output" || { echo "FAIL missing: $1"; cat "$tmp/output"; exit 1; }; }
run --dry-run
expect 'Close terminal t-path (env-a, settled dispatch on this path)'
expect 'Close terminal t-handle (env-a, settled dispatch)'
for pair in 't-live|live dispatch' 't-own|own terminal' 't-lead|lead worktree' 't-agent|agent running' 't-unknown|unknown owner, still running'; do
  expect "Kept terminal ${pair%|*} (env-a, ${pair#*|})"
done
test ! -e "$tmp/closed"
echo 'ok coordinator dispatches classify remote handles and paths while preserving keep rules'
run --apply
printf '%s\n' t-handle t-path > "$tmp/expected"
sort "$tmp/closed" | cmp - "$tmp/expected"
echo 'ok apply closes only the two eligible remote terminals through their environment'
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
printf '%s\n' t-handle t-unknown > "$tmp/expected"
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
