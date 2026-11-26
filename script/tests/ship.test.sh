#!/usr/bin/env bash
# Hermetic tests for script/ship.sh (ticket T3, issue #717).
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck disable=SC1091
. "$here/tests/lib/asdf-pin.sh"
# shellcheck disable=SC1091
. "$here/tests/lib/merge-fixture.sh"

mf_setup
trap mf_teardown EXIT
cd "$MF_REPO" || exit 1
# ship.sh checks the PR text for private names and fails without a pattern file.
printf 'xyzzynomatch\nzzprivproj\n' >"$MF_DIR/names.pattern"
export NO_PROJECT_NAMES_FILE="$MF_DIR/names.pattern"

# ship.sh calls Orca only to list worktrees and set the board status after a merge: the stub logs every call and exits ORCA_FAKE_RC (default 0).
# `worktree list` answers from $MF_DIR/orca-list when that file exists (the board lookup by path).
printf '#!/usr/bin/env bash\necho "$*" >> "%s/orca-called"\ncase "$*" in "worktree list"*) cat "%s/orca-list" 2>/dev/null; exit 0 ;; esac\nexit "${ORCA_FAKE_RC:-0}"\n' "$MF_DIR" "$MF_DIR" > "$MF_DIR/fake-orca"
chmod +x "$MF_DIR/fake-orca"
export ORCA_CLI_COMMAND="$MF_DIR/fake-orca"

# session-sync must not add its offline notice to ship output: the switch skips it even when the
# dotfiles checkout cannot fetch (#1325).
mkdir -p "$MF_DIR/dotfiles-offline"
git -C "$MF_DIR/dotfiles-offline" init -q -b main
git -C "$MF_DIR/dotfiles-offline" remote add origin "$MF_DIR/no-such-remote.git"
export DOTFILES_DIR="$MF_DIR/dotfiles-offline" DOTFILES_FRESH_DONE=1

pass=0 fail=0
ok() { echo "ok   $1"; pass=$((pass + 1)); }
bad() { echo "FAIL $1: $2"; fail=$((fail + 1)); }

set_checks() { # <pr> <json array>
  local f="$MF_GH_DIR/pr-$1.json"
  jq --argjson c "$2" '.statusCheckRollup = $c' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}

green_checks='[{"name":"script-tests","status":"COMPLETED","conclusion":"SUCCESS"},{"name":"shellcheck","status":"COMPLETED","conclusion":"SUCCESS"}]'

post_verdict() { # <pr> <result> <head> [verifier] [author] [agent/model, default claude/opus; "none" omits it]
  local n=$1 res=$2 h=$3 v=${4:-ctx_verifier} a=${5:-ctx_author} am=${6:-claude/opus} suffix=""
  [ "$am" = none ] || suffix=" agent=${am%%/*} model=${am#*/}"
  gh pr comment "$n" --repo example/repo --body "Verdict: $res head=$h verifier=$v author=$a$suffix" >/dev/null
}

# The builder's own record on the PR: one body line. The head argument is unused (the old Self-review gate is gone).
mf_self_review() { # <pr> <head> [agent/model, default cursor/grok-4.7-high]
  local pr_n=$1 am=${3:-cursor/grok-4.7-high} f block
  f="$MF_GH_DIR/pr-${pr_n}.json"
  block=$(printf 'Builder: agent=%s model=%s\n\n## Self-check\n$ bash script/checks-local.sh\nexit 0' "${am%%/*}" "${am#*/}")
  jq --arg l "$block" '.body = ((.body // "") + "\n\n" + $l + "\n")' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}

run_ship() { # <args...>
  SHIP_OUT=$(bash "$here/ship.sh" "$@" 2>&1)
  SHIP_RC=$?
}

# 1. PASS at head merges with --squash --match-head-commit and reads back MERGED
mf_pr_add 1 feat-pass "Body"
h1=$(jq -r .headRefOid "$MF_GH_DIR/pr-1.json")
mf_self_review 1 "$h1"
set_checks 1 "$green_checks"
post_verdict 1 PASS "$h1"
: > "$MF_GH_LOG"
run_ship --repo example/repo --pr 1
if [ "$SHIP_RC" -eq 0 ] && [[ "$SHIP_OUT" =~ ^shipped\ PR\ 1\ as\ [0-9a-f]{40}$ ]] \
  && grep -q "gh pr merge 1 --repo example/repo --squash --match-head-commit $h1" "$MF_GH_LOG" \
  && [ "$(jq -r .state "$MF_GH_DIR/pr-1.json")" = MERGED ]; then
  ok "PASS at head merges and reads back"
else
  bad "PASS at head merges and reads back" "rc=$SHIP_RC out=$SHIP_OUT"
fi

# 2. Verdict at an older head with the same patch-id merges
"$MF_REAL_GIT" -C "$MF_REPO" fetch -q origin
mf_pr_add 2 feat-rebase "Body"
old_h2=$(jq -r .headRefOid "$MF_GH_DIR/pr-2.json")
"$MF_REAL_GIT" -C "$MF_REPO" checkout -q -B main origin/main
echo unrelated > "$MF_REPO/unrelated-main.txt"
"$MF_REAL_GIT" -C "$MF_REPO" add unrelated-main.txt
"$MF_REAL_GIT" -C "$MF_REPO" commit -q -m "advance main"
"$MF_REAL_GIT" -C "$MF_REPO" push -q origin main
"$MF_REAL_GIT" -C "$MF_REPO" fetch -q origin
new_base=$("$MF_REAL_GIT" -C "$MF_REPO" rev-parse origin/main)
"$MF_REAL_GIT" -C "$MF_REPO" checkout -q -B feat-rebase "$new_base"
"$MF_REAL_GIT" -C "$MF_REPO" cherry-pick "$old_h2" >/dev/null
"$MF_REAL_GIT" -C "$MF_REPO" push -q -f origin feat-rebase
"$MF_REAL_GIT" -C "$MF_REPO" checkout -q main
new_h2=$("$MF_REAL_GIT" -C "$MF_REPO" rev-parse feat-rebase)
jq --arg h "$new_h2" --arg b "$new_base" '.headRefOid = $h | .baseRefOid = $b' "$MF_GH_DIR/pr-2.json" > "$MF_GH_DIR/pr-2.tmp" && mv "$MF_GH_DIR/pr-2.tmp" "$MF_GH_DIR/pr-2.json"
mf_self_review 2 "$new_h2"
set_checks 2 "$green_checks"
post_verdict 2 "PASS+NOTES" "$old_h2"
: > "$MF_GH_LOG"
run_ship --repo example/repo --pr 2
if [ "$old_h2" != "$new_h2" ] && [ "$SHIP_RC" -eq 0 ] && [[ "$SHIP_OUT" =~ ^shipped\ PR\ 2\ as\ [0-9a-f]{40}$ ]] \
  && grep -q "gh pr merge 2 --repo example/repo --squash --match-head-commit $new_h2" "$MF_GH_LOG"; then
  ok "verdict at an older head with the same patch id merges"
else
  bad "verdict at an older head with the same patch id merges" "rc=$SHIP_RC out=$SHIP_OUT"
fi

# 3. Different patch-id refuses
mf_pr_add 3 feat-diff "Body"
old_h3=$(jq -r .headRefOid "$MF_GH_DIR/pr-3.json")
"$MF_REAL_GIT" -C "$MF_REPO" checkout -q feat-diff
echo changed >> "$MF_REPO/feat-diff.txt"
"$MF_REAL_GIT" -C "$MF_REPO" commit -q -am "change patch"
"$MF_REAL_GIT" -C "$MF_REPO" push -q -f origin feat-diff
"$MF_REAL_GIT" -C "$MF_REPO" checkout -q main
new_h3=$("$MF_REAL_GIT" -C "$MF_REPO" rev-parse feat-diff)
jq --arg h "$new_h3" '.headRefOid = $h' "$MF_GH_DIR/pr-3.json" > "$MF_GH_DIR/pr-3.tmp" && mv "$MF_GH_DIR/pr-3.tmp" "$MF_GH_DIR/pr-3.json"
mf_self_review 3 "$new_h3"
set_checks 3 "$green_checks"
post_verdict 3 PASS "$old_h3"
: > "$MF_GH_LOG"
run_ship --repo example/repo --pr 3
if [ "$SHIP_RC" -ne 0 ] && [ "$(wc -l <<<"$SHIP_OUT" | tr -d ' ')" -eq 1 ] \
  && grep -qi "patch-id" <<<"$SHIP_OUT" && ! grep -q "pr merge" "$MF_GH_LOG"; then
  ok "different patch id refuses"
else
  bad "different patch id refuses" "rc=$SHIP_RC out=$SHIP_OUT"
fi

# 4. FAIL verdict refuses
mf_pr_add 4 feat-fail "Body"
h4=$(jq -r .headRefOid "$MF_GH_DIR/pr-4.json")
set_checks 4 "$green_checks"
post_verdict 4 PASS "$h4"
post_verdict 4 FAIL "$h4"
: > "$MF_GH_LOG"
run_ship --repo example/repo --pr 4
if [ "$SHIP_RC" -ne 0 ] && [ "$(wc -l <<<"$SHIP_OUT" | tr -d ' ')" -eq 1 ] \
  && grep -q "FAIL" <<<"$SHIP_OUT" && ! grep -q "pr merge" "$MF_GH_LOG"; then
  ok "FAIL refuses"
else
  bad "FAIL refuses" "rc=$SHIP_RC out=$SHIP_OUT"
fi

# 5. Pending check refuses
mf_pr_add 5 feat-pending "Body"
h5=$(jq -r .headRefOid "$MF_GH_DIR/pr-5.json")
set_checks 5 '[{"name":"script-tests","status":"COMPLETED","conclusion":"SUCCESS"},{"name":"shellcheck","status":"IN_PROGRESS","conclusion":null}]'
post_verdict 5 PASS "$h5"
: > "$MF_GH_LOG"
run_ship --repo example/repo --pr 5
if [ "$SHIP_RC" -ne 0 ] && [ "$(wc -l <<<"$SHIP_OUT" | tr -d ' ')" -eq 1 ] \
  && grep -qi "check" <<<"$SHIP_OUT" && ! grep -q "pr merge" "$MF_GH_LOG"; then
  ok "pending check refuses"
else
  bad "pending check refuses" "rc=$SHIP_RC out=$SHIP_OUT"
fi

# 6. No verdict refuses
mf_pr_add 6 feat-noverdict "Body"
set_checks 6 "$green_checks"
: > "$MF_GH_LOG"
run_ship --repo example/repo --pr 6
if [ "$SHIP_RC" -ne 0 ] && [ "$(wc -l <<<"$SHIP_OUT" | tr -d ' ')" -eq 1 ] \
  && grep -qi "verdict" <<<"$SHIP_OUT" && ! grep -q "pr merge" "$MF_GH_LOG"; then
  ok "no verdict refuses"
else
  bad "no verdict refuses" "rc=$SHIP_RC out=$SHIP_OUT"
fi

# 7. Merge read-back not MERGED fails
mf_pr_add 7 feat-readback "Body"
h7=$(jq -r .headRefOid "$MF_GH_DIR/pr-7.json")
mf_self_review 7 "$h7"
set_checks 7 "$green_checks"
post_verdict 7 PASS "$h7"
rm -f "$MF_DIR/orca-called"
mkdir -p "$MF_DIR/noop-merge"
cat > "$MF_DIR/noop-merge/gh" <<EOS
#!/usr/bin/env bash
if [ "\$1 \$2" = "pr merge" ]; then
  echo "gh \$*" >> "$MF_GH_LOG"
  exit 0
fi
exec "$MF_BIN/gh" "\$@"
EOS
chmod +x "$MF_DIR/noop-merge/gh"
: > "$MF_GH_LOG"
SHIP_OUT=$(PATH="$MF_DIR/noop-merge:$PATH" bash "$here/ship.sh" --repo example/repo --pr 7 2>&1)
SHIP_RC=$?
if [ "$SHIP_RC" -ne 0 ] && [ "$(wc -l <<<"$SHIP_OUT" | tr -d ' ')" -eq 1 ] \
  && grep -q "not MERGED" <<<"$SHIP_OUT" && [ ! -e "$MF_DIR/orca-called" ]; then
  ok "merge read back not MERGED fails and leaves the board status alone"
else
  bad "merge read back not MERGED fails and leaves the board status alone" "rc=$SHIP_RC out=$SHIP_OUT"
fi

# 8. Protected path without approval refuses (and with approval merges)
mf_pr_add 8 feat-protected "Body" AGENTS.md
h8=$(jq -r .headRefOid "$MF_GH_DIR/pr-8.json")
mf_self_review 8 "$h8"
set_checks 8 "$green_checks"
gh pr comment 8 --repo example/repo --body "Review: PASS head=$h8" >/dev/null
: > "$MF_GH_LOG"
run_ship --repo example/repo --pr 8
if [ "$SHIP_RC" -ne 0 ] && [ "$(wc -l <<<"$SHIP_OUT" | tr -d ' ')" -eq 1 ] \
  && grep -q "Owner-approved" <<<"$SHIP_OUT" && ! grep -q "pr merge" "$MF_GH_LOG"; then
  ok "protected path without approval refuses"
else
  bad "protected path without approval refuses" "rc=$SHIP_RC out=$SHIP_OUT"
fi

# 8b. Intent trailer (#1982): a gated file listed in the cited spec's Owner steps merges; one that is not refuses
mkdir -p "$MF_GH_DIR/contents/docs/intent/2026-11-27-example"
printf '{"number":80,"state":"MERGED","baseRefName":"main","headRefName":"intent-80","files":[{"path":"docs/intent/2026-11-27-example/intent.md"}],"comments":[]}\n' > "$MF_GH_DIR/pr-80.json"
printf '# Example\n\nStatus: Proposed 2026-11-26 · Accepted 2026-11-27\n' > "$MF_GH_DIR/contents/docs/intent/2026-11-27-example/intent.md"
# shellcheck disable=SC2016 # literal Markdown backticks
printf '# Example: spec\n\n## Owner steps\n- `AGENTS.md`: add the rule.\n' > "$MF_GH_DIR/contents/docs/intent/2026-11-27-example/spec.md"
intent_trailer_pr() { # <pr> <branch> <path>: the PR's one commit carries the intent trailer
  local h
  mf_pr_add "$1" "$2" "Body" "$3"
  "$MF_REAL_GIT" -C "$MF_REPO" checkout -q "$2"
  "$MF_REAL_GIT" -C "$MF_REPO" commit -q --amend -m "$2" -m "Owner-approved: intent example/repo#80 accepted 2026-11-27"
  "$MF_REAL_GIT" -C "$MF_REPO" push -q -f origin "$2"
  "$MF_REAL_GIT" -C "$MF_REPO" checkout -q main
  h=$("$MF_REAL_GIT" -C "$MF_REPO" rev-parse "$2")
  jq --arg h "$h" '.headRefOid = $h' "$MF_GH_DIR/pr-$1.json" > "$MF_GH_DIR/pr-$1.tmp" && mv "$MF_GH_DIR/pr-$1.tmp" "$MF_GH_DIR/pr-$1.json"
  mf_self_review "$1" "$h"
  set_checks "$1" "$green_checks"
  post_verdict "$1" PASS "$h"
}
intent_trailer_pr 81 feat-intent-listed AGENTS.md
: > "$MF_GH_LOG"
run_ship --repo example/repo --pr 81
if [ "$SHIP_RC" -eq 0 ] && grep -q "gh pr merge 81 " "$MF_GH_LOG"; then
  ok "intent trailer merges a gated file listed in the cited spec's Owner steps"
else
  bad "intent trailer merges a gated file listed in the cited spec's Owner steps" "rc=$SHIP_RC out=$SHIP_OUT"
fi
intent_trailer_pr 82 feat-intent-unlisted .claude/agents/example.md
: > "$MF_GH_LOG"
run_ship --repo example/repo --pr 82
if [ "$SHIP_RC" -ne 0 ] && grep -q "is not listed under Owner steps" <<<"$SHIP_OUT" && ! grep -q "pr merge" "$MF_GH_LOG"; then
  ok "intent trailer refuses a gated file missing from the cited spec's Owner steps"
else
  bad "intent trailer refuses a gated file missing from the cited spec's Owner steps" "rc=$SHIP_RC out=$SHIP_OUT"
fi

# 9. --dry-run merges nothing
mf_pr_add 9 feat-dry "Body"
h9=$(jq -r .headRefOid "$MF_GH_DIR/pr-9.json")
mf_self_review 9 "$h9"
set_checks 9 "$green_checks"
post_verdict 9 PASS "$h9"
: > "$MF_GH_LOG"
run_ship --repo example/repo --pr 9 --dry-run
if [ "$SHIP_RC" -eq 0 ] && grep -qi "dry-run" <<<"$SHIP_OUT" \
  && ! grep -q "^shipped PR" <<<"$SHIP_OUT" \
  && ! grep -q "pr merge" "$MF_GH_LOG" \
  && [ "$(jq -r .state "$MF_GH_DIR/pr-9.json")" = OPEN ]; then
  ok "--dry-run merges nothing"
else
  bad "--dry-run merges nothing" "rc=$SHIP_RC out=$SHIP_OUT"
fi

# 10. Verifier with the same agent and model as the builder refuses
mf_pr_add 10 feat-same-pair "Body"
h10=$(jq -r .headRefOid "$MF_GH_DIR/pr-10.json")
mf_self_review 10 "$h10" claude/opus
set_checks 10 "$green_checks"
post_verdict 10 PASS "$h10"
: > "$MF_GH_LOG"
run_ship --repo example/repo --pr 10
if [ "$SHIP_RC" -ne 0 ] && [ "$(wc -l <<<"$SHIP_OUT" | tr -d ' ')" -eq 1 ] \
  && grep -Fq "verifier claude/opus is the same agent and model as the builder" <<<"$SHIP_OUT" \
  && ! grep -q "pr merge" "$MF_GH_LOG"; then
  ok "same agent and model as the builder refuses"
else
  bad "same agent and model as the builder refuses" "rc=$SHIP_RC out=$SHIP_OUT"
fi

# Same family without the Verdict tag refuses. The tag plus a different model ships. Exact pair still refuses with the tag.
mf_pr_add 3018 feat-same-family "Body"
h3018=$(jq -r .headRefOid "$MF_GH_DIR/pr-3018.json")
mf_self_review 3018 "$h3018" claude/sonnet
set_checks 3018 "$green_checks"
post_verdict 3018 PASS "$h3018"
run_ship --repo example/repo --pr 3018
if [ "$SHIP_RC" -ne 0 ] && grep -Fq "same model family" <<<"$SHIP_OUT" && ! grep -Fq "same agent and model" <<<"$SHIP_OUT"; then
  ok "same model family without the tag refuses"
else
  bad "same model family without the tag refuses" "rc=$SHIP_RC out=$SHIP_OUT"
fi

mf_pr_add 3030 feat-family-tag "Body"
h3030=$(jq -r .headRefOid "$MF_GH_DIR/pr-3030.json")
mf_self_review 3030 "$h3030" claude/sonnet
set_checks 3030 "$green_checks"
gh pr comment 3030 --repo example/repo --body "$(printf 'Verdict: PASS head=%s verifier=ctx_verifier author=ctx_author agent=claude model=opus\nsame-family-different-model\n' "$h3030")" >/dev/null
: > "$MF_GH_LOG"
run_ship --repo example/repo --pr 3030
if [ "$SHIP_RC" -eq 0 ] && grep -q '^shipped PR' <<<"$SHIP_OUT"; then
  ok "tagged same-family different model ships"
else
  bad "tagged same-family different model ships" "rc=$SHIP_RC out=$SHIP_OUT"
fi

mf_pr_add 3028 feat-tagged-same "Body"
h3028=$(jq -r .headRefOid "$MF_GH_DIR/pr-3028.json")
mf_self_review 3028 "$h3028" claude/opus
set_checks 3028 "$green_checks"
gh pr comment 3028 --repo example/repo --body "$(printf 'Verdict: PASS head=%s verifier=ctx_verifier author=ctx_author agent=claude model=opus\nsame-family-different-model\n' "$h3028")" >/dev/null
run_ship --repo example/repo --pr 3028
if [ "$SHIP_RC" -ne 0 ] && grep -Fq "same agent and model" <<<"$SHIP_OUT"; then
  ok "exact pair still refuses when the Verdict is tagged"
else
  bad "exact pair still refuses when the Verdict is tagged" "rc=$SHIP_RC out=$SHIP_OUT"
fi

mf_pr_add 3031 feat-unchecked $'## Acceptance\n- [ ] still open\n'
h3031=$(jq -r .headRefOid "$MF_GH_DIR/pr-3031.json")
mf_self_review 3031 "$h3031"
set_checks 3031 "$green_checks"
post_verdict 3031 PASS "$h3031"
run_ship --repo example/repo --pr 3031
if [ "$SHIP_RC" -ne 0 ] && grep -Fq "unchecked Acceptance items" <<<"$SHIP_OUT"; then
  ok "unchecked Acceptance refuses"
else
  bad "unchecked Acceptance refuses" "rc=$SHIP_RC out=$SHIP_OUT"
fi

mf_pr_add 3027 feat-no-self "Body"
h3027=$(jq -r .headRefOid "$MF_GH_DIR/pr-3027.json")
jq --arg l "Builder: agent=cursor model=grok-4.7-high" '.body = $l' "$MF_GH_DIR/pr-3027.json" > "$MF_GH_DIR/pr-3027.tmp" && mv "$MF_GH_DIR/pr-3027.tmp" "$MF_GH_DIR/pr-3027.json"
set_checks 3027 "$green_checks"
post_verdict 3027 PASS "$h3027"
run_ship --repo example/repo --pr 3027
if [ "$SHIP_RC" -ne 0 ] && grep -Fq "PR body needs ## Self-check" <<<"$SHIP_OUT"; then
  ok "missing Self-check refuses"
else
  bad "missing Self-check refuses" "rc=$SHIP_RC out=$SHIP_OUT"
fi

# #1882: ship.sh passes the PR diff to pr-body-gate, so a change to a shared function needs a Readers: section.
readers_case() { # <pr> <extra body>; sets SHIP_RC and SHIP_OUT
  local n=$1 h
  mf_pr_add "$n" "feat-readers-$n" "Closes #9"
  h=$(jq -r .headRefOid "$MF_GH_DIR/pr-$n.json")
  mf_self_review "$n" "$h"
  [ -z "$2" ] || jq --arg l "$2" '.body = (.body + "\n" + $l + "\n")' "$MF_GH_DIR/pr-$n.json" > "$MF_GH_DIR/pr-$n.tmp" && mv "$MF_GH_DIR/pr-$n.tmp" "$MF_GH_DIR/pr-$n.json"
  set_checks "$n" "$green_checks"
  post_verdict "$n" PASS "$h"
  mkdir -p "$MF_DIR/readers-$n"
  printf '#!/usr/bin/env bash\nif [ "$1 $2" = "pr diff" ]; then printf %%s "$READERS_DIFF"; exit 0; fi\nexec "%s/gh" "$@"\n' "$MF_BIN" > "$MF_DIR/readers-$n/gh"; chmod +x "$MF_DIR/readers-$n/gh"
  : > "$MF_GH_LOG"
  SHIP_OUT=$(READERS_DIFF=$'diff --git a/lib/shared.py b/lib/shared.py\n--- a/lib/shared.py\n+++ b/lib/shared.py\n@@ -1,2 +1,2 @@ def shared(x):\n-    return x\n+    return x + 1\n' \
    PATH="$MF_DIR/readers-$n:$PATH" bash "$here/ship.sh" --repo example/repo --pr "$n" 2>&1); SHIP_RC=$?
}
readers_case 3033 ""
if [ "$SHIP_RC" -ne 0 ] && grep -Fq "Readers:" <<<"$SHIP_OUT" && ! grep -q "pr merge" "$MF_GH_LOG"; then
  ok "a shared function change without Readers: refuses"
else
  bad "a shared function change without Readers: refuses" "rc=$SHIP_RC out=$SHIP_OUT"
fi
readers_case 3034 $'Readers:\n- shared: lib/test_shared.py covers its one caller'
if ! grep -Fq "Readers:" <<<"$SHIP_OUT"; then
  ok "a Readers: section naming the changed function passes the body gate"
else
  bad "a Readers: section naming the changed function passes the body gate" "rc=$SHIP_RC out=$SHIP_OUT"
fi

# 1952: a stacked PR (base is another branch) merges only while an open PR still has that base as its head.
stack_case() { # <pr> <branch> <base branch>; sets SHIP_RC and SHIP_OUT
  local n=$1 b=$2 base=$3 h
  mf_pr_add "$n" "$b" "Body"
  jq --arg base "$base" '.baseRefName = $base' "$MF_GH_DIR/pr-$n.json" > "$MF_GH_DIR/pr-$n.tmp" && mv "$MF_GH_DIR/pr-$n.tmp" "$MF_GH_DIR/pr-$n.json"
  h=$(jq -r .headRefOid "$MF_GH_DIR/pr-$n.json")
  mf_self_review "$n" "$h"; set_checks "$n" "$green_checks"; post_verdict "$n" PASS "$h"
  : > "$MF_GH_LOG"
  run_ship --repo example/repo --pr "$n"
}
mf_pr_add 3040 feat-base-merged "Body"
jq '.state = "MERGED"' "$MF_GH_DIR/pr-3040.json" > "$MF_GH_DIR/pr-3040.tmp" && mv "$MF_GH_DIR/pr-3040.tmp" "$MF_GH_DIR/pr-3040.json"
stack_case 3041 feat-stacked-merged feat-base-merged
if [ "$SHIP_RC" -ne 0 ] && grep -Fq "base feat-base-merged is merged; retarget to main and rebase" <<<"$SHIP_OUT" \
  && ! grep -q "pr merge" "$MF_GH_LOG"; then
  ok "stacked PR whose base PR is merged refuses and names the default branch"
else
  bad "stacked PR whose base PR is merged refuses and names the default branch" "rc=$SHIP_RC out=$SHIP_OUT"
fi
mf_pr_add 3042 feat-base-live "Body"
stack_case 3043 feat-stacked-live feat-base-live
if [ "$SHIP_RC" -eq 0 ] && [[ "$SHIP_OUT" =~ ^shipped\ PR\ 3043 ]]; then
  ok "stacked PR whose base PR is still open ships"
else
  bad "stacked PR whose base PR is still open ships" "rc=$SHIP_RC out=$SHIP_OUT"
fi
stack_case 3044 feat-default-base main
if [ "$SHIP_RC" -eq 0 ] && [[ "$SHIP_OUT" =~ ^shipped\ PR\ 3044 ]]; then
  ok "PR whose base is the default branch ships"
else
  bad "PR whose base is the default branch ships" "rc=$SHIP_RC out=$SHIP_OUT"
fi

# 11. Edited FAIL still blocks an older PASS
mf_pr_add 11 feat-edited-fail "Body"
h11=$(jq -r .headRefOid "$MF_GH_DIR/pr-11.json")
set_checks 11 "$green_checks"
post_verdict 11 PASS "$h11"
post_verdict 11 FAIL "$h11"
mf_comment_flag 11 1 edited true
: > "$MF_GH_LOG"
run_ship --repo example/repo --pr 11
if [ "$SHIP_RC" -ne 0 ] && [ "$(wc -l <<<"$SHIP_OUT" | tr -d ' ')" -eq 1 ] \
  && grep -Fq "newest Verdict on PR 11 is FAIL" <<<"$SHIP_OUT" \
  && ! grep -q "pr merge" "$MF_GH_LOG"; then
  ok "edited FAIL still blocks older PASS"
else
  bad "edited FAIL still blocks older PASS" "rc=$SHIP_RC out=$SHIP_OUT"
fi

# 12. Empty statusCheckRollup refuses
mf_pr_add 12 feat-nochecks "Body"
h12=$(jq -r .headRefOid "$MF_GH_DIR/pr-12.json")
set_checks 12 '[]'
post_verdict 12 PASS "$h12"
: > "$MF_GH_LOG"
run_ship --repo example/repo --pr 12
if [ "$SHIP_RC" -ne 0 ] && [ "$(wc -l <<<"$SHIP_OUT" | tr -d ' ')" -eq 1 ] \
  && grep -Fq "no checks reported at head $h12" <<<"$SHIP_OUT" \
  && ! grep -q "pr merge" "$MF_GH_LOG"; then
  ok "empty statusCheckRollup refuses"
else
  bad "empty statusCheckRollup refuses" "rc=$SHIP_RC out=$SHIP_OUT"
fi

# 12a. A check name is judged by its newest run; a superseded SKIPPED run does not block
rollup_case() { # <pr> <expect ship|refuse> <label> <json array>
  local n=$1 want=$2 label=$3 h
  mf_pr_add "$n" "feat-rollup-$n" "Body"
  h=$(jq -r .headRefOid "$MF_GH_DIR/pr-$n.json"); mf_self_review "$n" "$h"
  set_checks "$n" "$4"; post_verdict "$n" PASS "$h"
  run_ship --repo example/repo --pr "$n"
  if [ "$want" = ship ] && [ "$SHIP_RC" -eq 0 ] && [[ "$SHIP_OUT" =~ ^shipped\ PR\ $n ]]; then ok "$label"
  elif [ "$want" = refuse ] && [ "$SHIP_RC" -ne 0 ] && grep -Fq "required checks are not all SUCCESS" <<<"$SHIP_OUT"; then ok "$label"
  else bad "$label" "rc=$SHIP_RC out=$SHIP_OUT"; fi
}
rollup_case 121 ship "SKIPPED newer than SUCCESS, same name, ships" \
  '[{"name":"head-checks","status":"COMPLETED","conclusion":"SKIPPED","startedAt":"2026-11-14T06:13:43Z","completedAt":"2026-11-14T06:13:43Z"},{"name":"head-checks","status":"COMPLETED","conclusion":"SUCCESS","startedAt":"2026-11-14T05:36:50Z","completedAt":"2026-11-14T05:52:44Z"},{"context":"review","state":"SUCCESS","startedAt":"2026-11-14T06:12:34Z"}]'
rollup_case 122 refuse "SKIPPED as the only run of a name refuses" \
  '[{"name":"head-checks","status":"COMPLETED","conclusion":"SKIPPED","startedAt":"2026-11-14T06:13:43Z","completedAt":"2026-11-14T06:13:43Z"}]'
rollup_case 123 refuse "newer FAILURE over older SUCCESS refuses" \
  '[{"name":"head-checks","status":"COMPLETED","conclusion":"SUCCESS","startedAt":"2026-11-14T05:36:50Z","completedAt":"2026-11-14T05:52:44Z"},{"name":"head-checks","status":"COMPLETED","conclusion":"FAILURE","startedAt":"2026-11-14T06:00:00Z","completedAt":"2026-11-14T06:10:00Z"}]'
rollup_case 124 ship "newer SUCCESS over older FAILURE ships" \
  '[{"name":"head-checks","status":"COMPLETED","conclusion":"FAILURE","startedAt":"2026-11-14T05:36:50Z","completedAt":"2026-11-14T05:52:44Z"},{"name":"head-checks","status":"COMPLETED","conclusion":"SUCCESS","startedAt":"2026-11-14T06:00:00Z","completedAt":"2026-11-14T06:10:00Z"}]'
rollup_case 125 refuse "pending newer run over older SUCCESS refuses" \
  '[{"name":"head-checks","status":"COMPLETED","conclusion":"SUCCESS","startedAt":"2026-11-14T05:36:50Z","completedAt":"2026-11-14T05:52:44Z"},{"name":"head-checks","status":"IN_PROGRESS","conclusion":"","startedAt":"2026-11-14T06:00:00Z"}]'

# 13. No Self-review needed, no builder dispatch required, no cwd root check: the PR lands from any directory.
# The board call stays on the local Orca when the dispatch record names no remote host.
mf_pr_add 13 feat-no-self-review "Body"
h13=$(jq -r .headRefOid "$MF_GH_DIR/pr-13.json")
mf_self_review 13 "$h13"
set_checks 13 "$green_checks"
post_verdict 13 PASS "$h13" ctx_never_seen ctx_unknown_author
: > "$MF_GH_LOG"
rm -f "$MF_DIR/orca-called"
printf '%s\n' '{"ok":true,"result":{"worktrees":[{"path":"/wt/issue-13","branch":"refs/heads/feat-no-self-review"},{"path":"/wt/other","branch":"refs/heads/other"}]}}' > "$MF_DIR/orca-list"
SHIP_OUT=$(cd "$MF_REPO" && bash "$here/ship.sh" --repo example/repo --pr 13 2>&1); SHIP_RC=$?
if [ "$SHIP_RC" -eq 0 ] && [[ "$SHIP_OUT" =~ ^shipped\ PR\ 13 ]] \
  && grep -Fxq 'worktree set --worktree path:/wt/issue-13 --workspace-status completed' "$MF_DIR/orca-called" \
  && ! grep -q 'branch:' "$MF_DIR/orca-called" && ! grep -q '/wt/other' "$MF_DIR/orca-called" \
  && ! grep -q -- '--environment' "$MF_DIR/orca-called" \
  && ! grep -q 'worker-list' "$MF_DIR/orca-called" \
  && ! grep -q "Self-review" <<<"$(jq -r .body "$MF_GH_DIR/pr-13.json")"; then
  ok "no Self-review check; sets the merged branch's worktree completed by path on the local Orca"
else
  bad "no Self-review check; sets the merged branch's worktree completed by path on the local Orca" "rc=$SHIP_RC out=$SHIP_OUT called=$(cat "$MF_DIR/orca-called" 2>/dev/null)"
fi

# 13a. A failing board call warns and does not undo or fail the merge
mf_pr_add 133 feat-board-fails "Body"
h=$(jq -r .headRefOid "$MF_GH_DIR/pr-133.json"); mf_self_review 133 "$h"; set_checks 133 "$green_checks"
post_verdict 133 PASS "$h"
printf '%s\n' '{"ok":true,"result":{"worktrees":[{"path":"/wt/feat-board-fails","branch":"refs/heads/feat-board-fails"}]}}' > "$MF_DIR/orca-list"
SHIP_OUT=$(ORCA_FAKE_RC=1 bash "$here/ship.sh" --repo example/repo --pr 133 2>&1); SHIP_RC=$?
if [ "$SHIP_RC" -eq 0 ] && [[ "$SHIP_OUT" =~ ^shipped\ PR\ 133 ]] && grep -Fq "could not set completed on path:/wt/feat-board-fails" <<<"$SHIP_OUT"; then
  ok "board failure after merge only warns"
else
  bad "board failure after merge only warns" "rc=$SHIP_RC out=$SHIP_OUT"
fi

# 988. The worktree is on another host. A local set answers selector_not_found; the dispatch record names the host.
mf_pr_add 988 feat-988 "Body"
h988=$(jq -r .headRefOid "$MF_GH_DIR/pr-988.json")
mf_self_review 988 "$h988"
set_checks 988 "$green_checks"
post_verdict 988 PASS "$h988"
cat > "$MF_DIR/fake-orca-988" <<'EOS'
#!/usr/bin/env bash
echo "$*" >> "$ORCA_LOG"
case "$*" in
  orchestration\ worker-list\ *)
    printf '%s\n' '{"ok":true,"result":{"workers":[{"host":"blueDevil","projection":{"host":{"id":"blueDevil"}},"workspace":"repo::/remote/feat-988"}]}}'
    ;;
  'worktree list --json')
    printf '%s\n' '{"ok":true,"result":{"truncated":false,"worktrees":[]}}'
    ;;
  'worktree list --environment blueDevil --json')
    printf '%s\n' '{"ok":true,"result":{"truncated":false,"worktrees":[{"path":"/remote/feat-988","branch":"refs/heads/feat-988"}]}}'
    ;;
  *'--environment blueDevil'*)
    exit 0
    ;;
  'worktree set '*)
    echo 'selector_not_found' >&2
    exit 1
    ;;
  *) echo "unexpected orca: $*" >&2; exit 1 ;;
esac
EOS
chmod +x "$MF_DIR/fake-orca-988"
: > "$MF_DIR/orca-called"
SHIP_OUT=$(ORCA_LOG="$MF_DIR/orca-called" ORCA_CLI_COMMAND="$MF_DIR/fake-orca-988" bash "$here/ship.sh" --repo example/repo --pr 988 2>&1); SHIP_RC=$?
if [ "$SHIP_RC" -eq 0 ] && [[ "$SHIP_OUT" =~ ^shipped\ PR\ 988 ]] \
  && grep -Fxq 'worktree set --worktree path:/remote/feat-988 --workspace-status completed --environment blueDevil' "$MF_DIR/orca-called" \
  && ! grep -Fq 'selector_not_found' <<<"$SHIP_OUT"; then
  ok "board status is set on the host from the dispatch record"
else
  bad "board status is set on the host from the dispatch record" "rc=$SHIP_RC out=$SHIP_OUT called=$(cat "$MF_DIR/orca-called" 2>/dev/null)"
fi

# --environment skips the lookup and is the host the card is set on.
mf_pr_add 989 feat-989 "Body"
h989=$(jq -r .headRefOid "$MF_GH_DIR/pr-989.json")
mf_self_review 989 "$h989"
set_checks 989 "$green_checks"
post_verdict 989 PASS "$h989"
printf '%s\n' '{"ok":true,"result":{"worktrees":[{"path":"/wt/feat-989","branch":"refs/heads/feat-989"}]}}' > "$MF_DIR/orca-list"
: > "$MF_DIR/orca-called"
SHIP_OUT=$(bash "$here/ship.sh" --repo example/repo --pr 989 --environment other-host 2>&1); SHIP_RC=$?
if [ "$SHIP_RC" -eq 0 ] && [[ "$SHIP_OUT" =~ ^shipped\ PR\ 989 ]] \
  && [ "$(cat "$MF_DIR/orca-called")" = "worktree list --environment other-host --json
worktree set --worktree path:/wt/feat-989 --workspace-status completed --environment other-host" ]; then
  ok "--environment sets the card on that host without a lookup"
else
  bad "--environment sets the card on that host without a lookup" "rc=$SHIP_RC out=$SHIP_OUT called=$(cat "$MF_DIR/orca-called" 2>/dev/null)"
fi

# 1184. Every worktree of the issue is completed: builder, verify, rework and their -2..-n copies. Others stay.
mf_pr_add 1184 feat-1184 "Closes #4242"
h1184=$(jq -r .headRefOid "$MF_GH_DIR/pr-1184.json")
mf_self_review 1184 "$h1184"
set_checks 1184 "$green_checks"
post_verdict 1184 PASS "$h1184"
printf '%s\n' '{"ok":true,"result":{"worktrees":[
 {"path":"/wt/issue-4242","branch":"refs/heads/feat-1184"},
 {"path":"/wt/issue-4242-2","branch":"refs/heads/feat-1184-2"},
 {"path":"/wt/verify-4242","branch":"refs/heads/verify-x"},
 {"path":"/wt/verify-4242-3","branch":""},
 {"path":"/wt/rework-4242-2","branch":"refs/heads/rework-y"},
 {"path":"/wt/verify-42420","branch":"refs/heads/z"},
 {"path":"/wt/verify-9999","branch":"refs/heads/w"}]}}' > "$MF_DIR/orca-list"
: > "$MF_DIR/orca-called"
SHIP_OUT=$(bash "$here/ship.sh" --repo example/repo --pr 1184 2>&1); SHIP_RC=$?
done_paths=$(grep -o 'path:[^ ]*' "$MF_DIR/orca-called" | sort | tr '\n' ' ')
if [ "$SHIP_RC" -eq 0 ] \
  && [ "$done_paths" = "path:/wt/issue-4242 path:/wt/issue-4242-2 path:/wt/rework-4242-2 path:/wt/verify-4242 path:/wt/verify-4242-3 " ]; then
  ok "ship completes the builder, verify and rework worktrees of the issue, copies included"
else
  bad "ship completes the builder, verify and rework worktrees of the issue, copies included" "rc=$SHIP_RC paths=$done_paths out=$SHIP_OUT"
fi
rm -f "$MF_DIR/orca-list"

# 13b. A Verdict without agent and model refuses; a PR without a Builder line refuses
mf_pr_add 131 feat-old-verdict "Body"
h=$(jq -r .headRefOid "$MF_GH_DIR/pr-131.json"); mf_self_review 131 "$h"; set_checks 131 "$green_checks"
post_verdict 131 PASS "$h" ctx_verifier ctx_author none
run_ship --repo example/repo --pr 131
if [ "$SHIP_RC" -ne 0 ] && grep -Fq "does not record the verifier agent and model" <<<"$SHIP_OUT"; then ok "Verdict without agent and model refuses"; else bad "Verdict without agent and model refuses" "rc=$SHIP_RC out=$SHIP_OUT"; fi
mf_pr_add 132 feat-no-builder "Body"
h=$(jq -r .headRefOid "$MF_GH_DIR/pr-132.json"); set_checks 132 "$green_checks"; post_verdict 132 PASS "$h"
run_ship --repo example/repo --pr 132
if [ "$SHIP_RC" -ne 0 ] && grep -Fq "no 'Builder: agent=<agent> model=<model>' line" <<<"$SHIP_OUT"; then ok "PR without a Builder line refuses"; else bad "PR without a Builder line refuses" "rc=$SHIP_RC out=$SHIP_OUT"; fi
# A verifier from a different model family passes the pair rule.
mf_pr_add 133 feat-other-agent "Body"
h=$(jq -r .headRefOid "$MF_GH_DIR/pr-133.json"); mf_self_review 133 "$h" claude/opus; set_checks 133 "$green_checks"; post_verdict 133 PASS "$h" ctx_verifier ctx_author antigravity/gemini-3-pro
run_ship --repo example/repo --pr 133
if [ "$SHIP_RC" -eq 0 ]; then ok "a verifier from a different model family passes"; else bad "a verifier from a different model family passes" "rc=$SHIP_RC out=$SHIP_OUT"; fi

# 13c. Docs only: a cold Review: PASS at the head (or a Verdict, see 13d) lands; code still needs a Verdict
docs_case() { # <pr> <branch> <file> <review line or empty> <expect ship|refuse> <label> [text] [flags]
  local n=$1 b=$2 f=$3 line=$4 expect=$5 label=$6 text=${7:-} h
  mf_pr_add "$n" "$b" "Body" "$f"
  h=$(jq -r .headRefOid "$MF_GH_DIR/pr-$n.json"); set_checks "$n" "$green_checks"
  [ -z "$line" ] || gh pr comment "$n" --repo example/repo --body "${line//@HEAD@/$h}" >/dev/null
  : > "$MF_GH_LOG"
  run_ship --repo example/repo --pr "$n"
  if [ "$expect" = ship ]; then
    if [ "$SHIP_RC" -eq 0 ] && grep -q "pr merge $n" "$MF_GH_LOG"; then ok "$label"; else bad "$label" "rc=$SHIP_RC out=$SHIP_OUT"; fi
  elif [ "$SHIP_RC" -ne 0 ] && grep -Fq "$text" <<<"$SHIP_OUT" && ! grep -q "pr merge" "$MF_GH_LOG"; then ok "$label"; else bad "$label" "rc=$SHIP_RC out=$SHIP_OUT"; fi
}
docs_case 134 feat-docs-pass notes/doc.md "Review: PASS head=@HEAD@" ship "docs only PR lands on a cold Review: PASS"
docs_case 135 feat-docs-frag changelog.d/135-x.md "Review: PASS head=@HEAD@ main=$(printf 'b%.0s' {1..40})" ship "changelog fragment PR lands on Review: PASS with a main= tail"
docs_case 136 feat-docs-none notes/doc2.md "" refuse "docs only PR without Review refuses" "needs a cold 'Review: PASS head="
docs_case 137 feat-docs-stale notes/doc3.md "Review: PASS head=$(printf 'c%.0s' {1..40})" refuse "Review at another head refuses" "needs a cold 'Review: PASS head="
docs_case 138 feat-code-review-only notes/code.sh "Review: PASS head=@HEAD@" refuse "a code PR does not land on Review: PASS" "missing Verdict comment"
mf_pr_add 139 feat-docs-fail "Body" notes/doc4.md
h=$(jq -r .headRefOid "$MF_GH_DIR/pr-139.json"); set_checks 139 "$green_checks"
gh pr comment 139 --repo example/repo --body "Review: PASS head=$h" >/dev/null; gh pr comment 139 --repo example/repo --body "Review: FAIL head=$h" >/dev/null
run_ship --repo example/repo --pr 139
if [ "$SHIP_RC" -ne 0 ] && grep -Fq "newest Review on PR 139 is FAIL" <<<"$SHIP_OUT"; then ok "a newer Review: FAIL refuses a docs only PR"; else bad "a newer Review: FAIL refuses a docs only PR" "rc=$SHIP_RC out=$SHIP_OUT"; fi
mf_pr_add 140 feat-docs-edited "Body" notes/doc5.md
h=$(jq -r .headRefOid "$MF_GH_DIR/pr-140.json"); set_checks 140 "$green_checks"
gh pr comment 140 --repo example/repo --body "Review: PASS head=$h" >/dev/null; mf_comment_flag 140 0 edited true
run_ship --repo example/repo --pr 140
if [ "$SHIP_RC" -ne 0 ] && grep -Fq "needs a cold 'Review: PASS head=" <<<"$SHIP_OUT"; then ok "an edited Review: PASS does not count"; else bad "an edited Review: PASS does not count" "rc=$SHIP_RC out=$SHIP_OUT"; fi

# 13d. Docs only: a post-verdict.sh Verdict at the exact head also lands; FAIL or an older head refuses
docs_verdict_case() { # <pr> <branch> <file> <result> <verdict head: @HEAD@ or sha> <expect ship|refuse> <label> [text]
  local n=$1 b=$2 f=$3 res=$4 vh=$5 expect=$6 label=$7 text=${8:-} h
  mf_pr_add "$n" "$b" "Body" "$f"
  h=$(jq -r .headRefOid "$MF_GH_DIR/pr-$n.json"); mf_self_review "$n" "$h" cursor/grok-4.7-high; set_checks "$n" "$green_checks"
  post_verdict "$n" "$res" "${vh//@HEAD@/$h}"
  : > "$MF_GH_LOG"
  run_ship --repo example/repo --pr "$n"
  if [ "$expect" = ship ]; then
    if [ "$SHIP_RC" -eq 0 ] && grep -q "pr merge $n" "$MF_GH_LOG"; then ok "$label"; else bad "$label" "rc=$SHIP_RC out=$SHIP_OUT"; fi
  elif [ "$SHIP_RC" -ne 0 ] && grep -Fq "$text" <<<"$SHIP_OUT" && ! grep -q "pr merge" "$MF_GH_LOG"; then ok "$label"; else bad "$label" "rc=$SHIP_RC out=$SHIP_OUT"; fi
}
docs_verdict_case 141 feat-docs-vpass notes/v1.md PASS @HEAD@ ship "docs only PR lands on a Verdict: PASS at the head"
docs_verdict_case 142 feat-docs-vnotes notes/v2.md PASS+NOTES @HEAD@ ship "docs only PR lands on a Verdict: PASS+NOTES at the head"
docs_verdict_case 143 feat-docs-vold notes/v3.md PASS "$(printf 'c%.0s' {1..40})" refuse "a Verdict at an older head does not count" "needs a cold 'Review: PASS head="
docs_verdict_case 144 feat-docs-vfail notes/v4.md FAIL @HEAD@ refuse "a FAIL Verdict at the head refuses a docs only PR" "newest Verdict on PR 144 is FAIL"
mf_pr_add 145 feat-docs-vsame "Body" notes/v5.md
h=$(jq -r .headRefOid "$MF_GH_DIR/pr-145.json"); mf_self_review 145 "$h" claude/opus; set_checks 145 "$green_checks"; post_verdict 145 PASS "$h"
run_ship --repo example/repo --pr 145
if [ "$SHIP_RC" -ne 0 ] && grep -Fq "is the same agent and model as the builder" <<<"$SHIP_OUT"; then ok "a docs Verdict from the builder's own agent and model refuses"; else bad "a docs Verdict from the builder's own agent and model refuses" "rc=$SHIP_RC out=$SHIP_OUT"; fi

# 13e. Tier 0 (#1730): test files and docs only, 150 changed lines or fewer, take the docs lane (cold Review: PASS, no Verdict)
docs_case 1730 feat-t0-pass script/tests/test_t0.py "Review: PASS head=@HEAD@" ship "tier 0 test only PR lands on a cold Review: PASS and green Checks"
docs_case 1731 feat-t0-none script/tests/test_t0b.py "" refuse "tier 0 PR without Review refuses" "needs a cold 'Review: PASS head="
docs_case 1732 feat-t0-helper script/tests/lib/t0.sh "Review: PASS head=@HEAD@" refuse "a shared test helper is not tier 0 and needs a Verdict" "missing Verdict comment"
docs_case 1733 feat-t0-auth script/tests/test_auth.py "Review: PASS head=@HEAD@" refuse "a protected path (auth) is not tier 0" "missing Verdict comment"
mf_pr_add 1734 feat-t0-big "Body" script/tests/test_big.py
jq '.files[0].additions = 151' "$MF_GH_DIR/pr-1734.json" > "$MF_GH_DIR/pr-1734.tmp" && mv "$MF_GH_DIR/pr-1734.tmp" "$MF_GH_DIR/pr-1734.json"
h=$(jq -r .headRefOid "$MF_GH_DIR/pr-1734.json"); set_checks 1734 "$green_checks"; gh pr comment 1734 --repo example/repo --body "Review: PASS head=$h" >/dev/null
run_ship --repo example/repo --pr 1734
if [ "$SHIP_RC" -ne 0 ] && grep -Fq "missing Verdict comment" <<<"$SHIP_OUT"; then ok "a test only PR over 150 lines is not tier 0"; else bad "a test only PR over 150 lines is not tier 0" "rc=$SHIP_RC out=$SHIP_OUT"; fi
mf_pr_add 1735 feat-t0-red "Body" script/tests/test_red.py
h=$(jq -r .headRefOid "$MF_GH_DIR/pr-1735.json"); gh pr comment 1735 --repo example/repo --body "Review: PASS head=$h" >/dev/null
run_ship --repo example/repo --pr 1735
if [ "$SHIP_RC" -ne 0 ] && grep -Fq "checks" <<<"$SHIP_OUT"; then ok "tier 0 still needs green Checks at the head"; else bad "tier 0 still needs green Checks at the head" "rc=$SHIP_RC out=$SHIP_OUT"; fi

# 14-15. Patch-id carry refuses an empty or whitespace-only commit after the verdict head (#771)
blank_case() { # <pr> <branch> <empty|whitespace>
  local n=$1 b=$2 kind=$3 old new
  mf_pr_add "$n" "$b" "Body"
  old=$(jq -r .headRefOid "$MF_GH_DIR/pr-$n.json")
  "$MF_REAL_GIT" -C "$MF_REPO" checkout -q "$b"
  if [ "$kind" = empty ]; then
    "$MF_REAL_GIT" -C "$MF_REPO" commit -q --allow-empty -m "empty"
  else
    printf '%s   \n' "$b" > "$MF_REPO/$b.txt"
    "$MF_REAL_GIT" -C "$MF_REPO" commit -q -am "whitespace"
  fi
  "$MF_REAL_GIT" -C "$MF_REPO" push -q -f origin "$b"
  "$MF_REAL_GIT" -C "$MF_REPO" checkout -q main
  new=$("$MF_REAL_GIT" -C "$MF_REPO" rev-parse "$b")
  jq --arg h "$new" '.headRefOid = $h' "$MF_GH_DIR/pr-$n.json" > "$MF_GH_DIR/pr-$n.tmp" && mv "$MF_GH_DIR/pr-$n.tmp" "$MF_GH_DIR/pr-$n.json"
  mf_self_review "$n" "$new"
  set_checks "$n" "$green_checks"
  post_verdict "$n" PASS "$old"
  : > "$MF_GH_LOG"
  run_ship --repo example/repo --pr "$n"
  if [ "$SHIP_RC" -ne 0 ] && grep -Fq "commit ${new:0:12} after verdict head ${old:0:12} is empty or whitespace only" <<<"$SHIP_OUT" \
    && ! grep -q "pr merge" "$MF_GH_LOG"; then
    ok "$kind commit after verdict head refuses"
  else
    bad "$kind commit after verdict head refuses" "rc=$SHIP_RC out=$SHIP_OUT"
  fi
}
blank_case 14 feat-empty empty
blank_case 15 feat-ws whitespace

# 940. A wording-only change after the Verdict head ships on green checks; code, protected paths and code fences keep the patch-id refusal
wording_case() { # <pr> <branch> <file> <content> <expect ship|refuse> <label> [rename-from: a file the PR already has, moved to <file> unchanged] [pre: content <file> has at the Verdict head]
  local n=$1 b=$2 f=$3 content=$4 expect=$5 label=$6 from=${7:-} pre=${8:-} old new
  mf_pr_add "$n" "$b" "Body" ${from:+"$from"}
  if [ -n "$pre" ]; then
    "$MF_REAL_GIT" -C "$MF_REPO" checkout -q "$b"
    mkdir -p "$MF_REPO/$(dirname "$f")"
    printf '%s\n' "$pre" > "$MF_REPO/$f"
    "$MF_REAL_GIT" -C "$MF_REPO" add -A
    "$MF_REAL_GIT" -C "$MF_REPO" commit -q -m "before verdict"
    "$MF_REAL_GIT" -C "$MF_REPO" push -q -f origin "$b"
    "$MF_REAL_GIT" -C "$MF_REPO" checkout -q main
    jq --arg h "$("$MF_REAL_GIT" -C "$MF_REPO" rev-parse "$b")" '.headRefOid = $h' "$MF_GH_DIR/pr-$n.json" > "$MF_GH_DIR/pr-$n.tmp" && mv "$MF_GH_DIR/pr-$n.tmp" "$MF_GH_DIR/pr-$n.json"
  fi
  old=$(jq -r .headRefOid "$MF_GH_DIR/pr-$n.json")
  "$MF_REAL_GIT" -C "$MF_REPO" checkout -q "$b"
  mkdir -p "$MF_REPO/$(dirname "$f")"
  if [ -n "$from" ]; then
    "$MF_REAL_GIT" -C "$MF_REPO" mv "$from" "$f"
  else
    printf '%s\n' "$content" > "$MF_REPO/$f"
  fi
  "$MF_REAL_GIT" -C "$MF_REPO" add -A
  "$MF_REAL_GIT" -C "$MF_REPO" commit -q -m "after verdict"
  "$MF_REAL_GIT" -C "$MF_REPO" push -q -f origin "$b"
  "$MF_REAL_GIT" -C "$MF_REPO" checkout -q main
  new=$("$MF_REAL_GIT" -C "$MF_REPO" rev-parse "$b")
  jq --arg h "$new" --arg f "$f" '.headRefOid = $h | .files += [{path:$f, filename:$f}]' "$MF_GH_DIR/pr-$n.json" > "$MF_GH_DIR/pr-$n.tmp" && mv "$MF_GH_DIR/pr-$n.tmp" "$MF_GH_DIR/pr-$n.json"
  mf_self_review "$n" "$new"
  set_checks "$n" "$green_checks"
  post_verdict "$n" PASS "$old"
  : > "$MF_GH_LOG"
  run_ship --repo example/repo --pr "$n"
  if [ "$expect" = ship ]; then
    if [ "$SHIP_RC" -eq 0 ] && grep -q "pr merge $n" "$MF_GH_LOG"; then ok "$label"; else bad "$label" "rc=$SHIP_RC out=$SHIP_OUT"; fi
  elif [ "$SHIP_RC" -ne 0 ] && grep -Fq "patch-id does not match" <<<"$SHIP_OUT" && ! grep -q "pr merge" "$MF_GH_LOG"; then ok "$label"; else bad "$label" "rc=$SHIP_RC out=$SHIP_OUT"; fi
}
wording_case 60 feat-word-docs docs/note.md "plain words" ship "docs text change after the Verdict ships with no new Verdict"
wording_case 61 feat-word-log changelog.d/61-x.md "a fragment" ship "changelog fragment after the Verdict ships"
wording_case 62 feat-word-top README.md "top level words" ship "top level .md after the Verdict ships"
wording_case 63 feat-word-sh script/new.sh "echo hi" refuse "a .sh change after the Verdict is refused"
wording_case 64 feat-word-hook .claude/hooks/guard.md "words" refuse "a hooks path change after the Verdict is refused"
wording_case 65 feat-word-intent docs/intent/x.md "words" refuse "an intent change after the Verdict is refused"
wording_case 66 feat-word-fence docs/fence.md '```sh
rm -rf x
```' refuse "a docs change that adds a code fence is refused"
wording_case 67 feat-word-nested notes/other.md "words" refuse "a .md outside docs and changelog.d is refused"
wording_case 68 feat-word-rename docs/run.md "" refuse "a script renamed into docs after the Verdict is refused" script/run.sh
fence_doc='intro
```sh
rm -rf x
```
outro'
wording_case 69 feat-word-infence docs/f1.md 'intro
```sh
rm -rf y
```
outro' refuse "an edit to a line inside an existing code fence is refused" "" "$fence_doc"
wording_case 70 feat-word-outfence docs/f2.md 'intro changed
```sh
rm -rf x
```
outro' ship "a prose edit outside an existing code fence still ships" "" "$fence_doc"
wording_case 71 feat-word-claude CLAUDE.md "@AGENTS.md" refuse "a top level CLAUDE.md change is refused"

# Red main: refuses and names the run, unless the PR body says it fixes that run and the PR touches what failed.
# red_main_case <pr> <branch> <body-line or empty> <expect: refuse|ship> <pr file> <label> [conclusion] [expect text]
red_main_case() {
  local n=$1 b=$2 line=$3 expect=$4 file=$5 label=$6 conclusion=${7:-failure} text=${8:-https://example.test/runs/777} h
  mf_pr_add "$n" "$b" "Body" "$file"
  if [ -n "$line" ]; then
    jq --arg l "$line" '.body += "\n" + $l' "$MF_GH_DIR/pr-$n.json" > "$MF_GH_DIR/pr-$n.tmp" && mv "$MF_GH_DIR/pr-$n.tmp" "$MF_GH_DIR/pr-$n.json"
  fi
  h=$(jq -r .headRefOid "$MF_GH_DIR/pr-$n.json")
  mf_self_review "$n" "$h"
  set_checks "$n" "$green_checks"
  post_verdict "$n" PASS "$h"
  jq -n --arg c "$conclusion" --arg s "$main_sha" '{databaseId:777,conclusion:$c,url:"https://example.test/runs/777",headSha:$s}' > "$MF_GH_DIR/main-run.json"
  printf 'script/post-verdict.sh\n' > "$MF_GH_DIR/commit-$main_sha.txt"
  : > "$MF_GH_LOG"
  run_ship --repo example/repo --pr "$n"
  rm -f "$MF_GH_DIR/main-run.json" "$MF_GH_DIR/main-run-fails"
  if [ "$expect" = refuse ]; then
    if [ "$SHIP_RC" -ne 0 ] && grep -Fq "$text" <<<"$SHIP_OUT" && ! grep -q "pr merge" "$MF_GH_LOG"; then
      ok "$label"
    else
      bad "$label" "rc=$SHIP_RC out=$SHIP_OUT"
    fi
  elif [ "$SHIP_RC" -eq 0 ] && grep -q "pr merge $n" "$MF_GH_LOG"; then
    ok "$label"
  else
    bad "$label" "rc=$SHIP_RC out=$SHIP_OUT"
  fi
}
main_sha=$(printf 'a%.0s' {1..40})
red_main_case 16 feat-red-main "" refuse script/post-verdict.sh "red main refuses and names the run"
red_main_case 17 feat-red-wrong-run "Fixes main: 778" refuse script/post-verdict.sh "Fixes main for another run refuses"
red_main_case 18 feat-fix-main "Fixes main: 777" ship script/post-verdict.sh "PR that touches a file of the red main commit ships"
red_main_case 19 feat-fix-main-test "Fixes main: 777" ship script/tests/post-verdict.test.sh "PR that touches a test of the red main commit ships"
red_main_case 20 feat-fix-unrelated "Fixes main: 777" refuse notes/unrelated.txt "Fixes main with unrelated files refuses" failure "touches neither the files nor the tests"
red_main_case 21 feat-cancelled-main "" refuse script/post-verdict.sh "cancelled main says rerun or fix main first" cancelled "rerun or fix main first"

# Several commits landed on main since the last green push run: the fix may touch any of them (#1670).
range_case() { # <pr> <branch> <pr file> <expect> <label> [text]
  local n=$1 b=$2 file=$3 expect=$4 label=$5 text=${6:-touches neither}
  local base_sha mid_sha
  base_sha=$(printf 'b%.0s' {1..40}); mid_sha=$(printf 'c%.0s' {1..40})
  mf_pr_add "$n" "$b" "Body" "$file"
  jq '.body += "\nFixes main: 777"' "$MF_GH_DIR/pr-$n.json" > "$MF_GH_DIR/pr-$n.tmp" && mv "$MF_GH_DIR/pr-$n.tmp" "$MF_GH_DIR/pr-$n.json"
  h=$(jq -r .headRefOid "$MF_GH_DIR/pr-$n.json")
  mf_self_review "$n" "$h"; set_checks "$n" "$green_checks"; post_verdict "$n" PASS "$h"
  jq -n --arg s "$main_sha" '{databaseId:777,conclusion:"failure",url:"https://example.test/runs/777",headSha:$s}' > "$MF_GH_DIR/main-run.json"
  jq -n --arg s "$base_sha" '{databaseId:700,conclusion:"success",url:"https://example.test/runs/700",headSha:$s}' > "$MF_GH_DIR/main-base.json"
  printf 'notes/head-only.txt\n' > "$MF_GH_DIR/commit-$main_sha.txt"
  printf 'script/range-earlier.sh\nnotes/head-only.txt\n' > "$MF_GH_DIR/commit-compare-$base_sha...$main_sha.txt"
  : > "$MF_GH_LOG"
  run_ship --repo example/repo --pr "$n"
  rm -f "$MF_GH_DIR/main-run.json" "$MF_GH_DIR/main-base.json"
  if [ "$expect" = ship ]; then
    if [ "$SHIP_RC" -eq 0 ] && grep -q "pr merge $n" "$MF_GH_LOG"; then ok "$label"; else bad "$label" "rc=$SHIP_RC out=$SHIP_OUT"; fi
  elif [ "$SHIP_RC" -ne 0 ] && grep -Fq "$text" <<<"$SHIP_OUT" && ! grep -q "pr merge" "$MF_GH_LOG"; then ok "$label"; else bad "$label" "rc=$SHIP_RC out=$SHIP_OUT"; fi
}
range_case 24 feat-range-fix script/range-earlier.sh ship "fix touching an earlier commit of the red range ships"
range_case 25 feat-range-unrelated notes/unrelated.txt refuse "fix touching nothing in the red range refuses"

# A second always-run guard in the selector (as #1601 adds) must not make an unrelated PR overlap main's tests (#1620).
cat > "$MF_DIR/fake-selector" <<'SEL'
#!/usr/bin/env bash
shift # --list-only
for p in "$@"; do [ "$p" = script/post-verdict.sh ] && echo "Selected: script/tests/post-verdict.test.sh"; done
echo "Selected: script/tests/no-project-names.test.sh"
echo "Selected: script/tests/script-docs-coverage.test.sh"
SEL
chmod +x "$MF_DIR/fake-selector"
SHIP_SELECT_TESTS="$MF_DIR/fake-selector" red_main_case 23 feat-fix-unrelated-2 "Fixes main: 777" refuse notes/unrelated.txt "Fixes main with unrelated files refuses with two always-run guards" failure "touches neither the files nor the tests"

# gh failing while reading main's Checks run refuses and merges nothing.
mf_pr_add 22 feat-main-gh-fails "Body"
h=$(jq -r .headRefOid "$MF_GH_DIR/pr-22.json")
mf_self_review 22 "$h"
set_checks 22 "$green_checks"
post_verdict 22 PASS "$h"
: > "$MF_GH_DIR/main-run-fails"
: > "$MF_GH_LOG"
run_ship --repo example/repo --pr 22
rm -f "$MF_GH_DIR/main-run-fails"
if [ "$SHIP_RC" -ne 0 ] && grep -Fq "cannot read the latest Checks run on main" <<<"$SHIP_OUT" && ! grep -q "pr merge" "$MF_GH_LOG"; then
  ok "gh failing on main's Checks run refuses"
else
  bad "gh failing on main's Checks run refuses" "rc=$SHIP_RC out=$SHIP_OUT"
fi

# Only push runs count: a pull_request run from a fork's main branch must not.
if grep -q "run list .*--event push" "$MF_GH_LOG" || { : > "$MF_GH_LOG"; run_ship --repo example/repo --pr 22 >/dev/null; grep -q "run list .*--event push" "$MF_GH_LOG"; }; then
  ok "main run lookup is limited to push events"
else
  bad "main run lookup is limited to push events" "$(cat "$MF_GH_LOG")"
fi

# --mechanical: pure substitution or deletion lands with no Verdict (ported from the old merge script)
mech_case() { # <pr> <expect ship|refuse> <label> <text> <diff body>; the fake gh serves a PR diff of the file list, so fixtures use a wrapper
  local n=$1 expect=$2 label=$3 text=$4 diff=$5 h
  mf_pr_add "$n" "feat-mech-$n" "Body" "${6:-script/mech-$n.sh}"
  h=$(jq -r .headRefOid "$MF_GH_DIR/pr-$n.json"); set_checks "$n" "$green_checks"
  mkdir -p "$MF_DIR/mech-$n"
  printf '#!/usr/bin/env bash\nif [ "$1 $2" = "pr diff" ]; then printf %%s "$MECH_DIFF"; exit 0; fi\nexec "%s/gh" "$@"\n' "$MF_BIN" > "$MF_DIR/mech-$n/gh"; chmod +x "$MF_DIR/mech-$n/gh"
  : > "$MF_GH_LOG"
  SHIP_OUT=$(MECH_DIFF="$diff" PATH="$MF_DIR/mech-$n:$PATH" bash "$here/ship.sh" --repo example/repo --pr "$n" --mechanical 2>&1); SHIP_RC=$?
  if [ "$expect" = ship ]; then
    if [ "$SHIP_RC" -eq 0 ] && grep -q "pr merge $n" "$MF_GH_LOG" && grep -Fq "mechanical lane" <<<"$SHIP_OUT"; then ok "$label"; else bad "$label" "rc=$SHIP_RC out=$SHIP_OUT"; fi
  elif [ "$SHIP_RC" -ne 0 ] && grep -Fq "$text" <<<"$SHIP_OUT" && ! grep -q "pr merge" "$MF_GH_LOG"; then ok "$label"; else bad "$label" "rc=$SHIP_RC out=$SHIP_OUT"; fi
}
SUBST=$'diff --git a/script/foo.sh b/script/foo.sh\n--- a/script/foo.sh\n+++ b/script/foo.sh\n@@ -1 +1 @@\n-echo old\n+echo new\n'
mech_case 150 ship "mechanical substitution needs no Verdict" "" "$SUBST"
mech_case 151 ship "mechanical allows whole file deletion" "" "$SUBST"$'diff --git a/old.txt b/old.txt\ndeleted file mode 100644\n--- a/old.txt\n+++ /dev/null\n@@ -1,2 +0,0 @@\n-a\n-b\n'
mech_case 152 refuse "mechanical refuses an added logic line" "pure substitution" $'diff --git a/script/foo.sh b/script/foo.sh\n--- a/script/foo.sh\n+++ b/script/foo.sh\n@@ -1 +1,2 @@\n echo hi\n+rm -rf "$x"\n'
mech_case 153 refuse "mechanical names a path with spaces" 'script/a b/c.sh: 0 removed, 1 added' $'diff --git a/script/a b/c.sh b/script/a b/c.sh\n--- a/script/a b/c.sh\n+++ b/script/a b/c.sh\n@@ -1 +1,2 @@\n echo hi\n+rm -rf "$x"\n'
mech_case 154 refuse "mechanical refuses a new script" "new file" $'diff --git a/script/new.sh b/script/new.sh\nnew file mode 100755\n--- /dev/null\n+++ b/script/new.sh\n@@ -0,0 +1 @@\n+echo hi\n'
mech_case 155 refuse "mechanical refuses a rename" "renames" $'diff --git a/a b/b\nsimilarity index 90%\nrename from a\nrename to b\n'
mech_case 156 refuse "mechanical still refuses protected paths" "owner through Elon" "$SUBST" .claude/settings.json
mech_case 157 refuse "mechanical gate file still needs countersign" "Countersign" "$SUBST" script/ship.sh
# Template copies of owner only paths are gated too (issue #954)
mech_case 159 refuse "template hook copy waits for the owner" "owner through Elon" "$SUBST" templates/agent-team/.claude/hooks/guard-bash.py
mech_case 160 refuse "template settings copy waits for the owner" "owner through Elon" "$SUBST" templates/agent-team/.claude/settings.json
# Without the flag the same PR needs a Verdict
mf_pr_add 158 feat-mech-noflag "Body" script/mech-158.sh; set_checks 158 "$green_checks"
run_ship --repo example/repo --pr 158
if [ "$SHIP_RC" -ne 0 ] && grep -Fq "missing Verdict comment" <<<"$SHIP_OUT"; then ok "without --mechanical the substitution needs a Verdict"; else bad "without --mechanical the substitution needs a Verdict" "rc=$SHIP_RC out=$SHIP_OUT"; fi
run_ship --repo example/repo --pr 158 --mechanical --verdict-from x/dotfiles#1
if [ "$SHIP_RC" -ne 0 ] && grep -Fq "exclusive" <<<"$SHIP_OUT"; then ok "--verdict-from and --mechanical are exclusive"; else bad "--verdict-from and --mechanical are exclusive" "rc=$SHIP_RC out=$SHIP_OUT"; fi

# --verdict-from: generated team copies land on the Verdict of the matching MERGED dotfiles PR (ported from the old merge script)
{
  # ship.sh renders templates from origin/main, so the fixture syncs from origin/main too: a branch that edits a template must not fail here.
  repo_root="$MF_DIR/main-tree"; mkdir -p "$repo_root"
  git -C "$here/.." archive origin/main | tar -x -C "$repo_root"
  # agent-team.sh syncs every file it lists, so a template file this branch adds (and origin/main lacks) is overlaid as is.
  while IFS= read -r added; do
    mkdir -p "$repo_root/$(dirname "$added")"; cp "$here/../$added" "$repo_root/$added"
  done < <(git -C "$here/.." diff --diff-filter=A --name-only origin/main HEAD -- templates/agent-team)
  fx="$MF_DIR/dot"; mkdir -p "$fx/script" "$fx/.agents/skills"
  cp "$here/ship.sh" "$here/check-project-names.sh" "$here/check-commit-trailers.sh" "$here/usage-gate.py" "$here/pr-body-gate.py" "$here/agent-team.sh" "$here/check-skill-collisions.sh" "$here/check-skill-refs.sh" "$here/apply-local-overlay.py" "$here/ship.config.example.json" "$fx/script/"
  cp -R "$here/lib" "$fx/script/lib"; cp -R "$repo_root/templates" "$fx/templates"
  cp -R "$repo_root/.agents/skills/setup-matt-pocock-skills" "$fx/.agents/skills/setup-matt-pocock-skills"
  # check-skill-refs.sh looks each /skill the generated AGENTS.md names up under $fx; stub SKILL.md files stand in (git drops empty dirs, and the pinned check reads the commit) for the vendored skills.
  for d in "$repo_root"/.agents/skills/*/; do mkdir -p "$fx/.agents/skills/$(basename "$d")"; : > "$fx/.agents/skills/$(basename "$d")/SKILL.md"; done
  "$MF_REAL_GIT" -C "$fx" init -q -b main && "$MF_REAL_GIT" -C "$fx" add . && "$MF_REAL_GIT" -C "$fx" commit -qm fx
  "$MF_REAL_GIT" -C "$fx" update-ref refs/remotes/origin/main HEAD
  g() { "$MF_REAL_GIT" -C "$MF_REPO" "$@"; }
  g fetch -q origin; g checkout -q -B main origin/main
  DOTFILES="$repo_root" bash "$here/agent-team.sh" project "$MF_REPO" --project-name acme >/dev/null 2>&1
  echo "# old" > "$MF_REPO/docs/agents/team.md"; echo "# old" >> "$MF_REPO/bin/changelog-compile.sh"
  echo "# old" >> "$MF_REPO/bin/check-commit-trailers.sh"; echo "# old" >> "$MF_REPO/.githooks/commit-msg"
  g add -A && g commit -qm seed-base && g push -q origin main && g fetch -q origin
  base_sha=$(g rev-parse HEAD)
  g checkout -q -B feat-gen
  DOTFILES="$repo_root" bash "$here/agent-team.sh" sync "$MF_REPO" --project-name acme >/dev/null 2>&1
  g add -A && g commit -qm sync && g push -q -f origin feat-gen
  gen_head=$(g rev-parse HEAD)
  gen_files=$(g diff --name-only "$base_sha" "$gen_head" | jq -Rsc 'split("\n")[:-1]')
  mkpr() { # <n> <head> <files json> <body>
    jq -n --argjson n "$1" --arg h "$2" --arg base "$base_sha" --argjson fl "$3" --arg body "$4" \
      '{number:$n,state:"OPEN",baseRefName:"main",headRefName:"feat-gen",headRefOid:$h,baseRefOid:$base,changedFiles:($fl|length),body:$body,
        files:($fl|map({path:., filename:.})),comments:[],closingIssuesReferences:[],mergeable:"MERGEABLE",mergeCommit:null,statusCheckRollup:[]}' > "$MF_GH_DIR/pr-$1.json"
  }
  mkpr 200 "$gen_head" "$gen_files" "Body"; set_checks 200 "$green_checks"
  DH=dddddddddddddddddddddddddddddddddddddd99
  GOOD="Verdict: PASS head=$DH verifier=ctx_verify author=ctx_author agent=claude model=opus"
  BADF="Verdict: FAIL head=$DH verifier=ctx_verify author=ctx_author agent=claude model=opus"
  src() { # <state> <json comments> [builder line]
    local default=$'Builder: agent=cursor model=grok-4.7-high\n\n## Self-check\n$ bash script/checks-local.sh\nexit 0'
    jq -n --arg st "$1" --arg h "$DH" --argjson c "$2" --arg b "${3:-$default}" \
      '{number:9,state:$st,headRefName:"src",headRefOid:$h,baseRefOid:$h,body:$b,comments:$c,files:[],changedFiles:0,mergeable:"MERGEABLE",mergeCommit:null}' > "$MF_GH_DIR/pr-9.json"
  }
  one() { jq -nc --arg b "$1" '[{body:$b}]'; }
  vf() { # <label> <expect rc> <text> [repo]
    local lbl=$1 want=$2 text=$3 r=${4:-example/repo} saved_dry=1
    : > "$MF_GH_LOG"
    SHIP_OUT=$(bash "$fx/script/ship.sh" --repo "$r" --pr 200 --verdict-from d/dotfiles#9 --dry-run 2>&1); SHIP_RC=$?
    if { [ "$want" = 0 ] && [ "$SHIP_RC" -eq 0 ]; } || { [ "$want" != 0 ] && [ "$SHIP_RC" -ne 0 ]; }; then
      if grep -Fq -- "$text" <<<"$SHIP_OUT"; then ok "$lbl"; else bad "$lbl" "missing [$text] in: $SHIP_OUT"; fi
    else bad "$lbl" "rc=$SHIP_RC out=$SHIP_OUT"; fi
  }
  src MERGED "$(one "$GOOD")"
  vf "verdict-from refuses without local config" 1 "no configured verdict_from_repos"
  printf '{"verdict_from_repos":["example/repo","acme/project-beta"]}\n' > "$fx/script/ship.local.json"
  vf "generated copies land on the dotfiles PR Verdict" 0 "generated team copies"
  vf "verdict-from refuses an unconfigured repo" 1 "repo is not configured" other/repo
  src OPEN "$(one "$GOOD")";  vf "verdict-from refuses an unmerged dotfiles PR" 1 "not MERGED"
  src MERGED "$(one "$BADF")"; vf "verdict-from refuses a FAIL Verdict" 1 "no passing Verdict"
  src MERGED "$(one "${GOOD//$DH/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb}")"; vf "verdict-from refuses a Verdict for another head" 1 "no passing Verdict"
  src MERGED "$(jq -nc --arg g "$GOOD" --arg f "$BADF" '[{body:$g},{body:$f}]')"; vf "verdict-from: a newer FAIL beats an older PASS" 1 "FAIL Verdict"
  src MERGED "$(jq -nc --arg g "$GOOD" --arg f "$BADF" '[{body:$f},{body:$g}]')"; vf "verdict-from: an older FAIL beside a newer PASS refuses" 1 "FAIL Verdict"
  src MERGED "$(jq -nc --arg g "$GOOD" '[{body:$g,edited:true}]')"; vf "verdict-from: an edited Verdict is refused" 1 "edited or minimized"
  src MERGED "$(jq -nc --arg g "$GOOD" '[{body:$g,minimized:true}]')"; vf "verdict-from: a minimized Verdict is refused" 1 "edited or minimized"
  src MERGED "$(jq -nc --arg g "$GOOD" '[{body:$g,edited:true},{body:$g}]')"; vf "verdict-from: a fresh Verdict after an edited one lands" 0 "generated team copies"
  src MERGED "$(jq -nc --arg g "$GOOD" --arg f "$BADF" '[{body:$f,edited:true},{body:$g}]')"; vf "verdict-from: an edited FAIL still refuses" 1 "FAIL Verdict"
  src MERGED "$(one "Verdict: PASS head=$DH verifier=ctx_verify author=ctx_verify agent=claude model=opus")"; vf "verdict-from: author equal to verifier is refused" 1 "author cannot supply"
  src MERGED "$(one "Verdict: PASS head=$DH verifier=ctx_verify author=ctx_author")"; vf "verdict-from: a Verdict without agent and model is refused" 1 "does not record the verifier agent and model"
  src MERGED "$(one "$GOOD")" "Builder: agent=claude model=opus"; vf "verdict-from: verifier with the builder's agent and model is refused" 1 "same agent and model as the builder"
  src MERGED "$(one "$GOOD")" "no builder here"; vf "verdict-from: a source PR without a Builder line is refused" 1 "no 'Builder: agent=<agent> model=<model>' line"
  src MERGED "$(one "$GOOD")"
  # The sync result equals the origin/main render, so the verdict lane does not call it a hand edit.
  # The Verdict gate still applies.
  : > "$MF_GH_LOG"; SHIP_OUT=$(bash "$fx/script/ship.sh" --repo example/repo --pr 200 2>&1); SHIP_RC=$?
  if [ "$SHIP_RC" -ne 0 ] && grep -Fq "missing Verdict comment" <<<"$SHIP_OUT" && ! grep -Fq "edits generated team copy" <<<"$SHIP_OUT"; then
    ok "render-equal generated copies pass the verdict lane and still need a Verdict"
  else
    bad "render-equal generated copies pass the verdict lane and still need a Verdict" "rc=$SHIP_RC out=$SHIP_OUT"
  fi
  # Header string alone is not a generated copy
  g checkout -q -B feat-gen "$base_sha"
  printf '<!-- Generated from dotfiles templates/agent-team/.agents/skills/x by script/sync-team-skills.sh, do not edit. -->\n' > "$MF_REPO/spoof.md"
  g add -A && g commit -qm spoof && sp=$(g rev-parse HEAD)
  mkpr 200 "$sp" '["spoof.md"]' "Body"; set_checks 200 "$green_checks"
  vf "verdict-from refuses a file that only carries the header string" 1 "spoof.md is not"
  # Hand edited generated copy fails agent-team.sh check
  g checkout -q -B feat-gen "$base_sha"; echo "hand edit" >> "$MF_REPO/docs/agents/team.md"
  g add -A && g commit -qm edit && he=$(g rev-parse HEAD)
  mkpr 200 "$he" '["docs/agents/team.md"]' "Body"; set_checks 200 "$green_checks"
  vf "verdict-from refuses a hand edited generated copy" 1 "agent-team.sh check fails"
  # Symlink in a managed path
  g checkout -q -B feat-gen "$base_sha"; ln -sf /etc/passwd "$MF_REPO/docs/agents/team.md"
  g add -A && g commit -qm link && ln_h=$(g rev-parse HEAD)
  mkpr 200 "$ln_h" '["docs/agents/team.md"]' "Body"; set_checks 200 "$green_checks"
  vf "verdict-from refuses a symlink inside a managed path" 1 "refuses symlink"
  # Unmerged template edits must not vouch for themselves
  echo "unmerged template edit" >> "$fx/templates/agent-team/docs/agents/team.md"
  vf "verdict-from refuses when the dotfiles tree differs from origin/main for templates/agent-team" 1 "not at origin/main"
  "$MF_REAL_GIT" -C "$fx" checkout -q -- templates/agent-team
  echo untracked > "$fx/templates/agent-team/untracked-template.md"
  vf "verdict-from refuses an untracked file under templates/agent-team" 1 "not at origin/main"
  rm -f "$fx/templates/agent-team/untracked-template.md"

  # Pinned bump PRs (#1247): the copies are checked against the template at the head's .claude/agent-team-pin.
  fxg() { "$MF_REAL_GIT" -C "$fx" -c user.name=t -c user.email=t@example.invalid "$@"; }
  fx_tpl="$fx/templates/agent-team/docs/agents/team.md"
  pin_p=$(fxg rev-parse HEAD)
  pin_branch() { # <dotfiles dir to sync from> -> sets pin_head, pin_files
    g checkout -q -B feat-gen "$base_sha"
    DOTFILES="$1" bash "$1/script/agent-team.sh" sync "$MF_REPO" --project-name acme >/dev/null 2>&1
  }
  pin_commit() {
    g add -A && g commit -qm bump && g push -q -f origin feat-gen
    pin_head=$(g rev-parse HEAD)
    pin_files=$(g diff --name-only "$base_sha" "$pin_head" | jq -Rsc 'split("\n")[:-1]')
    mkpr 200 "$pin_head" "$pin_files" "Body"; set_checks 200 "$green_checks"
  }
  pin_branch "$fx"; pin_commit
  if [ "$(g show "$pin_head:.claude/agent-team-pin")" = "$pin_p" ]; then
    vf "verdict-from: a bump PR with pin = origin/main passes" 0 "generated team copies"
  else
    bad "verdict-from: a bump PR with pin = origin/main passes" "pin not written: $(g show "$pin_head:.claude/agent-team-pin" 2>&1)"
  fi
  # A template change lands on dotfiles main: the bump PR pinned at the older commit still passes.
  printf '\nA later template change.\n' >> "$fx_tpl"
  fxg commit -qam 'template change'; fxg update-ref refs/remotes/origin/main HEAD
  vf "verdict-from: a bump PR pinned before a later template change still passes" 0 "generated team copies"
  # A pin that is not an ancestor of dotfiles origin/main.
  pin_branch "$fx"; printf '%s\n' 0123456789abcdef0123456789abcdef01234567 > "$MF_REPO/.claude/agent-team-pin"; pin_commit
  vf "verdict-from: a non-ancestor pin is refused" 1 "not an ancestor of dotfiles origin/main"
  # Copies rendered from the newer template but pinned at the older commit do not match the render at the pin.
  pin_branch "$fx"; printf '%s\n' "$pin_p" > "$MF_REPO/.claude/agent-team-pin"; pin_commit
  vf "verdict-from: a copy that does not match the render at the pin is refused" 1 "agent-team.sh check fails"
  fxg checkout -q "$pin_p" -- templates; fxg commit -qam "restore template"; fxg update-ref refs/remotes/origin/main HEAD
  g checkout -q -B feat-gen "$base_sha"

  # A generated-copy PR may also delete the paths check flags: a canonical role file, or a shared
  # hook nothing kept loads. An add, an edit, a kept hook, or an unrelated deletion still refuses.
  src MERGED "$(one "$GOOD")"
  seed_base=$base_sha
  role_rel=.claude/agents/elon.md
  hook_rel=.claude/hooks/strikes.py
  g checkout -q -B main "$seed_base"
  mkdir -p "$MF_REPO/.claude/agents" "$MF_REPO/.claude/hooks"
  printf 'canonical role\n' > "$MF_REPO/$role_rel"
  printf 'shared hook\n' > "$MF_REPO/$hook_rel"
  g add -A && g commit -qm legacy-copies && g push -q origin main
  legacy_base=$(g rev-parse HEAD)
  name_status=$(g diff --name-status "$legacy_base" "$gen_head")
  del_files=$(g diff --name-only "$legacy_base" "$gen_head" | jq -Rsc 'split("\n")[:-1]')
  if grep -q $'^D\t'"$role_rel" <<<"$name_status" && grep -q $'^D\t'"$hook_rel" <<<"$name_status"; then
    base_sha=$legacy_base
    mkpr 200 "$gen_head" "$del_files" "Body"; set_checks 200 "$green_checks"
    vf "verdict-from accepts generated copies plus deletion of a canonical role file and an unkept shared hook" 0 "generated team copies"
  else
    bad "verdict-from accepts generated copies plus deletion of a canonical role file and an unkept shared hook" "fixture diff missing demanded deletions: $name_status"
  fi
  g checkout -q -B feat-gen "$legacy_base"
  printf 'edited role\n' >> "$MF_REPO/$role_rel"
  printf '\n# edited\n' >> "$MF_REPO/docs/agents/team.md"
  g add -A && g commit -qm edit-role && g push -q -f origin feat-gen
  edit_head=$(g rev-parse HEAD)
  edit_files=$(g diff --name-only "$legacy_base" "$edit_head" | jq -Rsc 'split("\n")[:-1]')
  base_sha=$legacy_base
  mkpr 200 "$edit_head" "$edit_files" "Body"; set_checks 200 "$green_checks"
  vf "verdict-from refuses an edit of a canonical role file" 1 "is not"
  g checkout -q -B feat-gen "$seed_base"
  mkdir -p "$MF_REPO/.claude/agents"
  printf 'added role\n' > "$MF_REPO/$role_rel"
  printf '\n# edited\n' >> "$MF_REPO/docs/agents/team.md"
  g add -A && g commit -qm add-role && g push -q -f origin feat-gen
  add_head=$(g rev-parse HEAD)
  add_files=$(g diff --name-only "$seed_base" "$add_head" | jq -Rsc 'split("\n")[:-1]')
  base_sha=$seed_base
  mkpr 200 "$add_head" "$add_files" "Body"; set_checks 200 "$green_checks"
  vf "verdict-from refuses an added canonical role file" 1 "is not"
  g checkout -q -B main "$seed_base"
  printf 'notes\n' > "$MF_REPO/notes.txt"
  g add notes.txt && g commit -qm notes && g push -q -f origin main
  notes_base=$(g rev-parse HEAD)
  g checkout -q -B feat-gen
  rm "$MF_REPO/notes.txt"
  printf '\n# edited\n' >> "$MF_REPO/docs/agents/team.md"
  g add -A && g commit -qm del-notes && g push -q -f origin feat-gen
  notes_head=$(g rev-parse HEAD)
  notes_files=$(g diff --name-only "$notes_base" "$notes_head" | jq -Rsc 'split("\n")[:-1]')
  base_sha=$notes_base
  mkpr 200 "$notes_head" "$notes_files" "Body"; set_checks 200 "$green_checks"
  vf "verdict-from refuses deletion of an unrelated file" 1 "is not"
  g checkout -q -B main "$seed_base"
  mkdir -p "$MF_REPO/.claude/hooks"
  printf 'shared hook\n' > "$MF_REPO/$hook_rel"
  printf 'loads strikes.py\n' > "$MF_REPO/.claude/hooks/local-keep.py"
  g add -A && g commit -qm kept-hook && g push -q -f origin main
  kept_base=$(g rev-parse HEAD)
  g checkout -q -B feat-gen
  rm "$MF_REPO/$hook_rel"
  printf '\n# edited\n' >> "$MF_REPO/docs/agents/team.md"
  g add -A && g commit -qm del-kept && g push -q -f origin feat-gen
  kept_head=$(g rev-parse HEAD)
  kept_files=$(g diff --name-only "$kept_base" "$kept_head" | jq -Rsc 'split("\n")[:-1]')
  base_sha=$kept_base
  mkpr 200 "$kept_head" "$kept_files" "Body"; set_checks 200 "$green_checks"
  vf "verdict-from refuses deletion of a shared hook check keeps" 1 "is not"

  # guard-config.json is project owned and the template only fills in missing defaults (#1366). A sync PR that
  # only adds those defaults lands with the other generated copies. A changed or dropped project key is refused.
  g checkout -q -B main "$seed_base"
  printf '{\n  "project_key": ["keep-me"]\n}\n' > "$MF_REPO/.claude/hooks/guard-config.json"
  g add -A && g commit -qm guard-base && g push -q -f origin main
  guard_base=$(g rev-parse HEAD)
  g checkout -q -B feat-gen
  DOTFILES="$repo_root" bash "$here/agent-team.sh" sync "$MF_REPO" --project-name acme >/dev/null 2>&1
  g add -A && g commit -qm guard-fill && g push -q -f origin feat-gen
  guard_head=$(g rev-parse HEAD)
  guard_files=$(g diff --name-only "$guard_base" "$guard_head" | jq -Rsc 'split("\n")[:-1]')
  base_sha=$guard_base
  mkpr 200 "$guard_head" "$guard_files" "Body"; set_checks 200 "$green_checks"
  if jq -e 'index(".claude/hooks/guard-config.json") != null' <<<"$guard_files" >/dev/null \
    && jq -e '.project_key == ["keep-me"] and has("worktree_env_allow")' <(g show "$guard_head:.claude/hooks/guard-config.json") >/dev/null; then
    vf "verdict-from accepts guard-config.json that only gains template defaults" 0 "generated team copies"
  else
    bad "verdict-from accepts guard-config.json that only gains template defaults" "fixture sync did not fill guard-config.json: $guard_files"
  fi
  g checkout -q -B feat-gen "$guard_head"
  printf '{"project_key":["changed"],"worktree_env_allow":[".env.example"]}\n' > "$MF_REPO/.claude/hooks/guard-config.json"
  g add -A && g commit -qm guard-edit && g push -q -f origin feat-gen
  guard_edit=$(g rev-parse HEAD)
  guard_edit_files=$(g diff --name-only "$guard_base" "$guard_edit" | jq -Rsc 'split("\n")[:-1]')
  mkpr 200 "$guard_edit" "$guard_edit_files" "Body"; set_checks 200 "$green_checks"
  vf "verdict-from refuses guard-config.json with a changed project key" 1 "guard-config.json is not"
  g checkout -q -B feat-gen "$guard_head"
  printf '{"project_key":["keep-me"],"extra":["new"],"worktree_env_allow":[".env.example",".env.sample",".env.template"]}\n' > "$MF_REPO/.claude/hooks/guard-config.json"
  g add -A && g commit -qm guard-extra && g push -q -f origin feat-gen
  guard_extra=$(g rev-parse HEAD)
  guard_extra_files=$(g diff --name-only "$guard_base" "$guard_extra" | jq -Rsc 'split("\n")[:-1]')
  mkpr 200 "$guard_extra" "$guard_extra_files" "Body"; set_checks 200 "$green_checks"
  vf "verdict-from refuses guard-config.json with a new project key" 1 "guard-config.json is not"

  # .claude/settings.json is compiled from the template and the project's settings.project.json (#1374). The same
  # sync path as guard-config.json decides: a sync result lands, a hand edit of a project permission is refused.
  g checkout -q -B main "$seed_base"
  mkdir -p "$MF_REPO/.claude"
  printf '{"permissions":{"allow":["Bash(acme-tool:*)"],"deny":[]},"hooks":{}}\n' > "$MF_REPO/.claude/settings.project.json"
  g add -A && g commit -qm settings-base && g push -q -f origin main
  settings_base=$(g rev-parse HEAD)
  g checkout -q -B feat-gen
  DOTFILES="$repo_root" bash "$here/agent-team.sh" sync "$MF_REPO" --project-name acme >/dev/null 2>&1
  g add -A && g commit -qm settings-fill && g push -q -f origin feat-gen
  settings_head=$(g rev-parse HEAD)
  settings_files=$(g diff --name-only "$settings_base" "$settings_head" | jq -Rsc 'split("\n")[:-1]')
  base_sha=$settings_base
  mkpr 200 "$settings_head" "$settings_files" "Body"; set_checks 200 "$green_checks"
  if jq -e 'index(".claude/settings.json") != null' <<<"$settings_files" >/dev/null \
    && jq -e '.permissions.allow | index("Bash(acme-tool:*)") != null' <(g show "$settings_head:.claude/settings.json") >/dev/null; then
    vf "verdict-from accepts a settings.json that is the sync merge" 0 "generated team copies"
  else
    bad "verdict-from accepts a settings.json that is the sync merge" "fixture sync did not write settings.json: $settings_files"
  fi
  g checkout -q -B feat-gen "$settings_head"
  jq '.permissions.allow += ["Bash(rm:*)"]' "$MF_REPO/.claude/settings.json" > "$MF_REPO/.claude/settings.edit" \
    && mv "$MF_REPO/.claude/settings.edit" "$MF_REPO/.claude/settings.json"
  g add -A && g commit -qm settings-edit && g push -q -f origin feat-gen
  settings_edit=$(g rev-parse HEAD)
  settings_edit_files=$(g diff --name-only "$settings_base" "$settings_edit" | jq -Rsc 'split("\n")[:-1]')
  mkpr 200 "$settings_edit" "$settings_edit_files" "Body"; set_checks 200 "$green_checks"
  vf "verdict-from refuses a settings.json with a changed project key" 1 "settings.json is not"

  # Verdict lane: a generated copy whose bytes equal the origin/main render (same project name
  # substitution as agent-team.sh) may ride with project edits and a deletion check demands.
  # A hand edit, a render of a template that is not on origin/main, or a deletion check does
  # not demand still uses the hand-edit refusal.
  render_acme_from() { # <blob spec in the fixture dotfiles repo>
    python3 - "$fx" "$1" "$MF_REPO/docs/agents/team.md" <<'PY'
import subprocess, sys
fx, spec, dest = sys.argv[1:]
raw = subprocess.check_output(["git", "-C", fx, "cat-file", "blob", spec])
with open(dest, "wb") as fh:
    fh.write(raw.replace(b"{{PROJECT_NAME}}", b"acme"))
PY
  }
  open_lane() { # <pr> <base> <head>
    local files
    files=$(g diff --name-only "$2" "$3" | jq -Rsc 'split("\n")[:-1]')
    base_sha=$2
    mkpr "$1" "$3" "$files" "Body"
    set_checks "$1" "$green_checks"
    mf_self_review "$1" "$3"
    post_verdict "$1" PASS "$3"
    : > "$MF_GH_LOG"
    SHIP_OUT=$(bash "$fx/script/ship.sh" --repo example/repo --pr "$1" --dry-run 2>&1)
    SHIP_RC=$?
  }
  g checkout -q -B main "$seed_base"
  mkdir -p "$MF_REPO/.agents/skills/tdd"
  printf 'stale skill copy\n' > "$MF_REPO/.agents/skills/tdd/SKILL.md"
  g add -A && g commit -qm 'skill copy on base'
  skill_base=$(g rev-parse HEAD)
  g checkout -q -B feat-lane "$skill_base"
  render_acme_from "origin/main:templates/agent-team/docs/agents/team.md"
  printf 'project edit\n' > "$MF_REPO/notes-adoption.txt"
  rm -f "$MF_REPO/.agents/skills/tdd/SKILL.md"
  g add -A && g commit -q -m "adopt" -m "Owner-approved: owner 2026-11-11 (chat)"
  lane_head=$(g rev-parse HEAD)
  open_lane 210 "$skill_base" "$lane_head"
  if [ "$SHIP_RC" -eq 0 ] && grep -Fq "[dry-run] would ship PR 210" <<<"$SHIP_OUT"; then
    ok "verdict lane accepts a mixed PR whose generated copies equal the origin/main render"
  else
    bad "verdict lane accepts a mixed PR whose generated copies equal the origin/main render" "rc=$SHIP_RC out=$SHIP_OUT"
  fi
  g checkout -q -B feat-lane "$skill_base"
  render_acme_from "origin/main:templates/agent-team/docs/agents/team.md"
  printf '\nhand edit\n' >> "$MF_REPO/docs/agents/team.md"
  printf 'project edit\n' > "$MF_REPO/notes-adoption.txt"
  g add -A && g commit -q -m "hand edit" -m "Owner-approved: owner 2026-11-11 (chat)"
  lane_head=$(g rev-parse HEAD)
  open_lane 211 "$skill_base" "$lane_head"
  if [ "$SHIP_RC" -ne 0 ] && grep -Fq "edits generated team copy docs/agents/team.md" <<<"$SHIP_OUT"; then
    ok "verdict lane refuses a hand edited generated copy"
  else
    bad "verdict lane refuses a hand edited generated copy" "rc=$SHIP_RC out=$SHIP_OUT"
  fi
  printf '\nunmerged template line\n' >> "$fx/templates/agent-team/docs/agents/team.md"
  "$MF_REAL_GIT" -C "$fx" add templates/agent-team/docs/agents/team.md
  "$MF_REAL_GIT" -C "$fx" commit -qm 'unmerged template'
  g checkout -q -B feat-lane "$skill_base"
  render_acme_from "HEAD:templates/agent-team/docs/agents/team.md"
  printf 'project edit\n' > "$MF_REPO/notes-adoption.txt"
  g add -A && g commit -q -m "unmerged render" -m "Owner-approved: owner 2026-11-11 (chat)"
  lane_head=$(g rev-parse HEAD)
  open_lane 212 "$skill_base" "$lane_head"
  if [ "$SHIP_RC" -ne 0 ] && grep -Fq "edits generated team copy docs/agents/team.md" <<<"$SHIP_OUT"; then
    ok "verdict lane refuses a generated copy rendered from an unmerged template"
  else
    bad "verdict lane refuses a generated copy rendered from an unmerged template" "rc=$SHIP_RC out=$SHIP_OUT"
  fi
  "$MF_REAL_GIT" -C "$fx" checkout -q origin/main -- templates/agent-team/docs/agents/team.md
  g checkout -q -B feat-lane "$skill_base"
  rm -f "$MF_REPO/docs/agents/team.md"
  printf 'project edit\n' > "$MF_REPO/notes-adoption.txt"
  g add -A && g commit -q -m "delete template file" -m "Owner-approved: owner 2026-11-11 (chat)"
  lane_head=$(g rev-parse HEAD)
  open_lane 213 "$skill_base" "$lane_head"
  if [ "$SHIP_RC" -ne 0 ] && grep -Fq "edits generated team copy docs/agents/team.md" <<<"$SHIP_OUT"; then
    ok "verdict lane refuses deletion of a generated copy check does not demand"
  else
    bad "verdict lane refuses deletion of a generated copy check does not demand" "rc=$SHIP_RC out=$SHIP_OUT"
  fi

  # A kept guard-bash.py and its test that equal an older template release follow the template (#1392).
  # Release 2 of the fixture template adds a line to both; the project base still holds release 1.
  "$MF_REAL_GIT" -C "$fx" checkout -q origin/main -- templates/agent-team
  hk_guard=.claude/hooks/guard-bash.py hk_test=.claude/hooks/tests/test_guard_bash.py
  for f in "$hk_guard" "$hk_test"; do printf '\n# release 2\n' >> "$fx/templates/agent-team/$f"; done
  "$MF_REAL_GIT" -C "$fx" add templates/agent-team && "$MF_REAL_GIT" -C "$fx" commit -qm 'template release 2'
  "$MF_REAL_GIT" -C "$fx" update-ref refs/remotes/origin/main HEAD
  g checkout -q -B main "$seed_base"
  mkdir -p "$MF_REPO/.claude/hooks/tests"
  printf 'import runpy\nfrom pathlib import Path\n\nrunpy.run_path(str(Path(__file__).with_name("guard-bash.py")))\n' > "$MF_REPO/.claude/hooks/project-guard.py"
  for f in "$hk_guard" "$hk_test"; do "$MF_REAL_GIT" -C "$fx" show "HEAD~1:templates/agent-team/$f" > "$MF_REPO/$f"; done
  g add -A && g commit -qm stale-hooks-base && g push -q -f origin main
  stale_base=$(g rev-parse HEAD)
  g checkout -q -B feat-gen
  DOTFILES="$fx" bash "$fx/script/agent-team.sh" sync "$MF_REPO" --project-name acme >/dev/null 2>&1
  g add -A && g commit -qm stale-hooks-sync && g push -q -f origin feat-gen
  stale_head=$(g rev-parse HEAD)
  stale_files=$(g diff --name-only "$stale_base" "$stale_head" | jq -Rsc 'split("\n")[:-1]')
  base_sha=$stale_base
  mkpr 200 "$stale_head" "$stale_files" "Body"; set_checks 200 "$green_checks"
  if jq -e --arg a "$hk_guard" --arg b "$hk_test" 'index($a) != null and index($b) != null' <<<"$stale_files" >/dev/null; then
    vf "verdict-from accepts a stale guard-bash.py and test refreshed to the template" 0 "generated team copies"
  else
    bad "verdict-from accepts a stale guard-bash.py and test refreshed to the template" "fixture sync did not refresh them: $stale_files"
  fi
  g checkout -q -B feat-gen "$stale_head"
  printf '\n# project rule\n' >> "$MF_REPO/$hk_guard"
  g add -A && g commit -qm stale-hooks-edit && g push -q -f origin feat-gen
  stale_edit=$(g rev-parse HEAD)
  stale_edit_files=$(g diff --name-only "$stale_base" "$stale_edit" | jq -Rsc 'split("\n")[:-1]')
  mkpr 200 "$stale_edit" "$stale_edit_files" "Body"; set_checks 200 "$green_checks"
  vf "verdict-from refuses a guard-bash.py edited beyond the template" 1 "guard-bash.py is not"
  # A project PR that customizes a kept guard-bash.py is not a hand edit of a generated copy (#1179).
  g checkout -q -B feat-custom "$stale_base"
  printf '\n# project rule\n' >> "$MF_REPO/$hk_guard"
  g add -A && g commit -q -m "customize guard" -m "Owner-approved: owner 2026-11-11 (chat)"
  custom_head=$(g rev-parse HEAD)
  open_lane 214 "$stale_base" "$custom_head"
  if grep -Fq "edits generated team copy" <<<"$SHIP_OUT"; then
    bad "verdict lane does not treat a customized guard-bash.py as a generated copy" "rc=$SHIP_RC out=$SHIP_OUT"
  else
    ok "verdict lane does not treat a customized guard-bash.py as a generated copy"
  fi
} </dev/null

# GitHub reports mergeable UNKNOWN until it has calculated the merge. ship.sh rereads, then refuses.
mergeable_pr() { # <number> <branch>
  mf_pr_add "$1" "$2" "Body"
  local h
  h=$(jq -r .headRefOid "$MF_GH_DIR/pr-$1.json")
  mf_self_review "$1" "$h"
  set_checks "$1" "$green_checks"
  post_verdict "$1" PASS "$h"
  jq '.mergeable = "UNKNOWN"' "$MF_GH_DIR/pr-$1.json" > "$MF_GH_DIR/pr-$1.json.tmp" && mv "$MF_GH_DIR/pr-$1.json.tmp" "$MF_GH_DIR/pr-$1.json"
}

mkdir -p "$MF_DIR/flipbin"
cat > "$MF_DIR/gh-flip" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-} ${2:-}" = "pr view" ]; then
  n=0
  [ -f "$MERGEABLE_VIEWS" ] && n=$(cat "$MERGEABLE_VIEWS")
  n=$((n + 1))
  printf '%s\n' "$n" > "$MERGEABLE_VIEWS"
  if [ "$n" -ge 2 ] && [ -n "${MERGEABLE_FLIP_PR:-}" ]; then
    f="$MF_GH_DIR/pr-${MERGEABLE_FLIP_PR}.json"
    jq '.mergeable = "MERGEABLE"' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
  fi
fi
exec "$MF_BIN/gh" "$@"
EOF
chmod +x "$MF_DIR/gh-flip"
ln -sf "$MF_DIR/gh-flip" "$MF_DIR/flipbin/gh"

mergeable_pr 3019 feat-unknown-then-mergeable
: > "$MF_GH_LOG"
: > "$MF_DIR/mergeable-views"
SHIP_OUT=$(
  SHIP_MERGEABLE_WAIT=0 SHIP_MERGEABLE_REREADS=3 \
  MERGEABLE_VIEWS="$MF_DIR/mergeable-views" MERGEABLE_FLIP_PR=3019 \
  PATH="$MF_DIR/flipbin:$PATH" \
  bash "$here/ship.sh" --repo example/repo --pr 3019 2>&1
)
SHIP_RC=$?
views_before_merge=$(awk '/gh pr view / { n++ } /gh pr merge / { print n; exit }' "$MF_GH_LOG")
if [ "$SHIP_RC" -eq 0 ] && [[ "$SHIP_OUT" =~ ^shipped\ PR\ 3019\ as\ [0-9a-f]{40}$ ]] \
  && [ "${views_before_merge:-0}" -ge 2 ] \
  && grep -q "gh pr merge 3019 --repo example/repo --squash --match-head-commit" "$MF_GH_LOG"; then
  ok "UNKNOWN mergeable rereads and then merges"
else
  bad "UNKNOWN mergeable rereads and then merges" "rc=$SHIP_RC views=${views_before_merge:-0} out=$SHIP_OUT"
fi

mergeable_pr 3020 feat-unknown-stays
: > "$MF_GH_LOG"
SHIP_OUT=$(SHIP_MERGEABLE_WAIT=0 SHIP_MERGEABLE_REREADS=3 bash "$here/ship.sh" --repo example/repo --pr 3020 2>&1)
SHIP_RC=$?
unknown_views=$(grep -c 'gh pr view 3020 ' "$MF_GH_LOG" || true)
if [ "$SHIP_RC" -ne 0 ] && [ "$unknown_views" -ge 2 ] && [ "$unknown_views" -le 5 ] \
  && grep -Fq "mergeable=UNKNOWN" <<<"$SHIP_OUT" && ! grep -q "pr merge" "$MF_GH_LOG"; then
  ok "UNKNOWN mergeable rereads a few times and then refuses"
else
  bad "UNKNOWN mergeable rereads a few times and then refuses" "rc=$SHIP_RC views=$unknown_views out=$SHIP_OUT"
fi

# 1200. The default wait is 4 s and 15 rereads (60 s in all), not 20 s and 3.
mergeable_pr 3021 feat-unknown-default-wait
: > "$MF_GH_LOG"
mkdir -p "$MF_DIR/sleepbin"
printf '#!/usr/bin/env bash\necho "$1" >> "%s/sleeps"\n' "$MF_DIR" > "$MF_DIR/sleepbin/sleep"
chmod +x "$MF_DIR/sleepbin/sleep"
: > "$MF_DIR/sleeps"
SHIP_OUT=$(env -u SHIP_MERGEABLE_WAIT -u SHIP_MERGEABLE_REREADS PATH="$MF_DIR/sleepbin:$PATH" bash "$here/ship.sh" --repo example/repo --pr 3021 2>&1)
SHIP_RC=$?
if [ "$SHIP_RC" -ne 0 ] && [ "$(wc -l <"$MF_DIR/sleeps" | tr -d ' ')" = 15 ] && [ "$(sort -u "$MF_DIR/sleeps")" = 4 ]; then
  ok "default mergeable wait is 4 s with 15 rereads"
else
  bad "default mergeable wait is 4 s with 15 rereads" "rc=$SHIP_RC sleeps=$(tr '\n' ' ' <"$MF_DIR/sleeps") out=$SHIP_OUT"
fi

# A Review: FAIL at the merge head blocks the merge. A later Verdict: PASS does not
# cover it. A later Review: PASS for that head, or a Countersign, does (#1070).
code_head() { # <pr> <branch>
  mf_pr_add "$1" "$2" "Body"
  local h
  h=$(jq -r .headRefOid "$MF_GH_DIR/pr-$1.json")
  mf_self_review "$1" "$h"
  set_checks "$1" "$green_checks"
  printf '%s\n' "$h"
}

h1070=$(code_head 1070 feat-review-fail-verdict)
gh pr comment 1070 --repo example/repo --body "Review: FAIL head=$h1070" >/dev/null
post_verdict 1070 PASS "$h1070"
: > "$MF_GH_LOG"
run_ship --repo example/repo --pr 1070
if [ "$SHIP_RC" -ne 0 ] && [ "$(wc -l <<<"$SHIP_OUT" | tr -d ' ')" -eq 1 ] \
  && grep -Fq "Review: FAIL at head ${h1070:0:12}" <<<"$SHIP_OUT" \
  && ! grep -q "pr merge" "$MF_GH_LOG"; then
  ok "Review FAIL at head then Verdict PASS refuses"
else
  bad "Review FAIL at head then Verdict PASS refuses" "rc=$SHIP_RC out=$SHIP_OUT"
fi

h1071=$(code_head 1071 feat-review-pass-only)
gh pr comment 1071 --repo example/repo --body "Review: PASS head=$h1071" >/dev/null
post_verdict 1071 PASS "$h1071"
: > "$MF_GH_LOG"
run_ship --repo example/repo --pr 1071
if [ "$SHIP_RC" -eq 0 ] && [[ "$SHIP_OUT" =~ ^shipped\ PR\ 1071\ as\ [0-9a-f]{40}$ ]] \
  && grep -q "gh pr merge 1071 --repo example/repo --squash --match-head-commit $h1071" "$MF_GH_LOG"; then
  ok "a PR whose only Review at the head is PASS still merges"
else
  bad "a PR whose only Review at the head is PASS still merges" "rc=$SHIP_RC out=$SHIP_OUT"
fi

h1072=$(code_head 1072 feat-review-fail-then-pass)
gh pr comment 1072 --repo example/repo --body "Review: FAIL head=$h1072 model=opus" >/dev/null
gh pr comment 1072 --repo example/repo --body "Review: PASS head=$h1072 model=opus" >/dev/null
post_verdict 1072 PASS "$h1072"
: > "$MF_GH_LOG"
run_ship --repo example/repo --pr 1072
if [ "$SHIP_RC" -eq 0 ] && grep -q "gh pr merge 1072 --repo example/repo --squash --match-head-commit $h1072" "$MF_GH_LOG"; then
  ok "a later Review PASS for the same head covers an earlier Review FAIL"
else
  bad "a later Review PASS for the same head covers an earlier Review FAIL" "rc=$SHIP_RC out=$SHIP_OUT"
fi

h1073=$(code_head 1073 feat-review-fail-countersign)
gh pr comment 1073 --repo example/repo --body "Review: FAIL head=$h1073" >/dev/null
gh pr comment 1073 --repo example/repo --body "Countersign: Elon head=$h1073 reason=covered the review fail" >/dev/null
post_verdict 1073 PASS "$h1073"
: > "$MF_GH_LOG"
run_ship --repo example/repo --pr 1073
if [ "$SHIP_RC" -eq 0 ] && grep -q "gh pr merge 1073 --repo example/repo --squash --match-head-commit $h1073" "$MF_GH_LOG"; then
  ok "a Countersign covers a Review FAIL at the head"
else
  bad "a Countersign covers a Review FAIL at the head" "rc=$SHIP_RC out=$SHIP_OUT"
fi

h1074=$(code_head 1074 feat-review-fail-other-head)
other1074=$(printf 'd%.0s' {1..40})
gh pr comment 1074 --repo example/repo --body "Review: FAIL head=$other1074" >/dev/null
post_verdict 1074 PASS "$h1074"
: > "$MF_GH_LOG"
run_ship --repo example/repo --pr 1074
if [ "$SHIP_RC" -eq 0 ] && grep -q "gh pr merge 1074 --repo example/repo --squash --match-head-commit $h1074" "$MF_GH_LOG"; then
  ok "a Review FAIL at another head does not block"
else
  bad "a Review FAIL at another head does not block" "rc=$SHIP_RC out=$SHIP_OUT"
fi

h1075=$(code_head 1075 feat-review-fail-again)
gh pr comment 1075 --repo example/repo --body "Review: FAIL head=$h1075 model=opus" >/dev/null
gh pr comment 1075 --repo example/repo --body "Review: PASS head=$h1075 model=opus" >/dev/null
gh pr comment 1075 --repo example/repo --body "Review: FAIL head=$h1075 model=opus" >/dev/null
post_verdict 1075 PASS "$h1075"
: > "$MF_GH_LOG"
run_ship --repo example/repo --pr 1075
if [ "$SHIP_RC" -ne 0 ] && grep -Fq "Review: FAIL at head ${h1075:0:12}" <<<"$SHIP_OUT" \
  && ! grep -q "pr merge" "$MF_GH_LOG"; then
  ok "a Review FAIL after a Review PASS still refuses"
else
  bad "a Review FAIL after a Review PASS still refuses" "rc=$SHIP_RC out=$SHIP_OUT"
fi

h1076=$(code_head 1076 feat-review-edited-pass)
gh pr comment 1076 --repo example/repo --body "Review: FAIL head=$h1076 model=opus" >/dev/null
gh pr comment 1076 --repo example/repo --body "Review: PASS head=$h1076 model=opus" >/dev/null
mf_comment_flag 1076 1 edited true
post_verdict 1076 PASS "$h1076"
: > "$MF_GH_LOG"
run_ship --repo example/repo --pr 1076
if [ "$SHIP_RC" -ne 0 ] && grep -Fq "Review: FAIL at head ${h1076:0:12}" <<<"$SHIP_OUT" \
  && ! grep -q "pr merge" "$MF_GH_LOG"; then
  ok "an edited Review PASS does not cover a Review FAIL"
else
  bad "an edited Review PASS does not cover a Review FAIL" "rc=$SHIP_RC out=$SHIP_OUT"
fi

# A Review PASS from another model does not cover a Review FAIL at the head (#1770).
h1770=$(code_head 1770 feat-split-review)
gh pr comment 1770 --repo example/repo --body "Review: FAIL head=$h1770 model=gemini" >/dev/null
gh pr comment 1770 --repo example/repo --body "Review: PASS head=$h1770 model=opus" >/dev/null
post_verdict 1770 PASS "$h1770"
: > "$MF_GH_LOG"
run_ship --repo example/repo --pr 1770
if [ "$SHIP_RC" -ne 0 ] && grep -Fq "Review: FAIL at head ${h1770:0:12}" <<<"$SHIP_OUT" \
  && ! grep -q "pr merge" "$MF_GH_LOG"; then
  ok "a Review PASS from another model does not cover a Review FAIL"
else
  bad "a Review PASS from another model does not cover a Review FAIL" "rc=$SHIP_RC out=$SHIP_OUT"
fi

h1771=$(code_head 1771 feat-split-review-same-model)
gh pr comment 1771 --repo example/repo --body "Review: FAIL head=$h1771 model=gemini" >/dev/null
gh pr comment 1771 --repo example/repo --body "Review: PASS head=$h1771 model=gemini" >/dev/null
post_verdict 1771 PASS "$h1771"
: > "$MF_GH_LOG"
run_ship --repo example/repo --pr 1771
if [ "$SHIP_RC" -eq 0 ] && grep -q "gh pr merge 1771 --repo example/repo --squash --match-head-commit $h1771" "$MF_GH_LOG"; then
  ok "a later Review PASS from the model that posted the FAIL covers it"
else
  bad "a later Review PASS from the model that posted the FAIL covers it" "rc=$SHIP_RC out=$SHIP_OUT"
fi

h1772=$(code_head 1772 feat-split-review-answered)
gh pr comment 1772 --repo example/repo --body "Review: FAIL head=$h1772 model=gemini
- the total ignores the discount" >/dev/null
gh pr comment 1772 --repo example/repo --body "Review: PASS head=$h1772 model=opus" >/dev/null
gh pr comment 1772 --repo example/repo --body "Verdict: PASS head=$h1772 verifier=ctx_verifier author=ctx_author agent=claude model=opus

> Review: FAIL head=$h1772 model=gemini
Does not hold: the discount is applied in cart.php line 40, the test covers it." >/dev/null
: > "$MF_GH_LOG"
run_ship --repo example/repo --pr 1772
if [ "$SHIP_RC" -eq 0 ] && grep -q "gh pr merge 1772 --repo example/repo --squash --match-head-commit $h1772" "$MF_GH_LOG"; then
  ok "a Verdict that quotes the Review FAIL and says why it does not hold ships"
else
  bad "a Verdict that quotes the Review FAIL and says why it does not hold ships" "rc=$SHIP_RC out=$SHIP_OUT"
fi

h1773=$(code_head 1773 feat-split-review-quote-no-reason)
gh pr comment 1773 --repo example/repo --body "Review: FAIL head=$h1773 model=gemini" >/dev/null
gh pr comment 1773 --repo example/repo --body "Review: PASS head=$h1773 model=opus" >/dev/null
gh pr comment 1773 --repo example/repo --body "Verdict: PASS head=$h1773 verifier=ctx_verifier author=ctx_author agent=claude model=opus

> Review: FAIL head=$h1773 model=gemini" >/dev/null
: > "$MF_GH_LOG"
run_ship --repo example/repo --pr 1773
if [ "$SHIP_RC" -ne 0 ] && grep -Fq "Review: FAIL at head ${h1773:0:12}" <<<"$SHIP_OUT" \
  && ! grep -q "pr merge" "$MF_GH_LOG"; then
  ok "a Verdict that quotes the Review FAIL with no reason does not cover it"
else
  bad "a Verdict that quotes the Review FAIL with no reason does not cover it" "rc=$SHIP_RC out=$SHIP_OUT"
fi

# Every FAIL at the head needs covering, and only the newest Verdict can answer one (#1770).
h1774=$(code_head 1774 feat-two-fails)
gh pr comment 1774 --repo example/repo --body "Review: FAIL head=$h1774 model=gemini" >/dev/null
gh pr comment 1774 --repo example/repo --body "Review: FAIL head=$h1774 model=opus" >/dev/null
gh pr comment 1774 --repo example/repo --body "Review: PASS head=$h1774 model=opus" >/dev/null
post_verdict 1774 PASS "$h1774"
: > "$MF_GH_LOG"
run_ship --repo example/repo --pr 1774
if [ "$SHIP_RC" -ne 0 ] && grep -Fq "Review: FAIL at head ${h1774:0:12}" <<<"$SHIP_OUT" \
  && ! grep -q "pr merge" "$MF_GH_LOG"; then
  ok "covering only the newest of two Review FAILs still refuses"
else
  bad "covering only the newest of two Review FAILs still refuses" "rc=$SHIP_RC out=$SHIP_OUT"
fi

h1775b=$(code_head 1777 feat-superseded-answer)
gh pr comment 1777 --repo example/repo --body "Review: FAIL head=$h1775b model=gemini" >/dev/null
gh pr comment 1777 --repo example/repo --body "Verdict: PASS head=$h1775b verifier=ctx_verifier author=ctx_author agent=claude model=opus

> Review: FAIL head=$h1775b model=gemini
Does not hold: covered by the cart test." >/dev/null
post_verdict 1777 PASS "$h1775b"
: > "$MF_GH_LOG"
run_ship --repo example/repo --pr 1777
if [ "$SHIP_RC" -ne 0 ] && grep -Fq "Review: FAIL at head ${h1775b:0:12}" <<<"$SHIP_OUT" \
  && ! grep -q "pr merge" "$MF_GH_LOG"; then
  ok "an older answering Verdict superseded by a plain Verdict does not cover the FAIL"
else
  bad "an older answering Verdict superseded by a plain Verdict does not cover the FAIL" "rc=$SHIP_RC out=$SHIP_OUT"
fi

# One Does not hold line answers only the FAIL it follows (#1770).
h1778=$(code_head 1778 feat-two-fails-one-reason)
gh pr comment 1778 --repo example/repo --body "Review: FAIL head=$h1778 model=gemini" >/dev/null
gh pr comment 1778 --repo example/repo --body "Review: FAIL head=$h1778 model=opus" >/dev/null
gh pr comment 1778 --repo example/repo --body "Verdict: PASS head=$h1778 verifier=ctx_verifier author=ctx_author agent=claude model=opus

> Review: FAIL head=$h1778 model=gemini
Does not hold: covered by the cart test.
> Review: FAIL head=$h1778 model=opus" >/dev/null
: > "$MF_GH_LOG"
run_ship --repo example/repo --pr 1778
if [ "$SHIP_RC" -ne 0 ] && grep -Fq "Review: FAIL at head ${h1778:0:12}" <<<"$SHIP_OUT" \
  && ! grep -q "pr merge" "$MF_GH_LOG"; then
  ok "one Does not hold line does not answer a second quoted Review FAIL"
else
  bad "one Does not hold line does not answer a second quoted Review FAIL" "rc=$SHIP_RC out=$SHIP_OUT"
fi

# Split review in reverse order: Review: PASS (opus) first, then Review: FAIL (gemini) at the same head (#1772 note 3).
h1779=$(code_head 1779 feat-split-review-pass-first)
gh pr comment 1779 --repo example/repo --body "Review: PASS head=$h1779 model=opus" >/dev/null
gh pr comment 1779 --repo example/repo --body "Review: FAIL head=$h1779 model=gemini
- the total ignores the discount" >/dev/null
post_verdict 1779 PASS "$h1779"
: > "$MF_GH_LOG"
run_ship --repo example/repo --pr 1779
if [ "$SHIP_RC" -ne 0 ] && grep -Fq "Review: FAIL at head ${h1779:0:12}" <<<"$SHIP_OUT" \
  && ! grep -q "pr merge" "$MF_GH_LOG"; then
  ok "a plain Verdict does not cover a Review FAIL posted after an earlier Review PASS from another model"
else
  bad "a plain Verdict does not cover a Review FAIL posted after an earlier Review PASS from another model" "rc=$SHIP_RC out=$SHIP_OUT"
fi

h1780=$(code_head 1780 feat-split-review-pass-first-answered)
gh pr comment 1780 --repo example/repo --body "Review: PASS head=$h1780 model=opus" >/dev/null
gh pr comment 1780 --repo example/repo --body "Review: FAIL head=$h1780 model=gemini
- the total ignores the discount" >/dev/null
gh pr comment 1780 --repo example/repo --body "Verdict: PASS head=$h1780 verifier=ctx_verifier author=ctx_author agent=claude model=opus

> Review: FAIL head=$h1780 model=gemini
Does not hold: the discount is applied in cart.php line 40, the test covers it." >/dev/null
: > "$MF_GH_LOG"
run_ship --repo example/repo --pr 1780
if [ "$SHIP_RC" -eq 0 ] && grep -q "gh pr merge 1780 --repo example/repo --squash --match-head-commit $h1780" "$MF_GH_LOG"; then
  ok "a Verdict that quotes a Review FAIL posted after an earlier Review PASS from another model ships"
else
  bad "a Verdict that quotes a Review FAIL posted after an earlier Review PASS from another model ships" "rc=$SHIP_RC out=$SHIP_OUT"
fi

# Private name check runs only on a public repo (visibility read from GitHub).
name_scope_case() { # <pr> <repo> <visibility|fails> <expect ship|refuse> <label>
  local n=$1 r=$2 vis=$3 expect=$4 label=$5 h
  rm -f "$MF_GH_DIR/visibility-fails"
  mf_pr_add "$n" "feat-name-$n" "Fix zzprivproj placement"
  h=$(jq -r .headRefOid "$MF_GH_DIR/pr-$n.json")
  mf_self_review "$n" "$h"
  set_checks "$n" "$green_checks"
  post_verdict "$n" PASS "$h"
  if [ "$vis" = fails ]; then : > "$MF_GH_DIR/visibility-fails"; else printf '%s\n' "$vis" >"$MF_GH_DIR/visibility-${r//\//__}"; fi
  run_ship --repo "$r" --pr "$n" --dry-run
  rm -f "$MF_GH_DIR/visibility-fails" "$MF_GH_DIR/visibility-${r//\//__}"
  if [ "$expect" = ship ] && [ "$SHIP_RC" -eq 0 ] && grep -q "would ship" <<<"$SHIP_OUT"; then ok "$label"
  elif [ "$expect" = refuse ] && [ "$SHIP_RC" -ne 0 ]; then ok "$label"
  else bad "$label" "rc=$SHIP_RC out=$SHIP_OUT"; fi
}
name_scope_case 1201 example/repo PRIVATE ship "private repo PR naming a private project ships"
name_scope_case 1202 example/repo INTERNAL ship "internal repo PR naming a private project ships"
name_scope_case 1203 example/repo PUBLIC refuse "public repo PR naming a private project is refused"
name_scope_case 1204 example/repo fails refuse "unreadable visibility refuses"

# gh pr diff refuses a very large diff (PullRequest.diff too_large): ship.sh builds the diff locally instead (#1162).
big_case() { # <pr> <gh error text> <expect local|refuse> <label>
  local n=$1 err=$2 expect=$3 label=$4
  mf_pr_add "$n" "feat-big-$n" "Body" "script/big-$n.sh"
  set_checks "$n" "$green_checks"
  mkdir -p "$MF_DIR/big-$n"
  printf '#!/usr/bin/env bash\nif [ "$1 $2" = "pr diff" ]; then echo "$BIG_ERR" >&2; exit 1; fi\nexec "%s/gh" "$@"\n' "$MF_BIN" > "$MF_DIR/big-$n/gh"; chmod +x "$MF_DIR/big-$n/gh"
  : > "$MF_GH_LOG"
  SHIP_OUT=$(BIG_ERR="$err" PATH="$MF_DIR/big-$n:$PATH" bash "$here/ship.sh" --repo example/repo --pr "$n" --mechanical 2>&1); SHIP_RC=$?
  # The branch adds a new file, so a --mechanical run that read the local diff refuses with "new file".
  if [ "$expect" = local ] && [ "$SHIP_RC" -ne 0 ] && grep -Fq "new file" <<<"$SHIP_OUT" && ! grep -Fq "cannot read diff" <<<"$SHIP_OUT"; then ok "$label"
  elif [ "$expect" = refuse ] && [ "$SHIP_RC" -ne 0 ] && grep -Fq "cannot read diff of PR $n" <<<"$SHIP_OUT"; then ok "$label"
  else bad "$label" "rc=$SHIP_RC out=$SHIP_OUT"; fi
}
big_case 1301 "could not find pull request diff: HTTP 406: Sorry, the diff exceeded the maximum number of lines (PullRequest.diff too_large)" local "too_large diff falls back to a local git diff"
big_case 1302 "HTTP 500: server error" refuse "another gh pr diff failure still refuses"

# After a dotfiles merge, ship.sh pulls the fleet in the background and logs the result (#1173). Other repos do not.
fp_dir="$MF_DIR/fleet-pull"; mkdir -p "$fp_dir"
cat > "$fp_dir/fake-fleet-pull" <<EOF
#!/usr/bin/env bash
echo called >> "$fp_dir/calls"
if [ -f "$fp_dir/fail" ]; then echo "ok   hostA ~/dotfiles abc1234"; echo "fail hostB ~/dotfiles (unreachable host)"; exit 1; fi
if [ -f "$fp_dir/hang" ]; then sleep 30; fi
echo "ok   hostA ~/dotfiles abc1234"
EOF
chmod +x "$fp_dir/fake-fleet-pull"
export SHIP_FLEET_PULL="$fp_dir/fake-fleet-pull" SHIP_FLEET_PULL_LOG="$fp_dir/log"
fleet_case() { # <pr> <repo> <expect called|silent> [fail|hang]
  local n=$1 r=$2 expect=$3 mode=${4:-} h i
  rm -f "$fp_dir/calls" "$fp_dir/log" "$fp_dir/fail" "$fp_dir/hang"
  [ -z "$mode" ] || : > "$fp_dir/$mode"
  mf_pr_add "$n" "feat-fleet-$n" "Body"
  h=$(jq -r .headRefOid "$MF_GH_DIR/pr-$n.json")
  mf_self_review "$n" "$h"; set_checks "$n" "$green_checks"; post_verdict "$n" PASS "$h"
  SHIP_FLEET_PULL_TIMEOUT=2 run_ship --repo "$r" --pr "$n"
  for i in $(seq 1 100); do
    grep -q '^fleet-pull ' "$fp_dir/log" 2>/dev/null && break
    [ "$expect" = silent ] && [ "$i" -ge 10 ] && break
    sleep 0.1
  done
  FP_LOG=$(cat "$fp_dir/log" 2>/dev/null || true)
}
fleet_case 1401 mingster/dotfiles called
if [ "$SHIP_RC" -eq 0 ] && [ -f "$fp_dir/calls" ] && grep -q 'pr=1401 .*exit=0' <<<"$FP_LOG" && grep -q '^ok   hostA' <<<"$FP_LOG"; then ok "dotfiles merge triggers fleet-pull and logs ok"
else bad "dotfiles merge triggers fleet-pull and logs ok" "rc=$SHIP_RC log=$FP_LOG out=$SHIP_OUT"; fi
if grep -qE '^fleet-pull .* pr=1401 .*exit=0 duration_s=[0-9]+$' <<<"$FP_LOG"; then ok "the fleet-pull log header carries duration_s"
else bad "the fleet-pull log header carries duration_s" "log=$FP_LOG"; fi
fleet_case 1402 example/repo silent
if [ "$SHIP_RC" -eq 0 ] && [ ! -f "$fp_dir/calls" ] && [ -z "$FP_LOG" ]; then ok "a non dotfiles merge does not trigger fleet-pull"
else bad "a non dotfiles merge does not trigger fleet-pull" "rc=$SHIP_RC log=$FP_LOG"; fi
fleet_case 1403 mingster/dotfiles called fail
if [ "$SHIP_RC" -eq 0 ] && [[ "$SHIP_OUT" =~ shipped\ PR\ 1403 ]] && grep -q 'pr=1403 .*exit=1' <<<"$FP_LOG" && grep -q '^fail hostB' <<<"$FP_LOG"; then ok "a failing host does not fail ship and is logged"
else bad "a failing host does not fail ship and is logged" "rc=$SHIP_RC out=$SHIP_OUT log=$FP_LOG"; fi
fp_start=$SECONDS
fleet_case 1404 mingster/dotfiles called hang
if [ "$SHIP_RC" -eq 0 ] && [ $((SECONDS - fp_start)) -lt 20 ] && grep -q 'pr=1404 .*exit=124' <<<"$FP_LOG"; then ok "a hanging fleet-pull is cut off by the timeout"
else bad "a hanging fleet-pull is cut off by the timeout" "rc=$SHIP_RC log=$FP_LOG"; fi
# A dotfiles merge that touched the team template also starts template-sync-pr.sh in the background (#1247).
cat > "$fp_dir/fake-template-sync" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$fp_dir/sync-calls"
echo "example/repo open 7"
EOF
export SHIP_TEMPLATE_SYNC="$fp_dir/fake-template-sync" SHIP_TEMPLATE_SYNC_LOG="$fp_dir/sync-log"
sync_case() { # <pr> <path> <expect called|silent>
  local n=$1 h i
  rm -f "$fp_dir/sync-calls" "$fp_dir/sync-log"
  mf_pr_add "$n" "feat-sync-$n" "Body" "$2"
  h=$(jq -r .headRefOid "$MF_GH_DIR/pr-$n.json")
  mf_self_review "$n" "$h"; set_checks "$n" "$green_checks"; post_verdict "$n" PASS "$h"
  SHIP_FLEET_PULL_TIMEOUT=2 run_ship --repo mingster/dotfiles --pr "$n"
  for i in $(seq 1 100); do
    grep -q '^template-sync ' "$fp_dir/sync-log" 2>/dev/null && break
    [ "$3" = silent ] && [ "$i" -ge 10 ] && break
    sleep 0.1
  done
  SYNC_LOG=$(cat "$fp_dir/sync-log" 2>/dev/null || true)
}
sync_case 1405 templates/agent-team/docs/agents/x.md called
if [ "$SHIP_RC" -eq 0 ] && grep -q -- '--verdict-from mingster/dotfiles#1405' "$fp_dir/sync-calls" 2>/dev/null && grep -q 'pr=1405 .*exit=0' <<<"$SYNC_LOG"; then
  ok "a template merge starts template-sync-pr.sh and logs it"
else bad "a template merge starts template-sync-pr.sh and logs it" "rc=$SHIP_RC log=$SYNC_LOG out=$SHIP_OUT"; fi
sync_case 1406 docs/notes-1406.md silent
if [ "$SHIP_RC" -eq 0 ] && [ ! -f "$fp_dir/sync-calls" ] && [ -z "$SYNC_LOG" ]; then ok "a dotfiles merge without template changes does not start template sync"
else bad "a dotfiles merge without template changes does not start template sync" "rc=$SHIP_RC log=$SYNC_LOG"; fi
unset SHIP_FLEET_PULL SHIP_FLEET_PULL_LOG SHIP_TEMPLATE_SYNC SHIP_TEMPLATE_SYNC_LOG

# #1745: after a merge that touches a watched schema path, ship.sh runs the project's post-merge hook and prints one line.
pm_dir="$MF_DIR/post-merge"; mkdir -p "$pm_dir"
cat > "$pm_dir/hook.sh" <<EOF
#!/usr/bin/env bash
echo "\$SHIP_PR \$SHIP_MERGE_SHA" >> "$pm_dir/hook-calls"
if [ -f "$pm_dir/hook-silent" ]; then exit "\$(cat "$pm_dir/hook-silent")"; fi
if [ -f "$pm_dir/hook-fails" ]; then echo "shard unreachable" >&2; exit 4; fi
echo "applied 3 migrations"
EOF
real_gh=$(command -v gh); mkdir -p "$pm_dir/bin"
cat > "$pm_dir/bin/gh" <<EOF
#!/usr/bin/env bash
[ "\$1" = issue ] || exec "$real_gh" "\$@"
case "\$1 \$2" in
  'issue list') cat "$pm_dir/issues.json" ;;
  'issue create') echo "\$*" >> "$pm_dir/created"; echo '[{"number":91,"title":"red gate: test-database"}]' > "$pm_dir/issues.json"; echo https://github.com/example/repo/issues/91 ;;
  'issue comment') echo "\$*" >> "$pm_dir/commented" ;;
esac
EOF
chmod +x "$pm_dir/hook.sh" "$pm_dir/bin/gh"
export SHIP_TEST_HOOK="$pm_dir/hook.sh" PATH="$pm_dir/bin:$PATH"
"$MF_REAL_GIT" -C "$MF_REPO" checkout -q main
mkdir -p "$MF_REPO/.agents"
printf '# post-merge-schema: bash "$SHIP_TEST_HOOK"\n# schema-paths: db/schema/* prisma/schema.prisma\ntrue\n' > "$MF_REPO/.agents/head-checks.conf"
"$MF_REAL_GIT" -C "$MF_REPO" add .agents/head-checks.conf
"$MF_REAL_GIT" -C "$MF_REPO" commit -q -m "post-merge hook config"
"$MF_REAL_GIT" -C "$MF_REPO" push -q origin main
"$MF_REAL_GIT" -C "$MF_REPO" fetch -q origin
pm_case() { # <pr> <changed path> [fails]
  local n=$1 h
  rm -f "$pm_dir/hook-calls" "$pm_dir/hook-fails" "$pm_dir/created" "$pm_dir/commented"
  echo '[]' > "$pm_dir/issues.json"
  [ -z "${3:-}" ] || : > "$pm_dir/hook-fails"
  mf_pr_add "$n" "feat-pm-$n" "Body" "$2"
  h=$(jq -r .headRefOid "$MF_GH_DIR/pr-$n.json")
  mf_self_review "$n" "$h"; set_checks "$n" "$green_checks"; post_verdict "$n" PASS "$h"
  run_ship --repo example/repo --pr "$n"
}
# A file already on this disk that matches the glob must not hide the merged path.
mkdir -p "$MF_REPO/db/schema"; echo local > "$MF_REPO/db/schema/local.sql"
pm_case 1501 db/schema/001_init.sql
rm -rf "$MF_REPO/db"
if [ "$SHIP_RC" -eq 0 ] && grep -q "^1501 [0-9a-f]\{40\}$" "$pm_dir/hook-calls" 2>/dev/null \
  && grep -qx 'post-merge schema: ok (applied 3 migrations)' <<<"$SHIP_OUT"; then
  ok "a merge touching a watched schema path runs the hook and prints one result line"
else bad "a merge touching a watched schema path runs the hook and prints one result line" "rc=$SHIP_RC out=$SHIP_OUT"; fi
pm_case 1502 docs/unrelated-1502.md
if [ "$SHIP_RC" -eq 0 ] && [ ! -f "$pm_dir/hook-calls" ] && ! grep -q 'post-merge' <<<"$SHIP_OUT"; then
  ok "a merge touching no watched path does not run the hook"
else bad "a merge touching no watched path does not run the hook" "rc=$SHIP_RC out=$SHIP_OUT"; fi
"$MF_REAL_GIT" -C "$MF_REPO" remote set-url origin https://github.com/example/repo.git
"$MF_REAL_GIT" -C "$MF_REPO" config url."$MF_ORIGIN".insteadOf https://github.com/example/repo.git
pm_case 1503 prisma/schema.prisma fails
if [ "$SHIP_RC" -eq 0 ] && [ "$(jq -r .state "$MF_GH_DIR/pr-1503.json")" = MERGED ] \
  && grep -q 'post-merge schema: FAILED exit 4, the merge stands, red gate #91' <<<"$SHIP_OUT" \
  && grep -q -- '--title red gate: test-database' "$pm_dir/created" && grep -q -- '--label P1' "$pm_dir/created"; then
  ok "a failing hook keeps the merge, exits 0 and files one red gate issue"
else bad "a failing hook keeps the merge, exits 0 and files one red gate issue" "rc=$SHIP_RC out=$SHIP_OUT"; fi
# The open issue is reused, not filed twice.
rm -f "$pm_dir/created" "$pm_dir/commented"
mf_pr_add 1504 feat-pm-1504 "Body" db/schema/002.sql
h=$(jq -r .headRefOid "$MF_GH_DIR/pr-1504.json"); mf_self_review 1504 "$h"; set_checks 1504 "$green_checks"; post_verdict 1504 PASS "$h"
run_ship --repo example/repo --pr 1504
if [ "$SHIP_RC" -eq 0 ] && [ ! -f "$pm_dir/created" ] && grep -q '^issue comment 91' "$pm_dir/commented" && grep -q 'red gate #91' <<<"$SHIP_OUT"; then
  ok "a second hook failure comments on the open issue"
else bad "a second hook failure comments on the open issue" "rc=$SHIP_RC out=$SHIP_OUT"; fi
# A hook that prints nothing must not abort ship under set -e (grep -v finds no line).
echo 0 > "$pm_dir/hook-silent"
pm_case 1505 db/schema/003.sql
if [ "$SHIP_RC" -eq 0 ] && grep -qx 'post-merge schema: ok (no output)' <<<"$SHIP_OUT"; then
  ok "a silent successful hook still prints its result line"
else bad "a silent successful hook still prints its result line" "rc=$SHIP_RC out=$SHIP_OUT"; fi
echo 7 > "$pm_dir/hook-silent"
pm_case 1506 db/schema/004.sql
if [ "$SHIP_RC" -eq 0 ] && grep -q 'post-merge schema: FAILED exit 7, the merge stands, red gate #91' <<<"$SHIP_OUT"; then
  ok "a silent failing hook files the red gate instead of aborting ship"
else bad "a silent failing hook files the red gate instead of aborting ship" "rc=$SHIP_RC out=$SHIP_OUT"; fi
rm -f "$pm_dir/hook-silent"
"$MF_REAL_GIT" -C "$MF_REPO" config --unset url."$MF_ORIGIN".insteadOf
"$MF_REAL_GIT" -C "$MF_REPO" remote set-url origin "$MF_ORIGIN"
unset SHIP_TEST_HOOK; PATH=${PATH#"$pm_dir/bin:"}
# #1325: an unreachable dotfiles remote adds nothing to ship output.
run_ship --repo example/repo --pr 1
if grep -q 'session-sync:' <<<"$SHIP_OUT"; then bad "ship output is free of session-sync notices" "$SHIP_OUT"; else ok "ship output is free of session-sync notices"; fi
# #1326: a cwd outside any git repo is named, not reported as an unreadable head.
SHIP_OUT=$(cd "$MF_DIR" && bash "$here/ship.sh" --repo example/repo --pr 1 2>&1); SHIP_RC=$?
if [ "$SHIP_RC" -ne 0 ] && grep -q 'run from inside the repo checkout (cwd is not a git repo)' <<<"$SHIP_OUT" && ! grep -q 'cannot read head' <<<"$SHIP_OUT"; then ok "ship from a non-git cwd names the cwd"
else bad "ship from a non-git cwd names the cwd" "rc=$SHIP_RC out=$SHIP_OUT"; fi

echo "passed $pass, failed $fail"
[ "$fail" -eq 0 ]
