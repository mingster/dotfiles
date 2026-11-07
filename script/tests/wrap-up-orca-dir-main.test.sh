#!/usr/bin/env bash
# Issue 678: main update ignores host pull.rebase; non-scheduled wrap-up resolves orca via find_orca_dir.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd -P)
tmp=$(mktemp -d)
tmp=$(cd "$tmp" && pwd -P)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/home/.orca/cli/bin" "$tmp/good-orca/bin"
cat > "$tmp/bin/gh" <<'FAKE'
#!/usr/bin/env bash
case "$*" in
  'repo view --json defaultBranchRef') echo '{"defaultBranchRef":{"name":"main"}}'; exit 0 ;;
  'api repos/{owner}/{repo}/pages') echo '{"source":null}'; exit 0 ;;
  'api --paginate repos/{owner}/{repo}/branches?protected=true&per_page=100') echo '[]'; exit 0 ;;
esac
echo '[]'
FAKE
cat > "$tmp/stub-orca" <<'STUB'
#!/usr/bin/env bash
echo stub-orca "$*" >> "$STUB_LOG"
case "$*" in
  'terminal list --json') echo '{"ok":false}'; exit 0 ;;
  'environment list'*) echo '{"ok":true,"result":{"environments":[]}}' ;;
  *run-list*) echo '{"ok":true,"result":{"runs":[]}}' ;;
  *worker-list*) echo '{"ok":true,"result":{"workers":[]}}' ;;
esac
exit 1
STUB
cat > "$tmp/good-orca/bin/orca" <<'GOOD'
#!/usr/bin/env bash
echo good-orca "$*" >> "$GOOD_LOG"
case "$*" in
  'terminal list --json') printf '{"ok":true,"result":{"terminals":[]}}\n'; exit 0 ;;
  'environment list'*) echo '{"ok":true,"result":{"environments":[]}}' ;;
  *run-list*) echo '{"ok":true,"result":{"runs":[]}}' ;;
  *worker-list*) echo '{"ok":true,"result":{"workers":[]}}' ;;
esac
exit 1
GOOD
chmod +x "$tmp/bin/gh" "$tmp/stub-orca" "$tmp/good-orca/bin/orca"
cp "$tmp/stub-orca" "$tmp/home/.orca/cli/bin/orca"
chmod +x "$tmp/home/.orca/cli/bin/orca"
ln -sf "$tmp/stub-orca" "$tmp/bin/orca"
export HOME="$tmp/home" GIT_CONFIG_NOSYSTEM=1
export STUB_LOG="$tmp/stub.log" GOOD_LOG="$tmp/good.log"
export WRAP_UP_ORCA_APP_BIN="$tmp/good-orca/bin"
export PATH="$tmp/bin:$PATH"
export WRAP_UP_CLONE_ROOT="$tmp/no-clones" WRAP_UP_SCRATCH_ROOT="$tmp/no-scratch"
export WRAP_UP_LOOSE_ROOT="$tmp/no-loose" WRAP_UP_RECENT_MIN=0 WRAP_UP_STATE_DIR="$tmp/no-state"
printf '#!/usr/bin/env bash\nexit 1\n' > "$tmp/bin/lsof"
chmod +x "$tmp/bin/lsof"

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
git -C "$tmp/origin" symbolic-ref HEAD refs/heads/main

: > "$tmp/stub.log"
: > "$tmp/good.log"
bash "$here/wrap-up.sh" --dry-run > "$tmp/output" 2> "$tmp/stderr" || true
grep -q 'good-orca' "$tmp/good.log" || { echo 'FAIL find_orca_dir: good orca not used'; cat "$tmp/good.log"; exit 1; }
grep -q 'terminal inventory incomplete' "$tmp/output" && {
  echo 'FAIL find_orca_dir: stale stub drove inventory failure'
  exit 1
}
echo 'ok find_orca_dir prefers app orca over stale ~/.orca/cli/bin'

# pull.rebase=true with two branch.main.merge entries must not break main fast-forward.
export GIT_CONFIG_GLOBAL=/dev/null
git branch extra-tracking
git push -q origin extra-tracking
git config pull.rebase true
git config branch.main.merge refs/heads/main
git config --add branch.main.merge refs/heads/extra-tracking

git clone -q -b main "$tmp/origin" "$tmp/upstream"
echo next >> "$tmp/upstream/file"
git -C "$tmp/upstream" add file
git -C "$tmp/upstream" -c user.email=test@example.invalid -c user.name=Test commit -qam next
git -C "$tmp/upstream" push -q origin main
before=$(git rev-parse HEAD)
bash "$here/wrap-up.sh" --apply > "$tmp/output" 2> "$tmp/stderr" || true
after=$(git rev-parse HEAD)
remote=$(git --git-dir="$tmp/origin" rev-parse main)
[ "$after" = "$remote" ] || {
  echo "FAIL pull.rebase: main not fast-forwarded (before=$before after=$after remote=$remote)"
  grep -i main "$tmp/output" || true
  exit 1
}
grep -q 'Kept main update' "$tmp/output" && {
  echo 'FAIL pull.rebase: main update was kept unexpectedly'
  exit 1
}
echo 'ok main update ignores pull.rebase and multiple branch.main.merge entries'
