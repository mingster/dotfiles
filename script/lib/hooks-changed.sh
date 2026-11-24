# shellcheck shell=bash
# hooks_changed <file>...: true when a hook, the shared DB guard, team.md, brief-lint.sh or checks-local.sh is among the files (#1200).
# Only those can break the hook tests and check-guard-false-positives.sh, which take about a minute.
# team.md and the shared DB guard are in because test_team_role_grants.py checks each role grant against its guard (#1747).
hooks_changed() {
  local f
  for f in "$@"; do
    case "$f" in
      templates/agent-team/.claude/hooks/*|.claude/hooks/*|script/brief-lint.sh|script/checks-local.sh|script/check-shared-db-write.py|script/check-shared-db-write.test.sh|templates/agent-team/docs/agents/team.md) return 0 ;;
    esac
  done
  return 1
}
