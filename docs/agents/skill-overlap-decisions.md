# Skill ownership and overlap decisions

Audit date: 2026-10-13. Base: `b402114`. Scope: all skills in `templates/agent-team/.agents/skills/` and every shared skill outside the protected sets below. This is a source audit, not a run of the skills against product repositories.

## Provenance and comparison set

The current shared tree has 31 skills. Commit `b712943` synced the Matt Pocock set to `49dd158`; the later manifest `.agents/skills/.mattpocock-upstream`, introduced in `bac9d34`, lists 21 names. History also identifies `resolving-merge-conflicts` as vendored in `c566eac`, although the sync manifest omits it. All 22 vendored skills and their local patches are protected by this task; repairing the sync manifest is outside this edit.

| Source | Skills compared against every owned skill |
| --- | --- |
| Matt Pocock, 22 vendored skills | `code-review`, `codebase-design`, `diagnosing-bugs`, `domain-modeling`, `grill-me`, `grill-with-docs`, `grilling`, `handoff`, `implement`, `improve-codebase-architecture`, `prototype`, `research`, `resolving-merge-conflicts`, `retro`, `setup-matt-pocock-skills`, `tdd`, `to-spec`, `to-tickets`, `triage`, `wayfinder`, `wizard`, `writing-for-agents` |
| Orca installed guides, from `orca skills list` and `orca skills get` | `orchestration`, `orca-cli`, `computer-use`, `orca-per-workspace-env`, `orca-linear`, `linear-tickets` (legacy alias), `orca-emulator`, `orca-emulator-android` |
| Protected team tooling | `orca-team`, including all pane and watch helpers |

The shared `orca-cli`, `computer-use` and `orca-per-workspace-env` files are Orca discovery stubs, so they are protected too. `orchestration` is installed by Orca and no longer tracked here. Although dotfiles owns `orca-team`, the dispatch explicitly excludes it from edits.

This leaves five shared skills and seven team skills, all listed below. `agent-browser` and the Laravel reference count as owned under the dispatch's definition even though their content came from other sources. No protected files changed.

## Decision table

Each row was compared with the full set above and the other owned skills. The overlap column lists the procedural matches; candidates not listed have a different job or only share ordinary safety and evidence rules.

| Owned skill | Decision | Duplicated steps or closest comparison | Result and unique behavior retained |
| --- | --- | --- | --- |
| Shared `agent-browser` | Slim | Orca CLI browser and computer use both inspect, interact and inspect again. | Route embedded Orca pages to `orca-cli` and native windows to `computer-use`. Keep the standalone CLI reference, sessions, interception and recording because the commands and runtime differ. |
| Shared `capture-intent` | Slim | Numbered question rounds, recommendations and fact lookup repeat `grilling`. `to-spec` instead writes a solution spec. | Call `grilling` for the interview. Keep the problem only boundary, owner wording, intent template, acceptance history and freeze rule. |
| Shared `create-pr` | Slim | Its review checklist repeats `code-review`; compile error diagnosis belongs to `diagnosing-bugs`; team shipping authority is already in model routing. | Call those skills when needed and route team publication to Elon. Keep branch preparation, build and repository checks, changelog hooks, commit scope and the owner's PR body rules. No vendored skill publishes this kind of PR; upstream `pr` is not vendored. |
| Shared `laravel-inertia-react-structure` | Keep | `codebase-design` covers interface depth; `prototype` covers disposable experiments. Neither defines Laravel frontend paths or naming. | Keep the framework directory, component, import and stylesheet conventions. |
| Shared `write-spec` | Slim | Interview rounds and inline domain records repeat `grill-with-docs`, `grilling` and `domain-modeling`. `to-spec` publishes tracker specs with a different template. | Call `grill-with-docs`. Keep the accepted intent prerequisite, adjacent file template, owner acceptance and frozen pair. Replacing it with `to-spec` would change storage and acceptance behavior. |
| Team `ceo` | Keep | Same entry point as `elon`, already implemented as a pointer. | Keep the single body line forwarding arguments so `/ceo` continues to work. |
| Team `elon` | Keep | Delivery already calls `crew`; role identity already points to the role file. | Keep the front door and routes for company status and the project daily run. No second lifecycle remains here. |
| Team `crew` | Slim | Run creation, dispatch, task fields, wait, retries, worker completion and cleanup repeat `orchestration`; panes repeat `orca-team`; contracts repeat `to-tickets`; review axes repeat `code-review`. | Delegate those procedures. Keep role ownership, the usage gate pointer, wave cap, role and skill paths in worker specs, local evidence, risk based reviewers, remediation limit, local integration and Elon's merge on completion policy. Use `handoff`, `retro` and `resolving-merge-conflicts` at their respective gates. |
| Team `teddy` and its relay reference | Slim | Delivery selection and worker launch repeat `crew` and `orchestration`; provider transfer repeats `orca-cli`. | Call the respective skills. Keep engineering status, the daily run alias, role entry, terminal shortcut and relay behavior outside Orca. |
| Team `deploy` | Slim | Creating and removing Orca worktrees repeats `orca-cli`. `orca-per-workspace-env` provisions disposable runtimes, not release stages. | Call `orca-cli` for Orca worktrees. Keep stage status gates, exact commit approval, smoke ownership, database guards, release timing, dependency cycle and rollback rules. |
| Team `grill-backlog` | Slim | Interview already calls `grilling`, but decision comments and label commands still duplicate its tracker section. Evaluation belongs to `triage`; dispatch belongs to `crew`. | Delegate those steps. Keep backlog collection, the owner action categories, letter choices, release batching and queue completion condition. |
| Team `team-audit` | Slim | General duplication and instruction critique repeat `writing-for-agents`; session improvement analysis belongs to `retro`. | Call those skills. Keep deterministic team checks, authority precedence, invocation evidence and template drift checks. |

Result: 9 slim, 3 keep, 0 merge, 0 remove. No command alias or sync list needs removal. `script/sync-team-skills.sh` discovers the seven template directories rather than carrying a fixed list. The retained `ceo` pointer is already the result of the earlier alias consolidation.

## Boundaries checked

The simulator skills and Linear adapter have no matching implementation in our skills. GitHub backlog collection is not a copy of Linear transport operations. The deployment pipeline does not provision Orca runtime recipes. No wrapper repeats `wayfinder` decision maps, `wizard` scripts, `research` reports, architecture reports or prototypes.

The wrappers call Matt Pocock skills by name and name the file when a harness may hide a skill. Orca lifecycle commands come from the installed guide. Team policy remains in the project facts and model routing. Workers retain local commits; Elon retains PR publication and merge on completion. The existing release manager exception for stage branch promotion and exact production approval remains in `deploy` and model routing.

## Validation and handoff

Branch: `mingster/dotfiles-skilldedupe`.
Worktree: `~/orca/workspaces/dotfiles/dotfiles-skilldedupe`.

| Check | Result |
| --- | --- |
| `DOTFILES="$PWD" bash script/check-skill-collisions.sh templates/agent-team` | Pass, all seven team skills, no collisions or broken links |
| `bash script/tests/sync-team-skills.test.sh` | Pass, 20 assertions |
| Actual template sync into a temporary Git project, then `--check` | Pass, seven generated skills and 14 valid tool links |
| Collision scan against that temporary project | Pass |
| `bash script/shellcheck-dotfiles.sh` | Pass, five install entrypoints |
| Protected file diff | Pass, all 22 Matt Pocock skills, Orca stubs, helpers and manifest unchanged |
| README lifecycle commands | Pass, all 15 named skills exist |
| Changed skill pointers and crew section references | Pass, targets retained and Step 0 through Step 5 preserved |
| Added prose punctuation and `git diff --check` | Pass, no dash punctuation or whitespace errors |

No skill was removed, so there are no removed skill references to repair. Existing Step 0 through Step 5 references to crew still resolve. The `ceo`, `elon`, `teddy` and relay file paths remain valid. Product adoption and sync into <project-a> or <project-b> are left to Elon after merge.
