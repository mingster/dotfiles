#!/usr/bin/env bash
# The Screenshots gate decides from each file's change kind: removed files are not a UI change.
# gh, git and orca are stubbed on PATH; the PR file inventory carries `status`.
here=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home"
LEAD="$HOME/orca/workspaces/proj/lead-x"
mkdir -p "$LEAD" "$tmp/bin" "$tmp/dot/script"
export GIT_ALLOW_PROTOCOL=file GIT_TERMINAL_PROMPT=0 GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
cat > "$tmp/bin/git" <<'EOS'
#!/usr/bin/env bash
[ "$1" = rev-parse ] && [ "${2:-}" = --show-toplevel ] && { echo "$FAKE_TOP"; exit 0; }
case "$1" in
  cat-file|fetch) exit 0 ;;
  merge-base) echo cccccccccccccccccccccccccccccccccccccccc ;;
  diff) case "$*" in *--name-only*) ;; *) echo current ;; esac ;;
  *) exit 1 ;;
esac
EOS
cat > "$tmp/bin/gh" <<'EOS'
#!/usr/bin/env bash
if [ "$1" = api ]; then printf '%s' "$API_FILES"; exit 0; fi
case "$2" in
  view) if grep -q ok "$MERGE_LOG" 2>/dev/null; then printf '%s' "$FINAL_JSON"; else printf '%s' "$PR_JSON"; fi ;;
  diff) ;;
  merge) echo ok >> "$MERGE_LOG" ;;
esac
EOS
cat > "$tmp/bin/orca" <<'EOS'
#!/usr/bin/env bash
if [ "$1 $2" = "orchestration run-list" ]; then echo '{"ok":true,"result":{"runs":[{"id":"run_a"}],"nextCursor":null}}'; exit 0; fi
[ "$1 $2" = "orchestration worker-list" ] || exit 1
echo '{"ok":true,"result":{"workers":[{"dispatchId":"ctx_author"},{"dispatchId":"ctx_verify"}],"page":{"nextCursor":null}}}'
EOS
chmod +x "$tmp/bin/"*
export ORCA_CLI_COMMAND="$tmp/bin/orca" PATH="$tmp/bin:$PATH" MERGE_LOG="$tmp/merge.log" FAKE_TOP="$LEAD"
cp "$here/lead-merge.sh" "$here/apply-local-overlay.py" "$here/lead-merge.config.example.json" "$tmp/dot/script/"
printf '{"ui_path_patterns":["app/"]}\n' > "$tmp/dot/script/lead-merge.local.json"

SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
ui_msg='UI change needs a ## Screenshots section with a phone image'
fail=0; pass=0
check() { # name expected_exit output_regex; $1.. then files json in $files
  local out code
  rm -f "$MERGE_LOG"
  API_FILES=$files
  PR_JSON=$(jq -n --arg sha "$SHA" --argjson n "$(jq length <<<"$files")" \
    '{state:"OPEN",baseRefName:"main",headRefName:"feature",headRefOid:$sha,mergeable:"MERGEABLE",url:"https://github.com/o/r/pull/7",
      body:"## Verification\n- Ran script successfully.",baseRefOid:"cccccccccccccccccccccccccccccccccccccccc",closingIssuesReferences:[],changedFiles:$n,
      comments:[{body:("Checks: PASS head="+$sha)},{body:("Verdict: PASS head="+$sha+" verifier=ctx_verify author=ctx_author")}]}')
  FINAL_JSON='{"state":"MERGED","mergeCommit":{"oid":"dddddddddddddddddddddddddddddddddddddddd"},"url":"https://github.com/o/r/pull/7"}'
  export API_FILES PR_JSON FINAL_JSON
  out=$("$tmp/dot/script/lead-merge.sh" --repo o/r --pr 7 --head "$SHA" 2>&1); code=$?
  if [ "$code" = "$2" ] && grep -qE "$3" <<<"$out"; then echo "ok   $1"; pass=$((pass+1))
  else printf 'FAIL %s (exit %s)\n%s\n' "$1" "$code" "$out"; fail=$((fail+1)); fi
}
files='[{"filename":"app/old.tsx","status":"removed"},{"filename":"app/gone.tsx","status":"removed"}]'
check "UIGATE removed UI files alone merge without Screenshots" 0 '^MERGED'
files='[{"filename":"app/old.tsx","status":"removed"},{"filename":"app/page.tsx","status":"modified"}]'
check "UIGATE removed plus modified UI file is refused" 1 "$ui_msg"
files='[{"filename":"app/old.tsx","status":"removed"},{"filename":"app/new.tsx","status":"renamed","previous_filename":"lib/new.tsx"}]'
check "UIGATE removed plus a rename into a UI path is refused" 1 "$ui_msg"
files='[{"filename":"app/new.tsx","status":"added"}]'
check "UIGATE added UI file is refused" 1 "$ui_msg"
echo "passed $pass, failed $fail"
[ "$fail" = 0 ]
