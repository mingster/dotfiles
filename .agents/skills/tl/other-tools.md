# Running the team outside Claude Code (Cursor, Antigravity)

Loaded by the Tech Lead only when it cannot spawn a named teammate and message it. Split out of `.claude/agents/tech-lead.md` so Claude Code lead sessions do not carry it.

The roles, task list, hotfix loop and gates are the same; only the mechanics change, because those tools have no named teammates, mailbox or shared task list. You are in this mode when you cannot spawn a named teammate and message it.

- **Task list.** Keep the same six tasks (or the hotfix chain) in the tool's own todo or task list, with the owner role in each title.
- **Roles.** Cursor loads `.claude/agents/` as subagents: run each task through the subagent of the same name, and independent tasks in parallel. Antigravity has no subagents: take one task at a time, read `.claude/agents/<role>.md` first, follow it, and say which role you are acting as. The owner may instead open one Antigravity agent per role with "act as `.claude/agents/<role>.md`".
- **Messaging.** There is no mailbox, so you relay. A role puts each message it would have sent in its final report, addressed to its recipient; you deliver it by starting that role's task with the artifact it names.
- **Tools.** Cursor ignores the `tools:` line, so a read only role is held only by its Never section. Check that its result wrote nothing it should not have.
- **Skills.** When a skill cannot be loaded by name, read its `SKILL.md` from `.agents/skills/`, `.cursor/skills/` or `~/.agents/skills/`.

## CEO reporting without a mailbox

Load the canonical shared CEO role in `.claude/agents/elon.md` for an explicit review of business priorities, material risk or cross-role trade-offs, then return to the Tech Lead role. `.claude/agents/ceo.md` is only a legacy compatibility alias. Routine small tasks do not require a separate CEO startup or review step. Routine delivery/support reports address the Tech Lead (`lead`); relay its consolidated delivery report to Elon (`elon`). Sales addresses commercial outcomes and SecOps independent risk to Elon; technical handoffs copy lead. Preserve critical/suppressed-concern escalations in the session, visible to CEO/owner. Owner-facing replies may use Taiwan Traditional Chinese or English without mirroring the owner. CEO recommendations never replace human owner approvals.
