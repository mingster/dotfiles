#!/usr/bin/env bash
# Run a heavy job (tsc, bun test, Playwright) for the current commit on a remote host.
#
#   remote-heavy.sh --host <ssh host> --repo-dir <remote checkout> --dir <remote worktree>
#                   [--sub <subdir>] [--weight N] [--gate <remote heavy-gate.sh>] -- <command>
#
# Sends HEAD to the remote checkout as refs/heavy/<sha> (never to origin), checks it out
# detached in the remote worktree, reinstalls packages when the lockfile changed, and runs
# the command under the remote heavy-gate. Exit status is the command's.
set -euo pipefail

# shellcheck disable=SC2016 # expanded on the remote host
host="" repo_dir="" dir="" sub=. weight=1 gate='$HOME/dotfiles/script/heavy-gate.sh'
while [ $# -gt 0 ]; do
  case "$1" in
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

sha=$(git rev-parse HEAD)
git push -q "ssh://$host/$repo_dir" "$sha:refs/heavy/$sha"

cmd=$(printf '%q ' "$@")
b64() { printf '%s' "$1" | base64 | tr -d '\n'; }
# The remote login shell may not be bash (fish eats a heredoc on stdin), so the script
# and every argument travel as base64 inside one plain word list.
remote=$(cat <<'REMOTE'
set -euo pipefail
d() { printf '%s' "$1" | base64 -d; }
dir=$(d "$1") sha=$(d "$2") sub=$(d "$3") weight=$(d "$4") gate=$(d "$5") cmd=$(d "$6")
gate="${gate/#\$HOME/$HOME}"
export PATH="$HOME/.bun/bin:$HOME/.asdf/shims:$PATH" LANG="${LANG:-en_US.UTF-8}"
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
# shellcheck disable=SC2029
ssh "$host" bash -c "\"\$(echo $(b64 "$remote") | base64 -d)\"" remote-heavy \
  "$(b64 "$dir")" "$(b64 "$sha")" "$(b64 "$sub")" "$(b64 "$weight")" "$(b64 "$gate")" "$(b64 "$cmd")"
