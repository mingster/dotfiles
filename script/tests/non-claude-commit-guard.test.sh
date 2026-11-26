#!/usr/bin/env bash
# #1940: a worktree prepared for an antigravity or grok worker refuses an Owner-approved: trailer and a secret path
# at commit and push time, keeps repo hooks that were already in effect, and a plain commit still works.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
script="$here/../worker-startup.sh"
pass=0 fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL: $1"; }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home"; mkdir -p "$HOME"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com

git init -q -b main "$tmp/origin.git" --bare
git clone -q "$tmp/origin.git" "$tmp/repo" 2>/dev/null
git -C "$tmp/repo" commit -q --allow-empty -m base && git -C "$tmp/repo" push -q origin main
# A repo hook that was already in effect must keep running.
mkdir -p "$tmp/repo/.githooks"
printf '#!/usr/bin/env bash\ngrep -q BLOCKME "$1" && { echo repo-hook-ran >&2; exit 1; }\nexit 0\n' >"$tmp/repo/.githooks/commit-msg"
chmod +x "$tmp/repo/.githooks/commit-msg"
git -C "$tmp/repo" add .githooks && git -C "$tmp/repo" commit -q -m "repo hook" && git -C "$tmp/repo" push -q origin main
git -C "$tmp/repo" config core.hooksPath .githooks
git -C "$tmp/repo" worktree add -q -b work "$tmp/wt" main

bash "$script" --install-agent-hooks "$tmp/wt" 2>/dev/null && ok || bad "installer exits 0"
# Idempotent: a second run keeps the first prior hooks.
bash "$script" --install-agent-hooks "$tmp/wt" 2>/dev/null && ok || bad "installer is re-runnable"

cd "$tmp/wt" || exit 1
echo a >a.txt; git add a.txt
if git commit -q -m "plain change" 2>/dev/null; then ok; else bad "a plain commit passes"; fi

echo b >b.txt; git add b.txt
if out=$(git commit -q -m "change

Owner-approved: Mingster 2026-11-26" 2>&1); then bad "Owner-approved trailer refused"
elif grep -q 'Owner-approved' <<<"$out"; then ok; else bad "refusal names the trailer ($out)"; fi

mkdir -p secrets; echo x >secrets/key.txt; git add -f secrets/key.txt
if out=$(git commit -q -m "add key" 2>&1); then bad "secret path refused"
elif grep -q 'secret path' <<<"$out"; then ok; else bad "refusal names the secret path ($out)"; fi
git reset -q secrets/key.txt; rm -rf secrets

echo e >.env; git add -f .env
if git commit -q -m "add env" 2>/dev/null; then bad ".env refused"; else ok; fi
git reset -q .env; rm -f .env
echo e >.env.example; git add .env.example
if git commit -q -m "add env example" 2>/dev/null; then ok; else bad ".env.example passes"; fi

echo c >c.txt; git add c.txt
if out=$(git commit -q -m "BLOCKME" 2>&1); then bad "repo hook still runs"
elif grep -q repo-hook-ran <<<"$out"; then ok; else bad "repo hook output ($out)"; fi
git commit -q -m "ok again" 2>/dev/null && ok || bad "commit passes after the refusal"

# pre-push catches a commit made with hooks bypassed.
echo d >d.txt; git add d.txt
git commit -q --no-verify -m "bypass

Owner-approved: Mingster 2026-11-26" 2>/dev/null
if out=$(git push -q origin work 2>&1); then bad "push of an Owner-approved commit refused"
elif grep -q 'Owner-approved' <<<"$out"; then ok; else bad "push refusal names the trailer ($out)"; fi
git reset -q --hard HEAD~1
echo k >secrets-note.txt; mkdir -p cfg/secrets; echo k >cfg/secrets/k; git add -f cfg/secrets/k
git commit -q --no-verify -m "bypass secret" 2>/dev/null
if git push -q origin work 2>/dev/null; then bad "push of a secret path refused"; else ok; fi
git reset -q --hard HEAD~1
git push -q origin work 2>/dev/null && ok || bad "a clean push passes"

# A Claude worktree gets no hooks from this script alone: the main checkout keeps its own hooksPath.
if [ "$(git -C "$tmp/repo" config --get core.hooksPath)" = .githooks ]; then ok; else bad "main checkout hooksPath untouched"; fi

# The brief of an antigravity or grok worker carries the owner decisions on its issue; a Claude brief does not.
cd "$here" || exit 1
fake="$tmp/fake-script"; mkdir -p "$fake"
printf '#!/usr/bin/env bash\necho "#$2: Owner decision 2026-11-21: verifier is another family"\n' >"$fake/owner-decisions.sh"
WORKER_BRIEF_DIR="$tmp/briefs"; mkdir -p "$WORKER_BRIEF_DIR"
die() { echo "$*" >&2; exit 1; }
# shellcheck disable=SC1090
. <(awk '/^issue_ref_from_spec\(\)/,/^}/; /^started_issue_ref\(\)/,/^}/; /^with_owner_decisions\(\)/,/^}/' "$script")
here_saved=$here; here=$fake
printf 'Task text\nRefs mingster/dotfiles#1305\n' >"$tmp/spec.txt"
for a in antigravity grok; do
  out=$(with_owner_decisions "$tmp/spec.txt" "#1305|fullstack-dev" "$a")
  if grep -q 'Owner decision 2026-11-21' "$out" && grep -q 'do not ask them again' "$out"; then ok; else bad "$a brief carries the owner decision"; fi
done
out=$(with_owner_decisions "$tmp/spec.txt" "#1305|fullstack-dev" claude)
if [ "$out" = "$tmp/spec.txt" ]; then ok; else bad "a claude brief is left alone"; fi
printf 'Task text\nRefs #1305\n' >"$tmp/norepo.txt"
out=$(with_owner_decisions "$tmp/norepo.txt" "#1305|fullstack-dev" grok)
if [ "$out" = "$tmp/norepo.txt" ]; then ok; else bad "a brief naming no repo is left alone"; fi
printf '#!/usr/bin/env bash\nexit 1\n' >"$fake/owner-decisions.sh"
out=$(with_owner_decisions "$tmp/spec.txt" "#1305|fullstack-dev" grok)
if [ "$out" = "$tmp/spec.txt" ]; then ok; else bad "no decision leaves the brief alone"; fi
here=$here_saved

echo "non-claude-commit-guard: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
