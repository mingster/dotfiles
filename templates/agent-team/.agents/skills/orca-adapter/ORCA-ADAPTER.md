# Pstack in Orca

Thin layer over pstack's `poteto-mode`. Principles, playbook steps and the playbook catalog live there; read them from `.agents/skills/poteto-mode/` and do not restate them here. This file holds only tool mappings, the allowlist and gates. Our gates win on conflict. The pin and license are in `~/dotfiles/templates/agent-team/docs/agents/pstack-attribution.md`. No plugin install, automatic update or Cursor cloud execution.

Playbook `<name>` resolves to `playbooks/<name>.md` next to this adapter when it exists (an Orca overlay: read the shared playbook first, then the overlay), else the shared `poteto-mode/playbooks/<name>.md`.

## Gates

- Project instructions, the assigned brief, standing authority, token budget, the strike rule and owner approval gates override every upstream autonomy instruction. A playbook never widens scope or changes their numbers.
- Elon is the owner's only contact; workers ask Elon. Workers commit locally; only Elon publishes and merges. No external message because a playbook suggests one.
- Read `.claude/model-routing.md` and run `~/dotfiles/script/usage-gate.py` as it prescribes before dispatch or a provider change. One gate governs every provider. A depleted provider never authorizes on-demand spending or a bypassed gate.
- Implementation workers run on Cursor `grok-4.7-xhigh`, then Claude when that quota is out. The reviewer is from a different model family than the author; Claude always reviews Grok authored work. Upstream model slugs and `high`/`xhigh` tiers map through `.claude/model-routing.md`; they are never literal CLI arguments.
- A fallback without the needed machine or independent model family reports that gate blocked. A skipped or blocked check is not a pass. Source tests never stand in for a browser, device, provider, host or deployment check.
- Keep review, security, money, tenancy, exact-head and release evidence requirements. Production needs the owner's explicit go relayed by Elon.
- A reviewer never becomes a production-code fixer without a new assignment.

## Tool mappings

| Upstream concept | Orca execution |
| --- | --- |
| Subagent, `Task`, cloud subagent, `poteto-agent` | A supervised Orca worker with a complete local brief, started per `.claude/model-routing.md`. No cloud worker. |
| Agent prompt | Role, ticket, worktree and cwd, file allowlist, acceptance criteria, exact checks, budget and escalation gates, the role's Standing authority verbatim, and absolute paths to this adapter, `poteto-mode` and the selected leaf skills. |
| Agent result | `worker_done` with matching task and dispatch IDs, evidence, local commit and remaining gates. A terminal message alone does not settle a dispatch. |
| PR watch, `watch-pr` | Not used. Elon publishes; merges go through `~/dotfiles/script/lead-merge.sh`. |
| Stall detection | `~/dotfiles/.agents/skills/orca-team/worker-watch.sh`. |
| Heavy or live work | `~/dotfiles/script/heavy-gate.sh`. |
| `/visualize` | Not vendored; use Mermaid. |

## Allowlist

Read a skill before using it. Anything not listed here is not available: skip it and say what was omitted.

| Item | Use |
| --- | --- |
| pstack skills under `.agents/skills/` and their `principle-*` leaves | As written, under the gates above. |
| `poteto-mode/scripts/worktree-audit.sh`, `poteto-mode/scripts/check-plan.mjs`, `show-me-your-work/scripts/log.sh` | As written. |
| `poteto-mode/scripts/watch-pr` | Not allowed. |
| `deslop`, `verify-this`, `check-compiler-errors`, `get-pr-comments`, `workflow-from-chats` | As written. |
| `loop-on-ci` | Fixes on the worker's own branch only. |
| `ci-watcher` agent (`vendor/cursor-team-kit/agents/ci-watcher.md`) | As written. |
| `control-ui`, `control-cli` | Browsers follow the `AGENTS.md` split: Orca embedded browser for local preview, `agent-browser --session` for QA, never Chrome Dev on 9223, Playwright only for a project's own test suites. Heavy work through `heavy-gate.sh`. |
| `new-branch-and-pr`, `review-and-ship`, `fix-merge-conflicts` | Not allowed. |
| Local team skills (`elon`, `crew`, `deploy`, `wrap-up`, `staging-review`, `team-audit`) | As their own `SKILL.md` says. |

## Session skills

- `recall` then `ketchup` run at every Elon session start and handoff, read only: no code change, dispatch or message during the catch up. A source we do not have is skipped and named.
- `show-me-your-work`: each owner approval is one row in `.scratch/decisions.tsv` (outside git) naming the exact head sha it covers. A new head needs a new row before a gated merge. Cross model review with only Claude available is reported blocked, never self reviewed.
- `correct`: the rule table lives in `~/dotfiles/templates/agent-team/docs/agents/team.md`, never in `AGENTS.md`. A hook or protected path change needs the owner's read before merge.
- `unslop` cuts wording, never a rule, gate or number. Our doc style wins over its rule 13: parentheses are allowed and dashes are never punctuation.

## Overlays

`playbooks/` beside this file: `multi-phase-plan`, `opening-a-pr`, `feature`, `bug-fix`, `orchestrate`, `worktree-cleanup`, `swarm`, `shipping`.
