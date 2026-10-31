#!/usr/bin/env bash
# Shared fixture for the merge pipeline suites. Source it, then call mf_setup.
# Real git (fixture repo plus bare origin), stateful fake gh and orca, a fifo barrier, a wall-clock limit.
# Only `git rev-parse --show-toplevel` is stubbed, through MF_TOPLEVEL.

mf_setup() {
  MF_DIR=$(mktemp -d)
  MF_REPO="$MF_DIR/repo" MF_ORIGIN="$MF_DIR/origin.git" MF_BIN="$MF_DIR/bin"
  MF_GH_DIR="$MF_DIR/gh" MF_ORCA_DIR="$MF_DIR/orca"
  MF_GH_LOG="$MF_DIR/gh.log" MF_ORCA_LOG="$MF_DIR/orca.log"
  MF_REAL_GIT=$(command -v git)
  mkdir -p "$MF_BIN" "$MF_GH_DIR" "$MF_ORCA_DIR"
  : > "$MF_GH_LOG"; : > "$MF_ORCA_LOG"
  echo '{"runs":[]}' > "$MF_ORCA_DIR/runs.json"
  echo '{"workers":[]}' > "$MF_ORCA_DIR/workers.json"
  echo '{"terminals":[]}' > "$MF_ORCA_DIR/terminals.json"
  export MF_DIR MF_REPO MF_ORIGIN MF_BIN MF_GH_DIR MF_ORCA_DIR MF_GH_LOG MF_ORCA_LOG MF_REAL_GIT
  export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_ALLOW_PROTOCOL=file
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

  "$MF_REAL_GIT" init -q --bare -b main "$MF_ORIGIN"
  "$MF_REAL_GIT" init -q -b main "$MF_REPO"
  "$MF_REAL_GIT" -C "$MF_REPO" remote add origin "$MF_ORIGIN"
  echo base > "$MF_REPO/base.txt"
  "$MF_REAL_GIT" -C "$MF_REPO" add base.txt
  "$MF_REAL_GIT" -C "$MF_REPO" commit -q -m init
  "$MF_REAL_GIT" -C "$MF_REPO" push -q origin main
  "$MF_REAL_GIT" -C "$MF_REPO" fetch -q origin

  _mf_write_git; _mf_write_gh; _mf_write_orca
  chmod +x "$MF_BIN/git" "$MF_BIN/gh" "$MF_BIN/orca"
  export PATH="$MF_BIN:$PATH"
}

mf_teardown() { [ -n "${MF_DIR:-}" ] && rm -rf "$MF_DIR"; }

_mf_write_git() {
  cat > "$MF_BIN/git" <<'EOS'
#!/usr/bin/env bash
if [ -n "${MF_TOPLEVEL:-}" ] && [ "$*" = "rev-parse --show-toplevel" ]; then echo "$MF_TOPLEVEL"; exit 0; fi
exec "$MF_REAL_GIT" "$@"
EOS
}

# mf_pr_add <number> <branch> [body] [file]: commit <file> (default <branch>.txt) on <branch>, push it, record the PR.
mf_pr_add() {
  local n=$1 branch=$2 body=${3:-} path=${4:-$2.txt} head files base
  base=$("$MF_REAL_GIT" -C "$MF_REPO" rev-parse origin/main)
  "$MF_REAL_GIT" -C "$MF_REPO" checkout -q -B "$branch" origin/main
  mkdir -p "$MF_REPO/$(dirname "$path")"
  echo "$branch" > "$MF_REPO/$path"
  "$MF_REAL_GIT" -C "$MF_REPO" add "$path"
  "$MF_REAL_GIT" -C "$MF_REPO" commit -q -m "$branch"
  "$MF_REAL_GIT" -C "$MF_REPO" push -q -f origin "$branch"
  "$MF_REAL_GIT" -C "$MF_REPO" checkout -q main
  head=$("$MF_REAL_GIT" -C "$MF_REPO" rev-parse "$branch")
  files=$(jq -n --arg f "$path" '[{path:$f, filename:$f}]')
  jq -n --argjson n "$n" --arg b "$branch" --arg h "$head" --arg body "$body" --argjson files "$files" --arg base "$base" \
    '{number:$n, state:"OPEN", baseRefName:"main", headRefName:$b, headRefOid:$h, baseRefOid:$base, changedFiles:($files|length), body:$body, files:$files,
      comments:[], closingIssuesReferences:[], mergeable:"MERGEABLE", mergeCommit:null,
      url:("https://example.test/pull/" + ($n|tostring))}' > "$MF_GH_DIR/pr-$n.json"
}

# mf_comment_flag <pr> <index> <edited|minimized> <true|false>
mf_comment_flag() {
  local f="$MF_GH_DIR/pr-$1.json"
  jq --argjson i "$2" --arg k "$3" --argjson v "$4" '.comments[$i][$k] = $v' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}

_mf_write_gh() {
  cat > "$MF_BIN/gh" <<'EOS'
#!/usr/bin/env bash
echo "gh $*" >> "$MF_GH_LOG"
cmd="$1 ${2:-}"; shift 2 || true
  pr="" body="" body_file="" json="" match="" base="" jq_expr=""
  case "$cmd" in
    api*) for a in "$@"; do case "$a" in repos/*/pulls/*/files) pr=${a#*/pulls/}; pr=${pr%%/*} ;; esac; done ;;
    *)
      # A missing PR number means the PR of the current branch, as with the real gh.
      case "${1:-}" in -*|"") ;; *) pr=$1; shift ;; esac
      if [ -z "$pr" ] && [ "$cmd" = "pr view" ]; then
        pr=$(jq -s -r --arg b "$("$MF_REAL_GIT" rev-parse --abbrev-ref HEAD 2>/dev/null)" '[.[] | select(.headRefName == $b)][0].number // empty' "$MF_GH_DIR"/pr-*.json)
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
    --repo|--limit|--state) shift ;;
  esac
  shift
done
file="$MF_GH_DIR/pr-$pr.json"
save() { jq "$1" "$file" > "$file.tmp" && mv "$file.tmp" "$file"; }
case "$cmd" in
  "pr view")
    [ -f "$file" ] || { echo "no such PR $pr" >&2; exit 1; }
    if [ -n "$json" ]; then
      out=$(jq --arg f "$json" '. as $o | ($f | split(",")) | map({(.): $o[.]}) | add
        | if has("comments") then .comments |= map(. + {includesCreatedEdit: .edited, isMinimized: .minimized}) else . end' "$file")
      if [ -n "$jq_expr" ]; then jq -r "$jq_expr" <<<"$out"; else printf '%s\n' "$out"; fi
    else jq -r '.body' "$file"; fi ;;
  "pr comment")
    [ -f "$file" ] || { echo "no such PR $pr" >&2; exit 1; }
    [ -n "$body_file" ] && body=$(cat "$body_file")
    if [ "${#body}" -gt 65536 ]; then echo "GraphQL: Body is too long (maximum is 65536 characters)" >&2; exit 1; fi
    jq --arg b "$body" '.comments += [{body:$b, author:"fixture", edited:false, minimized:false}]' "$file" > "$file.tmp" && mv "$file.tmp" "$file" ;;
  "pr edit") [ -n "$base" ] && save ".baseRefName = \"$base\"" ;;
  "pr list")
    jq -s --arg b "${base:-}" '[.[] | select(.state=="OPEN" and ($b=="" or .baseRefName==$b)) | {number}]' "$MF_GH_DIR"/pr-*.json ;;
  "pr diff") jq -r '.files[].path' "$file" ;;
  "pr merge")
    [ -f "$file" ] || { echo "no such PR $pr" >&2; exit 1; }
    head=$(jq -r '.headRefOid' "$file"); branch=$(jq -r '.headRefName' "$file")
    [ -z "$match" ] || [ "$match" = "$head" ] || { echo "head commit does not match" >&2; exit 1; }
    work=$(mktemp -d)
    "$MF_REAL_GIT" clone -q "$MF_ORIGIN" "$work" && "$MF_REAL_GIT" -C "$work" merge -q --no-ff -m "Merge PR $pr" "$head" \
      && "$MF_REAL_GIT" -C "$work" push -q origin HEAD:main || { rm -rf "$work"; exit 1; }
    sha=$("$MF_REAL_GIT" -C "$work" rev-parse HEAD); rm -rf "$work"
    save ".state = \"MERGED\" | .mergeCommit = {oid: \"$sha\"}" ;;
  api*) jq '[.files[]]' "$file" ;;
  *) echo "fake gh: unsupported: $cmd" >&2; exit 1 ;;
esac
EOS
}

mf_orca_add_run() { _mf_orca_append runs.json runs "$(jq -n --arg id "$1" '{id:$id}')"; }
# mf_orca_add_worker <run> <dispatch> <dispatchStatus> <worktree> [terminal handle]
# Entries carry the real Orca field names too: worktreeId ("repo::<path>") and agentTerminalHandle.
mf_orca_add_worker() {
  _mf_orca_append workers.json workers "$(jq -n --arg r "$1" --arg d "$2" --arg s "$3" --arg w "$4" --arg h "${5:-}" \
    '{runId:$r, dispatchId:$d, dispatchStatus:$s, worktree:$w, worktreeId:("repo::" + $w), agentTerminalHandle:$h}')"
}
# mf_orca_add_terminal <handle> <cwd>: cwd is a worktree root or any directory under it.
mf_orca_add_terminal() {
  _mf_orca_append terminals.json terminals "$(jq -n --arg h "$1" --arg w "$2" '{handle:$h, worktree:$w, cwd:$w, worktreePath:$w}')"
}
_mf_orca_append() {
  local f="$MF_ORCA_DIR/$1"
  jq --arg k "$2" --argjson v "$3" '.[$k] += [$v]' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}

_mf_write_orca() {
  cat > "$MF_BIN/orca" <<'EOS'
#!/usr/bin/env bash
echo "orca $*" >> "$MF_ORCA_LOG"
d="$MF_ORCA_DIR"
upd() { jq "$1" "$d/$2" > "$d/$2.tmp" && mv "$d/$2.tmp" "$d/$2"; }
case "$1 ${2:-}" in
  "orchestration run-list") jq '. + {ok: true, result: .}' "$d/runs.json" ;;
  "orchestration worker-list")
    run=""; shift 2
    while [ $# -gt 0 ]; do [ "$1" = --run ] && run=$2; shift; done
    jq --arg r "$run" '.workers |= map(select($r=="" or .runId==$r)) | . + {ok:true, result:.}' "$d/workers.json" ;;
  "orchestration worker-release")
    id=""; shift 2
    while [ $# -gt 0 ]; do [ "$1" = --dispatch ] && id=$2; shift; done
    upd ".workers |= map(if .dispatchId==\"$id\" then .dispatchStatus=\"released\" else . end)" workers.json ;;
  "terminal list") jq '. + {ok:true, result:.}' "$d/terminals.json" ;;
  "terminal close")
    h=""; shift 2
    while [ $# -gt 0 ]; do [ "$1" = --terminal ] && h=$2; shift; done
    upd ".terminals |= map(select(.handle != \"$h\"))" terminals.json ;;
  *) echo "fake orca: unsupported: $*" >&2; exit 1 ;;
esac
EOS
}

# Fifo barrier: mf_barrier_make <name>; a fake head-checks calls mf_barrier_wait <name>; the test calls mf_barrier_release <name>.
mf_barrier_make() { mkfifo "$MF_DIR/barrier-$1"; }
mf_barrier_wait() { : > "$MF_DIR/barrier-$1.waiting"; read -r _ < "$MF_DIR/barrier-$1"; }
mf_barrier_release() { echo go > "$MF_DIR/barrier-$1"; }
# mf_barrier_wait_until_blocked <name> <seconds>: poll until a process is waiting at the barrier.
mf_barrier_wait_until_blocked() {
  local i=0
  while [ ! -e "$MF_DIR/barrier-$1.waiting" ]; do
    i=$((i + 1)); [ "$i" -gt $(($2 * 10)) ] && return 1; sleep 0.1
  done
  sleep 0.2
}

# mf_run_limited <seconds> <cmd...>: run under a wall-clock limit without coreutils timeout. Exit 124 on timeout.
mf_run_limited() {
  local secs=$1 pid watcher flag rc
  shift
  flag=$(mktemp -u "${MF_DIR:-/tmp}/limit.XXXXXX")
  "$@" & pid=$!
  ( sleep "$secs"; : > "$flag"; _mf_kill_tree "$pid" ) >/dev/null 2>&1 & watcher=$!
  wait "$pid" 2>/dev/null; rc=$?
  _mf_kill_tree "$watcher"
  wait "$watcher" 2>/dev/null
  if [ -e "$flag" ]; then rm -f "$flag"; return 124; fi
  return "$rc"
}
_mf_kill_tree() {
  local c
  for c in $(pgrep -P "$1" 2>/dev/null); do _mf_kill_tree "$c"; done
  kill "$1" 2>/dev/null
  return 0
}
