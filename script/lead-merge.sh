#!/usr/bin/env bash
# The Tech Lead's only way to merge a reviewed PR.
# Usage: lead-merge.sh --repo owner/name --pr N --head <sha> [--mechanical]
#        lead-merge.sh --repo owner/name --batch N N [N ...] [--dry-run]
# Every refusal that needs no head-checks is collected and printed in one run (preflight); a batch drops the
# PRs preflight refuses and merges the rest.
# --mechanical: mechanical lane (pure text substitution or deletion); replaces the Verdict, nothing else.
# --verdict-from <owner/dotfiles#N>: a configured repo PR whose changed files are all generated team copies
#   (inside a skill dir that sync-team-skills.sh owns), with sync-team-skills.sh
#   --check passing at the head, merges on the newest PASS Verdict of that MERGED dotfiles PR instead of its own.
# One merge run per repo: a lead-merge.lock/ directory in the git common dir (pid and start time) is held from
#   the start of the run to the last merge and released before cleanup. A second run waits up to
#   LEAD_MERGE_LOCK_WAIT_SECONDS (default 1200), printing the holder, then refuses. A lock whose pid is gone is stale.
# A Verdict and the Checks: PASS comment also carry across a clean merge of main (see verdict_carry).
# --verify-command "<cmd>": the brief's test command; when a Verdict is relied on, its newest comment
#   must carry a `Command:` line equal to it (trimmed, exact match). Without the flag nothing changes.
set -euo pipefail

# Policy refusals are collected, not fatal, so one run reports every one (see refuse / flush_refusals).
refusals=()
refuse() { refusals+=("$*"); }
print_refusals() { local r; for r in ${refusals[@]+"${refusals[@]}"}; do echo "lead-merge: refused: $r" >&2; done; }
flush_refusals() { [ "${#refusals[@]}" -eq 0 ] || { print_refusals; exit 1; }; }
# A fatal error still reports the refusals collected before it.
die() { print_refusals; echo "lead-merge: refused: $*" >&2; exit 1; }

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
    --dry-run) DRY_RUN=1; shift ;;
    --verdict-from) [ $# -ge 2 ] || die "--verdict-from needs owner/repo#N"; verdict_from="${2:-}"; shift 2 ;;
    --verify-command) [ $# -ge 2 ] || die "--verify-command needs a value"; verify_command="${2:-}"; verify_set=true; shift 2 ;;
    *) die "unknown argument $1" ;;
  esac
done
[ -n "$repo" ] || die "usage: lead-merge.sh --repo owner/name (--pr N --head SHA | --batch N N [N ...])"
if [ "${#batch_prs[@]}" -gt 0 ]; then
  [ -z "$pr$head$verdict_from" ] && [ "$verify_set" = false ] && [ "$mechanical" = false ] \
    || die "--batch cannot be combined with single-PR options"
  duplicate_pr=$(printf '%s\n' "${batch_prs[@]}" | sort | uniq -d | head -n1)
  [ -z "$duplicate_pr" ] || die "--batch repeats PR $duplicate_pr"
  if [ "${#batch_prs[@]}" -eq 1 ]; then
    # One PR is a plain single merge: same gates, same receipt.
    pr=${batch_prs[0]}; batch_requested=false; batch_prs=()
    head_info=$(gh pr view "$pr" --repo "$repo" --json headRefOid) || die "cannot read PR $pr"
    head=$(jq -r .headRefOid <<<"$head_info")
  fi
fi
if [ "${#batch_prs[@]}" -eq 0 ]; then
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

# One merge run per repo. Children of a batch inherit LEAD_MERGE_LOCK_HELD and never take the lock themselves.
lock_dir="" lock_owned=false
lock_release() {
  if [ "$lock_owned" = true ] && [ "$(cat "$lock_dir/pid" 2>/dev/null)" = "$$" ]; then rm -rf "$lock_dir"; fi
  lock_owned=false
}
lock_acquire() {
  [ "${LEAD_MERGE_LOCK_HELD:-0}" != 1 ] || return 0
  local common wait waited=0 holder started noted=false
  common=$(git rev-parse --git-common-dir 2>/dev/null) && common=$(cd -P "$common" 2>/dev/null && pwd) \
    || { echo "lead-merge: no git common dir; running without the merge lock" >&2; return 0; }
  lock_dir="$common/lead-merge.lock"
  wait=${LEAD_MERGE_LOCK_WAIT_SECONDS:-1200}
  [[ "$wait" =~ ^[0-9]+$ ]] || die "LEAD_MERGE_LOCK_WAIT_SECONDS must be a number"
  trap 'lock_release' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  while ! mkdir "$lock_dir" 2>/dev/null; do
    holder=$(cat "$lock_dir/pid" 2>/dev/null || true)
    if [ "$holder" = "$$" ]; then lock_owned=true; return 0; fi # handed over through exec
    if [ -n "$holder" ] && ! kill -0 "$holder" 2>/dev/null; then
      # One waiter at a time clears a stale lock, and only after reading the dead pid again under that guard:
      # a waiter that read the pid before another takeover finished would otherwise delete the new live lock.
      if mkdir "$lock_dir.takeover" 2>/dev/null; then
        if [ "$(cat "$lock_dir/pid" 2>/dev/null || true)" = "$holder" ]; then
          echo "lead-merge: taking over stale merge lock of pid $holder" >&2
          rm -rf "$lock_dir"
        fi
        rmdir "$lock_dir.takeover"
        continue
      fi
      # A guard left by a run killed mid-takeover is cleared after a minute.
      [ -z "$(find "$lock_dir.takeover" -maxdepth 0 -mmin +1 2>/dev/null)" ] || rmdir "$lock_dir.takeover" 2>/dev/null || true
    fi
    started=$(cat "$lock_dir/started" 2>/dev/null || true)
    if [ "$noted" = false ]; then
      echo "lead-merge: waiting for the merge lock held by pid ${holder:-unknown}${started:+ since $(date -r "$started" '+%F %T' 2>/dev/null || echo "$started")}" >&2
      noted=true
    fi
    if [ "$waited" -ge "$wait" ]; then
      die "merge lock held by pid ${holder:-unknown}${started:+ since $started}; waited ${waited}s (LEAD_MERGE_LOCK_WAIT_SECONDS=$wait)"
    fi
    sleep 1; waited=$((waited+1))
  done
  lock_owned=true
  echo "$$" > "$lock_dir/pid"; date +%s > "$lock_dir/started"
}
lock_acquire
export LEAD_MERGE_LOCK_HELD=1

if [ "${#batch_prs[@]}" -gt 0 ]; then
  script=$(cd "$(dirname "$0")" && pwd)/$(basename "$0")
  head_checks=${LEAD_MERGE_HEAD_CHECKS:-$(dirname "$script")/head-checks.sh}
  dry=${DRY_RUN:-0}
  git fetch origin main >&2 || die "cannot fetch main for batch"
  batch_base=$(git rev-parse --verify 'origin/main^{commit}') || die "cannot resolve origin/main"
  ready_prs=() ready_heads=() refused_prs=()
  # A head-checks receipt is posted as a comment on every PR of its train; GitHub rejects a body over 65536 characters.
  receipt_limit=65536 receipt_cap=${HEAD_CHECKS_RECEIPT_CAP:-20000}
  [[ "$receipt_cap" =~ ^[0-9]+$ ]] && [ "$receipt_cap" -le "$receipt_limit" ] \
    || die "head-checks receipt cap $receipt_cap does not fit a $receipt_limit character comment"
  echo "lead-merge: train receipt is at most $receipt_cap characters per comment (GitHub limit $receipt_limit)" >&2
  [ "$dry" != 1 ] || echo "[dry-run] receipt cap $receipt_cap characters (GitHub limit $receipt_limit)"

  # One inventory read for the whole run, and only if a PR needs a Verdict: the first child that does
  # fills this file, later children read it.
  dispatches_file=$(mktemp); trap 'rm -f "$dispatches_file"; lock_release' EXIT
  export LEAD_MERGE_DISPATCHES_FILE=$dispatches_file LEAD_MERGE_BATCH_CHILD=1

  for batch_pr in "${batch_prs[@]}"; do
    batch_info=$(gh pr view "$batch_pr" --repo "$repo" --json headRefOid) || die "cannot read PR $batch_pr"
    batch_head=$(jq -r .headRefOid <<<"$batch_info")
    [[ "$batch_head" =~ ^[0-9a-f]{40}$ ]] || die "PR $batch_pr has an invalid head"
    git cat-file -e "$batch_head^{commit}" 2>/dev/null || git fetch origin "$batch_head" >&2 || die "cannot fetch PR $batch_pr head"
    # Preflight: every refusal that needs no head-checks, before this PR can join a train.
    if batch_why=$(LEAD_MERGE_PREFLIGHT_ONLY=1 bash "$script" --repo "$repo" --pr "$batch_pr" --head "$batch_head" 2>&1); then
      ready_prs+=("$batch_pr"); ready_heads+=("$batch_head")
    else
      refused_prs+=("$batch_pr")
      echo "lead-merge: preflight dropped PR #$batch_pr; its refusals:" >&2
      if grep -q '^lead-merge: refused: ' <<<"$batch_why"; then
        grep '^lead-merge: refused: ' <<<"$batch_why" | sed 's/^lead-merge: refused: /  - /' >&2
      else printf '%s\n' "$batch_why" >&2; fi
    fi
  done
  [ "${#ready_prs[@]}" -gt 0 ] || die "no PR passed batch preflight"

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
    # exec skips the exit trap: drop the inventory file and let the single path read live.
    rm -f "$dispatches_file"; unset LEAD_MERGE_DISPATCHES_FILE LEAD_MERGE_BATCH_CHILD
    # exec keeps this pid, so the single run takes the lock over without a gap.
    unset LEAD_MERGE_LOCK_HELD
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
  # Post a train receipt as a comment, after proving it fits.
  post_receipt() { # <pr> <file> <label>
    local size
    size=$(wc -c < "$2" | tr -d ' ')
    [ "$size" -le "$receipt_limit" ] || die "$3 Checks receipt is $size characters, over the $receipt_limit character comment limit"
    gh pr comment "$1" --repo "$repo" --body-file "$2" >/dev/null || die "cannot attach $3 Checks to PR $1"
  }
  # A red receipt is not posted, so show the failing step and the full log path here.
  show_red() { # <file> <label>
    echo "lead-merge: $1 train checks failed; failing step:" >&2
    awk '/^Command: /{n=0} {buf[n++]=$0} /^Result: exit [1-9]/{s=n>16?n-16:0; for(i=s;i<n;i++) print "  " buf[i]; done=1; exit}
         END{if(!done) for(i=(n>16?n-16:0);i<n;i++) print "  " buf[i]}' "$2" >&2
    grep '^Receipt cut.*Full log: ' "$2" | sed 's/^/  /' >&2 || true
  }
  check_group() { # recursively bisect red trains
    local ids=("$@") group_train group_heads group_prs receipt_file mid failures_before
    group_train=$(build_train "${ids[@]}") || die "cannot build bisect train"
    group_heads=""
    for i in "${ids[@]}"; do group_heads+="${group_heads:+,}${composed_heads[$i]}"; done
    receipt_file=$(mktemp)
    if "$head_checks" --repo "$top" --ref "$group_train" --base "$batch_base" --train-heads "$group_heads" >"$receipt_file"; then
      for i in "${ids[@]}"; do
        post_receipt "${composed_prs[$i]}" "$receipt_file" train
        pass_train[i]=$group_train; pass_heads[i]=$group_heads
      done
      rm -f "$receipt_file"
      return 0
    fi
    group_prs=""
    for i in "${ids[@]}"; do group_prs+="${group_prs:+,}#${composed_prs[$i]}"; done
    show_red "PRs $group_prs" "$receipt_file"
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
        post_receipt "${composed_prs[$i]}" "$survivor_receipt" survivor
        pass_train[i]=$survivor_train; pass_heads[i]=$survivor_heads
      done
    else
      for i in "${survivor_indexes[@]}"; do unset 'pass_train[i]' 'pass_heads[i]'; done
      failures=$((failures+${#survivor_indexes[@]}))
      show_red "survivor" "$survivor_receipt"
      echo "lead-merge: survivor train is red; returning every survivor" >&2
    fi
    rm -f "$survivor_receipt"
  fi

  # An outside push during the run leaves the train checks proving an old base: merge nothing.
  git fetch origin main >&2 || die "cannot fetch main after train checks"
  now_main=$(git rev-parse --verify 'origin/main^{commit}') || die "cannot resolve origin/main after train checks"
  [ "$now_main" = "$batch_base" ] || die "main moved from ${batch_base:0:12} to ${now_main:0:12} during the run; merged nothing, rebuild the batch"
  # Run every per-PR path and Countersign gate before the first merge mutates main. Preflight already
  # passed, so a refusal here is rare. It drops its own PR and every later train-mate, whose checks
  # included the dropped commits, so main only receives a tested prefix of the train.
  gate_dropped=""
  for i in "${!composed_prs[@]}"; do
    [ -n "${pass_train[$i]:-}" ] || continue
    if [ -n "$gate_dropped" ]; then
      echo "lead-merge: dropped PR #${composed_prs[$i]}: its train checks are untested without PR #$gate_dropped" >&2
      unset 'pass_train[i]' 'pass_heads[i]'; refused_prs+=("${composed_prs[$i]}")
      continue
    fi
    if ! LEAD_MERGE_PREFLIGHT_ONLY=0 LEAD_MERGE_TRAIN_HEAD=${pass_train[$i]} LEAD_MERGE_TRAIN_HEADS=${pass_heads[$i]} LEAD_MERGE_GATE_ONLY=1 \
        bash "$script" --repo "$repo" --batch --pr "${composed_prs[$i]}" --head "${composed_heads[$i]}"; then
      echo "lead-merge: gate dropped PR #${composed_prs[$i]} after train checks" >&2
      unset 'pass_train[i]' 'pass_heads[i]'; refused_prs+=("${composed_prs[$i]}"); gate_dropped=${composed_prs[$i]}
    fi
  done
  merged=0
  expected_main=$batch_base
  cleanup_file=$(mktemp)
  batch_cleanup() {
    rm -f "$dispatches_file"
    lock_release
    [ -s "$cleanup_file" ] || { rm -f "$cleanup_file"; return 0; }
    local args=() b s
    while read -r b s; do args+=(--branch "$b" --head-sha "$s"); done < "$cleanup_file"
    rm -f "$cleanup_file"
    echo "cleanup: starting after the last merge"
    bash "${LEAD_MERGE_CLEANUP:-$(dirname "$0")/merge-cleanup.sh}" "${args[@]}" \
      || echo "cleanup: incomplete (merges succeeded); run script/wrap-up.sh" >&2
    return 0
  }
  trap batch_cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  for i in "${!composed_prs[@]}"; do
    [ -n "${pass_train[$i]:-}" ] || continue
    expected_main_tree=$(git rev-parse "$expected_main^{tree}") || die "cannot read expected batch prefix tree"
    LEAD_MERGE_PREFLIGHT_ONLY=0 LEAD_MERGE_TRAIN_HEAD=${pass_train[$i]} LEAD_MERGE_TRAIN_HEADS=${pass_heads[$i]} \
      LEAD_MERGE_EXPECTED_MAIN_TREE=$expected_main_tree LEAD_MERGE_CLEANUP_FILE=$cleanup_file \
      bash "$script" --repo "$repo" --batch --pr "${composed_prs[$i]}" --head "${composed_heads[$i]}"
    expected_main=$(append_train "$expected_main" "${composed_prs[$i]}" "${composed_heads[$i]}") \
      || die "cannot advance expected batch prefix"
    merged=$((merged+1))
  done
  echo "lead-merge: batch complete: merged $merged, returned $failures, conflicted $((${#ready_prs[@]}-${#composed_prs[@]})), refused ${#refused_prs[@]}"
  exit 0
fi

# 2. PR state
info=$(gh pr view "$pr" --repo "$repo" --json state,baseRefName,headRefName,headRefOid,mergeable,url,changedFiles,body,comments,baseRefOid,closingIssuesReferences) \
  || die "cannot read PR $pr"
field() { jq -r "$1" <<<"$info"; }
for mergeable_retry in 1 2 3; do
  [ "$(field .mergeable)" = UNKNOWN ] || break
  sleep 2
  info=$(gh pr view "$pr" --repo "$repo" --json state,baseRefName,headRefName,headRefOid,mergeable,url,changedFiles,body,comments,baseRefOid,closingIssuesReferences) \
    || die "cannot reread PR $pr while mergeability is UNKNOWN"
done
preflight_only=${LEAD_MERGE_PREFLIGHT_ONLY:-0}
[ "$(field .state)" = OPEN ] || refuse "PR $pr is not open"
[ "$(field .baseRefName)" = main ] || refuse "PR $pr base is not main"
[ "$(field .headRefOid)" = "$head" ] || refuse "PR $pr head is $(field .headRefOid), not $head"
[ "$(field .mergeable)" = MERGEABLE ] || refuse "PR $pr is not MERGEABLE"

# 4. Head branch
case "$(field .headRefName)" in main|staging|production) refuse "head branch $(field .headRefName) is not mergeable here" ;; esac

# gh pr view truncates files at 100; every path gate shares this complete list.
file_pages=$(gh api --paginate "repos/$repo/pulls/$pr/files") || die "cannot read complete PR files"
files=$(jq -s '[.[][] | .filename]' <<<"$file_pages") || die "invalid PR file inventory"
# A removed file is not a UI change; a file with no status still counts.
live_files=$(jq -s '[.[][] | select(.status != "removed") | .filename]' <<<"$file_pages") || die "invalid PR file inventory"
[ "$(jq length <<<"$files")" = "$(field .changedFiles)" ] || die "PR file count differs from changed_files"

# 3. Owner only paths
while IFS= read -r f; do
  case "$f" in
    .claude/hooks/*|.claude/settings.json|bin/owner-approve.sh|.codex/*|*/.codex/*|*.rules)
      refuse "PR touches $f, which waits for the owner through Elon" ;;
  esac
done < <(jq -r '.[]' <<<"$files")
# 3b. Generated team copies change only through the dotfiles template, then merge with --verdict-from
# (a project PR hand edited a generated deploy skill and the next sync would have reverted it).
if [ -z "$verdict_from" ]; then
  tmpl_skills="$(cd "$(dirname "$0")/.." && pwd)/templates/agent-team/.agents/skills"
  while IFS= read -r f; do
    if [[ "$f" =~ ^\.(agents|claude|cursor)/skills/([^/]+)/ ]] && [ -f "$tmpl_skills/${BASH_REMATCH[2]}/SKILL.md" ]; then
      refuse "PR edits generated team copy $f; edit the dotfiles template, re-sync, then merge with --verdict-from"
    fi
  done < <(jq -r '.[]' <<<"$files")
fi
diff=$(gh pr diff "$pr" --repo "$repo") || die "cannot read diff of PR $pr"
if awk '/^\+\+\+ /{intent = ($2 ~ /^b\/docs\/intent\//)} intent && /^\+Status:.*Accepted/{found=1} END{exit !found}' <<<"$diff"; then
  refuse "PR accepts an intent under docs/intent/, which waits for the owner through Elon"
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
if grep -qE '^## verification$' <<<"$normalized_body"; then
  bullet_count=$(awk '/^## verification$/ {inside=1; next} inside && /^#+ / {inside=0} inside && /^[[:space:]]*[-*+] / {n++} END {print n+0}' <<<"$normalized_body")
  { [ "$bullet_count" -ge 1 ] && [ "$bullet_count" -le 3 ]; } || refuse "Verification needs 1 to 3 run and outcome bullets"
else refuse "missing ## Verification heading"; fi
if grep -qiE '^#{1,6} test plan$' <<<"$normalized_body"; then refuse "Test plan heading is forbidden"; fi
# UI changes need a phone screenshot: ui_path_patterns (path prefixes) come from lead-merge.local.json.
ui_dir=$(cd "$(dirname "$0")" && pwd)
ui_cfg=$(python3 "$ui_dir/apply-local-overlay.py" "$ui_dir/lead-merge.config.example.json" "$ui_dir/lead-merge.local.json") \
  || die "cannot read local UI path config"
ui_patterns=$(jq -r '.ui_path_patterns // [] | if type == "array" and all(.[]; type == "string") then .[] else error("ui_path_patterns") end' <<<"$ui_cfg") \
  || die "invalid ui_path_patterns config"
if [ -n "$ui_patterns" ]; then
  ui_touched=false
  while IFS= read -r f; do
    case "$f" in *.test.*|*.spec.*|*/__tests__/*|*.json|*/i18n/locales/*|*/api/*|*.server.ts) continue ;; esac
    while IFS= read -r prefix; do
      [ -n "$prefix" ] && [ "${f#"$prefix"}" != "$f" ] && ui_touched=true
    done <<<"$ui_patterns"
  done < <(jq -r '.[]' <<<"$live_files")
  if [ "$ui_touched" = true ]; then
    awk '/^## screenshots$/ {inside=1; next} inside && /^##? / {inside=0} inside' <<<"$normalized_body" \
      | grep -qE '!\[[^]]*\]\([^)]+\)|user-attachments' \
      || refuse "UI change needs a ## Screenshots section with a phone image"
  fi
fi
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
# The same rule for the Checks comment: a "Checks: PASS head=<V>" comment counts for head H when
# verdict_carry V H holds. Prints the newest such comment body; fails closed.
checks_carry() { # <pr json with .comments> <current head>; the caller has fetched main
  local info="$1" h="$2" row body v x fails
  fails=$(jq -r '.comments[].body | split("\n")[0] | capture("^Checks: FAIL head=(?<x>[0-9a-f]{40})$").x' <<<"$info" 2>/dev/null || true)
  while IFS= read -r row; do
    body=$(printf '%s' "$row" | base64 -d)
    v=${body%%$'\n'*}
    [[ "$v" =~ ^Checks:\ PASS\ head=([0-9a-f]{40})$ ]] || continue
    v=${BASH_REMATCH[1]}
    [ "$v" != "$h" ] || continue
    # A Checks FAIL on V or on any later head of this chain outvotes the PASS.
    for x in $fails; do
      if git cat-file -e "$x^{commit}" 2>/dev/null && git merge-base --is-ancestor "$v" "$x"; then
        echo "lead-merge: Checks FAIL at ${x:0:12} blocks the carry from ${v:0:12}" >&2; return 1
      fi
    done
    if verdict_carry "$v" "$h"; then printf '%s\n' "$body"; return 0; fi
    echo "lead-merge: Checks not carried from ${v:0:12}: $carry_why" >&2
  done < <(jq -r '[.comments[].body] | reverse | .[] | @base64' <<<"$info" 2>/dev/null | head -50)
  return 1
}
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
check_body="" checks=""
# A preflight-only run (batch) has no Checks yet: the train receipt is the proof, and it is verified after head-checks.
if [ "$preflight_only" != 1 ]; then
  check_body=$(jq -r --arg head "$head" --arg train "$train_check" '[.comments[].body | select((split("\n")[0]) == ("Checks: PASS head="+$head) or (split("\n")[0]) == ("Checks: FAIL head="+$head) or ($train != "" and (split("\n")[0]) == $train))] | last // ""' <<<"$info")
  checks=${check_body%%$'\n'*}
  if [ "$checks" = "Checks: PASS head=$head" ] || { [ -n "$train_check" ] && [ "$checks" = "$train_check" ]; }; then :
  elif [ "$checks" = "Checks: FAIL head=$head" ]; then
    # Never carry past a run that happened.
    refuse "Checks: FAIL at the current head"
  elif [ "$batch_requested" = true ]; then
    # Never carry in a batch (the train Checks is the proof there).
    refuse "missing current-head or containing-train Checks: PASS"
  else
    [ "${main_fetched:-false}" = true ] || { git fetch origin main >&2 || die "cannot fetch main to carry Checks"; main_fetched=true; }
    if check_body=$(checks_carry "$info" "$head"); then
      checks="Checks: PASS head=$head"
      echo "lead-merge: Checks carried to ${head:0:12} (merge of main only, clean replay)"
    else refuse "missing current-head or containing-train Checks: PASS"; fi
  fi
fi
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

# Coordinator ids allowed as a Verdict author (not a dispatch): coordinator_ids in lead-merge.local.json, read lazily.
coordinator_ids="" coordinators_loaded=false
is_coordinator() { # <id>
  if [ "$coordinators_loaded" = false ]; then
    local dir cfg
    dir=$(cd "$(dirname "$0")" && pwd)
    cfg=$(python3 "$dir/apply-local-overlay.py" "$dir/lead-merge.config.example.json" "$dir/lead-merge.local.json") \
      || die "cannot read local coordinator config"
    coordinator_ids=$(jq -r '.coordinator_ids // [] | if type == "array" and all(.[]; type == "string") then .[] else error("coordinator_ids") end' <<<"$cfg") \
      || die "invalid coordinator_ids config"
    coordinators_loaded=true
  fi
  grep -Fxq -- "$1" <<<"$coordinator_ids"
}

# Dispatch ids Orca knows about, read once per invocation, following page cursors. A batch parent
# creates LEAD_MERGE_DISPATCHES_FILE empty; the first child that needs the list fills it and the
# rest read it. Only batch children use the file, so a stray export never feeds a plain run. A missing
# or unreadable file falls back to one live read.
known_dispatches=""
load_dispatches() {
  local orca="${ORCA_CLI_COMMAND:-orca}" cursor="" page run n m runs="" cache="" tmp_cache
  [ "${LEAD_MERGE_BATCH_CHILD:-0}" != 1 ] || cache=${LEAD_MERGE_DISPATCHES_FILE:-}
  if [ -n "$cache" ] && [ -r "$cache" ]; then
    known_dispatches=$(cat "$cache") || known_dispatches=""
    [ -z "$known_dispatches" ] || return 0
  fi
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
    # Temp file then mv, so a child killed mid-write never leaves a cut-off last id.
    if [ -n "$cache" ] && [ -w "$cache" ] && tmp_cache=$(mktemp "$cache.XXXXXX" 2>/dev/null); then
      { printf '%s\n' "$known_dispatches" > "$tmp_cache" && mv "$tmp_cache" "$cache"; } 2>/dev/null || rm -f "$tmp_cache"
    fi
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
  sync_dir=$(mktemp -d); trap 'rm -rf "$sync_dir"; lock_release' EXIT
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
  passes=0 fails=0 edited=0 misplaced=0 main_fetched=${main_fetched:-false} carry_notes=""
  ignored_notes=() row_n=0 retired_seen=false newest_seen=false
  # The newest Verdict at the head decides: an invalid one refuses only while nothing newer applies, so a
  # corrected Verdict replaces a bad one and a bad one posted after a good one still refuses.
  bad_verdict() { if [ "$newest_seen" = true ]; then ignored_notes+=("ignored Verdict $ref: $1, and a newer Verdict replaces it"); else refuse "$1"; fi; }
  verdict_fix="post a fresh comment with script/post-verdict.sh (it builds the first line; edits never count)"
  # A FAIL is retired only by "Countersign: Elon head=<current head> reason=supersedes <comment url>".
  superseded=$(jq -r --arg h "$head" '.comments[].body | split("\n")[0] | capture("^Countersign: Elon head=(?<h>[0-9a-f]{40}) reason=supersedes (?<u>[^[:space:]]+)[[:space:]]*$")? | select(.h == $h) | .u' <<<"$info")
  # Every Verdict for this head (or carried across clean merges of main) counts. Newest first; none
  # of them can erase another. An edited or minimized PASS never counts (the
  # verifier posts a fresh one); an edited or minimized FAIL still blocks.
  while IFS= read -r row; do
    comment=$(jq -r '@base64d | fromjson | .body' <<<"\"$row\"")
    flagged=$(jq -r '@base64d | fromjson | ((.includesCreatedEdit // false) or (.isMinimized // false))' <<<"\"$row\"")
    row_n=$((row_n+1))
    ref=$(jq -r --arg n "$row_n" '@base64d | fromjson | .url // ("comment #" + $n + " (newest first)")' <<<"\"$row\"")
    line=${comment%%$'\n'*}
    if [[ "$line" != Verdict:* ]] && grep -q '^Verdict: ' <<<"$comment"; then
      misplaced=$((misplaced+1))
      ignored_notes+=("ignored Verdict $ref: the Verdict line is not the first line of its comment. Fix: $verdict_fix")
    fi
    if [[ "$line" =~ ^Verdict:\ (PASS\+NOTES|PASS|FAIL)\ head=([0-9a-f]{40})\ verifier=([a-zA-Z0-9_-]+)\ author=([a-zA-Z0-9_-]+)$ ]]; then
      verdict="${BASH_REMATCH[1]}"; candidate_head="${BASH_REMATCH[2]}"
      verifier_id="${BASH_REMATCH[3]}"; author_id="${BASH_REMATCH[4]}"
      if [ "${BASH_REMATCH[3]}" = "${BASH_REMATCH[4]}" ]; then
        if [ "$candidate_head" = "$head" ]; then bad_verdict "author cannot supply verifier verdict"; newest_seen=true; else refuse "author cannot supply verifier verdict"; fi
        continue
      fi
      if [ "$verdict" = FAIL ] && [[ "$ref" != "comment #"* ]] && grep -Fxq -- "$ref" <<<"$superseded"; then
        echo "lead-merge: FAIL Verdict $ref retired by a supersedes Countersign"; retired_seen=true; continue
      fi
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
        if ! grep -Fxq -- "$verifier_id" <<<"$known_dispatches"; then bad_verdict "verdict verifier $verifier_id is not a known dispatch"; newest_seen=true; continue; fi
        # author=unknown is the one literal allowed without a dispatch; any other author must be a known dispatch
        # or a configured coordinator id.
        if [ "$author_id" != unknown ] && ! grep -Fxq -- "$author_id" <<<"$known_dispatches" && ! is_coordinator "$author_id"; then
          bad_verdict "verdict author $author_id is not a known dispatch or a configured coordinator id (set coordinator_ids in script/lead-merge.local.json)"; newest_seen=true; continue
        fi
        if [ "$flagged" = true ] && [ "$verdict" != FAIL ]; then
          edited=$((edited+1))
          ignored_notes+=("ignored Verdict $ref: it was edited or minimized, so it does not count. Fix: $verdict_fix")
          continue
        fi
        # Newest first: a PASS read after a retired FAIL is older than that FAIL and cannot replace it.
        if [ "$retired_seen" = true ] && [ "$verdict" != FAIL ]; then
          ignored_notes+=("ignored Verdict $ref: it is older than the FAIL it would replace. Fix: $verdict_fix"); continue
        fi
        newest_seen=true
        [ -z "$carried" ] || echo "lead-merge: verdict carried from ${carried:0:12} to ${head:0:12} (merge of main only, clean replay)"
        applicable+=("$verdict"$'\n'"$comment")
        if [ "$verdict" = FAIL ]; then fails=$((fails+1)); else passes=$((passes+1)); fi
      fi
    elif [[ "$line" == Verdict:* ]]; then
      ignored_notes+=("ignored Verdict $ref: the first line must be exactly 'Verdict: PASS|PASS+NOTES|FAIL head=<40 hex sha> verifier=<id> author=<id>' (author= missing or the line is malformed). Fix: $verdict_fix")
    fi
  done < <(jq -r '.comments | reverse[] | @json | @base64' <<<"$info")
  if [ "$passes" -eq 0 ]; then
    if [ "$edited" -ne 0 ]; then refuse "missing passing verifier verdict: $edited edited or minimized PASS ignored; post a fresh Verdict"
    elif [ "$misplaced" -ne 0 ]; then refuse "missing passing verifier verdict: a Verdict line is not the first line of its comment; post a fresh comment that starts with it"
    else refuse "missing passing verifier verdict for current head or clean merge of main${carry_notes:+; not carried: ${carry_notes%; }}"; fi
    for note in ${ignored_notes[@]+"${ignored_notes[@]}"}; do refuse "$note"; done
  elif [ "$fails" -ne 0 ]; then
    refuse "conflicting PASS and FAIL verdicts for current head or clean merge of main"
  else
    if [ "$verify_set" = true ]; then
      want=$(sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' <<<"$verify_command")
      newest=${applicable[0]#*$'\n'}
      got=$(grep -m1 '^Command:' <<<"$newest" | sed -E 's/^Command:[[:space:]]*//; s/[[:space:]]+$//' || true)
      if [ -z "$want" ]; then refuse "--verify-command is empty"
      elif [ -z "$got" ]; then refuse "newest Verdict has no Command: line; expected: $want"
      elif [ "$got" != "$want" ]; then refuse "Verdict Command mismatch: verdict ran [$got], brief says [$want]"; fi
    fi
    for entry in "${applicable[@]}"; do
      comment=${entry#*$'\n'}
      if [ "$unchecked" = true ] && ! grep -qi 'unchecked' <<<"$comment"; then
        refuse "verdict must cover unchecked paths in its live lane"; break
      fi
    done
  fi
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
      'any(.comments[].body; startswith($prefix) and (.[($prefix|length):] | test("[^[:space:]]") and (startswith("supersedes ") | not)))' <<<"$info" >/dev/null
  }
  if ! countersigned "$head"; then
    countersign_ok=false
    while IFS= read -r candidate_head; do
      [ "$candidate_head" != "$head" ] || continue
      [ "${main_fetched:-false}" = true ] || { git fetch origin main >&2 || die "cannot fetch main to carry a countersign"; main_fetched=true; }
      if countersigned "$candidate_head" && verdict_carry "$candidate_head" "$head"; then countersign_ok=true; break; fi
    done < <(jq -r '.comments[].body | split("\n")[0] | capture("^Countersign: Elon head=(?<h>[0-9a-f]{40}) reason=").h?' <<<"$info" | awk '!seen[$0]++')
    [ "$countersign_ok" = true ] || refuse "missing Countersign: Elon for current head or clean merge of main"
  fi
fi

# Trunk drift of a single PR needs no head-checks, so it is part of preflight (a batch checks its train instead).
# A shared locale JSON file is accepted when both sides only added keys and the three way merge is clean (fails closed).
locale_additive() { # ancestor main head file
  local ancestor=$1 trunk=$2 tip=$3 f=$4 dir ok=1
  case "$f" in locales/*.json|*/locales/*.json) ;; *) return 1 ;; esac
  dir=$(mktemp -d) || return 1
  git show "$ancestor:$f" >"$dir/base" 2>/dev/null && git show "$trunk:$f" >"$dir/main" 2>/dev/null \
    && git show "$tip:$f" >"$dir/head" 2>/dev/null \
    && git merge-file -p "$dir/head" "$dir/base" "$dir/main" >"$dir/merged" 2>/dev/null \
    && jq -e -n --slurpfile b "$dir/base" --slurpfile m "$dir/main" --slurpfile h "$dir/head" --slurpfile x "$dir/merged" '
      def leaves: [paths(scalars) as $p | {key: ($p | tojson), value: getpath($p)}] | from_entries;
      ($b[0] | leaves) as $b | ($m[0] | leaves) as $m | ($h[0] | leaves) as $h
      | all($b | keys[]; . as $k | $m[$k] == $b[$k] and $h[$k] == $b[$k])
        and ((($m | keys) - ($b | keys)) - (($m | keys) - ($h | keys)) | length) == 0
        and ($x[0] | type) == "object"' >/dev/null 2>&1 && ok=0
  rm -rf "$dir"; return "$ok"
}
trunk_check() {
  local f ancestor trunk_files
  # A carried Verdict is judged against the current head, which includes the merged main commits.
  ancestor=$(git merge-base "$(field .baseRefOid)" "$head") || die "cannot find merge base; rebase and rerun head-checks"
  trunk_files=$(git diff --name-only "$ancestor" origin/main --) || die "cannot inspect trunk drift"
  while IFS= read -r f; do
    if grep -Fxq -- "$f" <<<"$trunk_files"; then
      locale_additive "$ancestor" origin/main "$head" "$f" || refuse "trunk changed $f; rebase and rerun head-checks"
    fi
  done < <(jq -r '.[]' <<<"$files")
}
if [ -z "$train_check" ] && [ "$preflight_only" != 1 ]; then
  git fetch origin main >&2 || die "cannot fetch main; rebase and rerun head-checks"
  trunk_check
fi

# Preflight ends here: every refusal that needs no head-checks has been collected.
flush_refusals
if [ "$preflight_only" = 1 ]; then echo "lead-merge: preflight passed for PR $pr"; exit 0; fi
[ "${LEAD_MERGE_GATE_ONLY:-0}" != 1 ] || exit 0

# Fetch immediately before merge; any shared changed path needs a new exact-head run.
git fetch origin main >&2 || die "cannot fetch main; rebase and rerun head-checks"
if [ -n "$train_check" ]; then
  [[ "${LEAD_MERGE_EXPECTED_MAIN_TREE:-}" =~ ^[0-9a-f]{40}$ ]] || die "batch item has no valid expected main tree"
  current_main_tree=$(git rev-parse --verify 'origin/main^{tree}') || die "cannot read current main tree"
  [ "$current_main_tree" = "$LEAD_MERGE_EXPECTED_MAIN_TREE" ] \
    || die "main changed since batch train checks; stop the batch and rebuild it"
else
  trunk_check
  flush_refusals
fi

if [ "${DRY_RUN:-0}" = 1 ]; then
  echo "[dry-run] would merge PR $pr head=$head"
  lock_release
  exit 0
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
lock_release

# Cleanup after the merge: the merged head branch and finished worktrees. Never fails the merge.
# The issue comes only from the PR's closing references. DRY_RUN=1 previews.
head_branch=$(field .headRefName)
issue=$(field '.closingIssuesReferences[0].number // empty')
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
  if [ -n "${LEAD_MERGE_CLEANUP_FILE:-}" ]; then
    # In a batch, cleanup runs once after the last merge.
    printf '%s %s\n' "$head_branch" "$head" >> "$LEAD_MERGE_CLEANUP_FILE"
    echo "cleanup: deferred until the batch ends ($head_branch)"
  else
    echo "cleanup: starting for $head_branch"
    bash "${LEAD_MERGE_CLEANUP:-$(dirname "$0")/merge-cleanup.sh}" --branch "$head_branch" --head-sha "$head" ${issue:+--issue "$issue"} \
      || echo "cleanup: incomplete (merge succeeded); run script/wrap-up.sh" >&2
  fi
else
  echo "cleanup: skipped (merge succeeded); could not retarget every PR based on $head_branch" >&2
fi
