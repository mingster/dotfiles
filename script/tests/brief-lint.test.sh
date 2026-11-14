#!/usr/bin/env bash
# Tests for script/brief-lint.sh: each missing part, a full brief passes, and the T8 brief passes.
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
lint="$here/../brief-lint.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

pass=0
fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL: $1"; }

write_full_brief() {
  cat >"$1" <<'EOF'
Refs dotfiles#717

## Acceptance
- [ ] New script/brief-lint.sh <file> checks all required sections.

## Out of scope
Docs prose and unrelated scripts.

## Verify
timeout 300 bash script/tests/brief-lint.test.sh and bash script/checks-local.sh

## Finish
Run orca worktree set --worktree active --workspace-status in-review before worker_done.
Self-review against origin/main, then send worker_done.
EOF
}

# 1. Full brief with - [ ] item passes
write_full_brief "$tmp/full.md"
set +e
out=$(bash "$lint" "$tmp/full.md" 2>&1)
ec=$?
set -e
if [ "$ec" -eq 0 ] && [ -z "$out" ]; then ok; else bad "full brief should exit 0 with no output (ec=$ec, out=$out)"; fi

# 2. Full brief with plain - item under Acceptance passes
cat >"$tmp/dash.md" <<'EOF'
Refs #42

## Acceptance
- Plain bullet item under acceptance.

## Out of scope
Nothing else.

## Verify
Run bash script/checks-local.sh.

## Finish
Run orca worktree set --worktree active --workspace-status in-review before worker_done.
Self-review, then send worker_done.
EOF
set +e
out=$(bash "$lint" "$tmp/dash.md" 2>&1)
ec=$?
set -e
if [ "$ec" -eq 0 ] && [ -z "$out" ]; then ok; else bad "dash bullet brief should exit 0 (ec=$ec, out=$out)"; fi

# 3. Missing Refs
grep -v '^Refs ' "$tmp/full.md" >"$tmp/no-refs.md"
set +e
out=$(bash "$lint" "$tmp/no-refs.md" 2>&1)
ec=$?
set -e
if [ "$ec" -eq 1 ] && [ "$out" = "brief-lint: missing Refs" ]; then ok; else bad "missing Refs (ec=$ec, out=$out)"; fi

# 4. Missing Acceptance (no bullet item)
cat >"$tmp/no-acc-item.md" <<'EOF'
Refs dotfiles#717

## Acceptance
Prose without a list item.

## Out of scope
Unrelated files.

## Verify
Run bash script/checks-local.sh.

## Finish
Run orca worktree set --worktree active --workspace-status in-review before worker_done.
Self-review, then send worker_done.
EOF
set +e
out=$(bash "$lint" "$tmp/no-acc-item.md" 2>&1)
ec=$?
set -e
if [ "$ec" -eq 1 ] && [ "$out" = "brief-lint: missing Acceptance" ]; then ok; else bad "missing Acceptance item (ec=$ec, out=$out)"; fi

# 5. Missing Out of scope (blank section)
cat >"$tmp/no-oos.md" <<'EOF'
Refs dotfiles#717

## Acceptance
- [ ] Checks pass.

## Out of scope

## Verify
Run bash script/checks-local.sh.

## Finish
Run orca worktree set --worktree active --workspace-status in-review before worker_done.
Self-review, then send worker_done.
EOF
set +e
out=$(bash "$lint" "$tmp/no-oos.md" 2>&1)
ec=$?
set -e
if [ "$ec" -eq 1 ] && [ "$out" = "brief-lint: missing Out of scope" ]; then ok; else bad "missing Out of scope (ec=$ec, out=$out)"; fi

# 6. Missing Verify
cat >"$tmp/no-verify.md" <<'EOF'
Refs dotfiles#717

## Acceptance
- [ ] Checks pass.

## Out of scope
Unrelated files.

## Verify

## Finish
Run orca worktree set --worktree active --workspace-status in-review before worker_done.
Self-review, then send worker_done.
EOF
set +e
out=$(bash "$lint" "$tmp/no-verify.md" 2>&1)
ec=$?
set -e
if [ "$ec" -eq 1 ] && [ "$out" = "brief-lint: missing Verify" ]; then ok; else bad "missing Verify (ec=$ec, out=$out)"; fi

# 8. This T8 brief passes
cat >"$tmp/t8-brief.md" <<'EOF'
Refs dotfiles#717 (T8). Role: fullstack-dev. Repo: dotfiles, worktree from origin/main. LOCAL ONLY: no push, no PR, no Actions. Owner accepted T8 on 2026-11-08 (protected hook path included).

## Goal
No worker starts from an incomplete brief. Today worker-startup.sh only checks the spec file is non empty, and a direct `orca orchestration worker-start --spec-file` is not checked at all, so briefs miss requirements and every miss costs a new worker round.

## Acceptance
- [ ] New script/brief-lint.sh <file>: exits 0 only when the brief has all of: a line matching `Refs [A-Za-z0-9_./-]*#[0-9]+`; a `## Acceptance` heading followed by at least one `- [ ]` or `- ` item; `## Out of scope` with at least one non blank line; `## Verify` with at least one non blank line; `## Finish` with at least one non blank line. Otherwise exit 1 and print one line per missing part, `brief-lint: missing <part>`.
- [ ] script/worker-startup.sh runs brief-lint.sh on --spec before any start and dies with its output on failure.
- [ ] templates/agent-team/.claude/hooks/guard-bash.py check_worker_start denies `orca orchestration worker-start` and `start-cursor-worker.sh` when the brief (`--spec-file F`, or inline `--spec TEXT`) fails the same rules; the deny message names the missing parts and points at ~/.agents/skills/triage/AGENT-BRIEF.md. One rule set: the hook calls brief-lint.sh (path next to the dotfiles checkout, fail closed when missing) rather than copying the rules.
- [ ] script/fleet-watch.py: build_issue_start_command writes the issue body as is; when it fails brief-lint, do not start, add label `needs-triage` and comment once per issue head of body `brief-lint: <missing parts>`. build_rework_start_command writes its spec with all five sections filled from what it already knows (PR, head, failure excerpt as Acceptance "the failing check passes", Out of scope "files outside this PR", Verify the failing check, Finish worker_done), so rework always passes.
- [ ] Tests red first: script/tests/brief-lint.test.sh (each missing part, a full brief passes, this brief passes); worker-startup test case refusing a bad brief; hook test in templates/agent-team/.claude/hooks/tests/ for deny and allow; fleet-watch test for the needs-triage path and for rework spec passing lint.

## Out of scope
Rewriting AGENT-BRIEF.md, team-audit.sh, docs prose, any <project-a> file, ship.sh.

## Verify
With timeout 300 each: bash script/checks-local.sh, brief-lint.test.sh, the worker-startup test, `python3 -m pytest -q templates/agent-team/.claude/hooks/tests` (or unittest if that is what the folder uses), every script/tests/test_fleet_watch*.py, no-project-names.test.sh, shellcheck -x on the two shell scripts. Paste tails.

## Finish
Run orca worktree set --worktree active --workspace-status in-review before worker_done.
Write ## Self-review against origin/main with the full 40 hex head sha, rewrite it after every push, wait for `gh pr checks <n> --watch --fail-fast` to pass at the final head, then worker_done with worktree path, `git log --oneline origin/main..HEAD`, `git diff --stat origin/main...HEAD`, red then green tails. Then end.
EOF
set +e
out=$(bash "$lint" "$tmp/t8-brief.md" 2>&1)
ec=$?
set -e
if [ "$ec" -eq 0 ] && [ -z "$out" ]; then ok; else bad "T8 brief should pass (ec=$ec, out=$out)"; fi

# 9. Agent Brief template bold labels count, and a bold label ends the section
cat >"$tmp/bold.md" <<'EOF'
Refs owner/app#21

## Agent Brief
**Acceptance criteria:**
- [ ] it is fixed

**Out of scope:**
- other files

## Verify
Run bash script/checks-local.sh.

## Finish
Run orca worktree set --worktree active --workspace-status in-review before worker_done.
Self-review, then send worker_done.
EOF
set +e
out=$(bash "$lint" "$tmp/bold.md" 2>&1)
ec=$?
set -e
if [ "$ec" -eq 0 ] && [ -z "$out" ]; then ok; else bad "bold label brief should pass (ec=$ec, out=$out)"; fi
cat >"$tmp/bold-empty.md" <<'EOF'
Refs owner/app#21
**Acceptance criteria:**
**Done condition:**
- not an acceptance item
**Out of scope:**

## Verify
Run bash script/checks-local.sh.

## Finish
Run orca worktree set --worktree active --workspace-status in-review before worker_done.
Self-review, then send worker_done.
EOF
set +e
out=$(bash "$lint" "$tmp/bold-empty.md" 2>&1)
ec=$?
set -e
if [ "$ec" -ne 0 ] && printf '%s' "$out" | grep -q 'missing Acceptance' && printf '%s' "$out" | grep -q 'missing Out of scope'; then ok; else bad "empty bold sections should fail (ec=$ec, out=$out)"; fi

# 11. Verify that does not run checks-local.sh is refused
cat >"$tmp/no-checks-local.md" <<'EOF'
Refs dotfiles#818

## Acceptance
- [ ] Verify runs the workflow's checks.

## Out of scope
Unrelated files.

## Verify
timeout 300 bash script/tests/brief-lint.test.sh

## Finish
Run orca worktree set --worktree active --workspace-status in-review before worker_done.
Self-review, then send worker_done.
EOF
set +e
out=$(bash "$lint" "$tmp/no-checks-local.md" 2>&1)
ec=$?
set -e
if [ "$ec" -eq 1 ] && [ "$out" = "brief-lint: Verify must run script/checks-local.sh" ]; then ok; else bad "Verify without checks-local.sh (ec=$ec, out=$out)"; fi

# 968. Finish is not the author's to write: a brief with no Finish passes, builder or not.
cat >"$tmp/no-finish.md" <<'EOF'
Refs dotfiles#717
Role: fullstack-dev.

## Acceptance
- [ ] Checks pass.

## Out of scope
Unrelated files.

## Verify
Run bash script/checks-local.sh.
EOF
set +e
out=$(bash "$lint" "$tmp/no-finish.md" 2>&1)
ec=$?
set -e
if [ "$ec" -eq 0 ] && [ -z "$out" ]; then ok; else bad "brief with no Finish passes (ec=$ec, out=$out)"; fi

# 969. No Self-review section anywhere in the brief: still passes, and a PR body never needed one.
if ! grep -qi 'self-review' "$tmp/no-finish.md"; then ok; else bad "969 fixture should have no Self-review"; fi

# Type defaults to build. Wording that looks like rework or verify does not change the type.
cat >"$tmp/implied-rework.md" <<'EOF'
Refs owner/app#4
Rework owner/app PR #4 head aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa

## Acceptance
- [ ] the failing check passes

## Out of scope
files outside this PR

## Verify
bash script/checks-local.sh, then the failing check:
lint broke
EOF
set +e
out=$(bash "$lint" "$tmp/implied-rework.md" 2>&1)
ec=$?
set -e
if [ "$ec" -eq 0 ] && [ -z "$out" ]; then ok; else bad "rework wording without Type stays build (ec=$ec, out=$out)"; fi

cat >"$tmp/implied-verify.md" <<'EOF'
Refs owner/app#4

Role: qa-sdet. Verify this open PR.

## Acceptance
- [ ] a Verdict for this head is posted

## Out of scope
Merging.

## Verify
bash script/checks-local.sh
EOF
set +e
out=$(bash "$lint" "$tmp/implied-verify.md" 2>&1)
ec=$?
set -e
if [ "$ec" -eq 0 ] && [ -z "$out" ]; then ok; else bad "verify wording without Type stays build (ec=$ec, out=$out)"; fi

lint_exact() {
  local name=$1 file=$2 exp_ec=$3 exp_out=$4
  set +e
  out=$(bash "$lint" "$file" 2>&1)
  ec=$?
  set -e
  if [ "$ec" -eq "$exp_ec" ] && [ "$out" = "$exp_out" ]; then ok; else bad "$name (ec=$ec, out=$out)"; fi
}

cat >"$tmp/type-build.md" <<'EOF'
Refs dotfiles#1026
Type: build

## Acceptance
- [ ] The script exits 0.

## Out of scope
Unrelated files.

## Verify
Run bash script/checks-local.sh.
EOF
lint_exact "Type build passes" "$tmp/type-build.md" 0 ""

cat >"$tmp/type-verify.md" <<'EOF'
Refs dotfiles#1026
Type: verify

## Acceptance
- [ ] A Verdict is posted for the head.

## Out of scope
Merging.

## Verify
Run bash script/checks-local.sh.
EOF
lint_exact "Type verify passes" "$tmp/type-verify.md" 0 ""

cat >"$tmp/type-unknown.md" <<'EOF'
Refs dotfiles#1026
Type: script

## Acceptance
- [ ] The script exits 0.

## Out of scope
Unrelated files.

## Verify
Run bash script/checks-local.sh.
EOF
lint_exact "unknown Type is refused" "$tmp/type-unknown.md" 1 "brief-lint: unknown brief type"

cat >"$tmp/type-two.md" <<'EOF'
Refs dotfiles#1026
Type: build
Type: verify

## Acceptance
- [ ] The script exits 0.

## Out of scope
Unrelated files.

## Verify
Run bash script/checks-local.sh.
EOF
lint_exact "two Type lines are refused" "$tmp/type-two.md" 1 "brief-lint: brief has more than one Type"

cat >"$tmp/rule.md" <<'EOF'
Refs dotfiles#1026
Type: rule/guide change

## Acceptance
- [ ] Builder and verifier both run `rg -n 'old wording'`.

## Out of scope
Do not run `rg -n 'somewhere else'`.

## Verify
Run bash script/checks-local.sh.
EOF
lint_exact "rule/guide change with one search command passes" "$tmp/rule.md" 0 ""

cat >"$tmp/rule-short.md" <<'EOF'
Refs dotfiles#1026
Type: rule/guide

## Acceptance
- [ ] Builder runs `rg -n 'old wording'`.
- [ ] Verifier runs `rg -n 'old wording'`.

## Out of scope
Unrelated files.

## Verify
Run bash script/checks-local.sh.
EOF
lint_exact "rule/guide repeated command is one command" "$tmp/rule-short.md" 0 ""

cat >"$tmp/rule-git-grep.md" <<'EOF'
Refs dotfiles#1026
Type: rule/guide change

## Acceptance
- [ ] The old wording is gone.

## Out of scope
Unrelated files.

## Verify
Builder and verifier both run this:
git grep -n 'old wording'
bash script/checks-local.sh
EOF
lint_exact "rule/guide bare git grep line passes" "$tmp/rule-git-grep.md" 0 ""

cat >"$tmp/rule-none.md" <<'EOF'
Refs dotfiles#1026
Type: rule/guide change

## Acceptance
- [ ] Builder and verifier both run the search.

## Out of scope
Unrelated files.

## Verify
Run bash script/checks-local.sh.
EOF
lint_exact "rule/guide without a search command" "$tmp/rule-none.md" 1 "brief-lint: rule/guide brief must name one search command for the builder and the verifier"

cat >"$tmp/rule-two.md" <<'EOF'
Refs dotfiles#1026
Type: rule/guide change

## Acceptance
- [ ] Builder and verifier both run `rg -n 'one'` and `rg -n 'two'`.

## Out of scope
Unrelated files.

## Verify
Run bash script/checks-local.sh.
EOF
lint_exact "rule/guide with two search commands" "$tmp/rule-two.md" 1 "brief-lint: rule/guide brief must name one search command for the builder and the verifier"

cat >"$tmp/rule-builder.md" <<'EOF'
Refs dotfiles#1026
Type: rule/guide change

## Acceptance
- [ ] Builder runs `rg -n 'old wording'`.

## Out of scope
Unrelated files.

## Verify
Run bash script/checks-local.sh.
EOF
lint_exact "rule/guide search command without the verifier" "$tmp/rule-builder.md" 1 "brief-lint: rule/guide brief must name one search command for the builder and the verifier"

cat >"$tmp/rework.md" <<'EOF'
Refs dotfiles#1027
Type: rework

## Acceptance
- [ ] Apply the Verdict at https://github.com/mingster/dotfiles/pull/12#issuecomment-99
- [ ] Put a Self-check section in the PR body with the command and its output.

## Out of scope
files outside this PR

## Verify
Run bash script/checks-local.sh.
EOF
lint_exact "rework with Verdict link and Self-check passes" "$tmp/rework.md" 0 ""

cat >"$tmp/rework-nolink.md" <<'EOF'
Refs dotfiles#1027
Type: rework

## Acceptance
- [ ] Read the Verdict and fix the listed items.
- [ ] Put a Self-check section in the PR body with the command and its output.

## Out of scope
files outside this PR

## Verify
Run bash script/checks-local.sh.
EOF
lint_exact "rework without a Verdict link" "$tmp/rework-nolink.md" 1 "brief-lint: rework brief must link the Verdict"

cat >"$tmp/rework-noself.md" <<'EOF'
Refs dotfiles#1027
Type: rework

## Acceptance
- [ ] Apply the Verdict at https://github.com/mingster/dotfiles/pull/12#issuecomment-99

## Out of scope
files outside this PR

## Verify
Run bash script/checks-local.sh.
EOF
lint_exact "rework without a Self-check" "$tmp/rework-noself.md" 1 "brief-lint: rework brief must require a Self-check"

cat >"$tmp/rework-neither.md" <<'EOF'
Refs dotfiles#1027
Type: rework

## Acceptance
- [ ] the failing check passes

## Out of scope
files outside this PR

## Verify
Run bash script/checks-local.sh.
EOF
lint_exact "rework without Verdict link or Self-check" "$tmp/rework-neither.md" 1 $'brief-lint: rework brief must link the Verdict\nbrief-lint: rework brief must require a Self-check'

# qa-sdet with green GitHub Checks does not need checks-local.sh. A builder brief still does.
cat >"$tmp/qa-green.md" <<'EOF'
Refs dotfiles#1031
Role: qa-sdet. Verify the head.

## Acceptance
- [ ] a Verdict is posted

## Out of scope
Merging.

## Verify
GitHub Checks are green at this head.
EOF
set +e
out=$(bash "$lint" "$tmp/qa-green.md" 2>&1)
ec=$?
set -e
if [ "$ec" -eq 0 ] && [ -z "$out" ]; then ok; else bad "qa-sdet green checks (ec=$ec, out=$out)"; fi

cat >"$tmp/builder-green.md" <<'EOF'
Refs dotfiles#1031
Role: fullstack-dev.

## Acceptance
- [ ] the check passes

## Out of scope
Other files.

## Verify
GitHub Checks are green at this head.
EOF
set +e
out=$(bash "$lint" "$tmp/builder-green.md" 2>&1)
ec=$?
set -e
if [ "$ec" -eq 1 ] && [ "$out" = "brief-lint: Verify must run script/checks-local.sh" ]; then ok; else bad "builder still needs checks-local.sh (ec=$ec, out=$out)"; fi

template="$here/../../.agents/skills/triage/AGENT-BRIEF.md"
if grep -q 'Type: rule/guide change' "$template" && grep -q 'one search command' "$template" \
  && grep -q 'builder' "$template" && grep -q 'verifier' "$template"; then
  ok
else
  bad "rule/guide template names one search command for the builder and the verifier"
fi

echo "brief-lint: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
