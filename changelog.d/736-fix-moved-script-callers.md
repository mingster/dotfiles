Weekly update, the sync drift precheck, skill impact report and test selection now call `agent-team.sh` instead of the retired adopt, init and sync scripts, which fixes the failing role word budget test.

The weekly update only runs `agent-team.sh check` on projects and never adopts or writes into them (`WEEKLY_UPDATE_SYNC_PROJECTS` is gone). The retired autoinit SessionStart hook is removed from the Claude Code settings, since `agent-team.sh` has no equivalent.
