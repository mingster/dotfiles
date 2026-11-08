#!/usr/bin/env bash
# shellcheck source=lib/asdf-pin.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/asdf-pin.sh"
# Chrome code_sign_clone cleanup: fake clone dirs and a fake lsof, disposable repo only.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd -P)
tmp=$(mktemp -d)
tmp=$(cd "$tmp" && pwd -P)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
cat > "$tmp/bin/gh" <<'FAKE'
#!/usr/bin/env bash
case "$*" in
  'repo view --json defaultBranchRef') echo '{"defaultBranchRef":{"name":"main"}}'; exit 0 ;;
  'api repos/{owner}/{repo}/pages') echo '{"source":null}'; exit 0 ;;
  'api --paginate repos/{owner}/{repo}/branches?protected=true&per_page=100') echo '[]'; exit 0 ;;
esac
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
hermetic_bin() {
  mkdir -p "$tmp/hermetic"
  for tool in jq git bash ps mktemp dirname sed awk grep printf test rm mkdir cat tr wc readlink; do
    command -v "$tool" >/dev/null 2>&1 && ln -sf "$(command -v "$tool")" "$tmp/hermetic/$tool"
  done
  ln -sf "$tmp/bin/gh" "$tmp/hermetic/gh"
  ln -sf "$tmp/bin/orca" "$tmp/hermetic/orca"
  ln -sf "$tmp/bin/lsof" "$tmp/hermetic/lsof"
}
hermetic_bin
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
ln -sf "$tmp/badbin/lsof" "$tmp/hermetic/lsof"
PATH="$tmp/hermetic:/bin:/usr/bin" bash "$root/script/wrap-up.sh" --apply > "$tmp/output" 2>&1 || true
check 'failing lsof keeps clone' test -d "$chrome/code_sign_clone.broken"
check 'failing lsof reports reason' has "Kept Chrome clone $chrome/code_sign_clone.broken (lsof failed)"
# Without lsof, Chrome clones must stay (macOS: unavailable; Linux: proc scan cannot prove idle).
mkdir -p "$chrome/code_sign_clone.unknown"
rm -f "$tmp/hermetic/lsof"
mv "$tmp/bin/lsof" "$tmp/lsof.off" 2>/dev/null || true
# Without lsof in PATH, path_busy fails closed (macOS semantics; avoids Linux fuser).
OSTYPE=darwin PATH="$tmp/hermetic:/bin" bash "$root/script/wrap-up.sh" --apply > "$tmp/output" 2>&1 || true
check 'no lsof keeps clones' test -d "$chrome/code_sign_clone.unknown"
printf '%s tests passed; %s failed\n' "$passed" "$failed"
test "$failed" -eq 0
