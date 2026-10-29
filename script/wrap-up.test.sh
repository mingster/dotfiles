#!/usr/bin/env bash
# shellcheck source=tests/lib/asdf-pin.sh
. "$(cd "$(dirname "$0")" && pwd)/tests/lib/asdf-pin.sh"
# Exercise the public CLI in disposable repositories only.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home" GIT_CONFIG_NOSYSTEM=1
mkdir -p "$HOME" "$tmp/bin"
export PATH="$tmp/bin:$PATH"
cat > "$tmp/bin/gh" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "${FAKE_PRS:-[]}"
FAKE
cat > "$tmp/bin/orca" <<'FAKE'
#!/usr/bin/env bash
case "$*" in
  'terminal list --json') printf '{"ok":true,"result":{"terminals":%s}}\n' "${FAKE_TERMINALS:-[]}" ;;
  'orchestration worker-show'*) printf '%s\n' "$FAKE_SHOW" ;;
  *) printf '{"ok":true,"result":{"workers":%s,"page":{"hasMore":false}}}\n' "${FAKE_WORKERS:-[]}" ;;
esac
FAKE
chmod +x "$tmp/bin/gh" "$tmp/bin/orca"
export ORCA_CLI_COMMAND="$tmp/bin/orca"
export WRAP_UP_CLONE_ROOT="$tmp/no-clones"
export WRAP_UP_SCRATCH_ROOT="$tmp/no-scratch" WRAP_UP_LOOSE_ROOT="$tmp/no-loose"
# Fixture worktrees are all new; 0 turns the recent-activity guard off except in its own case.
export WRAP_UP_RECENT_MIN=0
git init -q --bare "$tmp/origin"
git init -q -b main "$tmp/repo"
cd "$tmp/repo"
git config user.email test@example.invalid
git config user.name Test
echo initial > file
git add file
git commit -qm initial
git remote add origin "$tmp/origin"
git push -q -u origin main
git branch merged
git push -q origin merged
bash "$here/wrap-up.sh" --apply > "$tmp/output"
if git show-ref --verify --quiet refs/heads/merged; then exit 1; fi
if git --git-dir="$tmp/origin" show-ref --verify --quiet refs/heads/merged; then exit 1; fi
echo 'ok merged branch removed locally and remotely'
git checkout -qb unmerged
echo change >> file
git commit -qam unmerged
git push -q origin unmerged
git checkout -q main
bash "$here/wrap-up.sh" --apply > "$tmp/output"
git show-ref --verify --quiet refs/heads/unmerged
git --git-dir="$tmp/origin" show-ref --verify --quiet refs/heads/unmerged
echo 'ok unmerged branch kept locally and remotely'
for branch in master staging production web2/topic feature/staging feature/production; do
  git branch "$branch"
  git push -q origin "$branch"
done
bash "$here/wrap-up.sh" --apply > "$tmp/output"
for branch in main master staging production web2/topic feature/staging feature/production; do
  git show-ref --verify --quiet "refs/heads/$branch"
  git --git-dir="$tmp/origin" show-ref --verify --quiet "refs/heads/$branch"
done
echo 'ok all protected branch patterns kept'
git worktree add -qb dirty "$tmp/dirty worktree"
git push -q origin dirty
echo dirty > "$tmp/dirty worktree/untracked"
bash "$here/wrap-up.sh" --apply > "$tmp/output"
test -f "$tmp/dirty worktree/untracked"
git show-ref --verify --quiet refs/heads/dirty
git --git-dir="$tmp/origin" show-ref --verify --quiet refs/heads/dirty
echo 'ok dirty worktree and both branches kept'
git worktree add -qb finished "$tmp/finished worktree"
bash "$here/wrap-up.sh" --apply > "$tmp/output"
test ! -d "$tmp/finished worktree"
if git show-ref --verify --quiet refs/heads/finished; then exit 1; fi
echo 'ok clean merged worktree removed'
git worktree add -qb active "$tmp/active"
export FAKE_TERMINALS="[{\"worktreePath\":\"$tmp/active\"}]"
bash "$here/wrap-up.sh" --apply > "$tmp/output"
test -d "$tmp/active"
git show-ref --verify --quiet refs/heads/active
echo 'ok active Orca worktree kept'
git branch closed unmerged
git branch reopened unmerged
git push -q origin closed reopened
export FAKE_PRS='[{"headRefName":"closed","state":"CLOSED"},{"headRefName":"reopened","state":"CLOSED"},{"headRefName":"reopened","state":"OPEN"}]'
bash "$here/wrap-up.sh" --apply > "$tmp/output"
if git show-ref --verify --quiet refs/heads/closed; then exit 1; fi
if git --git-dir="$tmp/origin" show-ref --verify --quiet refs/heads/closed; then exit 1; fi
echo 'ok closed PR allows deleting unmerged local and remote branches'
git show-ref --verify --quiet refs/heads/reopened
git --git-dir="$tmp/origin" show-ref --verify --quiet refs/heads/reopened
echo 'ok open PR overrides historical closed PR'
mkdir -p "$HOME/.claude/skills/orca-team"
cat > "$HOME/.claude/skills/orca-team/worker-pane-close.sh" <<'FAKE'
#!/usr/bin/env bash
test "$#" -eq 0
touch "$HOME/panes-closed"
FAKE
git branch preview
git push -q origin preview
git worktree add -qb preview-wt "$tmp/preview"
git show-ref > "$tmp/refs-before"
git --git-dir="$tmp/origin" show-ref > "$tmp/origin-before"
git worktree list --porcelain > "$tmp/trees-before"
bash "$here/wrap-up.sh" > "$tmp/output"
git show-ref > "$tmp/refs-after"
git --git-dir="$tmp/origin" show-ref > "$tmp/origin-after"
git worktree list --porcelain > "$tmp/trees-after"
cmp "$tmp/refs-before" "$tmp/refs-after"
cmp "$tmp/origin-before" "$tmp/origin-after"
cmp "$tmp/trees-before" "$tmp/trees-after"
test ! -f "$HOME/panes-closed"
echo 'ok default dry run preserves branches worktrees and panes'
bash "$here/wrap-up.sh" --dry-run > "$tmp/output"
test ! -f "$HOME/panes-closed"
echo 'ok explicit dry run preserves panes'
bash "$here/wrap-up.sh" --apply > "$tmp/output"
test -f "$HOME/panes-closed"
echo 'ok apply invokes pane cleanup without arguments'
git clone -q --branch main "$tmp/origin" "$tmp/updater"
git -C "$tmp/updater" config user.email test@example.invalid
git -C "$tmp/updater" config user.name Test
echo next >> "$tmp/updater/file"
git -C "$tmp/updater" commit -qam next
git -C "$tmp/updater" push -q origin main
before=$(git rev-parse HEAD)
echo dirty-main > dirty-main
bash "$here/wrap-up.sh" --apply > "$tmp/output"
test "$(git rev-parse HEAD)" = "$before"
echo 'ok dirty main checkout does not pull'
rm dirty-main
bash "$here/wrap-up.sh" --apply > "$tmp/output"
test "$(git rev-parse HEAD)" = "$(git --git-dir="$tmp/origin" rev-parse main)"
echo 'ok clean main fast forwards'
git worktree add -qb lq-merged "$tmp/lead-queue"
bash "$here/wrap-up.sh" --apply > "$tmp/output"
test -d "$tmp/lead-queue"
git show-ref --verify --quiet refs/heads/lq-merged
echo 'ok lead-queue worktree kept even when merged and clean'
git worktree add -qb lx-merged "$tmp/lead-x"
bash "$here/wrap-up.sh" --apply > "$tmp/output"
test -d "$tmp/lead-x"
git show-ref --verify --quiet refs/heads/lx-merged
echo 'ok lead-* worktree kept even when merged and clean'
git worktree add -q --detach "$tmp/live-merge" HEAD
WRAP_UP_RECENT_MIN=30 bash "$here/wrap-up.sh" --apply > "$tmp/output"
test -d "$tmp/live-merge"
grep -q "live-merge (changed in the last 30 minutes)" "$tmp/output"
echo 'ok detached merged worktree with recent activity kept (a live lead may be editing)'
bash "$here/wrap-up.sh" --apply > "$tmp/output"
test ! -d "$tmp/live-merge"
echo 'ok same worktree removed once the guard window has passed'
git worktree add -qb settled "$tmp/settled"
export FAKE_TERMINALS="[{\"handle\":\"ended\",\"worktreePath\":\"$tmp/settled\"}]"
export FAKE_WORKERS='[{"agentTerminalHandle":"ended","dispatchId":"ctx_done","dispatchStatus":"completed"}]'
bash "$here/wrap-up.sh" --apply > "$tmp/output"
test ! -d "$tmp/settled"
echo 'ok settled dispatch terminal does not block cleanup'
git worktree add -qb live "$tmp/live"
export FAKE_TERMINALS='[]'
export FAKE_WORKERS='[{"dispatchId":"ctx_live","dispatchStatus":"dispatched"}]'
export FAKE_SHOW="{\"result\":{\"dispatch\":{\"status\":\"dispatched\"},\"terminal\":{\"cwd\":\"$tmp/live\"}}}"
bash "$here/wrap-up.sh" --apply > "$tmp/output"
test -d "$tmp/live"
echo 'ok active worker-show cwd blocks cleanup'
echo '15 tests passed'  
export TEAM_OBSERVATIONS_FILE="$tmp/obs.md"
git branch leftover
git push -q origin leftover
bash "$here/wrap-up.sh" --apply > "$tmp/output"
test ! -e "$tmp/obs.md"
echo 'ok wrap-up --apply writes no team observation (it runs every wake; leftovers are its job)'
git branch leftover2
bash "$here/wrap-up.sh" > "$tmp/output"
test ! -e "$tmp/obs.md"
echo 'ok a preview writes no team observation'
git worktree add -q --detach "$tmp/review" main
git worktree add -q --detach "$tmp/_checks" main
git worktree add -q --detach "$tmp/detached-dirty" main
echo dirty > "$tmp/detached-dirty/untracked"
git worktree add -q --detach "$tmp/detached-ahead" main
git -C "$tmp/detached-ahead" commit -q --allow-empty -m ahead
bash "$here/wrap-up.sh" --apply > "$tmp/output"
test ! -d "$tmp/review"
echo 'ok clean detached worktree at a merged commit removed'
test -d "$tmp/_checks"
echo 'ok script-owned _ worktree kept'
test -d "$tmp/detached-dirty"
echo 'ok dirty detached worktree kept'
test -d "$tmp/detached-ahead"
echo 'ok detached worktree with unmerged commits kept'
# Finished terminals close on the local host and every listed environment. The stub never touches a real terminal.
fake="$tmp/fake-orca"; mkdir -p "$fake"
cat > "$tmp/bin/orca-envs" <<'FAKE'
#!/usr/bin/env bash
env=local; args=("$@")
for i in "${!args[@]}"; do [ "${args[$i]}" = --environment ] && env=${args[$((i+1))]}; done
case "$*" in
  'environment list'*) printf '{"ok":true,"result":{"environments":[{"id":"env-a","name":"a"},{"id":"env-b","name":"b"}]}}\n' ;;
  *'terminal list'*) printf '{"ok":true,"result":{"terminals":%s}}\n' "$(cat "$FAKE_DIR/$env.terminals")" ;;
  *'terminal close'*)
    for i in "${!args[@]}"; do [ "${args[$i]}" = --terminal ] && h=${args[$((i+1))]}; done
    echo "$env $h" >> "$FAKE_DIR/closed.log"
    jq -c --arg h "$h" 'map(select(.handle != $h))' "$FAKE_DIR/$env.terminals" > "$FAKE_DIR/$env.tmp" && mv "$FAKE_DIR/$env.tmp" "$FAKE_DIR/$env.terminals" ;;
  *worker-show*) printf '{"ok":true,"result":{"dispatch":{"status":"completed"}}}\n' ;;
  *worker-list*) printf '{"ok":true,"result":{"workers":%s,"page":{"hasMore":false}}}\n' "$(cat "$FAKE_DIR/$env.workers")" ;;
esac
FAKE
chmod +x "$tmp/bin/orca-envs"
export FAKE_DIR="$fake" ORCA_CLI_COMMAND="$tmp/bin/orca-envs" ORCA_TERMINAL_HANDLE=t-own
t() { printf '{"handle":"%s","worktreePath":"/nowhere/%s","connected":true,"writable":%s}' "$1" "$1" "${2:-true}"; }
w() { printf '{"agentTerminalHandle":"%s","dispatchId":"d-%s","dispatchStatus":"%s"}' "$1" "$1" "$2"; }
echo "[$(t t-own),$(t t-done),$(t t-live),$(t t-unknown),$(t t-exited false)]" > "$fake/local.terminals"
echo "[$(w t-own completed),$(w t-done completed),$(w t-live dispatched)]" > "$fake/local.workers"
echo "[$(t e1-done),$(t e1-unknown),$(t e1-exited false)]" > "$fake/env-a.terminals"
echo "[$(w e1-done failed)]" > "$fake/env-a.workers"
echo "[$(t e2-gone),$(t e2-live)]" > "$fake/env-b.terminals"
echo "[$(w e2-gone released),$(w e2-live dispatched)]" > "$fake/env-b.workers"
bash "$here/wrap-up.sh" --dry-run > "$tmp/output"
test ! -e "$fake/closed.log"
for want in 'Close terminal t-done (local, settled dispatch)' 'Close terminal t-exited (local, exited)' \
  'Close terminal e1-done (env-a, settled dispatch)' 'Close terminal e1-exited (env-a, exited)' 'Close terminal e2-gone (env-b, settled dispatch)'; do
  grep -Fxq "$want" "$tmp/output" || { echo "missing: $want"; exit 1; }
done
grep -q 'terminals closed=5 kept=' "$tmp/output"
echo 'ok dry run lists finished terminals on two environments and closes nothing'
bash "$here/wrap-up.sh" --apply > "$tmp/output"
sort "$fake/closed.log" > "$tmp/closed"
printf '%s\n' 'env-a e1-done' 'env-a e1-exited' 'env-b e2-gone' 'local t-done' 'local t-exited' | cmp - "$tmp/closed"
for kept in t-own t-live t-unknown e1-unknown e2-live; do
  grep -q "Kept terminal $kept" "$tmp/output" || { echo "not reported kept: $kept"; exit 1; }
done
grep -q 'terminals closed=5 kept=5' "$tmp/output"
echo 'ok apply closes settled and exited terminals; own, live and unknown-running kept'
# Real orca output differs from the cases above: a released dispatch has no agentTerminalHandle, its leftover terminals
# still report connected and writable with no agent identity, and a pane from worker-pane.sh is just such a terminal.
# So terminals are linked to dispatches by worktree path. worker-list is newest first and read for 2 pages only.
rm -rf "$fake"; mkdir -p "$fake"
cat > "$tmp/bin/orca-real" <<'FAKE'
#!/usr/bin/env bash
args=("$@"); cursor=''
for i in "${!args[@]}"; do [ "${args[$i]}" = --cursor ] && cursor=${args[$((i+1))]}; done
case "$*" in
  'environment list'*) echo '{"ok":true,"result":{"environments":[]}}' ;;
  *'terminal list'*) printf '{"ok":true,"result":{"terminals":%s}}\n' "$(cat "$FAKE_DIR/terminals")" ;;
  *'terminal close'*)
    for i in "${!args[@]}"; do [ "${args[$i]}" = --terminal ] && echo "${args[$((i+1))]}" >> "$FAKE_DIR/closed.log"; done ;;
  *worker-show*) printf '{"ok":true,"result":{"dispatch":{"status":"completed"}}}\n' ;;
  *worker-list*)
    echo "$*" >> "$FAKE_DIR/list.log"
    case "$cursor" in
      '') page=1; more=true; next=c2 ;; c2) page=2; more=true; next=c3 ;; *) page=3; more=false; next=null ;;
    esac
    printf '{"ok":true,"result":{"workers":%s,"page":{"hasMore":%s,"nextCursor":"%s"}}}\n' "$(cat "$FAKE_DIR/workers$page")" "$more" "$next" ;;
esac
FAKE
chmod +x "$tmp/bin/orca-real"
export ORCA_CLI_COMMAND="$tmp/bin/orca-real"
rt() { printf '{"handle":"%s","title":"%s","worktreePath":"/nowhere/%s","connected":true,"writable":true,"agentIdentity":%s}' "$1" "$3" "$2" "${4:-null}"; }
rw() { printf '{"agentTerminalHandle":null,"dispatchId":"d-%s-%s","dispatchStatus":"%s","projection":{"workspace":{"id":"repo-1::/nowhere/%s"}}}' "$1" "$3" "$2" "$1"; }
echo "[$(rt t-own p-own x),$(rt t-shell p-rel '~/p-rel'),$(rt t-pane p-rel 'worker-pane.sh d-p-rel-a'),$(rt t-agent p-rel claude '"claude"'),$(rt t-mixed p-mix '~/p-mix'),$(rt t-none p-none '~/p-none'),$(rt t-lead lead-x '~/lead-x'),$(rt t-late p-late '~/p-late')]" > "$fake/terminals"
echo "[$(rw p-own released a),$(rw p-rel released a),$(rw p-rel failed b),$(rw p-mix released a)]" > "$fake/workers1"
echo "[$(rw p-mix dispatched b),$(rw lead-x completed a)]" > "$fake/workers2"
echo "[$(rw p-late completed a)]" > "$fake/workers3"
bash "$here/wrap-up.sh" --apply > "$tmp/output"
sort "$fake/closed.log" > "$tmp/closed"
printf '%s\n' t-pane t-shell | cmp - "$tmp/closed"
for kept in t-own t-agent t-mixed t-none t-lead t-late; do
  grep -q "Kept terminal $kept" "$tmp/output" || { echo "not reported kept: $kept"; exit 1; }
done
grep -Fq 'Close terminal t-pane (local, settled worker pane)' "$tmp/output"
grep -Fq 'Kept terminal t-none (local, unknown owner, still running)' "$tmp/output"
grep -q 'terminals closed=2 kept=6' "$tmp/output"
grep -q -- '--limit 100' "$fake/list.log"
echo 'ok released dispatch without a handle: terminals linked by path; panes close; live, agent, lead and unknown paths kept'
# #386: a dry run left every worktree with a leftover terminal on a released dispatch as "active or unknown", because
# the terminal it plans to close was still open when the worktree check ran. Apply closes it first, so the preview must agree.
for n in rel-shell rel-none live-term unk-term; do git worktree add -q --detach "$tmp/$n" main; done
git worktree add -q --detach "$tmp/live-disp" main
rm -rf "$fake"; mkdir -p "$fake"
echo "[{\"handle\":\"t-own\",\"title\":\"x\",\"worktreePath\":\"$tmp/own\",\"connected\":true,\"writable\":true,\"agentIdentity\":null},{\"handle\":\"t-rel\",\"title\":\"~/rel\",\"worktreePath\":\"$tmp/rel-shell\",\"connected\":true,\"writable\":true,\"agentIdentity\":null},{\"handle\":\"t-live\",\"title\":\"~/l\",\"worktreePath\":\"$tmp/live-term\",\"connected\":true,\"writable\":true,\"agentIdentity\":\"claude\"},{\"handle\":\"t-unk\",\"title\":\"~/u\",\"worktreePath\":\"$tmp/unk-term\",\"connected\":true,\"writable\":true,\"agentIdentity\":null}]" > "$fake/terminals"
rw2() { printf '{"agentTerminalHandle":null,"dispatchId":"d-%s","dispatchStatus":"%s","projection":{"workspace":{"id":"repo-1::%s/%s"}}}' "$1" "$2" "$tmp" "$1"; }
echo "[$(rw2 rel-shell released),$(rw2 rel-none released),$(rw2 live-term released),$(rw2 live-disp dispatched)]" > "$fake/workers1"
echo '[]' > "$fake/workers2"; echo '[]' > "$fake/workers3"
cat > "$tmp/bin/orca-real" <<'FAKE'
#!/usr/bin/env bash
args=("$@"); cursor=''
for i in "${!args[@]}"; do [ "${args[$i]}" = --cursor ] && cursor=${args[$((i+1))]}; done
case "$*" in
  'environment list'*) echo '{"ok":true,"result":{"environments":[]}}' ;;
  *'terminal list'*) printf '{"ok":true,"result":{"terminals":%s}}\n' "$(cat "$FAKE_DIR/terminals")" ;;
  *'terminal close'*) ;;
  *worker-show*) case "$*" in *d-pend*|*d-bad*) exit 1 ;; *d-live-disp*) printf '{"ok":true,"result":{"dispatch":{"status":"dispatched"},"terminal":{"cwd":"%s"}}}\n' "$FAKE_LIVE_CWD" ;; *) printf '{"ok":true,"result":{"dispatch":{"status":"completed"}}}\n' ;; esac ;;
  *worker-list*)
    case "$cursor" in '') page=1; more=false ;; esac
    [ ! -e "$FAKE_DIR/shape" ] || { cat "$FAKE_DIR/shape"; exit 0; }
    printf '{"ok":true,"result":{"workers":%s,"page":{"hasMore":false,"nextCursor":null}}}\n' "$(cat "$FAKE_DIR/workers1")" ;;
esac
FAKE
real=$(cd "$tmp" && pwd -P)
export FAKE_LIVE_CWD="$tmp/live-disp"
bash "$here/wrap-up.sh" --dry-run > "$tmp/output"
grep -Fq "Remove worktree $real/rel-shell" "$tmp/output" || { echo 'released dispatch with a closable leftover terminal still kept in preview'; exit 1; }
grep -Fq "Remove worktree $real/rel-none" "$tmp/output" || { echo 'released dispatch with no terminal kept'; exit 1; }
grep -Fq "Kept worktree $real/live-term (active or unknown Orca terminal)" "$tmp/output"
grep -Fq "Kept worktree $real/unk-term (active or unknown Orca terminal)" "$tmp/output"
grep -Fq "Kept worktree $real/live-disp (active or unknown Orca terminal)" "$tmp/output"
echo 'ok preview frees a worktree whose only terminal is a finished one; agent, unknown owner and live dispatch kept'
# A pending dispatch has no worker and no worktree, so a failed worker-show on it must not keep every worktree.
rw3() { printf '{"agentTerminalHandle":null,"dispatchId":"d-%s","dispatchStatus":"%s","projection":{"workspace":null}}' "$1" "$2"; }
echo "[$(rw2 rel-shell released),$(rw2 rel-none released),$(rw2 live-term released),$(rw2 live-disp dispatched),$(rw3 pend-1 pending)]" > "$fake/workers1"
bash "$here/wrap-up.sh" --dry-run > "$tmp/output" 2> "$tmp/stderr"
grep -Fq "Warning: worker-show failed for pending dispatch d-pend-1; skipped." "$tmp/stderr"
grep -Fq "Remove worktree $real/rel-none" "$tmp/output" || { echo 'pending dispatch with failed worker-show kept every worktree'; exit 1; }
grep -Fq "Kept worktree $real/live-disp (active or unknown Orca terminal)" "$tmp/output"
echo 'ok pending dispatch with failed worker-show is skipped with a warning'
# Any other worker-show failure still keeps everything, now with a warning.
echo "[$(rw2 rel-none released),$(rw3 bad-1 dispatched)]" > "$fake/workers1"
bash "$here/wrap-up.sh" --dry-run > "$tmp/output" 2> "$tmp/stderr"
grep -Fq "Warning: worker-show failed for d-bad-1; retaining all worktrees." "$tmp/stderr"
if grep -Fq "Remove worktree $real/rel-none" "$tmp/output"; then echo 'failed worker-show on a dispatched dispatch freed a worktree'; exit 1; fi
echo 'ok other worker-show failures keep all worktrees with a warning'
# A worker-list page of the wrong shape keeps everything and says so.
echo '{"ok":true,"result":{"workers":"x"}}' > "$fake/shape"
bash "$here/wrap-up.sh" --dry-run > "$tmp/output" 2> "$tmp/stderr"
grep -Fq "Warning: unexpected worker-list page shape; retaining all worktrees." "$tmp/stderr"
if grep -Fq "Remove worktree $real/rel-none" "$tmp/output"; then echo 'bad page shape freed a worktree'; exit 1; fi
rm -f "$fake/shape"
echo 'ok malformed worker-list page keeps all worktrees with a warning'
# #389: --fleet runs worktree and local branch cleanup on each configured host over a transport. The transport is a fake
# that runs the remote command on this machine; the test never opens a real ssh connection.
export ORCA_CLI_COMMAND="$tmp/bin/orca"
unset FAKE_TERMINALS FAKE_PRS FAKE_WORKERS
git init -q --bare "$tmp/origin2"
git clone -q "$tmp/origin2" "$tmp/rrepo" 2>/dev/null
git -C "$tmp/rrepo" config user.email test@example.invalid
git -C "$tmp/rrepo" config user.name Test
git -C "$tmp/rrepo" checkout -qb main
echo r > "$tmp/rrepo/file"; git -C "$tmp/rrepo" add file; git -C "$tmp/rrepo" commit -qm initial
git -C "$tmp/rrepo" push -q -u origin main
git -C "$tmp/rrepo" branch rdone; git -C "$tmp/rrepo" push -q origin rdone
git -C "$tmp/rrepo" worktree add -q "$tmp/rwt" rdone
git -C "$tmp/rrepo" worktree add -qb rdirty "$tmp/rwt-dirty"; echo x > "$tmp/rwt-dirty/untracked"
cat > "$tmp/bin/fake-ssh" <<'FAKE'
#!/usr/bin/env bash
# Drops ssh options, records the host, fails for the host named down, otherwise runs the remote command here.
while [ "${1:-}" = -o ]; do shift 2; done
host=$1; shift
echo "$host" >> "$FAKE_SSH_LOG"
[ "$host" != down ] || { echo 'ssh: connect to host down: No route to host' >&2; exit 255; }
# ssh joins its words and the remote login shell parses them.
exec sh -c "$*"
FAKE
chmod +x "$tmp/bin/fake-ssh"
export WRAP_UP_FLEET_SSH="$tmp/bin/fake-ssh" FAKE_SSH_LOG="$tmp/ssh.log" DOTFILES_DIR="$(cd "$here/.." && pwd)"
: > "$FAKE_SSH_LOG"
printf '{"hosts":[{"host":"down","repo_dir":"~/nowhere"},{"host":"alpha","repo_dir":"%s"}]}\n' "$tmp/rrepo" > "$tmp/fleet.json"
export WRAP_UP_FLEET_CONFIG="$tmp/fleet.json"
cd "$tmp/repo"
bash "$here/wrap-up.sh" --dry-run --fleet > "$tmp/output" 2> "$tmp/stderr"
grep -Fxq '== Fleet host alpha ==' "$tmp/output"
grep -Fq "Remove worktree $real/rwt " "$tmp/output" || { echo 'fleet preview did not propose the remote worktree'; exit 1; }
grep -Fq "Kept worktree $real/rwt-dirty (dirty)" "$tmp/output"
test -d "$tmp/rwt"
echo 'ok fleet preview runs per host and changes nothing'
grep -Fq 'Warning: fleet host down unreachable or incomplete' "$tmp/stderr"
grep -Fxq down "$FAKE_SSH_LOG"
grep -Fq 'Fleet total (local plus 1 of 2 hosts reached)' "$tmp/output"
echo 'ok unreachable host only warns and is skipped'
bash "$here/wrap-up.sh" --apply --fleet > "$tmp/output" 2> "$tmp/stderr"
test ! -d "$tmp/rwt"
if git -C "$tmp/rrepo" show-ref --verify --quiet refs/heads/rdone; then echo 'remote host kept a merged local branch'; exit 1; fi
test -d "$tmp/rwt-dirty"
echo 'ok fleet apply removes the host worktree and local branch, keeps the dirty one'
git --git-dir="$tmp/origin2" show-ref --verify --quiet refs/heads/rdone || { echo 'fleet host deleted a remote branch'; exit 1; }
grep -Fq 'removed worktrees=1 deleted local=1 deleted remote=0' "$tmp/output"
echo 'ok fleet host never deletes remote branches'
grep -Fq 'Fleet total' "$tmp/output"
if bash "$here/wrap-up.sh" --fleet --worktrees-only >/dev/null 2>&1; then echo '--fleet and --worktrees-only accepted together'; exit 1; fi
rm "$tmp/fleet.json"
bash "$here/wrap-up.sh" --dry-run --fleet > "$tmp/output" 2> "$tmp/stderr"
grep -Fq 'fleet config' "$tmp/stderr"
echo 'ok missing fleet config warns and the local run still succeeds'
