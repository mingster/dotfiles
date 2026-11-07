#!/usr/bin/env bash
# Issue #658 acceptance cases 1–6 for lead-merge text-only lane.
# shellcheck disable=SC2089,SC2090,SC2015
here=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
# shellcheck source=lib/asdf-pin.sh
. "$here/tests/lib/asdf-pin.sh"
export HOME="$tmp/home"
mkdir -p "$HOME/orca/workspaces/proj/lead-x" "$tmp/bin"
LEAD="$HOME/orca/workspaces/proj/lead-x"
REAL_GIT=$(command -v git); export REAL_GIT
export GIT_ALLOW_PROTOCOL=file GIT_TERMINAL_PROMPT=0 GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
cat > "$tmp/bin/git" <<'EOS'
#!/usr/bin/env bash
[ "$1" = rev-parse ] && [ "${2:-}" = --show-toplevel ] && { echo "$FAKE_TOP"; exit 0; }
[ -z "${REAL_PATCH_REPO:-}" ] || exec "$REAL_GIT" -C "$REAL_PATCH_REPO" "$@"
case "$1" in
  cat-file|fetch) exit 0 ;;
  merge-base) echo cccccccccccccccccccccccccccccccccccccccc ;;
  diff) case "$*" in *--name-only*) printf '%s\n' "$TRUNK_FILES" ;; *) echo current ;; esac ;;
  *) exit 1 ;;
esac
EOS
cat > "$tmp/bin/gh" <<'EOS'
#!/usr/bin/env bash
if [ "$1" = api ]; then printf '%s' "$API_FILES"; exit 0; fi
case "$2" in
  view) if [ -f "$MERGE_LOG" ] && grep -q ok "$MERGE_LOG"; then printf '%s' "$FINAL_JSON"; else printf '%s' "$PR_JSON"; fi ;;
  diff) cat "$PR_DIFF_FILE" ;;
  merge) echo "$*" >> "$MERGE_LOG.calls"; n=$(wc -l < "$MERGE_LOG.calls"); [ "$n" -gt "${MERGE_FAILS:-0}" ] || { echo boom >&2; exit 1; }; echo ok >> "$MERGE_LOG" ;;
esac
EOS
cat > "$tmp/bin/orca" <<'EOS'
#!/usr/bin/env bash
if [ "$1 $2" = "orchestration run-list" ]; then
  echo '{"ok":true,"result":{"runs":[{"id":"run_a"}],"nextCursor":null}}'; exit 0
fi
[ "$1 $2" = "orchestration worker-list" ] || exit 1
printf '{"ok":true,"result":{"workers":[{"dispatchId":"ctx_verify"},{"dispatchId":"ctx_author"}],"nextCursor":null}}\n'
EOS
chmod +x "$tmp/bin/"*
export ORCA_CLI_COMMAND="$tmp/bin/orca" PATH="$tmp/bin:$PATH" MERGE_LOG="$tmp/merge.log"
SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
pass=0 fail=0
say() { if [ "$2" = 0 ]; then echo "ok   $1"; pass=$((pass+1)); else echo "FAIL $1"; echo "$3"; fail=$((fail+1)); fi; }

setup() {
  rm -f "$MERGE_LOG" "$MERGE_LOG.calls"
  unset REAL_PATCH_REPO COMMENTS_JSON API_OVERRIDE
  FAKE_TOP="$LEAD"; MERGE_FAILS=0; PR_DIFF=""
  base_sha=cccccccccccccccccccccccccccccccccccccccc
  files='[{"path":"docs/a.md"}]'
  body=$'## Verification\n- Ran checks.\n'
  review="Review: PASS head=$SHA model=composer-2.5"
  verdict=""
  checks="Checks: PASS head=$SHA"
  countersign=""; TRUNK_FILES=""
  export TRUNK_FILES
  state=OPEN base=main headsha=$SHA mergeable=MERGEABLE branch=feature/t658
  FINAL_JSON='{"state":"MERGED","mergeCommit":{"oid":"dddddddddddddddddddddddddddddddddddddddd"},"url":"https://github.com/o/r/pull/9"}'
}

mkjson() {
  PR_JSON=$(printf '{"state":"%s","baseRefName":"%s","headRefName":"%s","headRefOid":"%s","mergeable":"%s","url":"https://github.com/o/r/pull/9","files":%s}' \
    "$state" "$base" "$branch" "$headsha" "$mergeable" "$files")
  comments_list=$(jq -nc --arg c "$checks" --arg r "$review" --arg v "$verdict" --arg x "$countersign" \
    '[{body:$c}] + (if ($r|length)>0 then [{body:$r}] else [] end) + (if ($v|length)>0 then [{body:$v}] else [] end) + (if ($x|length)>0 then [{body:$x}] else [] end)')
  PR_JSON=$(jq --arg body "$body" --argjson comments "$comments_list" --arg base "$base_sha" \
    '. + {body:$body, baseRefOid:$base, closingIssuesReferences:[], comments:$comments}' <<<"$PR_JSON")
  [ -z "$COMMENTS_JSON" ] || PR_JSON=$(jq --argjson comments "$COMMENTS_JSON" '.comments=$comments' <<<"$PR_JSON")
  API_FILES=$(jq '[.files[] | {filename:.path}]' <<<"$PR_JSON")
  PR_JSON=$(jq --argjson count "$(jq length <<<"$API_FILES")" '.changedFiles=$count' <<<"$PR_JSON")
  export API_FILES
  printf '%s' "$PR_DIFF" > "$MERGE_LOG.diff"; export PR_DIFF_FILE="$MERGE_LOG.diff"
  export PR_JSON FINAL_JSON FAKE_TOP MERGE_FAILS
}

run_merge() {
  mkjson
  if [ -n "${REAL_PATCH_REPO:-}" ]; then
    rm -rf "$REAL_PATCH_REPO.origin.git"
    cp -R "$REAL_PATCH_REPO/.git" "$REAL_PATCH_REPO.origin.git"
    "$REAL_GIT" -C "$REAL_PATCH_REPO.origin.git" config core.bare true
    "$REAL_GIT" -C "$REAL_PATCH_REPO" remote set-url origin "$REAL_PATCH_REPO.origin.git"
    if [ -n "${REAL_PATCH_REPO_MAIN:-}" ]; then
      "$REAL_GIT" -C "$REAL_PATCH_REPO.origin.git" update-ref refs/heads/main "$REAL_PATCH_REPO_MAIN"
    fi
  fi
  LAST_OUT=$("$here/lead-merge.sh" --repo o/r --pr 9 --head "$SHA" 2>&1); LAST_CODE=$?
  LAST_CALLS=0; [ -f "$MERGE_LOG.calls" ] && LAST_CALLS=$(wc -l < "$MERGE_LOG.calls" | tr -d ' ')
}

# 1 pass: markdown and changelog.d only
setup; files='[{"path":"docs/a.md"},{"path":"changelog.d/x.md"}]'; run_merge
say "T658-1 pass text-only merges" "$([ "$LAST_CODE" -eq 0 ] && [ "$LAST_CALLS" -eq 1 ]; echo $?)" "$LAST_OUT"

# 1 refuse: shell file keeps Verdict rule
setup; files='[{"path":"docs/a.md"},{"path":"script/x.sh"}]'; review="Review: PASS head=$SHA model=composer-2.5"; verdict=""
run_merge; say "T658-1 refuse shell needs verdict" "$([ "$LAST_CODE" -ne 0 ] && grep -q verdict <<<"$LAST_OUT"; echo $?)" "$LAST_OUT"

# 2 refuse: missing Checks
setup; checks=""; run_merge; say "T658-2 refuse missing Checks" "$([ "$LAST_CODE" -ne 0 ] && grep -q Checks <<<"$LAST_OUT"; echo $?)" "$LAST_OUT"

# 3 refuse: missing Review on pure docs
setup; review=""; run_merge; say "T658-3 refuse missing Review" "$([ "$LAST_CODE" -ne 0 ] && grep -q 'Review: PASS' <<<"$LAST_OUT"; echo $?)" "$LAST_OUT"

# 4 refuse: agent path with model=none
setup; files='[{"path":".claude/agents/role.md"}]'; review="Review: PASS head=$SHA model=none"
run_merge; say "T658-4 refuse model none" "$([ "$LAST_CODE" -ne 0 ] && grep -q 'model other than none' <<<"$LAST_OUT"; echo $?)" "$LAST_OUT"

# 4 pass: agent path with model named
setup; files='[{"path":"AGENTS.md"}]'; review="Review: PASS head=$SHA model=composer-2.5"
run_merge; say "T658-4 pass AGENTS with model" "$([ "$LAST_CODE" -eq 0 ]; echo $?)" "$LAST_OUT"

# 5 refuse: role file without Owner-approved
setup; files='[{"path":".claude/agents/role.md"}]'; review="Review: PASS head=$SHA model=composer-2.5"
export REAL_PATCH_REPO="$tmp/owner-repo"
"$REAL_GIT" init -q -b main "$REAL_PATCH_REPO"
"$REAL_GIT" -C "$REAL_PATCH_REPO" config user.name Fixture
"$REAL_GIT" -C "$REAL_PATCH_REPO" config user.email fixture@example.invalid
printf 'base\n' > "$REAL_PATCH_REPO/role.md"; mkdir -p "$REAL_PATCH_REPO/.claude/agents"
mv "$REAL_PATCH_REPO/role.md" "$REAL_PATCH_REPO/.claude/agents/role.md"
"$REAL_GIT" -C "$REAL_PATCH_REPO" add .; "$REAL_GIT" -C "$REAL_PATCH_REPO" commit -qm base
base_sha=$("$REAL_GIT" -C "$REAL_PATCH_REPO" rev-parse HEAD)
export REAL_PATCH_REPO_MAIN="$base_sha"
"$REAL_GIT" -C "$REAL_PATCH_REPO" update-ref refs/remotes/origin/main "$base_sha"
"$REAL_GIT" -C "$REAL_PATCH_REPO" remote add origin "$REAL_PATCH_REPO" 2>/dev/null || true
rm -rf "$REAL_PATCH_REPO.origin.git"
cp -R "$REAL_PATCH_REPO/.git" "$REAL_PATCH_REPO.origin.git"
"$REAL_GIT" -C "$REAL_PATCH_REPO.origin.git" config core.bare true
"$REAL_GIT" -C "$REAL_PATCH_REPO" remote set-url origin "$REAL_PATCH_REPO.origin.git"
printf 'edit\n' >> "$REAL_PATCH_REPO/.claude/agents/role.md"
"$REAL_GIT" -C "$REAL_PATCH_REPO" commit -qam 'role edit without trailer'
SHA=$("$REAL_GIT" -C "$REAL_PATCH_REPO" rev-parse HEAD); headsha=$SHA
checks="Checks: PASS head=$SHA"
review="Review: PASS head=$SHA model=composer-2.5"
run_merge; say "T658-5 refuse missing Owner-approved" "$([ "$LAST_CODE" -ne 0 ] && grep -q Owner-approved <<<"$LAST_OUT"; echo $?)" "$LAST_OUT"

# 5 pass: Owner-approved trailer present
"$REAL_GIT" -C "$REAL_PATCH_REPO" commit --amend -q --trailer "Owner-approved: Owner 2026-11-07" -m 'role edit'
SHA=$("$REAL_GIT" -C "$REAL_PATCH_REPO" rev-parse HEAD); headsha=$SHA
checks="Checks: PASS head=$SHA"
review="Review: PASS head=$SHA model=composer-2.5"
run_merge; say "T658-5 pass Owner-approved trailer" "$([ "$LAST_CODE" -eq 0 ]; echo $?)" "$LAST_OUT"
unset REAL_PATCH_REPO

# 6 refuse: hooks stay hard stop regardless of trailer
setup; files='[{"path":".claude/hooks/x.sh"}]'; review="Review: PASS head=$SHA model=composer-2.5"
run_merge; say "T658-6 refuse hooks hard stop" "$([ "$LAST_CODE" -ne 0 ] && grep -q hooks <<<"$LAST_OUT"; echo $?)" "$LAST_OUT"

echo "passed $pass, failed $fail"
[ "$fail" = 0 ]
