#!/usr/bin/env bash
# shellcheck source=lib/asdf-pin.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/asdf-pin.sh"
# Public CLI, hermetic holder tools and disposable repositories only.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd -P)
tmp=$(mktemp -d)
tmp=$(cd "$tmp" && pwd -P)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/home"
# Include system tools without ever inheriting a real holder tool.
for tool in /bin/* /usr/bin/*; do
  case "${tool##*/}" in lsof|fuser|ps|gh|orca) continue ;; esac
  [ ! -x "$tool" ] || [ -d "$tool" ] || ln -sf "$tool" "$tmp/bin/${tool##*/}"
done
ln -sf "$(command -v jq)" "$tmp/bin/jq"
cat > "$tmp/bin/gh" <<'FAKE'
#!/bin/bash
case "$*" in
  'repo view --json defaultBranchRef') echo '{"defaultBranchRef":{"name":"main"}}' ;;
  'api repos/{owner}/{repo}/pages') echo '{"source":null}' ;;
  *) echo '[]' ;;
esac
FAKE
cat > "$tmp/bin/orca" <<'FAKE'
#!/bin/bash
case "$*" in
  'terminal list --json') echo '{"ok":true,"result":{"terminals":[]}}' ;;
  *) echo '{"ok":true,"result":{"workers":[],"page":{"hasMore":false}}}' ;;
esac
FAKE
printf '#!/bin/bash\nexit 0\n' > "$tmp/bin/ps"
cat > "$tmp/bin/fuser" <<'FAKE'
#!/bin/bash
printf '%s\n' "$*" >> "$FAKE_FUSER_LOG"
for entry; do
  if [ "$entry" = -- ]; then
    printf 'No process specification given\nUsage: fuser [options] name ...\n' >&2
    exit 1
  fi
done
case "${FAKE_FUSER_MODE:-idle}" in
  busy) for entry; do
    case "$entry" in */finished/nested|*/code_sign_clone.idle) printf '%s: ' "$entry" >&2; echo 4242; exit 0 ;; esac
  done ;;
  late) for entry; do
    case "$entry" in */large/599) printf '%s: ' "$entry" >&2; echo 4242; exit 0 ;; esac
  done ;;
  stderr) echo 'fuser: permission denied' >&2 ;;
  error) exit 2 ;;
esac
exit 1
FAKE
chmod +x "$tmp/bin/gh" "$tmp/bin/orca" "$tmp/bin/ps" "$tmp/bin/fuser"
export PATH="$tmp/bin" HOME="$tmp/home" ORCA_CLI_COMMAND="$tmp/bin/orca"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 WRAP_UP_RECENT_MIN=0
export WRAP_UP_SCRATCH_ROOT="$tmp/no-scratch" WRAP_UP_LOOSE_ROOT="$tmp/no-loose"
export WRAP_UP_CLONE_ROOT="$tmp/clones" WRAP_UP_STATE_DIR="$tmp/state"
export WRAP_UP_TEST_PROC_ROOT="$tmp/proc" FAKE_FUSER_LOG="$tmp/fuser-log"
# OSTYPE is set only in this test process, so Linux paths are covered on macOS too.
export OSTYPE=linux-gnu
git init -q --bare "$tmp/origin"
git init -q -b main "$tmp/repo"
git -C "$tmp/repo" config user.email test@example.invalid
git -C "$tmp/repo" config user.name Test
git -C "$tmp/repo" commit -qm initial --allow-empty
git -C "$tmp/repo" remote add origin "$tmp/origin"
git -C "$tmp/repo" push -qu origin main
git -C "$tmp/repo" worktree add -qb finished "$tmp/finished"
mkdir -p "$tmp/finished/nested" "$tmp/clones/com.google.Chrome.code_sign_clone/code_sign_clone.idle"
clone="$tmp/clones/com.google.Chrome.code_sign_clone/code_sign_clone.idle"
passed=0; failed=0
check() { if "${@:2}"; then echo "ok $1"; passed=$((passed+1)); else echo "FAIL $1"; failed=$((failed+1)); fi; }
has() { grep -Fq -- "$1" "$tmp/output"; }
run() { /bin/bash "$root/script/wrap-up.sh" --repo "$tmp/repo" --dry-run > "$tmp/output" 2>&1; }
run
check 'fuser idle permits worktree removal preview' has "Remove worktree $tmp/finished (ancestor)"
check 'fuser idle permits Chrome clone removal preview' has "Remove Chrome clone $clone"
check 'fuser visits nested directories' grep -Fq -- "$tmp/finished/nested" "$FAKE_FUSER_LOG"
check 'working fallback suppresses keep-all summary' bash -c '! grep -q "^lsof unavailable:" "$1"' _ "$tmp/output"
FAKE_FUSER_MODE=busy run
check 'fuser holder in nested cwd keeps worktree' has "Kept worktree $tmp/finished (held open by a running process)"
check 'fuser holder keeps Chrome clone' has "Kept Chrome clone $clone (held open by a running process)"
for mode in stderr error; do
  FAKE_FUSER_MODE=$mode run
  check "fuser $mode keeps worktree" has "Kept worktree $tmp/finished (fuser failed)"
  check "fuser $mode keeps Chrome clone" has "Kept Chrome clone $clone (fuser failed)"
done
# A large fallback tree must not spawn one holder process for every file.
mkdir "$clone/large"
for ((i=0; i<600; i++)); do : > "$clone/large/$i"; done
: > "$FAKE_FUSER_LOG"
run
check 'large fallback tree remains removable' has "Remove Chrome clone $clone"
check 'large fallback tree uses fewer than 20 fuser processes' test "$(wc -l < "$FAKE_FUSER_LOG")" -lt 20
FAKE_FUSER_MODE=late run
check 'holder in a later batch keeps clone' has "Kept Chrome clone $clone (held open by a running process)"
# macOS still requires lsof even if fuser is installed.
OSTYPE=darwin run
check 'macOS missing lsof keeps worktree' has "Kept worktree $tmp/finished (lsof unavailable)"
# A complete proc inventory takes priority even when fuser would fail.
export FAKE_FUSER_MODE=error
: > "$FAKE_FUSER_LOG"
mkdir -p "$tmp/proc/123/fd" "$tmp/elsewhere"
ln -s "$tmp/elsewhere" "$tmp/proc/123/cwd"
ln -s / "$tmp/proc/123/root"
ln -s "$tmp/elsewhere" "$tmp/proc/123/fd/0"
run
check 'proc idle permits worktree removal preview' has "Remove worktree $tmp/finished (ancestor)"
check 'proc idle permits Chrome clone removal preview' has "Remove Chrome clone $clone"
check 'large proc tree never invokes fuser' test ! -s "$FAKE_FUSER_LOG"
check 'proc fallback suppresses keep-all summary' bash -c '! grep -q "^lsof unavailable:" "$1"' _ "$tmp/output"
rm -rf "$clone/large"
# A literal filename suffix must not be confused with Linux's deleted marker.
mkdir "$clone (deleted)"
rm "$tmp/proc/123/fd/0"
ln -s "$clone (deleted)" "$tmp/proc/123/fd/0"
run
check 'proc preserves a holder whose path literally ends in deleted marker' has "Kept Chrome clone $clone (deleted) (held open by a running process)"
rm -rf "$clone (deleted)"
rm "$tmp/proc/123/fd/0"
ln -s "$tmp/elsewhere" "$tmp/proc/123/fd/0"
for link in cwd root fd/0; do
  rm "$tmp/proc/123/$link"
  ln -s "$tmp/finished/nested" "$tmp/proc/123/$link"
  run
  check "proc $link holder keeps worktree" has "Kept worktree $tmp/finished (held open by a running process)"
  rm "$tmp/proc/123/$link"
  ln -s "$tmp/elsewhere" "$tmp/proc/123/$link"
done
rm "$tmp/proc/123/fd/0"
ln -s "$clone/blob (deleted)" "$tmp/proc/123/fd/0"
run
check 'proc deleted open file keeps clone' has "Kept Chrome clone $clone (held open by a running process)"
rm "$tmp/proc/123/fd/0"
ln -s "$tmp/finished-sibling" "$tmp/proc/123/fd/0"
run
check 'proc sibling prefix does not keep worktree' has "Remove worktree $tmp/finished (ancestor)"
# A failed readlink must retain actual items even under --apply in the fixture.
rm "$tmp/proc/123/cwd"
/bin/bash "$root/script/wrap-up.sh" --repo "$tmp/repo" --apply > "$tmp/output" 2>&1
check 'unreadable proc state keeps worktree with reason' has "Kept worktree $tmp/finished (proc inspection failed)"
check 'unreadable proc state keeps clone with reason' has "Kept Chrome clone $clone (proc inspection failed)"
check 'error apply retains fixture worktree and clone' test -d "$tmp/finished" -a -d "$clone"
mkdir -p "$tmp/empty-proc"
WRAP_UP_TEST_PROC_ROOT="$tmp/empty-proc" run
check 'empty proc inventory keeps worktree' has "Kept worktree $tmp/finished (proc inspection failed)"
check 'empty proc inventory keeps clone' has "Kept Chrome clone $clone (proc inspection failed)"
rm "$tmp/bin/fuser"
WRAP_UP_TEST_PROC_ROOT="$tmp/no-proc" run
check 'no holder tools or proc keeps worktree' has "Kept worktree $tmp/finished (lsof unavailable)"
check 'no holder tools or proc keeps counted summary' has 'lsof unavailable: kept all worktrees=2 and Chrome clones=1'
printf '%s tests passed; %s failed\n' "$passed" "$failed"
test "$failed" -eq 0
