#!/usr/bin/env bash
# Run a repository's ordered checks in an isolated worktree at one exact head.
# Database steps: a .agents/head-checks.conf line that needs Postgres runs on the head_checks_remote host when this
# host has no reachable local Postgres (pg_isready finds no server; having the client tools is not enough). Mark it with a trailing "# db" (bash reads it as a comment), e.g. `bash bin/head-checks-db.sh # db`,
# for a script that calls createdb itself. A literal createdb/dropdb/psql/pg_dump/pg_restore in the command also counts.
set -euo pipefail
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
head_checks_gate_wrap() {
  local command="$1"
  [ "$name" = dotfiles ] && return 0
  case "$command" in
    *playwright*|*'next build'*|*'run build'*|*test:regression*)
      printf '%s\n' python3 "$script_dir/heavy-gate.py" gate --weight 2 --
      ;;
    *head-checks-tsc*|*tsc\ *|*tsc.js*)
      printf '%s\n' python3 "$script_dir/heavy-gate.py" gate --measure --
      ;;
  esac
}
# A non-login ssh run has a bare PATH; keep this line the same as in remote-heavy.sh.
export PATH="$HOME/.bun/bin:$HOME/.asdf/shims:$PATH"
repo="" pr="" ref="" sha="" worktree="" lock="" refused="" train_heads=""
override="" changed="" explicit_base="" main_sha=""
usage() { echo "head-checks: $*" >&2; exit 1; }
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) repo="${2:-}"; shift 2 ;;
    --pr) pr="${2:-}"; shift 2 ;;
    --ref) ref="${2:-}"; shift 2 ;;
    --base) explicit_base="${2:-}"; shift 2 ;;
    --train-heads) train_heads="${2:-}"; shift 2 ;;
    --config) override="${2:-}"; shift 2 ;;
    *) usage "unknown argument $1" ;;
  esac
done
[ -d "$repo" ] || usage "--repo must name a repository directory"
[ -n "$pr" ] || [ -n "$ref" ] || usage "provide --pr N or --ref SHA"
[ -z "$pr" ] || [ -z "$ref" ] || usage "choose --pr or --ref, not both"
[ -z "$explicit_base" ] || [ -n "$ref" ] || usage "--base is only for --ref"
[ -z "$override" ] || { [ -n "$ref" ] && [ -f "$override" ]; } || usage "--config is a local --ref-only checklist override"
[ -z "$train_heads" ] || [ -n "$ref" ] || usage "--train-heads is only for --ref"
[ -z "$train_heads" ] || [[ "$train_heads" =~ ^[0-9a-f]{40}(,[0-9a-f]{40})*$ ]] || usage "--train-heads needs comma-separated full SHAs"
[ -z "$override" ] || override=$(cd "$(dirname "$override")" && printf "%s/%s" "$PWD" "$(basename "$override")")
case "$pr" in *[!0-9]*) usage "--pr must be numeric" ;; esac
repo=$(cd "$repo" && git rev-parse --show-toplevel)
remote=$(git -C "$repo" config --get remote.origin.url || true)
name=$(basename "${remote:-$repo}" .git)
[[ "$name" =~ ^[a-zA-Z0-9._-]+$ ]] || usage "invalid repository name"
if [ -n "${HEAD_CHECKS_SLOTS:-}" ]; then
  slots="$HEAD_CHECKS_SLOTS"
elif [ "$name" != dotfiles ] && [ -f "$HOME/.config/heavy-gate/slots.conf" ]; then
  slots=$(python3 -c 'import importlib.util,sys; spec=importlib.util.spec_from_file_location("hg",sys.argv[1]); m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m); print(m.config()["slots"])' "$script_dir/heavy-gate.py")
else
  slots=2
fi
[[ "$slots" =~ ^[1-9][0-9]*$ ]] || usage "HEAD_CHECKS_SLOTS must be a positive number"
log=$(mktemp); receipt=$(mktemp)
# Fixed cap on the posted receipt; GitHub rejects a comment body over 65536 characters.
receipt_cap=${HEAD_CHECKS_RECEIPT_CAP:-20000}
finish() {
  local status=$? result=FAIL
  trap - EXIT
  set +e
  [ -z "$lock" ] || rm -rf "$lock"
  [ -z "$refused" ] || { rm -f "$log" "$receipt"; exit 1; }
  printf '\nTotal: %ss\n' "$SECONDS" >> "$log"
  [ "$status" -ne 0 ] || result=PASS
  {
    printf 'Checks: %s head=%s%s%s\n\n' "$result" "$sha" "${main_sha:+ main=$main_sha}" "${train_heads:+ train-heads=$train_heads}"
    if [ -n "$changed" ]; then
      unchecked_paths=$(sed -n 's/^UNCHECKED: //p' "$changed.unchecked" 2>/dev/null | sort -u | paste -sd ',' - | sed 's/,/, /g')
      [ -z "$unchecked_paths" ] || printf 'Unchecked paths: %s\n\n' "$unchecked_paths"
    fi
    cat "$log"
  } | python3 -c '
import os,re,sys
text=sys.stdin.read()
for key,value in os.environ.items():
    if len(value)>3 and re.search(r"SECRET|TOKEN|PASSWORD|DATABASE_URL|API_KEY",key,re.I): text=text.replace(value,"[redacted]")
text=re.sub(r"(?:postgres(?:ql)?|mysql|mongodb(?:\+srv)?|redis|sqlserver)://[^\s]+", "[redacted database URL]", text)
cap=int(sys.argv[1]); path=sys.argv[2]
if len(text)>cap:
    # Budget each section once; sorting durations is O(n log n), selection is O(n).
    open(path,"w").write(text)
    lines=text.rstrip("\n").split("\n")
    header=lines.pop(0)
    total=lines.pop() if lines and lines[-1].startswith("Total: ") else ""
    closing=total+"\n" if total else ""
    footer="\nReceipt cut to fit %d characters. Full log: %s\n" % (cap,path)
    dur=re.compile(r"^Duration: (\d+)s$")
    duration_seconds={i:int(m.group(1)) for i,l in enumerate(lines) if (m:=dur.match(l))}
    dur_idx=sorted(duration_seconds, key=lambda i:(-duration_seconds[i],i))
    failures=[i for i,l in enumerate(lines) if l.startswith("Result: ") and not l.startswith("Result: exit 0")]
    # A failing check keeps its own Duration even when the budget is tight.
    failure_duration={i:d for i in failures if (d:=next((j for j in range(i+1,len(lines)) if j in duration_seconds),None)) is not None}
    failure_durations=list(failure_duration.values())
    execution=[i for i,l in enumerate(lines) if l.startswith(("Tests executed: ","Load errors: "))]
    metadata=[i for i,l in enumerate(lines) if l.startswith(("Unchecked paths: ","Checklist: "))]
    results=[i for i,l in enumerate(lines) if l.startswith("Result: exit 0")]
    nice=[i for i,l in enumerate(lines) if l.startswith(("Command: ","Scoped tests: ","Selected: ")) or i>=len(lines)-40]
    cut=lambda l: l if len(l)<=300 else l[:300]+"[... line cut]"
    # Reserve the largest possible omission counters, including their newlines.
    omitted_line="[... %d lines omitted]\n" % len(lines)
    omitted_durations="Durations omitted: %d (see full log)\n" % len(dur_idx)
    budget=cap-len(header)-1-len(closing)-len(omitted_line)-len(omitted_durations)
    # A long log path (long TMPDIR) must not crowd out the failing checks: drop
    # the path from the footer when it and the failure lines cannot both fit.
    essential=sum(len(cut(lines[i])+"\n") for i in set(failures)|set(failure_durations)|set(execution))
    if budget-len(footer)<essential:
        footer="\nReceipt cut to fit %d characters. Full log path too long to show.\n" % cap
    budget-=len(footer)
    chosen={}; kept_durations=0
    for group in (failures,failure_durations,execution,metadata,results,dur_idx,nice):
        for i in group:
            if i in chosen: continue
            line=cut(lines[i])+"\n"
            if len(line)<=budget:
                chosen[i]=line
                budget-=len(line)
                kept_durations+=i in duration_seconds
    # Emit failing results first as well as selecting them first.
    out=[header+"\n"]
    # Each failing Result is followed directly by its own Duration.
    for i in failures:
        out.extend(chosen[j] for j in (i,failure_duration.get(i)) if j in chosen)
    failed_indices=set(failures)|set(failure_durations)
    out.extend(chosen[i] for i in sorted(chosen) if i not in failed_indices)
    omitted=len(lines)-len(chosen)
    if omitted: out.append("[... %d lines omitted]\n" % omitted)
    skipped=len(dur_idx)-kept_durations
    if skipped: out.append("Durations omitted: %d (see full log)\n" % skipped)
    text="".join(out)+footer+closing
    if len(text)>cap:
        # Last resort for very small caps or unusually long header/log paths:
        # cut the middle, preserving the complete header and final Total if possible.
        opening=header+"\n"
        available=max(cap-len(opening)-len(closing),0)
        text=opening+text[len(opening):len(opening)+available]+closing
        if len(text)>cap:
            # A cap smaller than the two boundary lines cannot hold both in full.
            text=opening[:max(cap-len(closing),0)]+closing[:cap]

sys.stdout.write(text)
' "$receipt_cap" "${HEAD_CHECKS_LOG_DIR:-${TMPDIR:-/tmp}}/head-checks-${sha:0:12}.log" > "$receipt"
  cat "$receipt"
  if [ -n "$pr" ] && [ -n "$sha" ]; then
    (cd "$repo" && gh pr comment "$pr" --body-file "$receipt") || status=1
  fi
  rm -f "$log" "$receipt"
  [ -z "$changed" ] || rm -f "$changed" "$changed.unchecked"
  [ "$status" -eq 0 ] || exit 1
}
trap finish EXIT
# A killed run must not read as a pass: bash hands the EXIT trap status 0 after SIGTERM.
trap 'exit 143' TERM; trap 'exit 130' INT
if [ -n "$pr" ]; then
  pr_head_wait="${HEAD_CHECKS_PR_HEAD_WAIT_SECONDS:-60}"
  [[ "$pr_head_wait" =~ ^[0-9]+$ ]] || usage "HEAD_CHECKS_PR_HEAD_WAIT_SECONDS must be a whole number"
  local_pushed=$(git -C "$repo" rev-parse HEAD) || usage "cannot resolve local HEAD"
  [[ "$local_pushed" =~ ^[0-9a-f]{40}$ ]] || usage "cannot resolve local HEAD"
  gh_head_attempt=0
  pr_local_branch=0
  while :; do
    if ! info=$(cd "$repo" && gh pr view "$pr" --json headRefOid,baseRefOid,headRefName); then
      gh_head_attempt=$((gh_head_attempt + 1))
      [ "$gh_head_attempt" -lt $((pr_head_wait * 2)) ] || {
        refused=1
        usage "gh pr view failed for PR #$pr; waited ${pr_head_wait}s"
      }
      sleep 0.5
      continue
    fi
    sha=$(jq -r .headRefOid <<<"$info"); base=$(jq -r .baseRefOid <<<"$info")
    branch=$(jq -r .headRefName <<<"$info")
    pr_local_branch=0
    if [ -n "$branch" ] && [ "$branch" != null ] && git -C "$repo" show-ref --verify --quiet "refs/heads/$branch"; then
      local_pushed=$(git -C "$repo" rev-parse "refs/heads/$branch")
      pr_local_branch=1
    fi
    [[ "$sha" =~ ^[0-9a-f]{40}$ ]] && [[ "$base" =~ ^[0-9a-f]{40}$ ]] || usage "invalid head or base SHA from GitHub"
    [ "$pr_local_branch" -eq 0 ] && break
    [ "$sha" = "$local_pushed" ] && break
    # A local copy that is behind the PR head is stale, not a push still in flight: use the PR head.
    git -C "$repo" cat-file -e "$sha^{commit}" 2>/dev/null || git -C "$repo" fetch -q origin "$sha" >> "$log" 2>&1 || true
    git -C "$repo" merge-base --is-ancestor "$local_pushed" "$sha" 2>/dev/null && break
    gh_head_attempt=$((gh_head_attempt + 1))
    [ "$gh_head_attempt" -lt $((pr_head_wait * 2)) ] || {
      refused=1
      usage "GitHub PR #$pr head is $sha but local pushed head is $local_pushed; waited ${pr_head_wait}s for GitHub to update"
    }
    sleep 0.5
  done
else
  sha=$(git -C "$repo" rev-parse --verify "$ref^{commit}")
  if [ -z "$explicit_base" ] && git -C "$repo" merge-base --is-ancestor "$sha" origin/main; then
    usage "historical --ref requires --base <ref>"
  fi
  base=$(git -C "$repo" rev-parse --verify "${explicit_base:-origin/main}^{commit}")
fi
[[ "$sha" =~ ^[0-9a-f]{40}$ ]] && [[ "$base" =~ ^[0-9a-f]{40}$ ]] || usage "invalid head or base SHA"
pr_base="$base"
for commit in "$sha" "$base"; do
  git -C "$repo" cat-file -e "$commit^{commit}" 2>/dev/null || git -C "$repo" fetch origin "$commit" >> "$log" 2>&1
 done
if [ -n "$train_heads" ]; then
  IFS=, read -ra contained_heads <<<"$train_heads"
  for commit in "${contained_heads[@]}"; do
    git -C "$repo" cat-file -e "$commit^{commit}" 2>/dev/null \
      && git -C "$repo" merge-base --is-ancestor "$commit" "$sha" \
      || usage "train head does not contain $commit"
  done
fi
# The PR merge base always comes from the PR base. The trial merge target is the explicit --base,
# else the current origin/main tip when the remote has one, else the PR base.
base=$(git -C "$repo" merge-base "$base" "$sha") || usage "cannot resolve PR merge base"
main_sha="$pr_base"
if [ -z "$explicit_base" ] && git -C "$repo" remote get-url origin >/dev/null 2>&1; then
  git -C "$repo" fetch -q origin main >> "$log" 2>&1 || true
  main_sha=$(git -C "$repo" rev-parse --verify -q "origin/main^{commit}" || printf '%s' "$pr_base")
fi
wait_seconds="${HEAD_CHECKS_WAIT_SECONDS:-600}"
[[ "$wait_seconds" =~ ^[0-9]+$ ]] || usage "HEAD_CHECKS_WAIT_SECONDS must be a whole number"
mkdir -p "$HOME/orca/workspaces/$name"
# Each check worktree persists so installed packages survive between runs; one run at a time may use each.
# Until a worktree is held nothing is checked, so a run killed while waiting posts no verdict.
worktree="" busy="" attempt=0 refused=1
while :; do
  busy=""
  for i in $(seq 1 "$slots"); do
    candidate="$HOME/orca/workspaces/$name/_checks"; [ "$i" -eq 1 ] || candidate="$candidate-$i"
    lock="$candidate.lock"
    if ! mkdir "$lock" 2>/dev/null; then
      holder=$(cat "$lock/pid" 2>/dev/null || true)
      if [[ "$holder" =~ ^[0-9]+$ ]] && kill -0 "$holder" 2>/dev/null; then
        busy="$busy $holder"; lock=""; continue
      fi
      rm -rf "$lock"; mkdir "$lock" || { lock=""; continue; }
    fi
    worktree="$candidate"; break
  done
  # Wait for a worktree to free up, polling twice a second.
  [ -z "$worktree" ] && [ "$attempt" -lt $((wait_seconds * 2)) ] || break
  attempt=$((attempt+1)); sleep 0.5
done
# A busy refusal checked nothing, so it posts no Checks verdict.
[ -n "$worktree" ] || usage "every check worktree is in use by pid$busy"
refused=""
printf '%s\n' "$$" > "$lock/pid"
# Incremental tsc cache lives beside the check worktree, never inside the checkout.
tsc_build_info="$HOME/orca/workspaces/$name/tsc-${worktree##*/}.tsbuildinfo"
mkdir -p "$(dirname "$tsc_build_info")"
common=$(git -C "$repo" rev-parse --path-format=absolute --git-common-dir)
if [ -e "$worktree" ] && [ "$(git -C "$worktree" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" = "$common" ] \
    && [ -z "$(git -C "$worktree" status --porcelain --untracked-files=no 2>/dev/null)" ]; then
  git -C "$worktree" checkout -q --detach "$sha" >> "$log" 2>&1
  git -C "$worktree" clean -fdq -e node_modules >> "$log" 2>&1
else
  if [ -e "$worktree" ]; then
    git -C "$repo" worktree remove --force "$worktree" >/dev/null 2>&1 || usage "cannot replace unusable check worktree: $worktree"
  fi
  git -C "$repo" worktree prune
  git -C "$repo" worktree add --detach "$worktree" "$sha" >> "$log" 2>&1
fi
# Test the head as it will land: merge main into the check worktree only, never the caller's checkout.
if ! merge_out=$(git -C "$worktree" -c user.name=head-checks -c user.email=head-checks@localhost.invalid \
    merge --no-edit "$main_sha" 2>&1); then
  conflicts=$(git -C "$worktree" diff --name-only --diff-filter=U | paste -sd ',' - | sed 's/,/, /g')
  git -C "$worktree" merge --abort >> "$log" 2>&1 || git -C "$worktree" reset -q --hard "$sha" >> "$log" 2>&1 || true
  printf 'Trial merge conflict: head %s does not merge with main %s (conflicts: %s). Rebase the PR on main.\n' "$sha" "$main_sha" "${conflicts:-unknown}" >> "$log"
  printf '%s\n' "$merge_out" >> "$log"
  exit 1
fi
printf 'Trial merge: head %s with main %s\n' "$sha" "$main_sha" >> "$log"
config="${override:-$worktree/.agents/head-checks.conf}"
[ -f "$config" ] || usage "missing .agents/head-checks.conf"
if command -v shasum >/dev/null 2>&1; then checklist_sum=$(shasum -a 256 "$config"); else checklist_sum=$(sha256sum "$config"); fi
printf "Checklist: %s\n" "$checklist_sum" >> "$log"
changed=$(mktemp)
: > "$changed.unchecked"
git -C "$worktree" diff --no-renames --name-only -z "$base...$sha" -- > "$changed" 2>> "$log" || usage "cannot determine changed paths"
files=""
while IFS= read -r -d '' file; do
  printf -v quoted '%q' "$file"
  files="$files $quoted"
done < "$changed"
# The base commit's .claude/deploy-guard-paths (one glob per line) lists paths a deploy refuses; a PR cannot add one.
if guards=$(git -C "$worktree" show "$base:.claude/deploy-guard-paths" 2>/dev/null); then
  while IFS= read -r -d '' file; do
    while IFS= read -r glob || [ -n "$glob" ]; do
      case "$glob" in ''|\#*) continue ;; esac
      # shellcheck disable=SC2254
      case "$file" in $glob)
        # A guard refusal checked nothing, so it posts no Checks verdict.
        refused=1
        usage "Deploy guard: PR adds $file, which matches $glob in .claude/deploy-guard-paths" ;;
      esac
    done <<<"$guards"
  done < <(git -C "$worktree" diff --name-only --diff-filter=A -z "$base...$sha" --)
fi
# A PR that deletes the project team files must still pass the gate, so the base tree counts too.
team_files=0
for team_file in .claude/settings.project.json .claude/hooks/guard-config.json; do
  if [ -f "$worktree/$team_file" ] || git -C "$worktree" cat-file -e "$base:$team_file" 2>/dev/null; then
    team_files=1
  fi
done
if [ "$team_files" -eq 1 ]; then
  export DOTFILES="${DOTFILES_DIR:-${DOTFILES:-$(cd "$script_dir/.." && pwd)}}"
  printf '\nCommand: bash "%s/script/agent-team.sh" check "%s"\n' "$DOTFILES" "$worktree" >> "$log"
  started=$SECONDS
  if bash "$DOTFILES/script/agent-team.sh" check "$worktree" >> "$log" 2>&1; then
    printf 'Result: exit 0\nDuration: %ss\n' "$((SECONDS - started))" >> "$log"
  else
    status=$?
    printf 'Result: exit %s; remaining checks stopped\nDuration: %ss\n' "$status" "$((SECONDS - started))" >> "$log"
    exit 1
  fi
fi
# Read the complete output before tailing it. Bun assertion diagnostics also say
# error:, so use its unhandled-error summary rather than counting all diagnostics.
test_summary() {
  python3 - "$1" <<'PYTEST'
import re, sys
text = open(sys.argv[1]).read()
text = re.sub(r"\x1b\[[0-9;]*m", "", text)
if re.search(r"^bun test v", text, re.M):
    executed = sum(int(n) for n in re.findall(r"^\s*(\d+) (?:pass|fail)\s*$", text, re.M))
    errors = sum(int(n) for n in re.findall(r"^\s*(\d+) errors?\s*$", text, re.M))
    # A file can abort before Bun emits the final summary.
    errors = max(errors, len(re.findall(r"^# Unhandled error between tests$", text, re.M)))
    print(f"Tests executed: {executed}\nLoad errors: {errors}")
PYTEST
}
# A step that needs Postgres runs against the database host (head_checks_remote), never a host without it.
# Without a reachable local Postgres server and no remote host, the step is a host fault: FAIL, never a pass.
db_step_re='(^|[^[:alnum:]_-])(createdb|dropdb|psql|pg_dump|pg_restore)([^[:alnum:]_-]|$)'
db_marker_re='[[:space:]]#[[:space:]]*db[[:space:]]*$'
db_remote_host="" db_remote_repo_dir="" db_remote_dir=""
db_remote_load() {
  local cfg dir
  db_remote_host=${LEAD_MERGE_REMOTE_HOST:-}; db_remote_repo_dir=${LEAD_MERGE_REMOTE_REPO_DIR:-}; db_remote_dir=${LEAD_MERGE_REMOTE_DIR:-}
  [ -z "$db_remote_host" ] || return 0
  cfg=$(python3 "$script_dir/apply-local-overlay.py" "$script_dir/ship.config.example.json" "$script_dir/ship.local.json" 2>/dev/null) || return 0
  [ "$(jq -r --arg r "$name" '(.head_checks_remote.repo // $r) | split("/") | last' <<<"$cfg")" = "$name" ] || return 0
  db_remote_host=$(jq -r '.head_checks_remote.host // ""' <<<"$cfg")
  db_remote_repo_dir=$(jq -r '.head_checks_remote.repo_dir // ""' <<<"$cfg")
  db_remote_dir=$(jq -r '.head_checks_remote.dir // ""' <<<"$cfg")
}
# db_step_runner <expanded command>: prints the remote-heavy argv tokens, one per line, when the step must go to the
# database host; prints nothing when it runs here. Returns 1 (a host fault) when it can run nowhere.
db_step_runner() {
  [[ "$1" =~ $db_marker_re || "$1" =~ $db_step_re ]] || return 0
  # The probe is a command line (HEAD_CHECKS_DB_PROBE overrides it in tests). A missing pg_isready counts as no server.
  local -a probe
  read -r -a probe <<<"${HEAD_CHECKS_DB_PROBE:-pg_isready -q -t 2}"
  "${probe[@]}" >/dev/null 2>&1 && return 0
  db_remote_load
  if [ -z "$db_remote_host" ] || [ -z "$db_remote_repo_dir" ] || [ -z "$db_remote_dir" ]; then
    return 1
  fi
  printf '%s\n' bash "${HEAD_CHECKS_REMOTE_HEAVY:-$script_dir/remote-heavy.sh}" --host "$db_remote_host" --repo-dir "$db_remote_repo_dir" --dir "$db_remote_dir" --
}
# An asdf shim looks for .tool-versions under the caller's HOME and exits 126 when a test sets its own, so steps get
# the real python3 and node directories first. Resolved once, from the worktree; without asdf the PATH is unchanged.
step_path="$PATH"
for tool in python3 node; do
  real=$(cd "$worktree" && asdf which "$tool" 2>/dev/null) && [ -x "$real" ] && step_path="$(dirname "$real"):$step_path"
done
count=0
while IFS= read -r command || [ -n "$command" ]; do
  case "$command" in ''|\#*) continue ;; esac
  count=$((count+1))
  expanded=${command//\{files\}/$files}
  printf '\nCommand: %s\n' "$expanded" >> "$log"
  output=$(mktemp); started=$SECONDS
  step_env=(LANG="${LANG:-C}" DOTFILES_DIR="${DOTFILES_DIR:-}" HEAD_CHECK_SHA="$sha" HEAD_CHECK_BASE="$base" HEAD_CHECKS_TSC_BUILD_INFO="$tsc_build_info")
  run=(env -i PATH="$step_path" HOME="$HOME" "${step_env[@]}" bash -euo pipefail -c "$expanded")
  gate_prefix=()
  while IFS= read -r token || [ -n "${token:-}" ]; do
    [ -n "${token:-}" ] && gate_prefix+=("$token")
  done < <(head_checks_gate_wrap "$expanded" || true)
  if [ ${#gate_prefix[@]} -gt 0 ]; then
    runner=( "${gate_prefix[@]}" "${run[@]}" )
  else
    runner=( "${run[@]}" )
  fi
  db_prefix=()
  if db_out=$(db_step_runner "$expanded"); then
    while IFS= read -r token || [ -n "${token:-}" ]; do
      [ -n "${token:-}" ] && db_prefix+=("$token")
    done <<<"$db_out"
    # The database host has its own PATH and HOME; this host's would break the step there.
    [ ${#db_prefix[@]} -eq 0 ] || runner=( "${db_prefix[@]}" env "${step_env[@]}" bash -euo pipefail -c "$expanded" )
  else
    printf 'Result: host fault; this host has no reachable local Postgres (probe: %s) and no head_checks_remote database host is configured, so the database step did not run. Not a pass; run the head checks on the database host.\nDuration: 0s\n' "${HEAD_CHECKS_DB_PROBE:-pg_isready -q -t 2}" >> "$log"
    rm -f "$output"
    exit 1
  fi
  if (cd "$worktree" && "${runner[@]}") > "$output" 2>&1; then
    sed -n '/^UNCHECKED: /p' "$output" >> "$changed.unchecked"
    sed -n '/^Scoped tests: /p; /^Selected: /p' "$output" >> "$log"
    summary=$(test_summary "$output")
    tail -20 "$output" >> "$log"
    printf 'Result: exit 0\nDuration: %ss\n' "$((SECONDS - started))" >> "$log"
    [ -z "$summary" ] || printf '%s\n' "$summary" >> "$log"
    rm -f "$output"
  else
    status=$?
    sed -n '/^UNCHECKED: /p' "$output" >> "$changed.unchecked"
    sed -n '/^Scoped tests: /p; /^Selected: /p' "$output" >> "$log"
    summary=$(test_summary "$output")
    tail -20 "$output" >> "$log"
    # Exit 137 is a kill signal (often the kernel out of memory killer): still a FAIL, but not a verdict on the code.
    note=""; [ "$status" -ne 137 ] || note="; interrupted by a kill signal, the code was not judged, rerun Checks"
    printf 'Result: exit %s; remaining checks stopped%s\nDuration: %ss\n' "$status" "$note" "$((SECONDS - started))" >> "$log"
    [ -z "$summary" ] || printf '%s\n' "$summary" >> "$log"
    rm -f "$output"
    exit 1
  fi
done < "$config"
[ "$count" -gt 0 ] || usage "empty head-checks checklist"
