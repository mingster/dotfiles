#!/usr/bin/env bash
# Run a repository's ordered checks in an isolated worktree at one exact head.
set -euo pipefail
repo="" pr="" ref="" sha="" worktree="" created=false
override="" changed=""
usage() { echo "head-checks: $*" >&2; exit 1; }
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) repo="${2:-}"; shift 2 ;;
    --pr) pr="${2:-}"; shift 2 ;;
    --ref) ref="${2:-}"; shift 2 ;;
    --config) override="${2:-}"; shift 2 ;;
    *) usage "unknown argument $1" ;;
  esac
done
[ -d "$repo" ] || usage "--repo must name a repository directory"
[ -n "$pr" ] || [ -n "$ref" ] || usage "provide --pr N or --ref SHA"
[ -z "$pr" ] || [ -z "$ref" ] || usage "choose --pr or --ref, not both"
[ -z "$override" ] || { [ -n "$ref" ] && [ -f "$override" ]; } || usage "--config is a local --ref-only checklist override"
[ -z "$override" ] || override=$(cd "$(dirname "$override")" && printf "%s/%s" "$PWD" "$(basename "$override")")
case "$pr" in *[!0-9]*) usage "--pr must be numeric" ;; esac
repo=$(cd "$repo" && git rev-parse --show-toplevel)
log=$(mktemp); receipt=$(mktemp)
finish() {
  local status=$? result=FAIL
  trap - EXIT
  set +e
  if [ "$created" = true ]; then
    git -C "$repo" worktree remove --force "$worktree" >/dev/null 2>&1 || status=1
  fi
  [ "$status" -ne 0 ] || result=PASS
  {
    printf 'Checks: %s head=%s\n\n' "$result" "$sha"
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
  [ -z "$changed" ] || rm -f "$changed"
  [ "$status" -eq 0 ] || exit 1
}
trap finish EXIT
if [ -n "$pr" ]; then
  info=$(cd "$repo" && gh pr view "$pr" --json headRefOid,baseRefOid)
  sha=$(jq -r .headRefOid <<<"$info"); base=$(jq -r .baseRefOid <<<"$info")
else
  sha=$(git -C "$repo" rev-parse --verify "$ref^{commit}")
  base=$(git -C "$repo" rev-parse --verify origin/main)
fi
[[ "$sha" =~ ^[0-9a-f]{40}$ ]] && [[ "$base" =~ ^[0-9a-f]{40}$ ]] || usage "invalid head or base SHA"
for commit in "$sha" "$base"; do
  git -C "$repo" cat-file -e "$commit^{commit}" 2>/dev/null || git -C "$repo" fetch origin "$commit" >> "$log" 2>&1
 done
remote=$(git -C "$repo" config --get remote.origin.url || true)
name=$(basename "${remote:-$repo}" .git)
[[ "$name" =~ ^[a-zA-Z0-9._-]+$ ]] || usage "invalid repository name"
worktree="$HOME/orca/workspaces/$name/_checks"
[ ! -e "$worktree" ] || usage "check worktree already exists: $worktree"
mkdir -p "$(dirname "$worktree")"
git -C "$repo" worktree add --detach "$worktree" "$sha" >> "$log" 2>&1
created=true
config="${override:-$worktree/.agents/head-checks.conf}"
[ -f "$config" ] || usage "missing .agents/head-checks.conf"
printf "Checklist: %s\n" "$(shasum -a 256 "$config")" >> "$log"
changed=$(mktemp)
git -C "$worktree" diff --name-only -z "$base...$sha" -- > "$changed" 2>> "$log" || usage "cannot determine changed paths"
files=""
while IFS= read -r -d '' file; do
  printf -v quoted '%q' "$file"
  files="$files $quoted"
done < "$changed"
count=0
while IFS= read -r command || [ -n "$command" ]; do
  case "$command" in ''|\#*) continue ;; esac
  count=$((count+1))
  expanded=${command//\{files\}/$files}
  printf '\nCommand: %s\n' "$expanded" >> "$log"
  output=$(mktemp)
  if (cd "$worktree" && env -i PATH="$PATH" HOME="$HOME" LANG="${LANG:-C}" HEAD_CHECK_SHA="$sha" \
      bash -euo pipefail -c "$expanded") > "$output" 2>&1; then
    tail -20 "$output" >> "$log"
    printf 'Result: exit 0\n' >> "$log"
    rm -f "$output"
  else
    status=$?
    tail -20 "$output" >> "$log"
    printf 'Result: exit %s; remaining checks stopped\n' "$status" >> "$log"
    rm -f "$output"
    exit 1
  fi
done < "$config"
[ "$count" -gt 0 ] || usage "empty head-checks checklist"
