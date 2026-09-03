## General

Do not tell me I am right all the time. Be critical. We're equals. Try to be neutral and objective.

Do not excessively use emojis.

Prefer using browser agent skill over using playwright directly.

## Writing docs / README

Never use dashes (— or -) as punctuation in documentation or README files. Rephrase sentences using periods, commas, or parentheses instead.

## Coding Standards

When working with Laravel/PHP projects, always use the php-guidelines-from-spatie skill.

## Spreadsheet Files

For `.xlsx` updates, use the Mescius SpreadJS XLSX Editor when available. Use programmatic XLSX editing only for batch or precision changes.

## Using GitHub

For questions about GitHub, use the gh tool
Never mention Claude Code in PR descriptions, PR comments, or issue comments
Do not include a "Test plan" section in PR descriptions

## Agent instruction files

`AGENTS.md` at the repo root is the single source. `CLAUDE.md` beside it holds one line, `@AGENTS.md`, because Claude Code does not read `AGENTS.md`. Same in a subdirectory: `web/CLAUDE.md` is `@../AGENTS.md`, and `web/AGENTS.md` is a symlink to `../AGENTS.md`.

Keep `AGENTS.md` under 200 lines. It loads into every session, so it holds the map and the rules that are always true: layout, commands, constraints, pointers. Anything that only matters in one area goes in `docs/agents/<topic>.md` behind a pointer that names when to read it ("Read it before changing X"). Anything derivable from the codebase goes in neither. More `@` imports do not help, since imported files load at launch too.

Never accumulate learnings in `AGENTS.md`. Auto memory owns those.

Full convention and rationale: `~/dotfiles/docs/agents/agent-files.md`.

## Engineering workflow

Default path for any non-trivial feature, refactor, or bug. Run the stages in order and name the stage you are in.

| Stage | Skill | What it does |
|-------|-------|--------------|
| 1. Grill | `/grill-with-docs` | Interview me one question at a time to surface edge cases and align the design with the codebase, before writing any code. Produces ADRs and a glossary as a side effect. |
| 2. Spec | `/to-spec` | Synthesize the agreed plan into a spec on the issue tracker. No second interview, just what we already settled. |
| 3. Tickets | `/to-tickets` | Break the spec into tracer bullet vertical slices, each small enough to implement inside a fresh context window, with blocking edges declared. |
| 4. Implement | `/tdd` | Strict red, green, refactor. One failing test first, then the minimum code that passes it. |
| 5. Review | `/code-review` | Check the diff against this repo's coding standards and against the originating spec, in parallel sub-agents. |

Escape hatches, because the full loop is overkill for small work:

- A one line fix, a typo, a config tweak: go straight to `/tdd`, or straight to the edit if no behaviour changes.
- A change we already discussed in depth this session: start at `/to-spec`.
- A single slice that needs no decomposition: skip `/to-tickets`.

Whenever you skip a stage, say which one and why in a single line. Do not skip stage 5.

### Per repo setup

Stages 2, 3, and 5 read `docs/agents/` in the repo you are working in: `issue-tracker.md`, `triage-labels.md`, `domain.md`. Every repo needs that once.

If you reach stage 2 in a repo where `docs/agents/issue-tracker.md` does not exist, stop and set it up before continuing. Two ways:

- `~/dotfiles/script/init-agent-project.sh --labels` from the repo root. Deterministic, seeds the three files from the templates, appends the `## Agent skills` block, creates the triage labels on the GitHub remote. Safe to re-run, it never overwrites an existing file.
- `/setup-matt-pocock-skills` when the repo needs judgement instead: a monorepo layout, a tracker that is not GitHub or GitLab, or existing conventions to merge with.

Prefer the script. Fall back to the skill when it does not fit.

Related skills, invoked on demand rather than as part of the loop: `/grilling` (stress test an idea with no doc output), `/research` (gather context first), `/triage` (move issues through the triage state machine), `/retro` (review how a session went and feed it back into these instructions).

## 1. Think Before Coding

State assumptions explicitly. If uncertain, ask.

If multiple interpretations exist, present them, don't pick silently. If a simpler approach exists, say so. Push back when warranted.

If something is unclear, stop. Name what's confusing. Ask. This is deliberately stricter than "only ask when it changes the work": I would rather be asked.

## 2. Simplicity First

Minimum code that solves the problem. Nothing speculative.

- No features beyond what was asked.
- No abstractions for single-use code.
- No "flexibility" or "configurability" that wasn't requested.
- No error handling for impossible scenarios.
- If you write 200 lines and it could be 50, rewrite it.

## 3. Surgical Changes

Touch only what you must. Clean up only your own mess.

- Don't "improve" adjacent code, comments, or formatting.
- Don't refactor things that aren't broken.
- Match existing style, even if you'd do it differently.
- If you notice unrelated dead code, mention it, don't delete it.
- Remove imports/variables/functions that YOUR changes made unused. Leave pre-existing dead code alone unless asked.

The test: every changed line should trace directly to my request.

## 4. Goal-Driven Execution

Turn every task into a verifiable goal before starting, and let `/tdd` own the loop that gets there. "Add validation" becomes a failing test for invalid input. "Fix the bug" becomes a test that reproduces it. "Refactor X" becomes a green suite before and after.

For multi-step work, state the plan with one verification check per step, then run the red, green, refactor loop until each check passes.

## Cursor Rules

When working in a workspace that contains a `.cursor/rules` directory, always search or view the files in that directory (e.g. using `list_dir` or reading `.cursor/rules/README.md`) to find relevant `.mdc` files. Follow all constraints and guidelines defined in those rule files for the specific files/patterns you are editing.
