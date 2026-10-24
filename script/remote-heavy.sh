#!/usr/bin/env bash
# Run a heavy job (tsc, bun test, Playwright) for the current commit on a remote host.
#
#   remote-heavy.sh --host <ssh host> --repo-dir <remote checkout> --dir <remote worktree>
#                   [--sub <subdir>] [--weight N] [--gate <remote heavy-gate.sh>]
#                   [--fetch <worktree-relative path/glob> ... --into <local dir>] -- <command>
#
# Sends HEAD to the remote checkout as refs/heavy/<sha> (never to origin), checks it out
# detached in the remote worktree, reinstalls packages when the lockfile changed, and runs
# the command under the remote heavy-gate. Exit status is the command's. A missing
# --dir is created as a detached worktree of --repo-dir.
# Fetches use remote Python 3 globbing and OpenSSH scp (SFTP); files land by basename
# in --into, so select unique artifact names when fetching from multiple directories.
set -euo pipefail

# shellcheck disable=SC2016 # expanded on the remote host
host="" repo_dir="" dir="" sub=. weight=1 gate='$HOME/dotfiles/script/heavy-gate.sh'
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
git push -q "ssh://$host/$repo_dir" "$sha:refs/heavy/$sha"

cmd=$(printf '%q ' "$@")
b64() { printf '%s' "$1" | base64 | tr -d '\n'; }
# The remote login shell may not be bash (fish eats a heredoc on stdin), so the script
# and every argument travel as base64 inside one plain word list.
remote=$(cat <<'REMOTE'
set -euo pipefail
d() { printf '%s' "$1" | base64 -d; }
dir=$(d "$1") sha=$(d "$2") sub=$(d "$3") weight=$(d "$4") gate=$(d "$5") cmd=$(d "$6") repo_dir=$(d "$7")
gate="${gate/#\$HOME/$HOME}"
export PATH="$HOME/.bun/bin:$HOME/.asdf/shims:$PATH" LANG="${LANG:-en_US.UTF-8}"
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
exec "$gate" --weight "$weight" -- bash -c "$cmd"
REMOTE
)
status=0
# shellcheck disable=SC2029
ssh "$host" bash -c "\"\$(echo $(b64 "$remote") | base64 -d)\"" remote-heavy \
  "$(b64 "$dir")" "$(b64 "$sha")" "$(b64 "$sub")" "$(b64 "$weight")" "$(b64 "$gate")" "$(b64 "$cmd")" "$(b64 "$repo_dir")" || status=$?

if [ "${#fetches[@]}" -gt 0 ]; then
  # Use the same shell-independent transport for remote glob expansion. NUL records
  # keep whitespace and newlines in filenames intact, separate from command output.
  listing=$(cat <<'REMOTE'
set -euo pipefail
d() { printf '%s' "$1" | base64 -d; }
dir=$(d "$1")
shift
patterns=()
for encoded in "$@"; do patterns+=("$(d "$encoded")"); done
# Python is also required by heavy-gate; glob supports ** on older remote Bash.
python3 - "$dir" "${patterns[@]}" <<'PYTHON'
import glob, os, sys
os.chdir(sys.argv[1])
for pattern in sys.argv[2:]:
    for path in glob.iglob(pattern, recursive=True):
        if os.path.isfile(path):
            sys.stdout.buffer.write(os.fsencode(path) + b'\0')
PYTHON
REMOTE
)
  encoded_fetches=()
  for pattern in "${fetches[@]}"; do encoded_fetches+=("$(b64 "$pattern")"); done
  if ! manifest=$(mktemp); then
    echo 'remote-heavy: cannot create artifact manifest' >&2
    exit "$status"
  fi
  trap 'rm -f "$manifest"' EXIT
  # shellcheck disable=SC2029
  if ssh "$host" bash -c "\"\$(echo $(b64 "$listing") | base64 -d)\"" remote-heavy-fetch \
      "$(b64 "$dir")" "${encoded_fetches[@]}" > "$manifest"; then
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
