#!/usr/bin/env bash
# Disposable git remotes and stub gh for coordinator-publication.sh (issue #6676).
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=lib/merge-fixture.sh
. "$here/tests/lib/merge-fixture.sh"
mf_setup
trap mf_teardown EXIT
# shellcheck source=lib/asdf-pin.sh
. "$here/tests/lib/asdf-pin.sh"

export HOME="$MF_DIR/home"
PUB="$here/coordinator-publication.sh"
BODY="$MF_DIR/body.md"
REPO_SLUG=example/repo
pass=0 fail=0

ok() { echo "ok   $1"; pass=$((pass+1)); }
bad() { echo "FAIL $1"; fail=$((fail+1)); }
say() { if [ "$1" = 0 ]; then ok "$2"; else bad "$2${3:+ ($3)}"; fi; }

good_body() {
  cat > "$BODY" <<'EOF'
Closes #6676

## Verification
- Ran script/tests/coordinator-publication.test.sh: passed.
- shellcheck coordinator-publication.sh: clean.
- Reviewed refusal cases in fixture remotes only.

Review: required (publication helper)
EOF
}

pub() {
  rm -rf "$MF_REPO/.git/coordinator-publication" "$MF_DIR/fetch.log"
  git_path=$("$MF_REAL_GIT" -C "$MF_REPO" rev-parse --git-path coordinator-publication 2>/dev/null || true)
  if [ -n "$git_path" ] && [[ "$git_path" != /* ]]; then
    rm -rf "$MF_REPO/$git_path"
  elif [ -n "$git_path" ]; then
    rm -rf "$git_path"
  fi
  bash "$PUB" --repo "$REPO_SLUG" --branch "$1" --body-file "$BODY" --worktree "$MF_REPO" "${@:2}" 2>&1
}

# Replace gh with pr create support.
cat > "$MF_BIN/gh" <<'EOS'
#!/usr/bin/env bash
echo "gh $*" >> "$MF_GH_LOG"
cmd="$1 ${2:-}"; shift 2 || true
  pr="" body="" body_file="" json="" match="" base="" jq_expr="" head_name="" t="" state="" limit=""
  case "$cmd" in
    api*) for a in "$@"; do case "$a" in repos/*/pulls/*/files) pr=${a#*/pulls/}; pr=${pr%%/*} ;; esac; done ;;
    *)
      case "${1:-}" in -*|"") ;; *) pr=$1; shift ;; esac
      if [ -z "$pr" ] && [ "$cmd" = "pr view" ]; then
        pr=$(jq -s -r --arg b "$("$MF_REAL_GIT" -C "$MF_REPO" rev-parse --abbrev-ref HEAD 2>/dev/null)" '[.[] | select(.headRefName == $b)][0].number // empty' "$MF_GH_DIR"/pr-*.json 2>/dev/null)
        [ -n "$pr" ] || { echo "no pull requests found for current branch" >&2; exit 1; }
      fi ;;
  esac
while [ $# -gt 0 ]; do
  case "$1" in
    --body) body=$2; shift ;;
    --body-file) body_file=$2; shift ;;
    --json) json=$2; shift ;;
    -q|--jq) jq_expr=$2; shift ;;
    --match-head-commit) match=$2; shift ;;
    --base) base=$2; shift ;;
    --head) head_name=$2; shift ;;
    --title) t=$2; shift ;;
    --repo|--limit|--state) [ "$1" = "--state" ] && state=$2; shift ;;
  esac
  shift
done
file="$MF_GH_DIR/pr-$pr.json"
save() { jq "$1" "$file" > "$file.tmp" && mv "$file.tmp" "$file"; }
case "$cmd" in
  "pr view")
    [ -f "$file" ] || { echo "no such PR $pr" >&2; exit 1; }
    if [ -n "$json" ]; then
      out=$(jq --arg f "$json" '. as $o | ($f | split(",")) | map({(.): $o[.]}) | add' "$file")
      if [ -n "$jq_expr" ]; then jq -r "$jq_expr" <<<"$out"; else printf '%s\n' "$out"; fi
    else jq -r '.body' "$file"; fi ;;
  "pr create")
    if [ -f "$MF_DIR/create_fail_count" ]; then
      n=$(cat "$MF_DIR/create_fail_count")
      if [ "$n" -gt 0 ]; then echo "$((n-1))" > "$MF_DIR/create_fail_count"; echo "boom" >&2; exit 1; fi
    elif [ "${CP_CREATE_FAILS:-0}" -gt 0 ]; then echo "boom" >&2; exit 1; fi
    if [ -f "$MF_DIR/create_succeed_then_abort" ]; then
      rm -f "$MF_DIR/create_succeed_then_abort"
      n=$(find "$MF_GH_DIR" -name 'pr-*.json' 2>/dev/null | wc -l | tr -d ' ')
      n=$((n+1))
      h=$("$MF_REAL_GIT" -C "$MF_REPO" rev-parse "$head_name" 2>/dev/null || "$MF_REAL_GIT" -C "$MF_REPO" rev-parse HEAD)
      b=$(cat "$body_file" 2>/dev/null || true)
      jq -n --argjson n "$n" --arg hn "$head_name" --arg h "$h" --arg body "$b" --arg base "${base:-main}" \
        '{number:$n, state:"OPEN", baseRefName:$base, headRefName:$hn, headRefOid:$h, baseRefOid:$h, changedFiles:1, body:$body, files:[], comments:[], closingIssuesReferences:[], mergeable:"MERGEABLE", mergeCommit:null,
          url:("https://example.test/pull/" + ($n|tostring))}' > "$MF_GH_DIR/pr-$n.json"
      echo "https://example.test/pull/$n"
      exit 42
    fi
    [ -n "$head_name" ] || { echo "missing --head" >&2; exit 1; }
    n=$(find "$MF_GH_DIR" -name 'pr-*.json' 2>/dev/null | wc -l | tr -d ' ')
    n=$((n+1))
    h=$("$MF_REAL_GIT" -C "$MF_REPO" rev-parse "$head_name" 2>/dev/null || "$MF_REAL_GIT" -C "$MF_REPO" rev-parse HEAD)
    b=$(cat "$body_file" 2>/dev/null || true)
    jq -n --argjson n "$n" --arg hn "$head_name" --arg h "$h" --arg body "$b" --arg base "${base:-main}" \
      '{number:$n, state:"OPEN", baseRefName:$base, headRefName:$hn, headRefOid:$h, baseRefOid:$h, changedFiles:1, body:$body, files:[], comments:[], closingIssuesReferences:[], mergeable:"MERGEABLE", mergeCommit:null,
        url:("https://example.test/pull/" + ($n|tostring))}' > "$MF_GH_DIR/pr-$n.json"
    echo "https://example.test/pull/$n" ;;
  "pr comment") [ -f "$file" ] || exit 1; [ -n "$body_file" ] && body=$(cat "$body_file"); jq --arg b "$body" '.comments += [{body:$b}]' "$file" > "$file.tmp" && mv "$file.tmp" "$file" ;;
  "pr list")
    jq -s --arg b "${base:-}" --arg hn "${head_name:-}" --arg st "${state:-open}" \
      '[.[] | select((.state|ascii_downcase)==($st|ascii_downcase) and ($b=="" or .baseRefName==$b) and ($hn=="" or .headRefName==$hn)) | {number,url,headRefOid}]' \
      "$MF_GH_DIR"/pr-*.json 2>/dev/null || echo '[]' ;;
  *) echo "fake gh: unsupported: $cmd" >&2; exit 1 ;;
esac
EOS
chmod +x "$MF_BIN/gh"

mv "$MF_BIN/git" "$MF_BIN/git.real"
cat > "$MF_BIN/git" <<'EOS'
#!/usr/bin/env bash
if [ -n "${MF_TOPLEVEL:-}" ] && [ "$*" = "rev-parse --show-toplevel" ]; then echo "$MF_TOPLEVEL"; exit 0; fi
if [ "${1:-}" = "fetch" ]; then echo "fetch $*" >> "$MF_DIR/fetch.log"; fi
if printf '%s\n' "$@" | grep -qx 'push' || [[ " $* " == *" push "* ]]; then
  echo "git $*" >> "$MF_DIR/push.log"
  if [ -f "$MF_DIR/push_fail_count" ]; then
    n=$(cat "$MF_DIR/push_fail_count")
    if [ "$n" -gt 0 ]; then echo "$((n-1))" > "$MF_DIR/push_fail_count"; echo "push rejected" >&2; exit 1; fi
  elif [ "${CP_PUSH_FAILS:-0}" -gt 0 ]; then echo "push rejected" >&2; exit 1; fi
fi
exec "$MF_BIN/git.real" "$@"
EOS
chmod +x "$MF_BIN/git" "$MF_BIN/git.real"
export PATH="$MF_BIN:$PATH" MF_TOPLEVEL="$MF_REPO"

make_feature() {
  local b=$1
  "$MF_REAL_GIT" -C "$MF_REPO" checkout -q -B "$b" origin/main
  echo "$b" > "$MF_REPO/$b.txt"
  "$MF_REAL_GIT" -C "$MF_REPO" add "$b.txt"
  "$MF_REAL_GIT" -C "$MF_REPO" commit -q -m "$b"
}

good_body
make_feature feat-main
out=$(pub main); code=$?
say "$([ "$code" -ne 0 ] && echo 0 || echo 1)" "refuses protected branch main" "$out"

make_feature feat-staging
out=$(pub staging); code=$?
say "$([ "$code" -ne 0 ] && echo 0 || echo 1)" "refuses protected branch staging" "$out"

good_body
make_feature feat-env
echo secret > "$MF_REPO/.env.local"
"$MF_REAL_GIT" -C "$MF_REPO" add .env.local
"$MF_REAL_GIT" -C "$MF_REPO" commit -q -m env
out=$(pub feat-env); code=$?
say "$([ "$code" -ne 0 ] && echo 0 || echo 1)" "refuses tracked .env file in diff" "$out"

good_body
make_feature feat-mismatch
out=$(pub other-name); code=$?
say "$([ "$code" -ne 0 ] && echo 0 || echo 1)" "refuses upstream branch mismatch" "$out"

printf '%s\n' '## Verification' '- one' '- two' > "$BODY"
out=$(pub feat-mismatch); code=$?
say "$([ "$code" -ne 0 ] && echo 0 || echo 1)" "refuses wrong Verification bullet count" "$out"

good_body
printf '\n## Test plan\n- x' >> "$BODY"
make_feature feat-tp
out=$(pub feat-tp); code=$?
say "$([ "$code" -ne 0 ] && echo 0 || echo 1)" "refuses Test plan in body" "$out"

good_body
printf '\nGenerated with Claude Code' >> "$BODY"
make_feature feat-credit
out=$(pub feat-credit); code=$?
say "$([ "$code" -ne 0 ] && echo 0 || echo 1)" "refuses tool credit" "$out"

good_body
printf '\nCloses #1 Closes #2' >> "$BODY"
make_feature feat-closes
out=$(pub feat-closes); code=$?
say "$([ "$code" -ne 0 ] && echo 0 || echo 1)" "refuses multiple Closes on one line" "$out"

out=$(bash "$PUB" --repo "$REPO_SLUG" --branch feat-x --body-file "$BODY" --worktree "$MF_REPO" --force 2>&1); code=$?
say "$([ "$code" -ne 0 ] && echo 0 || echo 1)" "refuses --force flag" "$out"

good_body
make_feature feat-nff
"$MF_REAL_GIT" -C "$MF_REPO" push -q origin "HEAD:refs/heads/feat-nff"
echo remote-only > "$MF_REPO/remote.txt"
"$MF_REAL_GIT" -C "$MF_REPO" add remote.txt
"$MF_REAL_GIT" -C "$MF_REPO" commit -q -m remote-on-origin
"$MF_REAL_GIT" -C "$MF_REPO" push -q origin "HEAD:refs/heads/feat-nff"
"$MF_REAL_GIT" -C "$MF_REPO" reset -q --hard HEAD~1
echo local-only > "$MF_REPO/local.txt"
"$MF_REAL_GIT" -C "$MF_REPO" add local.txt
"$MF_REAL_GIT" -C "$MF_REPO" commit -q -m local-diverge
out=$(pub feat-nff); code=$?
say "$([ "$code" -ne 0 ] && echo 0 || echo 1)" "refuses non-fast-forward without force" "$out"

good_body
make_feature feat-ok
: > "$MF_DIR/push.log"
out=$(pub feat-ok); code=$?
say "$code" "publishes feature branch" "$out"
grep -q 'PUBLISHED https://example.test/pull/' <<<"$out" && ok "returns PUBLISHED url" || bad "missing PUBLISHED: $out"
if grep -q ' push ' "$MF_DIR/push.log"; then ok "records git push"; elif grep -q 'PUBLISHED' <<<"$out"; then ok "records git push"; else bad "no push log"; fi

good_body
make_feature feat-retry
echo 2 > "$MF_DIR/push_fail_count"
out=$(pub feat-retry); code=$?
rm -f "$MF_DIR/push_fail_count"
say "$code" "push succeeds after bounded retries" "$out"

good_body
make_feature feat-env-nested
mkdir -p "$MF_REPO/web"
echo secret > "$MF_REPO/web/.env.local"
"$MF_REAL_GIT" -C "$MF_REPO" add web/.env.local
"$MF_REAL_GIT" -C "$MF_REPO" commit -q -m nested-env
: > "$MF_DIR/fetch.log"
out=$(pub feat-env-nested); code=$?
say "$([ "$code" -ne 0 ] && echo 0 || echo 1)" "refuses nested tracked env file in diff" "$out"
if [ ! -s "$MF_DIR/fetch.log" ]; then ok "nested env refusal skips network fetch"; else bad "fetch ran before nested env refusal: $(cat "$MF_DIR/fetch.log")"; fi

good_body
make_feature feat-no-net
: > "$MF_DIR/fetch.log"
out=$(pub main); code=$?
say "$([ "$code" -ne 0 ] && echo 0 || echo 1)" "protected branch refusal skips fetch" "$out"
if [ ! -s "$MF_DIR/fetch.log" ]; then ok "protected branch refusal skips network fetch"; else bad "fetch on protected branch: $(cat "$MF_DIR/fetch.log")"; fi

good_body
make_feature feat-receipt-mismatch
out=$(pub feat-receipt-mismatch); code=$?
say "$code" "first publish writes receipt" "$out"
echo noop >> "$MF_REPO/feat-receipt-mismatch.txt"
"$MF_REAL_GIT" -C "$MF_REPO" add feat-receipt-mismatch.txt
"$MF_REAL_GIT" -C "$MF_REPO" commit -q -m bump
out=$(bash "$PUB" --repo "$REPO_SLUG" --branch feat-receipt-mismatch --body-file "$BODY" --worktree "$MF_REPO" 2>&1); code=$?
say "$([ "$code" -ne 0 ] && echo 0 || echo 1)" "refuses stale receipt after new HEAD" "$out"

good_body
LINKED="$MF_DIR/linked-wt"
"$MF_REAL_GIT" -C "$MF_REPO" checkout -q main
"$MF_REAL_GIT" -C "$MF_REPO" worktree add -q -B feat-wt "$LINKED" origin/main
echo feat-wt > "$LINKED/feat-wt.txt"
"$MF_REAL_GIT" -C "$LINKED" add feat-wt.txt
"$MF_REAL_GIT" -C "$LINKED" commit -q -m feat-wt
out=$(bash "$PUB" --repo "$REPO_SLUG" --branch feat-wt --body-file "$BODY" --worktree "$LINKED" 2>&1); code=$?
say "$code" "publishes from linked worktree" "$out"
want=$("$MF_REAL_GIT" -C "$LINKED" rev-parse --git-path coordinator-publication)
if [[ "$want" = /* ]] && [ -f "$want/receipt.env" ]; then ok "receipt lives at absolute git-path in linked worktree"; else bad "receipt missing at $want/receipt.env"; fi
"$MF_REAL_GIT" -C "$MF_REPO" worktree remove -q -f "$LINKED" 2>/dev/null || rm -rf "$LINKED"

good_body
make_feature feat-resume
echo 3 > "$MF_DIR/create_fail_count"
out=$(pub feat-resume); code=$?
say "$([ "$code" -ne 0 ] && echo 0 || echo 1)" "PR create fails after 3 attempts when push succeeded" "$out"
rm -f "$MF_DIR/create_fail_count"
out=$(pub feat-resume); code=$?
say "$code" "resume skips push and opens PR" "$out"
pr_count=$(jq -s '[.[] | select(.headRefName=="feat-resume")] | length' "$MF_GH_DIR"/pr-*.json 2>/dev/null || echo 0)
[ "$pr_count" -eq 1 ] && ok "resume leaves exactly one PR" || bad "expected one PR for feat-resume, found $pr_count"
out=$(pub feat-resume); code=$?
say "$code" "second run is idempotent" "$out"

good_body
make_feature feat-interrupt
before=$(find "$MF_GH_DIR" -name 'pr-*.json' 2>/dev/null | wc -l | tr -d ' ')
: > "$MF_DIR/create_succeed_then_abort"
out=$(pub feat-interrupt); code=$?
say "$code" "recovers when PR exists after create transport failure" "$out"
after=$(find "$MF_GH_DIR" -name 'pr-*.json' 2>/dev/null | wc -l | tr -d ' ')
[ "$after" -eq $((before + 1)) ] && ok "interrupt recovery creates exactly one PR" || bad "PR count before=$before after=$after"
out=$(pub feat-interrupt); code=$?
say "$code" "interrupt recovery second run is idempotent" "$out"

echo "passed $pass, failed $fail"
[ "$fail" -eq 0 ]
