#!/usr/bin/env bash
# The Tech Lead's only way to merge a reviewed PR.
# Usage: lead-merge.sh --repo owner/name --pr N --head <sha> [--mechanical]
#        lead-merge.sh --repo owner/name --batch N N [N ...]
# --mechanical: mechanical lane (pure text substitution or deletion); replaces the Verdict, nothing else.
# --verdict-from <owner/dotfiles#N>: a configured repo PR whose changed files are all generated team copies
#   (inside a skill dir that sync-team-skills.sh owns), with sync-team-skills.sh
#   --check passing at the head, merges on the newest PASS Verdict of that MERGED dotfiles PR instead of its own.
# A Verdict also carries across a clean merge of main (see verdict_carry).
# --verify-command "<cmd>": the brief's test command; when a Verdict is relied on, its newest comment
#   must carry a `Command:` line equal to it (trimmed, exact match). Without the flag nothing changes.
set -euo pipefail

die() { echo "lead-merge: refused: $*" >&2; exit 1; }

issue_from_branch() {
  printf '%s\n' "$1" | grep -oE '[0-9]{3,}' | tail -n1 || true
}

repo="" pr="" head="" mechanical=false verify_command="" verify_set=false verdict_from="" batch_requested=false
batch_prs=()
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) repo="${2:-}"; shift 2 ;;
    --pr) pr="${2:-}"; shift 2 ;;
    --head) head="${2:-}"; shift 2 ;;
    --batch)
      batch_requested=true
      shift
      while [ $# -gt 0 ] && [[ "$1" =~ ^[0-9]+$ ]]; do batch_prs+=("$1"); shift; done
      ;;
    --mechanical) mechanical=true; shift ;;
    --verdict-from) [ $# -ge 2 ] || die "--verdict-from needs owner/repo#N"; verdict_from="${2:-}"; shift 2 ;;
    --verify-command) [ $# -ge 2 ] || die "--verify-command needs a value"; verify_command="${2:-}"; verify_set=true; shift 2 ;;
    *) die "unknown argument $1" ;;
  esac
done
[ -n "$repo" ] || die "usage: lead-merge.sh --repo owner/name (--pr N --head SHA | --batch N N [N ...])"
if [ "${#batch_prs[@]}" -gt 0 ]; then
  [ -z "$pr$head$verdict_from" ] && [ "$verify_set" = false ] && [ "$mechanical" = false ] \
    || die "--batch cannot be combined with single-PR options"
  [ "${#batch_prs[@]}" -ge 2 ] || die "--batch needs at least two PR numbers"
  duplicate_pr=$(printf '%s\n' "${batch_prs[@]}" | sort | uniq -d | head -n1)
  [ -z "$duplicate_pr" ] || die "--batch repeats PR $duplicate_pr"
else
  [ -n "$pr" ] && [ -n "$head" ] || die "usage: lead-merge.sh --repo owner/name --pr N --head <sha> [--mechanical] [--verify-command <cmd>]"
  case "$pr" in *[!0-9]*) die "--pr must be a number" ;; esac
  if [ "$batch_requested" = true ]; then
    [ -n "${LEAD_MERGE_TRAIN_HEAD:-}" ] && [ -n "${LEAD_MERGE_TRAIN_HEADS:-}" ] \
      || die "internal --batch item needs a train head and PR heads"
  fi
fi

# 1. Caller is the lead. Orca sets no role variable (ORCA_TERMINAL_HANDLE and
# ORCA_AGENT_SESSION_ID exist for every agent), so the worktree name is the check.
top=$(git rev-parse --show-toplevel 2>/dev/null) || die "not inside a git worktree"
top=$(cd -P "$top" && pwd)
root=$(cd -P "$HOME/orca/workspaces" 2>/dev/null && pwd) || die "no $HOME/orca/workspaces"
case "$top" in "$root"/*) ;; *) die "worktree is not under $root" ;; esac
case "$(basename "$top")" in lead-*) ;; *) die "only the lead worktree (lead-*) may merge" ;; esac

if [ "${#batch_prs[@]}" -gt 0 ]; then
  script=$(cd "$(dirname "$0")" && pwd)/$(basename "$0")
  head_checks=${LEAD_MERGE_HEAD_CHECKS:-$(dirname "$script")/head-checks.sh}
  dry=${DRY_RUN:-0}
  git fetch origin main >&2 || die "cannot fetch main for batch"
  batch_base=$(git rev-parse --verify 'origin/main^{commit}') || die "cannot resolve origin/main"
  ready_prs=() ready_heads=()

  for batch_pr in "${batch_prs[@]}"; do
    batch_info=$(gh pr view "$batch_pr" --repo "$repo" --json headRefOid) || die "cannot read PR $batch_pr"
    batch_head=$(jq -r .headRefOid <<<"$batch_info")
    [[ "$batch_head" =~ ^[0-9a-f]{40}$ ]] || die "PR $batch_pr has an invalid head"
    git cat-file -e "$batch_head^{commit}" 2>/dev/null || git fetch origin "$batch_head" >&2 || die "cannot fetch PR $batch_pr head"
    ready_prs+=("$batch_pr"); ready_heads+=("$batch_head")
  done

  append_train() {
    local current=$1 number=$2 pr_head=$3 tree
    tree=$(git merge-tree --write-tree "$current" "$pr_head" 2>/dev/null) || return 1
    tree=${tree%%$'\n'*}
    printf 'lead merge train PR #%s\n' "$number" \
      | GIT_AUTHOR_NAME=lead-merge GIT_AUTHOR_EMAIL=lead-merge@example.invalid \
        GIT_COMMITTER_NAME=lead-merge GIT_COMMITTER_EMAIL=lead-merge@example.invalid \
        git commit-tree "$tree" -p "$current" -p "$pr_head"
  }
  # Compose once in queue order. A conflicting PR is reported and left out of the train.
  train=$batch_base
  composed_prs=() composed_heads=()
  for i in "${!ready_prs[@]}"; do
    if next_train=$(append_train "$train" "${ready_prs[$i]}" "${ready_heads[$i]}"); then
      train=$next_train
      composed_prs+=("${ready_prs[$i]}"); composed_heads+=("${ready_heads[$i]}")
    else
      echo "lead-merge: batch conflict PR #${ready_prs[$i]} head=${ready_heads[$i]} (skipped)" >&2
    fi
  done
  [ "${#composed_prs[@]}" -gt 0 ] || die "no conflict-free PRs remain in batch"
  if [ "${#composed_prs[@]}" -eq 1 ]; then
    if [ "$dry" = 1 ]; then
      echo "[dry-run] single PR #${composed_prs[0]} uses the unchanged single-PR path"
      exit 0
    fi
    exec bash "$script" --repo "$repo" --pr "${composed_prs[0]}" --head "${composed_heads[0]}"
  fi

  build_train() {
    local current=$batch_base index
    for index in "$@"; do
      current=$(append_train "$current" "${composed_prs[$index]}" "${composed_heads[$index]}") || return 1
    done
    printf '%s\n' "$current"
  }
  indexes=("${!composed_prs[@]}")
  train=$(build_train "${indexes[@]}") || die "cannot rebuild batch train"
  train_heads=$(IFS=,; echo "${composed_heads[*]}")
  if [ "$dry" = 1 ]; then
    echo "[dry-run] head-checks train=$train train-heads=$train_heads"
    for i in "${!composed_prs[@]}"; do
      echo "[dry-run] merge PR #${composed_prs[$i]} head=${composed_heads[$i]}"
    done
    exit 0
  fi

  declare -a pass_train pass_heads
  failures=0
  check_group() { # recursively bisect red trains
    local ids=("$@") group_train group_heads group_prs receipt_file mid failures_before
    group_train=$(build_train "${ids[@]}") || die "cannot build bisect train"
    group_heads=""
    for i in "${ids[@]}"; do group_heads+="${group_heads:+,}${composed_heads[$i]}"; done
    receipt_file=$(mktemp)
    if "$head_checks" --repo "$top" --ref "$group_train" --base "$batch_base" --train-heads "$group_heads" >"$receipt_file"; then
      for i in "${ids[@]}"; do
        gh pr comment "${composed_prs[$i]}" --repo "$repo" --body-file "$receipt_file" >/dev/null \
          || die "cannot attach train Checks to PR ${composed_prs[$i]}"
        pass_train[i]=$group_train; pass_heads[i]=$group_heads
      done
      rm -f "$receipt_file"
      return 0
    fi
    rm -f "$receipt_file"
    if [ "${#ids[@]}" -eq 1 ]; then
      i=${ids[0]}; failures=$((failures+1))
      echo "lead-merge: batch failing PR #${composed_prs[$i]} head=${composed_heads[$i]}" >&2
      return 0
    fi
    mid=$((${#ids[@]} / 2))
    failures_before=$failures
    check_group "${ids[@]:0:mid}"
    check_group "${ids[@]:mid}"
    if [ "$failures" -eq "$failures_before" ]; then
      group_prs=""
      for i in "${ids[@]}"; do
        unset 'pass_train[i]' 'pass_heads[i]'
        group_prs+="${group_prs:+,}${composed_prs[$i]}"
      done
      failures=$((failures+${#ids[@]}))
      echo "lead-merge: red interaction could not isolate one PR; returning PRs $group_prs" >&2
    fi
  }
  check_group "${indexes[@]}"

  # After removing a failing PR, verify all survivors together; separately green
  # halves do not prove their combination is green.
  survivor_indexes=()
  for i in "${!composed_prs[@]}"; do
    [ -z "${pass_train[$i]:-}" ] || survivor_indexes+=("$i")
  done
  if [ "$failures" -gt 0 ] && [ "${#survivor_indexes[@]}" -gt 1 ]; then
    survivor_train=$(build_train "${survivor_indexes[@]}") || die "cannot build survivor train"
    survivor_heads=""
    for i in "${survivor_indexes[@]}"; do survivor_heads+="${survivor_heads:+,}${composed_heads[$i]}"; done
    survivor_receipt=$(mktemp)
    if "$head_checks" --repo "$top" --ref "$survivor_train" --base "$batch_base" --train-heads "$survivor_heads" >"$survivor_receipt"; then
      for i in "${survivor_indexes[@]}"; do
        gh pr comment "${composed_prs[$i]}" --repo "$repo" --body-file "$survivor_receipt" >/dev/null \
          || die "cannot attach survivor Checks to PR ${composed_prs[$i]}"
        pass_train[i]=$survivor_train; pass_heads[i]=$survivor_heads
      done
    else
      for i in "${survivor_indexes[@]}"; do unset 'pass_train[i]' 'pass_heads[i]'; done
      failures=$((failures+${#survivor_indexes[@]}))
      echo "lead-merge: survivor train is red; returning every survivor" >&2
    fi
    rm -f "$survivor_receipt"
  fi

  # Run every per-PR path and Countersign gate before the first merge mutates main.
  for i in "${!composed_prs[@]}"; do
    [ -n "${pass_train[$i]:-}" ] || continue
    LEAD_MERGE_TRAIN_HEAD=${pass_train[$i]} LEAD_MERGE_TRAIN_HEADS=${pass_heads[$i]} LEAD_MERGE_GATE_ONLY=1 \
      bash "$script" --repo "$repo" --batch --pr "${composed_prs[$i]}" --head "${composed_heads[$i]}"
  done
  merged=0
  expected_main=$batch_base
  for i in "${!composed_prs[@]}"; do
    [ -n "${pass_train[$i]:-}" ] || continue
    expected_main_tree=$(git rev-parse "$expected_main^{tree}") || die "cannot read expected batch prefix tree"
    LEAD_MERGE_TRAIN_HEAD=${pass_train[$i]} LEAD_MERGE_TRAIN_HEADS=${pass_heads[$i]} \
      LEAD_MERGE_EXPECTED_MAIN_TREE=$expected_main_tree \
      bash "$script" --repo "$repo" --batch --pr "${composed_prs[$i]}" --head "${composed_heads[$i]}"
    expected_main=$(append_train "$expected_main" "${composed_prs[$i]}" "${composed_heads[$i]}") \
      || die "cannot advance expected batch prefix"
    merged=$((merged+1))
  done
  echo "lead-merge: batch complete: merged $merged, returned $failures, conflicted $((${#ready_prs[@]}-${#composed_prs[@]}))"
  exit 0
fi

# 2. PR state
info=$(gh pr view "$pr" --repo "$repo" --json state,baseRefName,headRefName,headRefOid,mergeable,url,changedFiles,body,comments,baseRefOid) \
  || die "cannot read PR $pr"
field() { jq -r "$1" <<<"$info"; }
for mergeable_retry in 1 2 3; do
  [ "$(field .mergeable)" = UNKNOWN ] || break
  sleep 2
  info=$(gh pr view "$pr" --repo "$repo" --json state,baseRefName,headRefName,headRefOid,mergeable,url,changedFiles,body,comments,baseRefOid) \
    || die "cannot reread PR $pr while mergeability is UNKNOWN"
done
[ "$(field .state)" = OPEN ] || die "PR $pr is not open"
[ "$(field .baseRefName)" = main ] || die "PR $pr base is not main"
[ "$(field .headRefOid)" = "$head" ] || die "PR $pr head is $(field .headRefOid), not $head"
[ "$(field .mergeable)" = MERGEABLE ] || die "PR $pr is not MERGEABLE"

# 4. Head branch
case "$(field .headRefName)" in main|staging|production) die "head branch $(field .headRefName) is not mergeable here" ;; esac

# gh pr view truncates files at 100; every path gate shares this complete list.
file_pages=$(gh api --paginate "repos/$repo/pulls/$pr/files") || die "cannot read complete PR files"
files=$(jq -s '[.[][] | .filename]' <<<"$file_pages") || die "invalid PR file inventory"
[ "$(jq length <<<"$files")" = "$(field .changedFiles)" ] || die "PR file count differs from changed_files"

# 3. Owner only paths
while IFS= read -r f; do
  case "$f" in
    .claude/hooks/*|.claude/settings.json|bin/owner-approve.sh|.codex/*|*/.codex/*|*.rules)
      die "PR touches $f, which waits for the owner through Elon" ;;
  esac
done < <(jq -r '.[]' <<<"$files")
# 3b. Generated team copies change only through the dotfiles template, then merge with --verdict-from
# (a project PR hand edited a generated deploy skill and the next sync would have reverted it).
if [ -z "$verdict_from" ]; then
  tmpl_skills="$(cd "$(dirname "$0")/.." && pwd)/templates/agent-team/.agents/skills"
  while IFS= read -r f; do
    if [[ "$f" =~ ^\.(agents|claude|cursor)/skills/([^/]+)/ ]] && [ -f "$tmpl_skills/${BASH_REMATCH[2]}/SKILL.md" ]; then
      die "PR edits generated team copy $f; edit the dotfiles template, re-sync, then merge with --verdict-from"
    fi
  done < <(jq -r '.[]' <<<"$files")
fi
diff=$(gh pr diff "$pr" --repo "$repo") || die "cannot read diff of PR $pr"
if awk '/^\+\+\+ /{intent = ($2 ~ /^b\/docs\/intent\//)} intent && /^\+Status:.*Accepted/{found=1} END{exit !found}' <<<"$diff"; then
  die "PR accepts an intent under docs/intent/, which waits for the owner through Elon"
fi

# 5. Verification is required even for documentation changes.
# Normalize heading case, spacing and trailing punctuation once for both gates.
normalized_body=$(field .body | awk '
/^[[:blank:]]*#+[[:space:]]/ {
  heading=$0; sub(/^[[:blank:]]*/, "", heading)
  hashes=heading; sub(/[[:space:]].*$/, "", hashes)
  title=heading; sub(/^#+[[:space:]]+/, "", title)
  gsub(/[[:space:]]+/, " ", title)
  sub(/[[:space:][:punct:]]+$/, "", title)
  print hashes " " tolower(title); next
}
{print}')
grep -qE '^## verification$' <<<"$normalized_body" || die "missing ## Verification heading"
if grep -qiE '^#{1,6} test plan$' <<<"$normalized_body"; then die "Test plan heading is forbidden"; fi
bullet_count=$(awk '/^## verification$/ {inside=1; next} inside && /^#+ / {inside=0} inside && /^[[:space:]]*[-*+] / {n++} END {print n+0}' <<<"$normalized_body")
[ "$bullet_count" -ge 1 ] && [ "$bullet_count" -le 3 ] || die "Verification needs 1 to 3 run and outcome bullets"
train_check=""
if [ "$batch_requested" = true ]; then
  [[ "${LEAD_MERGE_TRAIN_HEAD:-}" =~ ^[0-9a-f]{40}$ ]] || die "invalid batch train head"
  [[ "${LEAD_MERGE_TRAIN_HEADS:-}" =~ ^[0-9a-f]{40}(,[0-9a-f]{40})*$ ]] || die "invalid batch train PR heads"
  grep -Eq "(^|,)$head(,|$)" <<<"${LEAD_MERGE_TRAIN_HEADS:-}" || die "batch train does not contain PR $pr head"
  git cat-file -e "$LEAD_MERGE_TRAIN_HEAD^{commit}" 2>/dev/null \
    && git merge-base --is-ancestor "$head" "$LEAD_MERGE_TRAIN_HEAD" \
    || die "batch train commit does not contain PR $pr head"
  train_check="Checks: PASS head=$LEAD_MERGE_TRAIN_HEAD train-heads=$LEAD_MERGE_TRAIN_HEADS"
fi
check_body=$(jq -r --arg head "$head" --arg train "$train_check" '[.comments[].body | select((split("\n")[0]) == ("Checks: PASS head="+$head) or (split("\n")[0]) == ("Checks: FAIL head="+$head) or ($train != "" and (split("\n")[0]) == $train))] | last // ""' <<<"$info")
checks=${check_body%%$'\n'*}
{ [ "$checks" = "Checks: PASS head=$head" ] || { [ -n "$train_check" ] && [ "$checks" = "$train_check" ]; }; } \
  || die "missing current-head or containing-train Checks: PASS"
unchecked=false
if grep -q '^Unchecked paths: .' <<<"$check_body"; then unchecked=true; fi
skip_review=false
if grep -qiE '^review: skipped \(.+\)$' <<<"$normalized_body"; then skip_review=true; fi
docs_only=true
while IFS= read -r f; do
  case "$f" in
    .claude/agents/*|*/.claude/agents/*|.agents/skills/*|*/.agents/skills/*) [ "$skip_review" = true ] || docs_only=false ;;
    docs/*|*.md|changelog.d/*) ;;
    *) docs_only=false ;;
  esac
done < <(jq -r '.[]' <<<"$files")

# Carry a Verdict across a clean merge of main: V is an ancestor of H and every commit after V on the
# first-parent chain is a two parent merge of main that replays to exactly the same tree.
# Fails closed; sets carry_why to the failed check.
carry_why=""
verdict_carry() { # <verdict head> <current head>
  local v="$1" h="$2" commits c parents p replay
  carry_why=""
  git cat-file -e "$v^{commit}" 2>/dev/null || git fetch origin "$v" >&2 || { carry_why="cannot read verdict head"; return 1; }
  git merge-base --is-ancestor "$v" "$h" || { carry_why="verdict head is not an ancestor of the PR head"; return 1; }
  # --first-parent: the commits main brought in are reachable only through the merge's second parent.
  commits=$(git rev-list --first-parent "$v..$h") || { carry_why="check a: cannot list commits after the verdict head"; return 1; }
  for c in $commits; do
    parents=$(git rev-list --parents -n1 "$c") || { carry_why="check a: cannot read parents of $c"; return 1; }
    set -- $parents
    shift
    [ $# -ge 2 ] || { carry_why="check a: ${c:0:12} is an authored commit after the verdict head, not a merge of main"; return 1; }
    [ $# -eq 2 ] || { carry_why="check a: merge ${c:0:12} has more than two parents"; return 1; }
    shift
    for p in "$@"; do
      git merge-base --is-ancestor "$p" origin/main || { carry_why="check a: merge ${c:0:12} takes a parent that is not in origin/main"; return 1; }
    done
    # Check b: replay the merge. A clean replay must give the merge's own tree, so the merge added nothing.
    replay=$(git merge-tree --write-tree "$c^1" "$c^2" 2>/dev/null) || { carry_why="check b: conflicted merge ${c:0:12} needs a new Verdict"; return 1; }
    replay=${replay%%$'\n'*}
    [ "$replay" = "$(git rev-parse "$c^{tree}")" ] || { carry_why="check b: merge ${c:0:12} differs from a clean replay"; return 1; }
  done
}
# Dispatch ids Orca knows about, read lazily and once, following page cursors.
known_dispatches=""
load_dispatches() {
  local orca="${ORCA_CLI_COMMAND:-orca}" cursor="" page run n m runs=""
  # worker-list without --run sees only the caller's bound run, so read every run.
  for n in $(seq 1 50); do
    page=$("$orca" orchestration run-list --limit 100 ${cursor:+--cursor "$cursor"} --json 2>/dev/null) \
      || die "cannot read orca run-list to verify verdict dispatch ids"
    runs+=$(jq -r '.result.runs[]?.id' <<<"$page" 2>/dev/null)$'\n' \
      || die "cannot parse orca run-list to verify verdict dispatch ids"
    cursor=$(jq -r '.result.nextCursor // empty' <<<"$page")
    [ -n "$cursor" ] && continue
    while IFS= read -r run; do
      [ -n "$run" ] || continue
      cursor=""
      for m in $(seq 1 50); do
        page=$("$orca" orchestration worker-list --run "$run" --limit 100 ${cursor:+--cursor "$cursor"} --json 2>/dev/null) \
          || die "cannot read orca worker-list to verify verdict dispatch ids"
        known_dispatches+=$(jq -r '.result.workers[]?.dispatchId // empty' <<<"$page" 2>/dev/null)$'\n' \
          || die "cannot parse orca worker-list to verify verdict dispatch ids"
        cursor=$(jq -r '.result.page.nextCursor // empty' <<<"$page")
        [ -n "$cursor" ] || break
      done
      [ -z "$cursor" ] || die "worker-list has too many pages to verify verdict dispatch ids"
    done <<<"$runs"
    return 0
  done
  die "run-list has too many pages to verify verdict dispatch ids"
}
# Generated team copies: merge on the Verdict of the matching MERGED dotfiles PR.
generated_ok=false
if [ -n "$verdict_from" ]; then
  [ "$mechanical" = false ] || die "--verdict-from and --mechanical are exclusive"
  # Copy this empty example to lead-merge.local.json beside the script and set
  # verdict_from_repos to exact owner/repo names; local overlays are gitignored.
  config_dir=$(cd "$(dirname "$0")" && pwd)
  verdict_config=$(python3 "$config_dir/apply-local-overlay.py" \
    "$config_dir/lead-merge.config.example.json" "$config_dir/lead-merge.local.json") \
    || die "--verdict-from: cannot read local repo config"
  jq -e '.verdict_from_repos | type == "array" and all(.[]; type == "string" and test("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$"))' \
    <<<"$verdict_config" >/dev/null || die "--verdict-from: invalid verdict_from_repos config"
  [ "$(jq '.verdict_from_repos | length' <<<"$verdict_config")" -gt 0 ] \
    || die "--verdict-from: no configured verdict_from_repos; set $config_dir/lead-merge.local.json"
  jq -e --arg repo "$repo" '.verdict_from_repos | index($repo) != null' \
    <<<"$verdict_config" >/dev/null || die "--verdict-from: repo is not configured in lead-merge.local.json"
  [[ "$verdict_from" =~ ^([A-Za-z0-9_.-]+/dotfiles)#([0-9]+)$ ]] || die "--verdict-from must look like owner/dotfiles#N"
  src_repo="${BASH_REMATCH[1]}"; src_pr="${BASH_REMATCH[2]}"
  [[ "$head" =~ ^[0-9a-f]{40}$ ]] || die "--verdict-from needs a full head sha"
  git cat-file -e "$head^{commit}" 2>/dev/null || git fetch origin "$head" >&2 || die "cannot read head $head"
  dotfiles_root=$(cd "$(dirname "$0")/.." && pwd)
  # An unmerged template must not vouch for its own generated copies.
  git -C "$dotfiles_root" rev-parse --verify -q origin/main >/dev/null || die "--verdict-from: cannot resolve origin/main in the dotfiles tree"
  git -C "$dotfiles_root" diff --quiet origin/main -- templates/agent-team \
    || die "--verdict-from: dotfiles tree is not at origin/main for templates/agent-team; merge and pull dotfiles first"
[ -z "$(git -C "$dotfiles_root" status --porcelain --ignored -- templates/agent-team)" ] \
  || die "--verdict-from: templates/agent-team has local changes, not at origin/main; clean or commit them first"
  skill_names=$(cd "$dotfiles_root/templates/agent-team/.agents/skills" 2>/dev/null && for d in */; do [ -f "$d/SKILL.md" ] && echo "${d%/}"; done; true) \
    || die "cannot list dotfiles team skills"
  while IFS= read -r f; do
    # Only paths sync-team-skills.sh owns count: a header string inside a file proves nothing, and
    # sync-team-skills.sh --check below byte-verifies every file in those directories.
    gen=false
    if [[ "$f" =~ ^\.(agents|claude|cursor)/skills/([^/]+)(/|$) ]] && grep -Fxq -- "${BASH_REMATCH[2]}" <<<"$skill_names"; then gen=true; fi
    if [ "$gen" = true ]; then
      # A symlink is allowed only as the skills link itself (.claude|.cursor/skills/<name>); sync --check does not list other links.
      mode=$(git ls-tree "$head" -- "$f" 2>/dev/null | awk 'NR == 1 {print $1}')
      if [ "$mode" = 120000 ] && ! [[ "$f" =~ ^\.(claude|cursor)/skills/[^/]+$ ]]; then die "--verdict-from refuses symlink $f"; fi
    fi
    [ "$gen" = true ] || die "--verdict-from needs every changed file to be a generated team copy; $f is not"
  done < <(jq -r '.[]' <<<"$files")
  sync_dir=$(mktemp -d); trap 'rm -rf "$sync_dir"' EXIT
  git archive "$head" .agents .claude .cursor 2>/dev/null | tar -x -C "$sync_dir" 2>/dev/null || true
  DOTFILES="$dotfiles_root" bash "$dotfiles_root/script/sync-team-skills.sh" --check "$sync_dir" >&2 \
    || die "sync-team-skills.sh --check fails at head $head"
  src=$(gh pr view "$src_pr" --repo "$src_repo" --json state,headRefOid,comments) || die "cannot read $verdict_from"
  [ "$(jq -r .state <<<"$src")" = MERGED ] || die "$verdict_from is not MERGED"
  src_head=$(jq -r .headRefOid <<<"$src")
  src_pass="" src_fail=false src_edited=0
  while IFS= read -r row; do
    c=$(jq -r '@base64d | fromjson | .body' <<<"\"$row\""); fl=$(jq -r '@base64d | fromjson | ((.includesCreatedEdit // false) or (.isMinimized // false))' <<<"\"$row\"")
    l=${c%%$'\n'*}
    if [[ "$l" =~ ^Verdict:\ (PASS\+NOTES|PASS|FAIL)\ head=$src_head\ verifier=([a-zA-Z0-9_-]+)\ author=([a-zA-Z0-9_-]+)$ ]]; then
      [ "${BASH_REMATCH[2]}" != "${BASH_REMATCH[3]}" ] || die "author cannot supply verifier verdict"
      [ -n "$known_dispatches" ] || load_dispatches
      grep -Fxq -- "${BASH_REMATCH[2]}" <<<"$known_dispatches" || die "verdict verifier ${BASH_REMATCH[2]} is not a known dispatch"
      [ "${BASH_REMATCH[3]}" = unknown ] || grep -Fxq -- "${BASH_REMATCH[3]}" <<<"$known_dispatches" || die "verdict author ${BASH_REMATCH[3]} is not a known dispatch"
      # An edited or minimized PASS never counts; an edited FAIL still blocks.
      if [ "$fl" = true ] && [ "${BASH_REMATCH[1]}" != FAIL ]; then src_edited=$((src_edited+1)); continue; fi
      if [ "${BASH_REMATCH[1]}" = FAIL ]; then src_fail=true; elif [ -z "$src_pass" ]; then src_pass="$c"; fi
    fi
  done < <(jq -r '.comments | reverse[] | @json | @base64' <<<"$src")
  [ -n "$src_pass" ] || die "$verdict_from has no passing Verdict for its merged head $src_head$([ "$src_edited" -eq 0 ] || echo "; $src_edited edited or minimized PASS ignored, post a fresh Verdict")"
  [ "$src_fail" = false ] || die "$verdict_from has a FAIL Verdict for its merged head"
  if [ "$verify_set" = true ]; then
    want=$(sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' <<<"$verify_command")
    got=$(grep -m1 '^Command:' <<<"$src_pass" | sed -E 's/^Command:[[:space:]]*//; s/[[:space:]]+$//' || true)
    [ -n "$want" ] && [ "$got" = "$want" ] || die "Verdict Command mismatch: verdict ran [$got], brief says [$want]"
  fi
  generated_ok=true
  echo "lead-merge: generated team copies, Verdict from $verdict_from"
fi
# Mechanical lane: no Verdict, but only for a diff that is pure substitution or deletion.
# Every hunk must remove as many lines as it adds (a whole deleted file is fine), the only
# new files are changelog fragments, and no file is renamed, copied or binary. Protected
# paths were refused above; gate files still need their Countersign below.
if [ "$mechanical" = true ]; then
  [ "$unchecked" = false ] || die "--mechanical needs every path checked (head-checks lists unchecked paths)"
  grep -qE '^(rename|copy|similarity|Binary files|GIT binary patch)' <<<"$diff" && die "--mechanical refuses renames, copies and binary changes"
  # Paths come from the ---/+++ lines (to end of line, so spaces and quoted names work), not from the diff --git line.
  bad=$(awk '
    function flush() { if (file != "" && !deleted && !created && (plus != minus)) print file ": " minus " removed, " plus " added"; plus = minus = 0 }
    function path(l) { sub(/^(\+\+\+|---) /, "", l); sub(/\t.*$/, "", l); gsub(/^"|"$/, "", l); sub(/^[ab]\//, "", l); return l }
    /^diff --git / { flush(); file = "?"; deleted = created = 0; next }
    /^new file mode/ { created = 1; next }
    /^deleted file mode/ { deleted = 1; next }
    /^--- / { if ($0 !~ /^--- \/dev\/null/) file = path($0); next }
    /^\+\+\+ / { if ($0 !~ /^\+\+\+ \/dev\/null/) file = path($0); if (created && file !~ /^changelog\.d\//) print file ": new file"; next }
    /^\+/ { plus++ } /^-/ { minus++ }
    END { flush() }' <<<"$diff")
  [ -z "$bad" ] || die "--mechanical needs a pure substitution or deletion diff: $bad"
  echo "lead-merge: mechanical lane, Verdict not required"
fi
if [ "$mechanical" = false ] && [ "$generated_ok" = false ] && { [ "$docs_only" = false ] || [ "$unchecked" = true ]; }; then
  applicable=()
  passes=0 fails=0 edited=0 misplaced=0 main_fetched=false carry_notes=""
  # Every Verdict for this head (or carried across clean merges of main) counts. Newest first; none
  # of them can erase another. An edited or minimized PASS never counts (the
  # verifier posts a fresh one); an edited or minimized FAIL still blocks.
  while IFS= read -r row; do
    comment=$(jq -r '@base64d | fromjson | .body' <<<"\"$row\"")
    flagged=$(jq -r '@base64d | fromjson | ((.includesCreatedEdit // false) or (.isMinimized // false))' <<<"\"$row\"")
    line=${comment%%$'\n'*}
    [[ "$line" == Verdict:* ]] || ! grep -q '^Verdict: ' <<<"$comment" || misplaced=$((misplaced+1))
    if [[ "$line" =~ ^Verdict:\ (PASS\+NOTES|PASS|FAIL)\ head=([0-9a-f]{40})\ verifier=([a-zA-Z0-9_-]+)\ author=([a-zA-Z0-9_-]+)$ ]]; then
      verdict="${BASH_REMATCH[1]}"; candidate_head="${BASH_REMATCH[2]}"
      verifier_id="${BASH_REMATCH[3]}"; author_id="${BASH_REMATCH[4]}"
      [ "${BASH_REMATCH[3]}" != "${BASH_REMATCH[4]}" ] || die "author cannot supply verifier verdict"
      applies=false carried=""
      if [ "$candidate_head" = "$head" ]; then
        applies=true
      else
        [ "$main_fetched" = true ] || { git fetch origin main >&2 || die "cannot fetch main to carry a verdict"; main_fetched=true; }
        if verdict_carry "$candidate_head" "$head"; then
          applies=true; carried="$candidate_head"
        else
          carry_notes+="${candidate_head:0:12}: $carry_why; "
        fi
      fi
      if [ "$applies" = true ]; then
        [ -n "$known_dispatches" ] || load_dispatches
        grep -Fxq -- "$verifier_id" <<<"$known_dispatches" || die "verdict verifier $verifier_id is not a known dispatch"
        # author=unknown is the one literal allowed without a dispatch; any other author must be known.
        [ "$author_id" = unknown ] || grep -Fxq -- "$author_id" <<<"$known_dispatches" || die "verdict author $author_id is not a known dispatch"
        if [ "$flagged" = true ] && [ "$verdict" != FAIL ]; then edited=$((edited+1)); continue; fi
        [ -z "$carried" ] || echo "lead-merge: verdict carried from ${carried:0:12} to ${head:0:12} (merge of main only, clean replay)"
        applicable+=("$verdict"$'\n'"$comment")
        if [ "$verdict" = FAIL ]; then fails=$((fails+1)); else passes=$((passes+1)); fi
      fi
    fi
  done < <(jq -r '.comments | reverse[] | @json | @base64' <<<"$info")
  if [ "$passes" -eq 0 ]; then
    [ "$edited" -eq 0 ] || die "missing passing verifier verdict: $edited edited or minimized PASS ignored; post a fresh Verdict"
    [ "$misplaced" -eq 0 ] || die "missing passing verifier verdict: a Verdict line is not the first line of its comment; post a fresh comment that starts with it"
    die "missing passing verifier verdict for current head or clean merge of main${carry_notes:+; not carried: ${carry_notes%; }}"
  fi
  [ "$fails" -eq 0 ] || die "conflicting PASS and FAIL verdicts for current head or clean merge of main"
  if [ "$verify_set" = true ]; then
    want=$(sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' <<<"$verify_command")
    [ -n "$want" ] || die "--verify-command is empty"
    newest=${applicable[0]#*$'\n'}
    got=$(grep -m1 '^Command:' <<<"$newest" | sed -E 's/^Command:[[:space:]]*//; s/[[:space:]]+$//' || true)
    [ -n "$got" ] || die "newest Verdict has no Command: line; expected: $want"
    [ "$got" = "$want" ] || die "Verdict Command mismatch: verdict ran [$got], brief says [$want]"
  fi
  for entry in "${applicable[@]}"; do
    comment=${entry#*$'\n'}
    if [ "$unchecked" = true ] && ! grep -qi 'unchecked' <<<"$comment"; then
      die "verdict must cover unchecked paths in its live lane"
    fi
  done
fi

# Gate changes need a fresh, head-bound countersign from Elon.
triggers=$(awk '/^\+[^+]/ && /\.skip\(|\.only\(|test\.todo([^A-Za-z0-9_]|$)|(^|[^A-Za-z0-9_.])xit\(|eslint-disable|biome-ignore|@ts-ignore|@ts-expect-error/ {print}' <<<"$diff")
while IFS= read -r f; do
  case "$f" in
    .agents/head-checks.conf|*/.agents/head-checks.conf|script/lead-merge.sh|*/script/lead-merge.sh)
      gate_lines=$(awk -v path="$f" '/^\+\+\+ / {active=($0 == "+++ b/" path)} active && /^[+-]/ && !/^\+\+\+ / && !/^--- / {print path ":" $0}' <<<"$diff")
      triggers="${triggers}${triggers:+$'\n'}${gate_lines:-gate definition changed: $f}" ;;
  esac
done < <(jq -r '.[]' <<<"$files")
if [ -n "$triggers" ]; then
  echo "lead-merge: countersign triggers:" >&2
  printf '%s\n' "$triggers" >&2
  # Checks: PASS for the current head is already required above. Like a retained
  # Verdict, a Countersign for an older head carries only across clean merges of main.
  countersigned() { # head
    jq -e --arg prefix "Countersign: Elon head=$1 reason=" \
      'any(.comments[].body; startswith($prefix) and (.[($prefix|length):] | test("[^[:space:]]")))' <<<"$info" >/dev/null
  }
  if ! countersigned "$head"; then
    countersign_ok=false
    while IFS= read -r candidate_head; do
      [ "$candidate_head" != "$head" ] || continue
      [ "${main_fetched:-false}" = true ] || { git fetch origin main >&2 || die "cannot fetch main to carry a countersign"; main_fetched=true; }
      if countersigned "$candidate_head" && verdict_carry "$candidate_head" "$head"; then countersign_ok=true; break; fi
    done < <(jq -r '.comments[].body | split("\n")[0] | capture("^Countersign: Elon head=(?<h>[0-9a-f]{40}) reason=").h?' <<<"$info" | awk '!seen[$0]++')
    [ "$countersign_ok" = true ] || die "missing Countersign: Elon for current head or clean merge of main"
  fi
fi

[ "${LEAD_MERGE_GATE_ONLY:-0}" != 1 ] || exit 0

# Fetch immediately before merge; any shared changed path needs a new exact-head run.
git fetch origin main >&2 || die "cannot fetch main; rebase and rerun head-checks"
if [ -n "$train_check" ]; then
  [[ "${LEAD_MERGE_EXPECTED_MAIN_TREE:-}" =~ ^[0-9a-f]{40}$ ]] || die "batch item has no valid expected main tree"
  current_main_tree=$(git rev-parse --verify 'origin/main^{tree}') || die "cannot read current main tree"
  [ "$current_main_tree" = "$LEAD_MERGE_EXPECTED_MAIN_TREE" ] \
    || die "main changed since batch train checks; stop the batch and rebuild it"
else
  # A carried Verdict is judged against the current head, which includes the merged main commits.
  ancestor=$(git merge-base "$(field .baseRefOid)" "$head") || die "cannot find merge base; rebase and rerun head-checks"
  trunk_files=$(git diff --name-only "$ancestor" origin/main --) || die "cannot inspect trunk drift"
  while IFS= read -r f; do
    if grep -Fxq -- "$f" <<<"$trunk_files"; then die "trunk changed $f; rebase and rerun head-checks"; fi
  done < <(jq -r '.[]' <<<"$files")
fi

merge() { gh pr merge "$pr" --repo "$repo" --merge --match-head-commit "$head"; }
if ! out=$(merge 2>&1); then
  out=$(merge 2>&1) || { echo "lead-merge: merge failed: $out" >&2; exit 1; }
fi

final=$(gh pr view "$pr" --repo "$repo" --json state,mergeCommit,url) || { echo "lead-merge: cannot confirm merge of PR $pr" >&2; exit 1; }
[ "$(jq -r .state <<<"$final")" = MERGED ] || { echo "lead-merge: PR $pr is not MERGED after merge" >&2; exit 1; }
merge_sha=$(jq -r '.mergeCommit.oid // empty' <<<"$final")
[ -n "$merge_sha" ] || die "MERGED read-back has no merge commit"
echo "MERGED $(jq -r .url <<<"$final") $merge_sha"

# Cleanup after the merge: head branch, ticket lanes, old recovery branches. Never fails the merge.
# Issue N: "Closes #N" in the PR body, else the last run of 3+ digits in the branch name. DRY_RUN=1 previews.
head_branch=$(field .headRefName)
issue=$(field .body | sed -nE 's/.*[Cc]loses[[:space:]]+#([0-9]+).*/\1/p' | head -n1)
[ -n "$issue" ] || issue=$(issue_from_branch "$head_branch")
retarget_ok=true
stacked=$(gh pr list --repo "$repo" --state open --base "$head_branch" --limit 1000 --json number) || retarget_ok=false
if [ "$retarget_ok" = true ]; then
  [ -n "$stacked" ] || stacked='[]'
  while IFS= read -r stacked_pr; do
    [ -n "$stacked_pr" ] || continue
    if [ "${DRY_RUN:-0}" = 1 ]; then
      echo "[dry-run] retarget PR #$stacked_pr from $head_branch to main"
    else
      gh pr edit "$stacked_pr" --repo "$repo" --base main >/dev/null || { retarget_ok=false; break; }
    fi
  done < <(jq -r '.[].number' <<<"$stacked")
fi
if [ "$retarget_ok" = true ]; then
  cleanup=${LEAD_MERGE_CLEANUP:-$(dirname "$0")/merge-cleanup.sh}
  bash "$cleanup" --branch "$head_branch" ${issue:+--issue "$issue"} ${pr:+--pr "$pr"} \
    || echo "lead-merge: cleanup incomplete (merge succeeded); run script/wrap-up.sh" >&2
else
  echo "lead-merge: cleanup skipped (merge succeeded); could not retarget every PR based on $head_branch" >&2
fi
