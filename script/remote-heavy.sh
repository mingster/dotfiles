#!/usr/bin/env bash
# Run a heavy job (tsc, bun test, Playwright) for the current commit on a remote host.
#
#   remote-heavy.sh --host <ssh host> --repo-dir <remote checkout> --dir <remote worktree>
#                   [--sub <subdir>] [--weight N] [--gate <remote heavy-gate.sh>]
#                   [--fetch <worktree-relative path/glob> ... --into <local dir>] -- <command>
#
# Sends HEAD (as a git bundle over ssh) to the remote checkout as refs/heavy/<sha> (never to origin), checks it out
# detached in the remote worktree, reinstalls packages when the lockfile changed, and runs
# the command under the remote heavy-gate. Exit status is the command's. A missing
# --dir is created as a detached worktree of --repo-dir.
# Every ssh call runs a base64 transported script and frames its stdout between tagged
# markers, so lines a login shell prints around the command never reach the caller.
# Fetches use remote Python 3 globbing and OpenSSH scp (SFTP); files land by basename
# in --into, so select unique artifact names when fetching from multiple directories.
# The remote command does not inherit the caller's stdin: the remote shell's stdin is the bundle stream.
set -euo pipefail

# shellcheck disable=SC2016 # expanded on the remote host
host="" repo_dir="" dir="" sub=. weight=1 gate='${DOTFILES_DIR:-$HOME/dotfiles}/script/heavy-gate.sh'
fetches=()
into=""
while [ $# -gt 0 ]; do
  case "$1" in
    --fetch) fetches+=("$2"); shift 2 ;;
    --into) into="$2"; shift 2 ;;
    --host) host="$2"; shift 2 ;;
    --repo-dir) repo_dir="$2"; shift 2 ;;
    --dir) dir="$2"; shift 2 ;;
    --sub) sub="$2"; shift 2 ;;
    --weight) weight="$2"; shift 2 ;;
    --gate) gate="$2"; shift 2 ;;
    --) shift; break ;;
    *) echo "remote-heavy: unknown argument $1" >&2; exit 64 ;;
  esac
done
[ -n "$host" ] && [ -n "$repo_dir" ] && [ -n "$dir" ] && [ $# -gt 0 ] \
  || { echo "usage: remote-heavy.sh --host H --repo-dir R --dir D [--sub S] [--weight N] -- cmd" >&2; exit 64; }
case "$host" in -*|*[!A-Za-z0-9._-]*) echo "remote-heavy: bad host $host" >&2; exit 64 ;; esac

if [ "${#fetches[@]}" -gt 0 ] || [ -n "$into" ]; then
  [ "${#fetches[@]}" -gt 0 ] && [ -n "$into" ] \
    || { echo 'remote-heavy: --fetch and --into are required together' >&2; exit 64; }
  for pattern in "${fetches[@]}"; do
    case "/$pattern/" in
      //*|*/../*) echo 'remote-heavy: fetch paths must be relative without ..' >&2; exit 64 ;;
    esac
  done
fi

sha=$(git rev-parse HEAD)
# Send only the commits past main (a full history is hundreds of MiB for a large repo).
# Excluding the merge base's parent keeps the bundle non-empty when HEAD is on main.
bundle_range=(HEAD)
base=$(git merge-base HEAD origin/main 2>/dev/null || true)
if [ -n "$base" ] && git rev-parse -q --verify "$base^" > /dev/null; then bundle_range=(HEAD "^$base^"); fi

cmd=$(printf '%q ' "$@")
b64() { printf '%s' "$1" | base64 | tr -d '\n'; }
tag="remote-heavy-$$-$RANDOM"
# The remote login shell may not be bash (fish eats a heredoc on stdin), so the script
# and every argument travel as base64 inside one plain word list.
remote=$(cat <<'REMOTE'
set -euo pipefail
d() { printf '%s' "$1" | base64 -d; }
dir=$(d "$1") sha=$(d "$2") sub=$(d "$3") weight=$(d "$4") gate=$(d "$5") cmd=$(d "$6") repo_dir=$(d "$7") tag=$(d "$8")
# The bundle on stdin carries HEAD, so no git transport shares stdout with the login shell.
bundle=$(mktemp)
trap 'rm -f "$bundle"' EXIT
base64 -d > "$bundle"
# The bundle holds only commits past main, so the remote needs main first; a full bundle does not.
git -C "$repo_dir" fetch -q origin main 2>/dev/null || true
git -C "$repo_dir" fetch -q "$bundle" "+HEAD:refs/heavy/$sha" \
  || { echo "remote-heavy: the remote checkout lacks the base commit of the bundle (its origin/main is behind this one); update origin/main there and retry" >&2; exit 1; }
export PATH="$HOME/.bun/bin:$HOME/.asdf/shims:$PATH" LANG="${LANG:-en_US.UTF-8}"
[ ! -d "$HOME/dotfiles-main" ] || export DOTFILES_DIR="$HOME/dotfiles-main"
[ ! -d /usr/bin/core_perl ] || export PATH="$PATH:/usr/bin/core_perl"
gate="${gate//\$\{DOTFILES_DIR:-\$HOME\/dotfiles\}/${DOTFILES_DIR:-$HOME/dotfiles}}"
gate="${gate/#\$HOME/$HOME}"
# A new lane's directory is created once as a worktree of the remote checkout.
[ -d "$dir" ] || git -C "$repo_dir" worktree add -q --detach "$dir" "$sha"
cd "$dir"
git checkout -q --detach "$sha"
cd "./$sub"
stamp=.remote-heavy-lock-sha
if [ -f bun.lock ]; then
  lock_sum=$({ sha256sum 2>/dev/null || shasum -a 256; } < bun.lock | cut -d' ' -f1)
  if [ "$(cat "$stamp" 2>/dev/null)" != "$lock_sum" ]; then
    DATABASE_URL="${DATABASE_URL:-postgresql://placeholder:x@127.0.0.1:5432/placeholder}" \
      bun install --frozen-lockfile >/tmp/remote-heavy-install.log 2>&1 \
      || { tail -20 /tmp/remote-heavy-install.log >&2; exit 1; }
    echo "$lock_sum" > "$stamp"
  fi
fi
[ -f next-env.d.ts ] || [ ! -f next.config.ts ] || bunx next typegen >/dev/null 2>&1 || true
printf '%s\n' "@@begin-$tag@@"
status=0
"$gate" --weight "$weight" -- bash -c "$cmd" || status=$?
printf '\n%s\n' "@@end-$tag-$status@@"
REMOTE
)
# Lines between the markers are the command's output. Each line is held back until the
# next one arrives so the newline before the end marker is not part of the output.
framed=$(cat <<'AWK'
$0 == "@@begin-" tag "@@" { on = 1; next }
on && index($0, "@@end-" tag "-") == 1 {
  s = substr($0, length("@@end-" tag "-") + 1); sub(/@@$/, "", s)
  if (have) printf "%s", prev
  print s > sf; close(sf); on = 0; next
}
on { if (have) print prev; prev = $0; have = 1 }
AWK
)
status_file=$(mktemp)
trap 'rm -f "$status_file"' EXIT
# shellcheck disable=SC2029
{ git bundle create - "${bundle_range[@]}" 2>/dev/null | base64 | tr -d '\n'; } \
  | ssh "$host" bash -c "\"\$(echo $(b64 "$remote") | base64 -d)\"" remote-heavy \
    "$(b64 "$dir")" "$(b64 "$sha")" "$(b64 "$sub")" "$(b64 "$weight")" "$(b64 "$gate")" "$(b64 "$cmd")" "$(b64 "$repo_dir")" "$(b64 "$tag")" \
  | awk -v tag="$tag" -v sf="$status_file" "$framed" || true
# No end marker means the remote setup failed before the command ran.
status=$(cat "$status_file")
[ -n "$status" ] || { echo 'remote-heavy: remote setup failed' >&2; status=255; }

if [ "${#fetches[@]}" -gt 0 ]; then
  # Use the same shell-independent transport for remote glob expansion. NUL records
  # keep whitespace and newlines in filenames intact, separate from command output.
  listing=$(cat <<'REMOTE'
set -euo pipefail
d() { printf '%s' "$1" | base64 -d; }
dir=$(d "$1") tag=$(d "$2")
shift 2
patterns=()
for encoded in "$@"; do patterns+=("$(d "$encoded")"); done
# Python is also required by heavy-gate; glob supports ** on older remote Bash.
found=$(python3 - "$dir" "${patterns[@]}" <<'PYTHON' | base64 | tr -d '\n'
import glob, os, sys
os.chdir(sys.argv[1])
for pattern in sys.argv[2:]:
    for path in glob.iglob(pattern, recursive=True):
        if os.path.isfile(path):
            sys.stdout.buffer.write(os.fsencode(path) + b'\0')
PYTHON
)
printf '%s\n' "$tag$found"
REMOTE
)
  encoded_fetches=()
  for pattern in "${fetches[@]}"; do encoded_fetches+=("$(b64 "$pattern")"); done
  if ! manifest=$(mktemp); then
    echo 'remote-heavy: cannot create artifact manifest' >&2
    exit "$status"
  fi
  trap 'rm -f "$manifest" "$status_file"' EXIT
  # shellcheck disable=SC2029
  listing_tag="@@listing-$tag@@"
  if ssh "$host" bash -c "\"\$(echo $(b64 "$listing") | base64 -d)\"" remote-heavy-fetch \
      "$(b64 "$dir")" "$(b64 "$listing_tag")" "${encoded_fetches[@]}" </dev/null \
      | sed -n "s/^$listing_tag//p" | head -n 1 | base64 -d > "$manifest"; then
    if mkdir -p "$into"; then
      while IFS= read -r -d '' file; do
        target="$into/$(basename "$file")"
        if mkdir -p "$(dirname "$target")" && scp -- "$host:$dir/$file" "$target"; then
          printf '%s\n' "$target"
        else
          echo 'remote-heavy: artifact copy failed' >&2
        fi
      done < "$manifest"
    else
      echo 'remote-heavy: cannot create artifact directory' >&2
    fi
  else
    echo 'remote-heavy: artifact listing failed' >&2
  fi
fi
exit "$status"
