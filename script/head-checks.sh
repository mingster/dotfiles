#!/usr/bin/env bash
# Run a repository's ordered checks in an isolated worktree at one exact head.
set -euo pipefail
# Claim the machine budget for the whole checklist, across repositories and tools.
# The marker is consumed here so a nested head-checks invocation gates normally.
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
if [ "${HEAD_CHECKS_GATE_HELD:-}" != 1 ]; then
  [ -z "${HEAD_CHECKS_SLOTS:-}" ] || [[ "$HEAD_CHECKS_SLOTS" =~ ^[1-9][0-9]*$ ]] || { echo 'head-checks: HEAD_CHECKS_SLOTS must be a positive number' >&2; exit 1; }
  exec python3 "$script_dir/heavy-gate.py" gate --head-checks -- \
    env HEAD_CHECKS_GATE_HELD=1 bash "$0" "$@"
fi
unset HEAD_CHECKS_GATE_HELD
repo="" pr="" ref="" sha="" worktree="" lock="" refused="" train_heads=""
override="" changed="" explicit_base=""
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
    printf 'Checks: %s head=%s%s\n\n' "$result" "$sha" "${train_heads:+ train-heads=$train_heads}"
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
    essential=sum(len(cut(lines[i])+"\n") for i in set(failures)|set(failure_durations))
    if budget-len(footer)<essential:
        footer="\nReceipt cut to fit %d characters. Full log path too long to show.\n" % cap
    budget-=len(footer)
    chosen={}; kept_durations=0
    for group in (failures,failure_durations,metadata,results,dur_idx,nice):
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
  info=$(cd "$repo" && gh pr view "$pr" --json headRefOid,baseRefOid)
  sha=$(jq -r .headRefOid <<<"$info"); base=$(jq -r .baseRefOid <<<"$info")
else
  sha=$(git -C "$repo" rev-parse --verify "$ref^{commit}")
  if [ -z "$explicit_base" ] && git -C "$repo" merge-base --is-ancestor "$sha" origin/main; then
    usage "historical --ref requires --base <ref>"
  fi
  base=$(git -C "$repo" rev-parse --verify "${explicit_base:-origin/main}^{commit}")
fi
[[ "$sha" =~ ^[0-9a-f]{40}$ ]] && [[ "$base" =~ ^[0-9a-f]{40}$ ]] || usage "invalid head or base SHA"
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
base=$(git -C "$repo" merge-base "$base" "$sha") || usage "cannot resolve PR merge base"
remote=$(git -C "$repo" config --get remote.origin.url || true)
name=$(basename "${remote:-$repo}" .git)
[[ "$name" =~ ^[a-zA-Z0-9._-]+$ ]] || usage "invalid repository name"
slots="$HEAD_CHECKS_SLOTS"
[[ "$slots" =~ ^[1-9][0-9]*$ ]] || usage "HEAD_CHECKS_SLOTS must be a positive number"
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
config="${override:-$worktree/.agents/head-checks.conf}"
[ -f "$config" ] || usage "missing .agents/head-checks.conf"
if command -v shasum >/dev/null 2>&1; then checklist_sum=$(shasum -a 256 "$config"); else checklist_sum=$(sha256sum "$config"); fi
printf "Checklist: %s\n" "$checklist_sum" >> "$log"
changed=$(mktemp)
: > "$changed.unchecked"
git -C "$worktree" diff --name-only -z "$base...$sha" -- > "$changed" 2>> "$log" || usage "cannot determine changed paths"
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
count=0
while IFS= read -r command || [ -n "$command" ]; do
  case "$command" in ''|\#*) continue ;; esac
  count=$((count+1))
  expanded=${command//\{files\}/$files}
  printf '\nCommand: %s\n' "$expanded" >> "$log"
  output=$(mktemp); started=$SECONDS
  if (cd "$worktree" && env -i PATH="$PATH" HOME="$HOME" LANG="${LANG:-C}" DOTFILES_DIR="${DOTFILES_DIR:-}" HEAD_CHECK_SHA="$sha" HEAD_CHECK_BASE="$base" HEAD_CHECKS_TSC_BUILD_INFO="$tsc_build_info" \
      bash -euo pipefail -c "$expanded") > "$output" 2>&1; then
    sed -n '/^UNCHECKED: /p' "$output" >> "$changed.unchecked"
    sed -n '/^Scoped tests: /p; /^Selected: /p' "$output" >> "$log"
    tail -20 "$output" >> "$log"
    printf 'Result: exit 0\nDuration: %ss\n' "$((SECONDS - started))" >> "$log"
    rm -f "$output"
  else
    status=$?
    sed -n '/^UNCHECKED: /p' "$output" >> "$changed.unchecked"
    sed -n '/^Scoped tests: /p; /^Selected: /p' "$output" >> "$log"
    tail -20 "$output" >> "$log"
    printf 'Result: exit %s; remaining checks stopped\nDuration: %ss\n' "$status" "$((SECONDS - started))" >> "$log"
    rm -f "$output"
    exit 1
  fi
done < "$config"
[ "$count" -gt 0 ] || usage "empty head-checks checklist"
