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
finish() {
  local status=$? result=FAIL
  trap - EXIT
  set +e
  [ -z "$lock" ] || rm -rf "$lock"
  [ -z "$refused" ] || { rm -f "$log" "$receipt"; exit 1; }
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
sys.stdout.write(text)
' > "$receipt"
  cat "$receipt"
  if [ -n "$pr" ] && [ -n "$sha" ]; then
    (cd "$repo" && gh pr comment "$pr" --body-file "$receipt") || status=1
  fi
  rm -f "$log" "$receipt"
  [ -z "$changed" ] || rm -f "$changed" "$changed.unchecked"
  [ "$status" -eq 0 ] || exit 1
}
trap finish EXIT
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
worktree="" busy="" attempt=0
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
[ -n "$worktree" ] || { refused=1; usage "every check worktree is in use by pid$busy"; }
printf '%s\n' "$$" > "$lock/pid"
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
printf "Checklist: %s\n" "$(shasum -a 256 "$config")" >> "$log"
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
  output=$(mktemp)
  if (cd "$worktree" && env -i PATH="$PATH" HOME="$HOME" LANG="${LANG:-C}" DOTFILES_DIR="${DOTFILES_DIR:-}" HEAD_CHECK_SHA="$sha" HEAD_CHECK_BASE="$base" \
      bash -euo pipefail -c "$expanded") > "$output" 2>&1; then
    sed -n '/^UNCHECKED: /p' "$output" >> "$changed.unchecked"
    sed -n '/^Scoped tests: /p; /^Selected: /p' "$output" >> "$log"
    tail -20 "$output" >> "$log"
    printf 'Result: exit 0\n' >> "$log"
    rm -f "$output"
  else
    status=$?
    sed -n '/^UNCHECKED: /p' "$output" >> "$changed.unchecked"
    sed -n '/^Scoped tests: /p; /^Selected: /p' "$output" >> "$log"
    tail -20 "$output" >> "$log"
    printf 'Result: exit %s; remaining checks stopped\n' "$status" >> "$log"
    rm -f "$output"
    exit 1
  fi
done < "$config"
[ "$count" -gt 0 ] || usage "empty head-checks checklist"
