# shellcheck shell=bash
# hooks_changed <file>...: true when a hook, brief-lint.sh or checks-local.sh is among the files (#1200).
# Only those can break the hook tests and check-guard-false-positives.sh, which take about a minute.
hooks_changed() {
  local f
  for f in "$@"; do
    case "$f" in
      templates/agent-team/.claude/hooks/*|.claude/hooks/*|script/brief-lint.sh|script/checks-local.sh) return 0 ;;
    esac
  done
  return 1
}
