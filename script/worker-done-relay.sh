#!/usr/bin/env bash
# Route a builder worker_done to the lead that owns the dispatch, and release the committer once.
#   worker-done-relay.sh relay --dispatch ID --branch B --sha S --payload PATH --coordinator HANDLE
#   worker-done-relay.sh release --dispatch ID
# Owner record: $WORKER_DONE_OWNER_DIR/<dispatch id> (default ~/.claude/state/dispatch-owners) holds the
# owning lead's terminal handle on one line. No record, or an empty one, sends to the coordinator.
# A successful release writes <dispatch id>.released, so a second release does nothing.
set -euo pipefail
orca=${ORCA_CLI_COMMAND:-orca}
dir=${WORKER_DONE_OWNER_DIR:-$HOME/.claude/state/dispatch-owners}
die() { echo "worker-done-relay: $*" >&2; exit 2; }

[ $# -ge 1 ] || die "usage: relay|release --dispatch ID ..."
mode=$1; shift
dispatch="" branch="" sha="" payload="" coordinator=""
while [ $# -gt 0 ]; do
  [ $# -ge 2 ] || die "$1 needs a value"
  case "$1" in
    --dispatch) dispatch=$2 ;; --branch) branch=$2 ;; --sha) sha=$2 ;;
    --payload) payload=$2 ;; --coordinator) coordinator=$2 ;;
    *) die "unknown argument $1" ;;
  esac
  shift 2
done
[[ "$dispatch" =~ ^[A-Za-z0-9_-]+$ ]] || die "--dispatch must be a plain id"

case "$mode" in
  relay)
    [ -n "$branch" ] && [ -n "$sha" ] && [ -n "$payload" ] && [ -n "$coordinator" ] \
      || die "relay needs --branch, --sha, --payload and --coordinator"
    to=""
    [ ! -f "$dir/$dispatch" ] || to=$(head -n 1 "$dir/$dispatch" | tr -d '[:space:]')
    subject="worker_done $dispatch"
    if [ -z "$to" ]; then
      to=$coordinator
      subject="worker_done $dispatch (no recorded owning lead)"
    fi
    here=$(cd "$(dirname "$0")" && pwd)
    exec "$here/orca-reply.sh" --to "$to" --subject "$subject" \
      --body "dispatch=$dispatch branch=$branch sha=$sha payload=$payload"
    ;;
  release)
    [ ! -f "$dir/$dispatch.released" ] || exit 0
    "$orca" orchestration worker-release --dispatch "$dispatch" --json
    mkdir -p "$dir" && : > "$dir/$dispatch.released"
    ;;
  *) die "mode must be relay or release" ;;
esac
