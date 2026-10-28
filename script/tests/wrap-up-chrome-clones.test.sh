#!/usr/bin/env bash
# Chrome code_sign_clone cleanup: fake clone dirs and a fake lsof, disposable repo only.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd -P)
tmp=$(mktemp -d)
tmp=$(cd "$tmp" && pwd -P)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
cat > "$tmp/bin/gh" <<'FAKE'
#!/usr/bin/env bash
echo '[]'
FAKE
cat > "$tmp/bin/orca" <<'FAKE'
#!/usr/bin/env bash
case "$*" in
  'terminal list --json') echo '{"ok":true,"result":{"terminals":[]}}' ;;
  *) echo '{"ok":true,"result":{"workers":[],"page":{"hasMore":false}}}' ;;
esac
FAKE
# Fake lsof: reports a holder only for directories whose name contains "held".
cat > "$tmp/bin/lsof" <<'FAKE'
#!/usr/bin/env bash
for last; do :; done
case "$last" in *held*) echo 4242 ;; esac
exit 0
FAKE
chmod +x "$tmp/bin/gh" "$tmp/bin/orca" "$tmp/bin/lsof"
export PATH="$tmp/bin:$PATH" ORCA_CLI_COMMAND="$tmp/bin/orca" HOME="$tmp/home"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export WRAP_UP_SCRATCH_ROOT="$tmp/no-scratch" WRAP_UP_LOOSE_ROOT="$tmp/no-loose"
mkdir -p "$HOME"
git init -q --bare "$tmp/origin"
git init -q -b main "$tmp/repo"
git -C "$tmp/repo" config user.email test@example.invalid
git -C "$tmp/repo" config user.name Test
git -C "$tmp/repo" commit -qm initial --allow-empty
git -C "$tmp/repo" remote add origin "$tmp/origin"
git -C "$tmp/repo" push -qu origin main
clones="$tmp/temp"
export WRAP_UP_CLONE_ROOT="$clones"
mkdir -p "$clones/com.google.Chrome.code_sign_clone/code_sign_clone.stale1" \
  "$clones/com.google.Chrome.code_sign_clone/code_sign_clone.held1" \
  "$clones/com.google.Chrome.dev.code_sign_clone/code_sign_clone.stale2" \
  "$clones/org.other.App.code_sign_clone/code_sign_clone.other"
echo data > "$clones/com.google.Chrome.code_sign_clone/code_sign_clone.stale1/blob"
chrome="$clones/com.google.Chrome.code_sign_clone"
dev="$clones/com.google.Chrome.dev.code_sign_clone"
passed=0; failed=0
check() { if "${@:2}"; then printf 'ok %s\n' "$1"; passed=$((passed+1)); else printf 'FAIL %s\n' "$1"; failed=$((failed+1)); fi; }
has() { grep -Fxq -- "$1" "$tmp/output"; }
cd "$tmp/repo"
bash "$root/script/wrap-up.sh" --dry-run > "$tmp/output"
check 'dry run lists stale clone' has "Remove Chrome clone $chrome/code_sign_clone.stale1"
check 'dry run lists stale clone of another Chrome build' has "Remove Chrome clone $dev/code_sign_clone.stale2"
check 'dry run keeps held clone' has "Kept Chrome clone $chrome/code_sign_clone.held1 (held open by a running process)"
check 'dry run deletes nothing' test -d "$chrome/code_sign_clone.stale1" -a -d "$dev/code_sign_clone.stale2"
bash "$root/script/wrap-up.sh" --apply > "$tmp/output"
check 'apply removes stale clone' test ! -e "$chrome/code_sign_clone.stale1"
check 'apply removes stale clone of another Chrome build' test ! -e "$dev/code_sign_clone.stale2"
check 'apply keeps held clone' test -d "$chrome/code_sign_clone.held1"
check 'apply leaves non Chrome clones alone' test -d "$clones/org.other.App.code_sign_clone/code_sign_clone.other"
check 'counts report chrome clones' has 'chrome clones removed=2 kept=1'
# An lsof that fails (exit 2, no output) must keep the clone: it proves nothing about holders.
mkdir -p "$chrome/code_sign_clone.broken" "$tmp/badbin"
printf '#!/usr/bin/env bash\nexit 2\n' > "$tmp/badbin/lsof"
chmod +x "$tmp/badbin/lsof"
PATH="$tmp/badbin:$PATH" bash "$root/script/wrap-up.sh" --apply > "$tmp/output" 2>&1 || true
check 'failing lsof keeps clone' test -d "$chrome/code_sign_clone.broken"
check 'failing lsof reports reason' has "Kept Chrome clone $chrome/code_sign_clone.broken (lsof failed)"
# A missing lsof must keep everything, never delete blindly.
mkdir -p "$chrome/code_sign_clone.unknown"
mv "$tmp/bin/lsof" "$tmp/lsof.off"
PATH="/usr/bin:/bin" bash "$root/script/wrap-up.sh" --apply > "$tmp/output" 2>&1 || true
check 'no lsof keeps clones' test -d "$chrome/code_sign_clone.unknown"
printf '%s tests passed; %s failed\n' "$passed" "$failed"
test "$failed" -eq 0
