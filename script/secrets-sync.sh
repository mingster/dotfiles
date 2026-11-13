#!/usr/bin/env bash
# Push the credential folder from this host to every fleet host. The folder is root owned, so the push runs
# inside the root owned gate (script/secrets-gate.sh, installed by script/secrets-gate-setup.sh), which
# prints the names of changed files and never their contents.
# The plain call uses the one passwordless sudoers entry (`sync`). Flags need Touch ID or the password.
# Flag: --dry-run (list the files and hosts, needs Touch ID). There is no --delete: the receiving side only adds and
# overwrites files, so remove a retired file on each host by hand with sudo.
# A host without the gate installed is skipped with a note, so fleet-pull keeps working until the owner sets it up.
set -u
gate=${SECRETS_GATE:-/opt/secrets-gate/secrets-gate}
flags=()
for a in "$@"; do
  case "$a" in
    --dry-run) flags+=("$a") ;;
    *) echo "unknown flag $a" >&2; exit 2 ;;
  esac
done
[ -x "$gate" ] || { echo "secrets-sync: no gate at $gate, skipped (owner runs script/secrets-gate-setup.sh)"; exit 0; }
if [ "${#flags[@]}" -eq 0 ]; then
  exec sudo -n "$gate" sync
fi
exec sudo "$gate" sync "${flags[@]}"
