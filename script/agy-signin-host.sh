#!/usr/bin/env bash
# Usage: agy-signin-host.sh <host>
# Sign a host in to agy where its Orca workers run (#1967). A sign in over ssh runs outside the host's
# login session, so the agy an Orca worker starts never sees it. This opens an Orca terminal titled
# agy-signin on the host running agy, never ssh, and prints its handle. The owner finishes the browser
# step in that Orca pane and quits agy. Then one `agy models` probe runs in another Orca terminal on
# the host: on "in" the host's agy-unavailable mark is cleared.
# <host> is an Orca environment name, or `local` for this host (no --environment flag).
# Exit 0 when the probe says signed in, 1 when it does not, 2 on misuse.
# Env: ORCA_CLI_COMMAND, AGY_SIGNIN_HOST_WAIT_MS (sign in wait, default 15 minutes).
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
orca=${ORCA_CLI_COMMAND:-orca}
case "${1:-}" in -h|--help) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;; esac
[ $# -eq 1 ] && [ -n "$1" ] || { echo 'Usage: agy-signin-host.sh <host>' >&2; exit 2; }
host=$1
env_args=()
[ "$host" = local ] || env_args=(--environment "$host")
# shellcheck disable=SC2016
agy='"$HOME/dotfiles/bin/agy"'

# The main worktree first: a remote refuses a terminal without one (start-remote-worker.sh).
worktree=$("$orca" worktree list ${env_args[@]+"${env_args[@]}"} --json 2>/dev/null | python3 -c '
import json, sys
rows = json.load(sys.stdin)["result"]["worktrees"]
rows = [r for r in rows if not r.get("isArchived") and r.get("path")]
rows.sort(key=lambda r: not r.get("isMainWorktree"))
print("path:" + rows[0]["path"] if rows else "")' 2>/dev/null) || worktree=
[ -n "$worktree" ] || { echo "agy-signin-host: no worktree on $host for the sign in terminal" >&2; exit 1; }

open_terminal() { # <title> <command>; prints the handle
  "$orca" terminal create ${env_args[@]+"${env_args[@]}"} --worktree "$worktree" --title "$1" --command "$2" --json 2>/dev/null \
    | python3 -c 'import json, sys; print(json.load(sys.stdin)["result"]["terminal"]["handle"])' 2>/dev/null || true
}

signin=$(open_terminal agy-signin "$agy; exit")
[ -n "$signin" ] || { echo "agy-signin-host: could not open an Orca terminal on $host" >&2; exit 1; }
echo "agy-signin-host: terminal $signin on $host runs agy."
echo "agy-signin-host: finish the browser sign in in that Orca pane, then quit agy there."
"$orca" terminal wait ${env_args[@]+"${env_args[@]}"} --terminal "$signin" --for exit \
  --timeout-ms "${AGY_SIGNIN_HOST_WAIT_MS:-900000}" --json >/dev/null 2>&1 || true

probe=$(open_terminal agy-signin-probe "$agy models; exit")
[ -n "$probe" ] || { echo "agy-signin-host: could not open the probe terminal on $host" >&2; exit 1; }
trap '"$orca" terminal close ${env_args[@]+"${env_args[@]}"} --terminal "$probe" --json >/dev/null 2>&1 || true' EXIT
"$orca" terminal wait ${env_args[@]+"${env_args[@]}"} --terminal "$probe" --for exit --timeout-ms 12000 --json >/dev/null 2>&1 || true
result=$("$orca" terminal read ${env_args[@]+"${env_args[@]}"} --terminal "$probe" --screen --json 2>/dev/null \
  | python3 "$here/agy-signin.py" probe-result || true)
case "$result" in
  in) python3 "$here/agy-signin.py" clear "$host"
      echo "agy-signin-host: $host is signed in to agy; its mark is cleared."; exit 0 ;;
  out) echo "agy-signin-host: $host is still signed out of agy." >&2; exit 1 ;;
  *) echo "agy-signin-host: the probe on $host gave no answer; run it again." >&2; exit 1 ;;
esac
