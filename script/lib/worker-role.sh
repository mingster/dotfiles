#!/usr/bin/env bash
# Shared by worker-startup.sh and start-cursor-worker.sh: the role parse and the "Worker role:" stamp (#1328).

role_from_title() { # "#<issue>|<role>" or the old "<role> - <job>" -> role; anything else prints nothing
  local title=$1 role
  case "$title" in
    "#"[0-9]*"|"*) role=$(printf "%s" "${title#*|}" | cut -d"|" -f1) ;;
    *" - "*) role=${title%% - *} ;;
    *) return 0 ;;
  esac
  case "$role" in
    *[!a-z0-9-]*) return 0 ;;
    [a-z]*) printf '%s\n' "$role" ;;
  esac
}

# First line of the brief copy: "Worker role: <role>" from the title, the one role every dispatch path sets (#1328).
# A leading stamp is replaced, never doubled. No parsed role means no stamp. A same task retry sends no spec, so the stored brief keeps its stamp.
stamp_worker_role() { # <spec_file> <title> [fallback_role] -> prints the stamped copy's path
  local spec_file=$1 title=$2 role out
  role=$(role_from_title "$title" || true)
  [ -n "$role" ] || role=${3:-}
  if [ -z "$role" ]; then
    printf '%s\n' "$spec_file"
    return 0
  fi
  out=$(mktemp "${WORKER_BRIEF_DIR:-${TMPDIR:-/tmp}}/worker-startup-role.XXXXXX") || { echo "cannot write the spec copy" >&2; return 1; }
  {
    printf 'Worker role: %s\n' "$role"
    sed '/^Worker role: [a-z0-9-]*$/d' "$spec_file"
  } >"$out"
  printf '%s\n' "$out"
}
