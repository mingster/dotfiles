# Running the team outside Claude Code (Cursor, Antigravity, Codex)

Loaded by Elon only when running outside Orca orchestration, in a tool that cannot spawn a named teammate and message it. Under Orca orchestration every provider's worker gets the same preamble, `ask` and `worker_done`, so this relay mode is not needed. Split out of `.claude/agents/tech-lead.md` so Claude Code lead sessions do not carry it.

The roles, task list, hotfix loop and gates are the same; only the mechanics change, because those tools have no named teammates, mailbox or shared task list. You are in this mode when you cannot spawn a named teammate and message it.

- **Task list.** Keep the same daily run tasks (`docs/agents/daily-run.md`) or the hotfix chain in the tool's own todo or task list, with the owner role in each title.
- **Roles.** Cursor loads `.claude/agents/` as subagents: run each task through the subagent of the same name, and independent tasks in parallel. Antigravity has no subagents: take one task at a time, read `.claude/agents/<role>.md` first, follow it, and say which role you are acting as. The owner may instead open one Antigravity agent per role with "act as `.claude/agents/<role>.md`".
- **Messaging.** There is no mailbox, so you relay. A role puts each message it would have sent in its final report, addressed to its recipient; you deliver it by starting that role's task with the artifact it names. Preserve tiered routing: routine specialists to lead, lead and Sales-Marketing to CEO, independent SecOps oversight to CEO, technical findings to lead. Relay critical escalation directly to CEO and the human owner (the one exception to reporting through Elon); never treat CEO advice as approval.
- **Tools.** Cursor ignores the `tools:` line, so a read only role is held only by its Never section. Check that its result wrote nothing it should not have.
- **Codex.** It reads `AGENTS.md` only, not `.claude/agents/`. Start each worker in its own Orca worktree, tell it to read `.claude/agents/<role>.md` first, and choose the model in Codex's own selector. There is no mailbox, so relay messages as for Cursor.
- **Strike rule.** The strike hook runs only in Claude Code. In these tools the strike rule in `AGENTS.md` is the only guard, so keep it there.
- **Moving a task between providers.** Under Orca orchestration rerun the Task with `worker-start --task <task_id> --agent <provider>`. For an unsupervised transfer you start yourself, use the `orca-cli` handoff. When and where to switch is in `.claude/model-routing.md` (Fallback).
- **Front door.** Claude Code starts as Elon through settings. In Cursor, Codex and Antigravity run `/elon` first, then delegate as described here. Teammates report to Elon only.
- **Skills.** When a skill cannot be loaded by name, read its `SKILL.md` from `.agents/skills/` or `~/.agents/skills/`.

## Reporting without a mailbox

Elon is the session, so every report already comes to Elon. Outside Orca orchestration a role puts each message it would have sent in its final report, addressed to its recipient, and Elon delivers it by starting that role's next task.

## Where each tool finds skills

| Tool | Project skills | User skills |
| --- | --- | --- |
| Claude Code | `.claude/skills/` (symlinks into `.agents/skills/`) | `~/.claude/skills` (dotfiles `.agents/skills`) |
| Codex | `.agents/skills/` | `~/.agents/skills` (dotfiles) |
| Cursor | `.cursor/skills/` (symlinks into `.agents/skills/`) | `~/.claude/skills` (dotfiles; Cursor reads it, so dotfiles makes no `~/.cursor/skills`) |
| Antigravity | `.agents/skills/` | `~/.gemini/config/skills.json` points at dotfiles `.agents/skills` |

The real directory lives in `.agents/skills/<name>/`. Every other tool gets a symlink to it. The team skills (`crew`, `tl`, `deploy`, `elon`, `ceo`) are generated from dotfiles `templates/agent-team/.agents/skills/` by `~/dotfiles/script/sync-team-skills.sh`; never edit them here, edit dotfiles and re-run the sync (`--check` reports drift). General skills (`tdd`, `code-review`, `orchestration` and the rest) come only from `~/.claude/skills` and `~/.agents/skills`, never a project copy. To add a project-only skill: create the directory there, then `ln -s ../../.agents/skills/<name> .claude/skills/<name>` and the same under `.cursor/skills/`. `script/check-skill-collisions.sh` in dotfiles flags a project skill that shadows a central one.
