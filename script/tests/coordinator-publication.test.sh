#!/usr/bin/env bash
# Disposable git remotes and stub gh for coordinator-publication.sh (issue #6676).
set -u
export GIT_ALLOW_PROTOCOL=file
here=$(cd "$(dirname "$0")/.." && pwd)
REQUESTED_HELPER=${COORDINATOR_PUBLICATION_HELPER:-${PUB:-}}
# shellcheck source=lib/merge-fixture.sh
. "$here/tests/lib/merge-fixture.sh"
mf_setup
trap mf_teardown EXIT
# shellcheck source=lib/asdf-pin.sh
. "$here/tests/lib/asdf-pin.sh"

export HOME="$MF_DIR/home"
PUB=${REQUESTED_HELPER:-$here/coordinator-publication.sh}
readonly PUB
echo "coordinator-publication-fixture-helper=$PUB"
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

receipt_path() {
  local wt=${1:-$MF_REPO}
  local git_path
  git_path=$("$MF_TEST_GIT" -C "$wt" rev-parse --git-path coordinator-publication 2>/dev/null || true)
  if [ -n "$git_path" ] && [[ "$git_path" != /* ]]; then
    git_path="$wt/$git_path"
  fi
  printf '%s/receipt.env' "$git_path"
}

clear_receipt() {
  local wt=${1:-$MF_REPO}
  rm -f "$MF_DIR/fetch.log"
  git_path=$("$MF_TEST_GIT" -C "$wt" rev-parse --git-path coordinator-publication 2>/dev/null || true)
  if [ -n "$git_path" ] && [[ "$git_path" != /* ]]; then
    rm -rf "$wt/$git_path"
  elif [ -n "$git_path" ]; then
    rm -rf "$git_path"
  fi
}

pub() {
  local keep=0 wt="$MF_REPO"
  while [ $# -gt 0 ]; do
    case "$1" in
      --keep-receipt) keep=1; shift ;;
      --worktree) wt="$2"; shift 2 ;;
      *) break ;;
    esac
  done
  local branch=$1; shift || true
  [ -n "$branch" ] || { echo "pub: missing branch" >&2; return 2; }
  if [ "$keep" = 0 ]; then
    clear_receipt "$wt"
  else
    rm -f "$MF_DIR/fetch.log"
  fi
  bash "$PUB" --repo "$REPO_SLUG" --branch "$branch" --body-file "$BODY" --worktree "$wt" "$@" 2>&1
}

# Replace gh with pr create support.
cat > "$MF_BIN/gh" <<'EOS'
#!/usr/bin/env bash
echo "gh $*" >> "$MF_GH_LOG"
cmd="$1 ${2:-}"; shift 2 || true
  pr="" body="" body_file="" json="" match="" base="" jq_expr="" head_name="" t="" state="" limit="" gh_repo=""
  case "$cmd" in
    api*) for a in "$@"; do case "$a" in repos/*/pulls/*/files) pr=${a#*/pulls/}; pr=${pr%%/*} ;; esac; done ;;
    *)
      case "${1:-}" in -*|"") ;; *) pr=$1; shift ;; esac
      if [ -z "$pr" ] && [ "$cmd" = "pr view" ]; then
        pr=$(jq -s -r --arg b "$("$MF_BIN/git.real" -C "$MF_REPO" rev-parse --abbrev-ref HEAD 2>/dev/null)" '[.[] | select(.headRefName == $b)][0].number // empty' "$MF_GH_DIR"/pr-*.json 2>/dev/null)
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
    --repo) gh_repo=$2; shift ;;
    --limit|--state) [ "$1" = "--state" ] && state=$2; shift ;;
  esac
  shift
done
gh_repo_must_be_github_com() {
  case "${gh_repo:-}" in
    github.com/*) return 0 ;;
    *) echo "fake gh: refused --repo without github.com host (GH_HOST must not redirect API)" >&2; return 1 ;;
  esac
}
file="$MF_GH_DIR/pr-$pr.json"
save() { jq "$1" "$file" > "$file.tmp" && mv "$file.tmp" "$file"; }
case "$cmd" in
  "pr view")
    gh_repo_must_be_github_com || exit 1
    if [ -n "$pr" ] && [ ! -f "$file" ]; then
      pr=$(jq -s -r --arg b "$pr" '[.[] | select(.headRefName == $b)][0].number // empty' "$MF_GH_DIR"/pr-*.json 2>/dev/null)
      [ -n "$pr" ] || { echo "no such PR $pr" >&2; exit 1; }
      file="$MF_GH_DIR/pr-$pr.json"
    fi
    [ -f "$file" ] || { echo "no such PR $pr" >&2; exit 1; }
    if [ -n "$json" ]; then
      out=$(jq --arg f "$json" '. as $o | ($f | split(",")) | map({(.): $o[.]}) | add' "$file")
      if [ -n "$jq_expr" ]; then jq -r "$jq_expr" <<<"$out"; else printf '%s\n' "$out"; fi
    else jq -r '.body' "$file"; fi ;;
  "pr create")
    gh_repo_must_be_github_com || exit 1
    if [ -f "$MF_DIR/create_fail_count" ]; then
      n=$(cat "$MF_DIR/create_fail_count")
      if [ "$n" -gt 0 ]; then echo "$((n-1))" > "$MF_DIR/create_fail_count"; echo "boom" >&2; exit 1; fi
    elif [ "${CP_CREATE_FAILS:-0}" -gt 0 ]; then echo "boom" >&2; exit 1; fi
    if [ -f "$MF_DIR/create_succeed_then_abort" ]; then
      rm -f "$MF_DIR/create_succeed_then_abort"
      n=$(find "$MF_GH_DIR" -name 'pr-*.json' 2>/dev/null | wc -l | tr -d ' ')
      n=$((n+1))
      h=$("$MF_BIN/git.real" -C "$MF_REPO" rev-parse "$head_name" 2>/dev/null || "$MF_BIN/git.real" -C "$MF_REPO" rev-parse HEAD)
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
    h=$("$MF_BIN/git.real" -C "$MF_REPO" rev-parse "$head_name" 2>/dev/null || "$MF_BIN/git.real" -C "$MF_REPO" rev-parse HEAD)
    b=$(cat "$body_file" 2>/dev/null || true)
    jq -n --argjson n "$n" --arg hn "$head_name" --arg h "$h" --arg body "$b" --arg base "${base:-main}" \
      '{number:$n, state:"OPEN", baseRefName:$base, headRefName:$hn, headRefOid:$h, baseRefOid:$h, changedFiles:1, body:$body, files:[], comments:[], closingIssuesReferences:[], mergeable:"MERGEABLE", mergeCommit:null,
        url:("https://example.test/pull/" + ($n|tostring))}' > "$MF_GH_DIR/pr-$n.json"
    echo "https://example.test/pull/$n" ;;
  "pr comment") [ -f "$file" ] || exit 1; [ -n "$body_file" ] && body=$(cat "$body_file"); jq --arg b "$body" '.comments += [{body:$b}]' "$file" > "$file.tmp" && mv "$file.tmp" "$file" ;;
  "pr list")
    gh_repo_must_be_github_com || exit 1
    if [ -f "$MF_DIR/stub_pr_list_fail" ]; then
      echo "fake gh: pr list failed (fixture)" >&2
      exit 1
    fi
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
fixture_git_wt() {
  local wt="" i=1 arg
  while [ "$i" -le "$#" ]; do
    arg=${!i}
    if [ "$arg" = "-C" ]; then
      i=$((i + 1))
      arg=${!i}
      wt=$arg
      return 0
    fi
    i=$((i + 1))
  done
  wt=${MF_REPO:-}
}
fixture_block_non_file_transport() {
  local wt=$1 url arg
  [ -n "$wt" ] || wt=${MF_REPO:-}
  for arg in "$@"; do
    case "$arg" in
      https://*|http://*|git@*|ssh://*)
        echo "fixture git: refused non-file remote transport in arguments" >&2
        exit 1
        ;;
    esac
  done
  while IFS= read -r url; do
    [ -n "$url" ] || continue
    case "$url" in
      file:*|/*) ;;
      *)
        echo "fixture git: refused non-file remote transport" >&2
        exit 1
        ;;
    esac
  done < <(
    GIT_ALLOW_PROTOCOL=file "$MF_BIN/git.real" -C "$wt" remote get-url origin 2>/dev/null || true
    GIT_ALLOW_PROTOCOL=file "$MF_BIN/git.real" -C "$wt" remote get-url --push --all origin 2>/dev/null || true
  )
}
if [[ " $* " == *" fetch "* ]] && [ -f "$MF_DIR/stub_fetch_fail" ]; then
  echo "fixture git: fetch failed" >&2
  exit 1
fi
if [[ " $* " == *" remote get-url --push --all "* ]] && [ -f "$MF_DIR/stub_pushurl_resolve_fail" ]; then
  echo "fixture git: push URL resolution failed" >&2
  exit 1
fi
if [[ " $* " == *" log "* ]] && [[ " $* " == *" --name-only "* ]] && [ -f "$MF_DIR/stub_env_log_fail" ]; then
  echo "fixture git: history inspection failed" >&2
  exit 1
fi
if [[ " $* " == *" fetch "* ]] || [[ " $* " == *" push "* ]] || [[ " $* " == *" ls-remote "* ]]; then
  wt=$(fixture_git_wt "$@")
  fixture_block_non_file_transport "$wt" "$@"
fi
if [[ " $* " == *" fetch "* ]]; then echo "fetch $*" >> "$MF_DIR/fetch.log"; fi
if printf '%s\n' "$@" | grep -qx 'push' || [[ " $* " == *" push "* ]]; then
  echo "git $*" >> "$MF_DIR/push.log"
  if [ -f "$MF_DIR/push_fail_count" ]; then
    n=$(cat "$MF_DIR/push_fail_count")
    if [ "$n" -gt 0 ]; then echo "$((n-1))" > "$MF_DIR/push_fail_count"; echo "push rejected" >&2; exit 1; fi
  elif [ "${CP_PUSH_FAILS:-0}" -gt 0 ]; then echo "push rejected" >&2; exit 1; fi
fi
exec env GIT_ALLOW_PROTOCOL=file "$MF_BIN/git.real" "$@"
EOS
chmod +x "$MF_BIN/git" "$MF_BIN/git.real"
MF_TEST_GIT="$MF_BIN/git"
export PATH="$MF_BIN:$PATH" MF_TOPLEVEL="$MF_REPO"
export COORDINATOR_PUBLICATION_FIXTURE_ORIGIN=1

make_feature() {
  local b=$1
  "$MF_TEST_GIT" -C "$MF_REPO" checkout -q -B "$b" origin/main
  echo "$b" > "$MF_REPO/$b.txt"
  "$MF_TEST_GIT" -C "$MF_REPO" add "$b.txt"
  "$MF_TEST_GIT" -C "$MF_REPO" commit -q -m "$b"
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
"$MF_TEST_GIT" -C "$MF_REPO" add .env.local
"$MF_TEST_GIT" -C "$MF_REPO" commit -q -m env
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

good_body
printf '\ncloses #1, closes #2' >> "$BODY"
make_feature feat-closes-lower
out=$(pub feat-closes-lower); code=$?
say "$([ "$code" -ne 0 ] && echo 0 || echo 1)" "refuses lowercase comma-separated closes directives" "$out"

good_body
printf '\nCloses example/repo#1, Closes example/repo#2' >> "$BODY"
make_feature feat-closes-qualified
out=$(pub feat-closes-qualified); code=$?
say "$([ "$code" -ne 0 ] && echo 0 || echo 1)" "refuses qualified Closes on one line" "$out"

good_body
printf '\ncloses #1' >> "$BODY"
make_feature feat-closes-noncanonical
out=$(pub feat-closes-noncanonical); code=$?
say "$([ "$code" -ne 0 ] && echo 0 || echo 1)" "refuses non-canonical closes casing" "$out"

out=$(bash "$PUB" --repo "$REPO_SLUG" --branch feat-x --body-file "$BODY" --worktree "$MF_REPO" --force 2>&1); code=$?
say "$([ "$code" -ne 0 ] && echo 0 || echo 1)" "refuses --force flag" "$out"

good_body
make_feature feat-nff
"$MF_TEST_GIT" -C "$MF_REPO" push -q origin "HEAD:refs/heads/feat-nff"
echo remote-only > "$MF_REPO/remote.txt"
"$MF_TEST_GIT" -C "$MF_REPO" add remote.txt
"$MF_TEST_GIT" -C "$MF_REPO" commit -q -m remote-on-origin
"$MF_TEST_GIT" -C "$MF_REPO" push -q origin "HEAD:refs/heads/feat-nff"
"$MF_TEST_GIT" -C "$MF_REPO" reset -q --hard HEAD~1
echo local-only > "$MF_REPO/local.txt"
"$MF_TEST_GIT" -C "$MF_REPO" add local.txt
"$MF_TEST_GIT" -C "$MF_REPO" commit -q -m local-diverge
out=$(pub feat-nff); code=$?
say "$([ "$code" -ne 0 ] && echo 0 || echo 1)" "refuses non-fast-forward without force" "$out"

good_body
make_feature feat-ok
: > "$MF_DIR/push.log"
out=$(pub feat-ok); code=$?
say "$code" "publishes feature branch" "$out"
grep -q 'PUBLISHED https://example.test/pull/' <<<"$out" && ok "returns PUBLISHED url" || bad "missing PUBLISHED: $out"
push_lines=$(grep -c ' push ' "$MF_DIR/push.log" 2>/dev/null || echo 0)
[ "$push_lines" -ge 1 ] && ok "records git push in push.log" || bad "no push log (lines=$push_lines)"

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
"$MF_TEST_GIT" -C "$MF_REPO" add web/.env.local
"$MF_TEST_GIT" -C "$MF_REPO" commit -q -m nested-env
: > "$MF_DIR/fetch.log"
: > "$MF_DIR/push.log"
out=$(pub feat-env-nested); code=$?
say "$([ "$code" -ne 0 ] && echo 0 || echo 1)" "refuses nested tracked env file in diff" "$out"
if grep -q 'fetch ' "$MF_DIR/fetch.log" 2>/dev/null; then ok "nested env refusal runs read-only fetch before history scan"; else bad "fetch missing before nested env refusal: $(cat "$MF_DIR/fetch.log")"; fi
if [ ! -s "$MF_DIR/push.log" ]; then ok "nested env refusal skips push"; else bad "push ran on nested env refusal"; fi

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
"$MF_TEST_GIT" -C "$MF_REPO" add feat-receipt-mismatch.txt
"$MF_TEST_GIT" -C "$MF_REPO" commit -q -m bump
out=$(bash "$PUB" --repo "$REPO_SLUG" --branch feat-receipt-mismatch --body-file "$BODY" --worktree "$MF_REPO" 2>&1); code=$?
say "$([ "$code" -ne 0 ] && echo 0 || echo 1)" "refuses stale receipt after new HEAD" "$out"

good_body
LINKED="$MF_DIR/linked-wt"
"$MF_TEST_GIT" -C "$MF_REPO" checkout -q main
"$MF_TEST_GIT" -C "$MF_REPO" worktree add -q -B feat-wt "$LINKED" origin/main
echo feat-wt > "$LINKED/feat-wt.txt"
"$MF_TEST_GIT" -C "$LINKED" add feat-wt.txt
"$MF_TEST_GIT" -C "$LINKED" commit -q -m feat-wt
out=$(bash "$PUB" --repo "$REPO_SLUG" --branch feat-wt --body-file "$BODY" --worktree "$LINKED" 2>&1); code=$?
say "$code" "publishes from linked worktree" "$out"
want=$("$MF_TEST_GIT" -C "$LINKED" rev-parse --git-path coordinator-publication)
if [[ "$want" = /* ]] && [ -f "$want/receipt.env" ]; then ok "receipt lives at absolute git-path in linked worktree"; else bad "receipt missing at $want/receipt.env"; fi
"$MF_TEST_GIT" -C "$MF_REPO" worktree remove -q -f "$LINKED" 2>/dev/null || rm -rf "$LINKED"

good_body
make_feature feat-resume
: > "$MF_GH_LOG"
echo 3 > "$MF_DIR/create_fail_count"
out=$(pub feat-resume); code=$?
create_first=$(grep -c 'gh pr create' "$MF_GH_LOG" 2>/dev/null || echo 0)
say "$([ "$code" -ne 0 ] && echo 0 || echo 1)" "PR create fails after 3 attempts when push succeeded" "$out"
[ "$create_first" -eq 3 ] && ok "PR create exhaustion uses exactly 3 attempts" || bad "expected 3 pr create calls, got $create_first"
rm -f "$MF_DIR/create_fail_count"
: > "$MF_DIR/push.log"
out=$(pub --keep-receipt feat-resume); code=$?
say "$code" "resume skips push and opens PR" "$out"
if grep -q ' push ' "$MF_DIR/push.log" 2>/dev/null; then
  bad "resume pushed unexpectedly ($(cat "$MF_DIR/push.log"))"
else
  ok "resume records no new push"
fi
pr_count=$(jq -s '[.[] | select(.headRefName=="feat-resume")] | length' "$MF_GH_DIR"/pr-*.json 2>/dev/null || echo 0)
[ "$pr_count" -eq 1 ] && ok "resume leaves exactly one PR" || bad "expected one PR for feat-resume, found $pr_count"
[ -f "$(receipt_path)" ] && ok "resume preserves receipt file" || bad "receipt missing after resume"
out=$(pub --keep-receipt feat-resume); code=$?
say "$code" "second run is idempotent" "$out"

good_body
make_feature feat-interrupt
before=$(find "$MF_GH_DIR" -name 'pr-*.json' 2>/dev/null | wc -l | tr -d ' ')
: > "$MF_DIR/create_succeed_then_abort"
out=$(pub feat-interrupt); code=$?
say "$code" "recovers when PR exists after create transport failure" "$out"
after=$(find "$MF_GH_DIR" -name 'pr-*.json' 2>/dev/null | wc -l | tr -d ' ')
[ "$after" -eq $((before + 1)) ] && ok "interrupt recovery creates exactly one PR" || bad "PR count before=$before after=$after"
out=$(pub --keep-receipt feat-interrupt); code=$?
say "$code" "interrupt recovery second run is idempotent" "$out"

good_body
make_feature feat-origin
saved_origin=$("$MF_TEST_GIT" -C "$MF_REPO" remote get-url origin)
"$MF_TEST_GIT" -C "$MF_REPO" remote set-url origin "https://github.com/wrong/slug.git"
unset COORDINATOR_PUBLICATION_FIXTURE_ORIGIN
out=$(bash "$PUB" --repo "$REPO_SLUG" --branch feat-origin --body-file "$BODY" --worktree "$MF_REPO" 2>&1); code=$?
export COORDINATOR_PUBLICATION_FIXTURE_ORIGIN=1
"$MF_TEST_GIT" -C "$MF_REPO" remote set-url origin "$saved_origin"
say "$([ "$code" -ne 0 ] && echo 0 || echo 1)" "refuses when origin slug does not match --repo" "$out"
[[ "$out" != *"@"* ]] && ok "origin mismatch message omits credential-bearing URLs" || bad "origin error leaked credentials"

good_body
make_feature feat-wrong-host
saved_origin=$("$MF_TEST_GIT" -C "$MF_REPO" remote get-url origin)
"$MF_TEST_GIT" -C "$MF_REPO" remote set-url origin "https://example/repo.git"
unset COORDINATOR_PUBLICATION_FIXTURE_ORIGIN
: > "$MF_DIR/fetch.log"
: > "$MF_DIR/push.log"
: > "$MF_GH_LOG"
out=$(bash "$PUB" --repo "$REPO_SLUG" --branch feat-wrong-host --body-file "$BODY" --worktree "$MF_REPO" 2>&1); code=$?
export COORDINATOR_PUBLICATION_FIXTURE_ORIGIN=1
"$MF_TEST_GIT" -C "$MF_REPO" remote set-url origin "$saved_origin"
say "$([ "$code" -ne 0 ] && echo 0 || echo 1)" "refuses non-github host with matching slug path" "$out"
[[ "$out" == *"URL redacted"* ]] && ok "wrong-host refusal redacts origin URL" || bad "wrong-host error leaked origin URL"
[ ! -s "$MF_DIR/fetch.log" ] && ok "wrong-host refusal skips fetch" || bad "fetch ran on wrong-host origin"
[ ! -s "$MF_DIR/push.log" ] && ok "wrong-host refusal skips push" || bad "push ran on wrong-host origin"
[ ! -s "$MF_GH_LOG" ] && ok "wrong-host refusal skips gh" || bad "gh ran on wrong-host origin"

good_body
make_feature feat-wrong-host-at
saved_origin=$("$MF_TEST_GIT" -C "$MF_REPO" remote get-url origin)
"$MF_TEST_GIT" -C "$MF_REPO" remote set-url origin "https://evil.invalid/x@github.com/example/repo.git"
unset COORDINATOR_PUBLICATION_FIXTURE_ORIGIN
: > "$MF_DIR/fetch.log"
: > "$MF_DIR/push.log"
: > "$MF_GH_LOG"
out=$(bash "$PUB" --repo "$REPO_SLUG" --branch feat-wrong-host-at --body-file "$BODY" --worktree "$MF_REPO" 2>&1); code=$?
export COORDINATOR_PUBLICATION_FIXTURE_ORIGIN=1
"$MF_TEST_GIT" -C "$MF_REPO" remote set-url origin "$saved_origin"
say "$([ "$code" -ne 0 ] && echo 0 || echo 1)" "refuses path-at wrong host before transport" "$out"
[[ "$out" == *"URL redacted"* ]] && ok "path-at wrong-host refusal redacts origin URL" || bad "path-at wrong-host error leaked origin URL"
[ ! -s "$MF_DIR/fetch.log" ] && ok "path-at wrong-host refusal skips fetch" || bad "fetch ran on path-at wrong-host origin"
[ ! -s "$MF_DIR/push.log" ] && ok "path-at wrong-host refusal skips push" || bad "push ran on path-at wrong-host origin"
[ ! -s "$MF_GH_LOG" ] && ok "path-at wrong-host refusal skips gh" || bad "gh ran on path-at wrong-host origin"

good_body
make_feature feat-pushurl-resolve-fail
: > "$MF_DIR/fetch.log"
: > "$MF_DIR/push.log"
: > "$MF_GH_LOG"
touch "$MF_DIR/stub_pushurl_resolve_fail"
out=$(pub feat-pushurl-resolve-fail); code=$?
rm -f "$MF_DIR/stub_pushurl_resolve_fail"
say "$([ "$code" -ne 0 ] && echo 0 || echo 1)" "refuses when effective push URLs cannot be resolved" "$out"
[[ "$out" == *"cannot resolve effective origin push URLs"* ]] && ok "push URL resolution error surfaces in parent" || bad "missing push URL resolution refusal"
[ ! -s "$MF_DIR/fetch.log" ] && ok "push URL resolution failure skips fetch" || bad "fetch ran after push URL resolution failure"
[ ! -s "$MF_DIR/push.log" ] && ok "push URL resolution failure skips push" || bad "push ran after push URL resolution failure"
[ ! -s "$MF_GH_LOG" ] && ok "push URL resolution failure skips gh" || bad "gh ran after push URL resolution failure"

good_body
make_feature feat-env-log-fail
: > "$MF_DIR/fetch.log"
: > "$MF_DIR/push.log"
: > "$MF_GH_LOG"
touch "$MF_DIR/stub_env_log_fail"
out=$(pub feat-env-log-fail); code=$?
rm -f "$MF_DIR/stub_env_log_fail"
say "$([ "$code" -ne 0 ] && echo 0 || echo 1)" "refuses when publish-range history inspection fails" "$out"
[[ "$out" == *"cannot inspect branch history for environment files"* ]] && ok "history inspection error surfaces in parent" || bad "missing history inspection refusal"
grep -q 'fetch ' "$MF_DIR/fetch.log" 2>/dev/null && ok "history inspection failure follows destination fetch" || bad "fetch missing before history inspection failure"
[ ! -s "$MF_DIR/push.log" ] && ok "history inspection failure skips push" || bad "push ran after history inspection failure"
[ ! -s "$MF_GH_LOG" ] && ok "history inspection failure skips gh" || bad "gh ran after history inspection failure"

good_body
"$MF_TEST_GIT" -C "$MF_REPO" checkout -q main
printf 'secret\n' > "$MF_REPO/.env"
"$MF_TEST_GIT" -C "$MF_REPO" add .env
"$MF_TEST_GIT" -C "$MF_REPO" commit -q -m 'unpublished env on main'
"$MF_TEST_GIT" -C "$MF_REPO" checkout -q -B feat-unpub-main-env main
echo regular > "$MF_REPO/regular.txt"
"$MF_TEST_GIT" -C "$MF_REPO" add regular.txt
"$MF_TEST_GIT" -C "$MF_REPO" commit -q -m 'feature on unpublished main'
"$MF_TEST_GIT" -C "$MF_REPO" update-ref -d refs/remotes/origin/main 2>/dev/null || true
: > "$MF_DIR/fetch.log"
: > "$MF_DIR/push.log"
: > "$MF_GH_LOG"
out=$(pub feat-unpub-main-env); code=$?
say "$([ "$code" -ne 0 ] && echo 0 || echo 1)" "refuses env on unpublished local main ancestry" "$out"
[[ "$out" == *"tracked environment file"* ]] && ok "unpublished main env surfaces in outgoing scan" || bad "missing env refusal for unpublished main: $out"
[ ! -s "$MF_DIR/push.log" ] && ok "unpublished main env refusal skips push" || bad "push ran: $(cat "$MF_DIR/push.log")"
[ ! -s "$MF_GH_LOG" ] && ok "unpublished main env refusal skips gh" || bad "gh ran on unpublished main env"
"$MF_TEST_GIT" -C "$MF_REPO" fetch -q origin main

good_body
touch "$MF_DIR/stub_fetch_fail"
: > "$MF_DIR/push.log"
: > "$MF_GH_LOG"
make_feature feat-fetch-fail
out=$(pub feat-fetch-fail); code=$?
rm -f "$MF_DIR/stub_fetch_fail"
say "$([ "$code" -ne 0 ] && echo 0 || echo 1)" "refuses when destination fetch fails" "$out"
[[ "$out" == *"cannot fetch destination main"* ]] && ok "fetch failure message surfaces" || bad "missing fetch failure refusal: $out"
[ ! -s "$MF_DIR/push.log" ] && ok "fetch failure skips push" || bad "push after fetch failure"
[ ! -s "$MF_GH_LOG" ] && ok "fetch failure skips gh" || bad "gh after fetch failure"

good_body
make_feature feat-receipt-evil
out=$(pub feat-receipt-evil); code=$?
say "$code" "first publish for receipt safety" "$out"
rcpt=$(receipt_path)
printf 'evil=1\n' >> "$rcpt"
out=$(bash "$PUB" --repo "$REPO_SLUG" --branch feat-receipt-evil --body-file "$BODY" --worktree "$MF_REPO" 2>&1); code=$?
say "$([ "$code" -ne 0 ] && echo 0 || echo 1)" "refuses receipt with unexpected keys" "$out"

good_body
make_feature feat-receipt-cmd
out=$(pub feat-receipt-cmd); code=$?
say "$code" "first publish before receipt command substitution probe" "$out"
marker="$MF_DIR/receipt-exec-marker"
rm -f "$marker"
rcpt=$(receipt_path)
{
  printf 'repo=example/repo$(touch %q)\n' "$marker"
  printf 'branch=feat-receipt-cmd\n'
  printf 'head_sha=%s\n' "$("$MF_TEST_GIT" -C "$MF_REPO" rev-parse HEAD)"
  printf 'push_ok=1\n'
  printf 'pr_url=\n'
  printf 'pr_number=\n'
} > "$rcpt"
out=$(bash "$PUB" --repo "$REPO_SLUG" --branch feat-receipt-cmd --body-file "$BODY" --worktree "$MF_REPO" 2>&1); code=$?
say "$([ "$code" -ne 0 ] && echo 0 || echo 1)" "refuses receipt with shell metacharacters in repo" "$out"
[ ! -e "$marker" ] && ok "recognized-key command substitution marker absent" || bad "receipt parsing executed shell: $marker"

good_body
make_feature feat-receipt-atomic
out=$(pub feat-receipt-atomic); code=$?
say "$code" "first publish before atomic receipt probe" "$out"
rcpt=$(receipt_path)
cp "$rcpt" "$MF_DIR/receipt.snap"
export COORDINATOR_PUBLICATION_TEST_STOP_BEFORE_MV=1
out=$(bash "$PUB" --repo "$REPO_SLUG" --branch feat-receipt-atomic --body-file "$BODY" --worktree "$MF_REPO" 2>&1); code=$?
unset COORDINATOR_PUBLICATION_TEST_STOP_BEFORE_MV
say "$([ "$code" -ne 0 ] && echo 0 || echo 1)" "test stop before receipt rename refuses" "$out"
cmp -s "$rcpt" "$MF_DIR/receipt.snap" && ok "interrupted receipt write preserves last complete receipt" || bad "receipt changed after aborted write"
out=$(pub --keep-receipt feat-receipt-atomic); code=$?
say "$code" "same command recovers after aborted receipt write" "$out"

good_body
make_feature feat-pushurl
WRONG_ORIGIN="$MF_DIR/wrong-origin.git"
"$MF_TEST_GIT" init -q --bare -b main "$WRONG_ORIGIN"
"$MF_TEST_GIT" -C "$MF_REPO" config --add remote.origin.pushurl "$WRONG_ORIGIN"
: > "$MF_DIR/push.log"
out=$(pub feat-pushurl); code=$?
"$MF_TEST_GIT" -C "$MF_REPO" config --unset-all remote.origin.pushurl 2>/dev/null || true
say "$([ "$code" -ne 0 ] && echo 0 || echo 1)" "refuses mismatched pushurl even with file origin" "$out"
[ ! -s "$MF_DIR/push.log" ] && ok "pushurl refusal skips push" || bad "push ran on pushurl mismatch"

good_body
make_feature feat-push-rewrite
WRONG_PUSH="$MF_DIR/wrong-push.git"
"$MF_TEST_GIT" init -q --bare -b main "$WRONG_PUSH"
"$MF_TEST_GIT" -C "$MF_REPO" config "url.$WRONG_PUSH.pushInsteadOf" "$MF_ORIGIN"
: > "$MF_DIR/push.log"
out=$(pub feat-push-rewrite); code=$?
"$MF_TEST_GIT" -C "$MF_REPO" config --unset-all "url.$WRONG_PUSH.pushInsteadOf" 2>/dev/null || true
say "$([ "$code" -ne 0 ] && echo 0 || echo 1)" "refuses Git-resolved push URL rewrite to different bare remote" "$out"
[ ! -s "$MF_DIR/push.log" ] && ok "push rewrite refusal skips push" || bad "push ran after url.pushInsteadOf rewrite"

good_body
make_feature feat-env-history
printf 'secret\n' > "$MF_REPO/.env"
"$MF_TEST_GIT" -C "$MF_REPO" add .env
"$MF_TEST_GIT" -C "$MF_REPO" commit -q -m add-env
"$MF_TEST_GIT" -C "$MF_REPO" rm -f .env
"$MF_TEST_GIT" -C "$MF_REPO" commit -q -m del-env
out=$(pub feat-env-history); code=$?
say "$([ "$code" -ne 0 ] && echo 0 || echo 1)" "refuses add-then-delete secret env in publish range" "$out"

good_body
make_feature feat-env-unicode
mkdir -p "$MF_REPO/テスト"
printf 'secret\n' > "$MF_REPO/テスト/.env"
"$MF_TEST_GIT" -C "$MF_REPO" add "テスト/.env"
"$MF_TEST_GIT" -C "$MF_REPO" commit -q -m unicode-env
out=$(pub feat-env-unicode); code=$?
say "$([ "$code" -ne 0 ] && echo 0 || echo 1)" "refuses non-ASCII path secret env file" "$out"

good_body
: > "$MF_DIR/push.log"
"$MF_TEST_GIT" -C "$MF_REPO" checkout -q -B topic-a origin/main
echo a > "$MF_REPO/a.txt"
"$MF_TEST_GIT" -C "$MF_REPO" add a.txt
"$MF_TEST_GIT" -C "$MF_REPO" commit -q -m topic-a
"$MF_TEST_GIT" -C "$MF_REPO" checkout -q -B topic-b origin/main
echo b > "$MF_REPO/b.txt"
"$MF_TEST_GIT" -C "$MF_REPO" add b.txt
"$MF_TEST_GIT" -C "$MF_REPO" commit -q -m topic-b
"$MF_TEST_GIT" -C "$MF_REPO" checkout -q -B feat-env-merge origin/main
"$MF_TEST_GIT" -C "$MF_REPO" merge -q --no-edit topic-a
"$MF_TEST_GIT" -C "$MF_REPO" merge --no-commit --no-ff topic-b
mkdir -p "$MF_REPO/web"
printf 'secret\n' > "$MF_REPO/web/.env.local"
"$MF_TEST_GIT" -C "$MF_REPO" add web/.env.local
"$MF_TEST_GIT" -C "$MF_REPO" commit -q -m 'merge resolution env'
out=$(pub feat-env-merge); code=$?
say "$([ "$code" -ne 0 ] && echo 0 || echo 1)" "refuses secret env introduced only in merge resolution" "$out"
[ ! -s "$MF_DIR/push.log" ] && ok "merge env refusal skips push" || bad "push ran after merge env refusal"

good_body
: > "$MF_DIR/push.log"
"$MF_TEST_GIT" -C "$MF_REPO" checkout -q -B topic-a-add origin/main
printf 'secret\n' > "$MF_REPO/.env"
"$MF_TEST_GIT" -C "$MF_REPO" add .env
"$MF_TEST_GIT" -C "$MF_REPO" commit -q -m 'add env on topic-a'
"$MF_TEST_GIT" -C "$MF_REPO" checkout -q -B feat-env-2merge origin/main
"$MF_TEST_GIT" -C "$MF_REPO" merge -q --no-ff topic-a-add -m 'merge add env'
"$MF_TEST_GIT" -C "$MF_REPO" checkout -q -B topic-b-del HEAD
"$MF_TEST_GIT" -C "$MF_REPO" rm -f .env
"$MF_TEST_GIT" -C "$MF_REPO" commit -q -m 'delete env on topic-b'
"$MF_TEST_GIT" -C "$MF_REPO" checkout -q feat-env-2merge
"$MF_TEST_GIT" -C "$MF_REPO" merge -q --no-ff topic-b-del -m 'merge delete env'
out=$(pub feat-env-2merge); code=$?
say "$([ "$code" -ne 0 ] && echo 0 || echo 1)" "refuses env add across separate merges even when final tree clean" "$out"
[ ! -s "$MF_DIR/push.log" ] && ok "two-merge env history refusal skips push" || bad "push after two-merge env refusal"

good_body
make_feature feat-receipt-partial-api
touch "$MF_DIR/stub_pr_list_fail"
: > "$MF_GH_LOG"
out=$(pub feat-receipt-partial-api); code=$?
rm -f "$MF_DIR/stub_pr_list_fail"
say "$code" "writes valid receipt when pr list fails after create" "$out"
grep -Fq 'pr_url=https://example.test/pull/' "$(receipt_path)" && ok "partial API failure receipt has https pr_url" || bad "receipt missing valid pr_url"
grep -Eq '^pr_number=[0-9]+$' "$(receipt_path)" && ok "partial API failure receipt has pr_number" || bad "receipt missing pr_number"
touch "$MF_DIR/stub_pr_list_fail"
: > "$MF_GH_LOG"
out=$(pub --keep-receipt feat-receipt-partial-api); code=$?
rm -f "$MF_DIR/stub_pr_list_fail"
say "$code" "resumes after partial API failure without duplicate PR" "$out"
pr_count=$(jq -s '[.[] | select(.headRefName=="feat-receipt-partial-api")] | length' "$MF_GH_DIR"/pr-*.json 2>/dev/null || echo 0)
[ "$pr_count" -eq 1 ] && ok "partial API recovery leaves exactly one PR" || bad "expected one PR, found $pr_count"

good_body
make_feature feat-gh-host-pin
: > "$MF_GH_LOG"
out=$(GH_HOST=enterprise.example.com pub feat-gh-host-pin); code=$?
say "$code" "publishes with inherited GH_HOST when gh repo is host-qualified" "$out"
grep -Fq -- '--repo github.com/example/repo' "$MF_GH_LOG" && ok "every gh call pins github.com in --repo" \
  || bad "gh log missing host-qualified repo: $(tr '\n' ' ' < "$MF_GH_LOG")"

good_body
branch_plus='fix/issue+6676'
"$MF_TEST_GIT" -C "$MF_REPO" checkout -q -B "$branch_plus" origin/main
echo plus > "$MF_REPO/plus.txt"
"$MF_TEST_GIT" -C "$MF_REPO" add plus.txt
"$MF_TEST_GIT" -C "$MF_REPO" commit -q -m plus
out=$(pub "$branch_plus"); code=$?
say "$code" "publishes Git-valid branch name containing plus" "$out"
grep -Fq "branch=$branch_plus" "$(receipt_path)" && ok "receipt records plus branch before transport completes" \
  || bad "receipt missing plus branch name"

good_body
make_feature feat-push-exhaust
echo 3 > "$MF_DIR/push_fail_count"
: > "$MF_DIR/push.log"
out=$(pub feat-push-exhaust); code=$?
push_try=$(grep -c ' push ' "$MF_DIR/push.log" 2>/dev/null || echo 0)
rm -f "$MF_DIR/push_fail_count"
say "$([ "$code" -ne 0 ] && echo 0 || echo 1)" "push fails after bounded attempts" "$out"
[ "$push_try" -eq 3 ] && ok "push exhaustion uses exactly 3 attempts" || bad "expected 3 push attempts, got $push_try"

echo "passed $pass, failed $fail"
[ "$fail" -eq 0 ]
