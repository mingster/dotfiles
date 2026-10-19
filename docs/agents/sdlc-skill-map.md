# SDLC skill map

Which role owns each SDLC stage and recurring job, which Matt Pocock skill it runs, and what was wrong before the 2026-10-12 alignment. Read it before changing a role file, the crew or tl skill, `model-routing.md`, a project `daily-run.md` or the Engineering workflow table in `.agents/claude/CLAUDE.md`.

Sources checked: the vendored skills in `.agents/skills/` (upstream `mattpocock/skills` README, its user invoked and model invoked split), `.agents/claude/CLAUDE.md`, `templates/agent-team/`, and in <project-a> and <project-b> the role files, `docs/SDLC.md`, `docs/agents/team.md`, `daily-run.md` and `lean-startup-sdlc.md`.

## Two facts that drive most fixes

1. **A `disable-model-invocation` skill runs only when named.** grill-me, grill-with-docs, handoff, implement, improve-codebase-architecture, retro, to-spec, to-tickets, triage and wayfinder carry the flag. Claude Code skips them in a role's `skills:` list (preloading draws from the skills the model may invoke) and refuses them through the Skill tool; Codex and Antigravity hide them until the prompt names them. An Orca worker spec is not a typed slash command, so the spec names the file: "read `~/.agents/skills/<name>/SKILL.md` and follow it".
2. **`skills:` preloads the whole skill on every start.** Only `claude --agent <role>` reads it; default Orca workers read the role body. So `skills:` holds the role's primary skills only, and the body names the rest with when to load them.

## Map

| Job | Owner | Skill | Our files before | Mismatch (fixed unless noted) |
| --- | --- | --- | --- | --- |
| Intake and triage of an issue | architect-pm, Elon as maintainer | `triage` (agent brief per `AGENT-BRIEF.md`) | daily run step 2: Elon reads each `needs-triage` issue and relabels it by hand | Home grown step duplicating `triage`, without its redundancy check, claim verification or agent brief |
| Intent | architect-pm | `capture-intent` (ours, no upstream equivalent) | correct | None |
| Grill | architect-pm with the owner | `grill-with-docs` (`grilling` and `domain-modeling` inside) | correct; <project-b> SDLC paired it with `to-spec` | See Spec |
| Spec | architect-pm | `write-spec` when the repo has `docs/SDLC.md`, else `to-spec` | <project-b> `fileServer/docs/SDLC.md` said `/grill-with-docs` and `/to-spec` | Wrong skill: `to-spec` publishes an issue, <project-b> commits spec files, so `write-spec` |
| Tickets | architect-pm | `to-tickets` (GitHub issues with blocking edges) | `skills: [..., to-tickets]`; role body and crew Step 1 said `tickets.md` | DMI skill in `skills:` is silently skipped; `tickets.md` contradicted `docs/SDLC.md` (issues) |
| Implement | fullstack-dev | `implement` per ticket (drives `tdd`, ends with `code-review`); `tdd` on the fast path | `tdd` only; Elon's "fast loop" ran `to-spec` on an issue that already exists | `implement` unused; `to-spec` misapplied to an existing issue |
| Bug diagnosis | qa-sdet reproduces, fullstack-dev fixes | `diagnosing-bugs`, then `tdd` | `diagnosing-bugs` preloaded on support-csm (read only, never diagnoses); hotfix "reproduce" step home grown | Skill on the wrong role; reproduce step now names the skill's feedback loop |
| Review | qa-sdet, secops-finops, lead for docs and fast path | `code-review` (fixed point the default branch, spec the ticket) | crew Step 4 and qa-sdet restated the two axes by hand | Home grown restatement; now runs the skill |
| Merge conflicts | fullstack-dev | `resolving-merge-conflicts` | named in fullstack-dev only; daily run step 4 did not | Daily run now names it |
| Architecture review | architect-pm (lead consults) | `improve-codebase-architecture`, `codebase-design` | only `codebase-design` named | Missing skill; now on architect-pm's load list. Cadence still unscheduled (open) |
| Prototype | architect-pm | `prototype` | not named anywhere | Missing skill; now on architect-pm's load list |
| Retro | Elon after a failed task | `retro` | none; owner requested `team-audit` covers team files, not a session | Missing; crew Step 4 now runs it after a task fails both remediation rounds |
| Handoff between sessions | the worker that runs out of context | `handoff` | model-routing: a "what is left" list in `worker_done`; `active_run.md` for multi slice tickets | Home grown list; now written with `handoff` and its path reported. `active_run.md` stays (it lives in the worktree, `handoff` writes to `$TMPDIR`) |
| Worker spec | Elon, lead | names the skill and its file | crew Step 2 spec had no skill field | Missing; crew Step 2 and elon.md now require it |
| Deploy | release-manager | `deploy` (ours) | correct | Unchanged by rule |

## Other fixes

* `qa-sdet` preloaded five skills its body said to load only on demand; now `[tdd, code-review]`. `secops-finops` dropped `research`, the template and <project-a> `lead` dropped `deploy` and `code-review`, for the same reason.
* `e2e-test-scaffold` exists only in <project-a>; it was named in the template and <project-b> qa-sdet. Removed there.
* dotfiles `AGENTS.md` named `implement-spec`, which is not vendored (`skills-inventory.md` explains why).
* `script/init-agent-project.sh` wrote `$to-tickets` inside an unquoted heredoc, which aborts under `set -u`; escaped, and the "Invoking skills" block now covers Claude Code. <project-a> `AGENTS.md` gained the block <project-b> already had.

## Open items closed

Closed by owner rulings (issue 73):

* `agent-team-architecture.md` and its SVGs now say GitHub issues instead of `tickets.md`; the PDF is deleted.
* `improve-codebase-architecture` gets no cadence. Owner decision: no change.
* Upstream `pr` stays unvendored; `create-pr` stays. Owner decision: no change.
* The `team-audit` default projects come from the untracked `script/team-audit.local.conf` (one real checkout per line), never a bare repo.
