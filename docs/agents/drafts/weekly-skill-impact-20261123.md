# Weekly skill impact (20261123)

Report only. No role or team file edits by this script.

## pstack template skills

### Diff stat

```
 script/.pstack-template-upstream                   |   2 +-
 .../agent-team/.agents/.claude-plugin/plugin.json  |   2 +-
 templates/agent-team/.agents/README.md             |  15 +-
 .../agent-team/.agents/agents/comment-sicko.md     |   2 +-
 .../agent-team/.agents/agents/poteto-agent.md      |   1 +
 .../agent-team/.agents/docs/guide/01-setup.md      |   6 +-
 .../.agents/docs/guide/02-poteto-mode.md           |  10 +-
 .../agent-team/.agents/docs/guide/03-understand.md |   6 +-
 .../agent-team/.agents/docs/guide/04-design.md     |  16 +-
 .../.agents/docs/guide/05-build-and-clean.md       |   2 +-
 .../.agents/docs/guide/06-verify-and-ship.md       |   4 +-
 .../agent-team/.agents/docs/guide/07-overnight.md  |   8 +-
 .../.agents/docs/guide/09-make-it-yours.md         |   2 +-
 .../.agents/docs/guide/10-recipes-and-pitfalls.md  |   2 +-
 .../agent-team/.agents/docs/harness/claude-code.md |   7 +-
 templates/agent-team/.agents/plugin.json           |   2 +-
 .../agent-team/.agents/skills/architect/SKILL.md   |  72 +-------
 .../architect/references/design-red-flags.md       |  57 ------
 .../architect/references/rationale-template.md     |  35 ----
 .../skills/architect/references/runner-prompt.md   |  20 --
 templates/agent-team/.agents/skills/arena/SKILL.md |   4 +-
 .../agent-team/.agents/skills/automate-me/SKILL.md |   2 +-
 .../.agents/skills/benchmark-checklist/SKILL.md    |   2 +-
 .../.agents/skills/blast-radius/SKILL.md           |   4 +-
 .../.agents/skills/figure-it-out/SKILL.md          |   2 +-
 templates/agent-team/.agents/skills/how/SKILL.md   |  27 +--
 .../skills/how/references/explainer-prompt.md      |  55 ------
 .../skills/how/references/explorer-prompt.md       |  35 ----
 .../agent-team/.agents/skills/no-comments/SKILL.md |   4 +-
 .../agent-team/.agents/skills/poteto-help/SKILL.md |  11 +-
 .../agent-team/.agents/skills/poteto-mode/SKILL.md |  94 +++-------
 .../skills/poteto-mode/playbooks/autonomous-run.md |   2 +-
 .../skills/poteto-mode/playbooks/autopilot-full.md |   2 +-
 .../poteto-mode/playbooks/autopilot-stack.md       |   2 +-
 .../skills/poteto-mode/playbooks/babysit.md        |  29 +--
 .../skills/poteto-mode/playbooks/bug-fix.md        |   6 +-
 .../.agents/skills/poteto-mode/playbooks/eval.md   |   2 +-
 .../skills/poteto-mode/playbooks/feature.md        |   6 +-
 .../skills/poteto-mode/playbooks/hillclimb.md      |   4 +-
 .../skills/poteto-mode/playbooks/investigation.md  |   4 +-
 .../poteto-mode/playbooks/multi-phase-plan.md      | 154 +---------------
 .../skills/poteto-mode/playbooks/opening-a-pr.md   |  31 +---
 .../skills/poteto-mode/playbooks/orchestrate.md    |  25 ---
 .../skills/poteto-mode/playbooks/perf-issue.md     |   4 +-
 .../skills/poteto-mode/playbooks/refactoring.md    |   6 +-
 .../poteto-mode/playbooks/runtime-forensics.md     |   2 +-
 .../skills/poteto-mode/playbooks/session-pickup.md |   2 +-
 .../skills/poteto-mode/playbooks/shipping.md       |   2 +-
 .../poteto-mode/playbooks/trace-forensics.md       |   2 +-
 .../poteto-mode/playbooks/worktree-cleanup.md      |   2 +-
 .../skills/poteto-mode/scripts/check-plan.mjs      | 205 ---------------------
 .../skills/poteto-mode/scripts/check-plan.test.ts  | 110 -----------
 .../skills/poteto-mode/scripts/package.json        |   2 +-
 .../skills/principle-attack-the-premise/SKILL.md   |  14 +-
 .../skills/principle-boundary-discipline/SKILL.md  |  27 +--
 .../skills/principle-build-the-lever/SKILL.md      |  21 +--
 .../skills/principle-explain-the-number/SKILL.md   |  14 +-
 .../skills/principle-fix-root-causes/SKILL.md      |  17 +-
 .../principle-foundational-thinking/SKILL.md       |  14 +-
 .../principle-make-operations-idempotent/SKILL.md  |  15 +-
 .../skills/principle-minimize-reader-load/SKILL.md |  13 +-
 .../skills/principle-model-the-domain/SKILL.md     |  17 +-
 .../skills/principle-prove-it-works/SKILL.md       |  17 +-
 .../SKILL.md                                       |   9 +-
 .../principle-sequence-verifiable-units/SKILL.md   |  10 +-
 .../SKILL.md                                       |  12 +-
 .../principle-type-system-discipline/SKILL.md      |  12 +-
 .../agent-team/.agents/skills/recall/SKILL.md      |   6 +-
 .../agent-team/.agents/skills/reflect/SKILL.md     |  62 +------
 .../reflect/references/divergent-reviewer.md       |  38 ----
 .../skills/reflect/references/judgment-reviewer.md |  37 ----
 .../skills/reflect/references/synthesizer.md       |  56 ------
 .../skills/reflect/references/tooling-reviewer.md  |  48 -----
 .../.agents/skills/setup-pstack/SKILL.md           |  52 +++---
 .../agent-team/.agents/skills/sharpen/SKILL.md     |   2 +-
 .../.agents/skills/show-me-your-work/SKILL.md      |   2 +-
 .../agent-team/.agents/skills/statechart/SKILL.md  |   2 +-
 .../skills/statechart/scripts/backends/mermaid.ts  |  58 +++++-
 .../skills/statechart/scripts/frontends/dot.ts     |   5 +-
 .../.agents/skills/statechart/scripts/run.ts       |  59 ++++--
 .../skills/statechart/scripts/statechart.ts        |  27 +--
 .../skills/statechart/scripts/test/chart.test.ts   |  43 +++++
 .../skills/statechart/scripts/test/cli.test.ts     |  70 +++++--
 .../skills/statechart/scripts/test/corpus.test.ts  |  38 ++++
 .../statechart/scripts/test/corpus/Login/chart.mmd |   3 +-
 .../skills/statechart/scripts/test/labels.ts       |  27 +--
 .../statechart/scripts/test/messages.test.ts       |  14 ++
 .../skills/statechart/scripts/test/render.test.ts  |  64 +++++++
 templates/agent-team/.agents/skills/swarm/SKILL.md |   2 +-
 templates/agent-team/.agents/skills/teach/SKILL.md |   2 +-
 .../.agents/skills/technical-writing/SKILL.md      | 102 ++++------
 .../agent-team/.agents/skills/unslop/SKILL.md      |  78 +++-----
 templates/agent-team/.agents/skills/why/SKILL.md   |  95 +---------
 .../.agents/skills/why/references/epistemics.md    |  71 -------
 .../skills/why/references/investigator-prompt.md   |  84 ---------
 .../skills/why/references/source-playbook.md       |  17 --
 .../why/references/sources/code-archaeology.md     |  51 -----
 .../skills/why/references/sources/databricks.md    |  70 -------
 .../skills/why/references/sources/datadog.md       |  97 ----------
 .../why/references/sources/incident-postmortem.md  |   5 -
 .../skills/why/references/sources/linear.md        |  48 -----
 .../skills/why/references/sources/notion.md        |  55 ------
 .../skills/why/references/sources/sentry.md        |  66 -------
 .../.agents/skills/why/references/sources/slack.md |  17 --
 .../skills/why/references/synthesizer-prompt.md    | 129 -------------
 105 files changed, 628 insertions(+), 2401 deletions(-)
```

### Skills in state

  - architect
  - arena
  - automate-me
  - benchmark-checklist
  - blast-radius
  - bro
  - check-compiler-errors
  - control-cli
  - control-ui
  - correct
  - create-formal-verification-skill
  - create-verification-skill
  - deslop
  - figure-it-out
  - fix-ci
  - fix-merge-conflicts
  - get-pr-comments
  - how
  - in-your-own-words
  - interrogate
  - ketchup
  - ketchup-video
  - loop-on-ci
  - maintain-formal-verification-skill
  - maintain-verification-skill
  - make-bot-ui
  - make-pr-easy-to-review
  - new-branch-and-pr
  - no-comments
  - poteto-help
  - poteto-mode
  - pr-review-canvas
  - principle-attack-the-premise
  - principle-boundary-discipline
  - principle-build-the-lever
  - principle-encode-lessons-in-structure
  - principle-exhaust-the-design-space
  - principle-experience-first
  - principle-explain-the-number
  - principle-fix-root-causes
  - principle-foundational-thinking
  - principle-guard-the-context-window
  - principle-laziness-protocol
  - principle-make-operations-idempotent
  - principle-migrate-callers-then-delete-legacy-apis
  - principle-minimize-reader-load
  - principle-model-the-domain
  - principle-never-block-on-the-human
  - principle-outcome-oriented-execution
  - principle-prove-it-works
  - principle-redesign-from-first-principles
  - principle-separate-before-serializing-shared-state
  - principle-sequence-verifiable-units
  - principle-subtract-before-you-add
  - principle-test-behavior-not-implementation
  - principle-the-algorithm
  - principle-type-system-discipline
  - recall
  - reflect
  - review-and-ship
  - run-smoke-tests
  - setup-pstack
  - sharpen
  - show-me-your-work
  - statechart
  - swarm
  - tdd
  - teach
  - technical-writing
  - thermo-nuclear-code-quality-review
  - typescript-best-practices
  - unslop
  - verify-this
  - weekly-review
  - what-did-i-get-done
  - why
  - workflow-from-chats

### Citation map

  - `docs/agents/skills-inventory.md` cites `poteto-mode`
  - `docs/agents/team-reference.md` cites `poteto-mode`
  - `templates/agent-team/.claude/agents/architect-pm.md` cites `poteto-mode`
  - `templates/agent-team/.claude/agents/elon.md` cites `poteto-mode`
  - `templates/agent-team/.claude/agents/fullstack-dev.md` cites `poteto-mode`
  - `templates/agent-team/.claude/agents/qa-sdet.md` cites `poteto-mode`
  - `templates/agent-team/.claude/agents/release-manager.md` cites `poteto-mode`
  - `templates/agent-team/.claude/agents/sales-marketing.md` cites `poteto-mode`
  - `templates/agent-team/.claude/agents/secops-finops.md` cites `poteto-mode`
  - `templates/agent-team/.claude/agents/support-csm.md` cites `poteto-mode`
  - `templates/agent-team/.agents/skills/elon/SKILL.md` cites `poteto-mode`
  - `docs/agents/skills-inventory.md` cites `benchmark-checklist`
  - `templates/agent-team/.claude/agents/fullstack-dev.md` cites `benchmark-checklist`
  - `templates/agent-team/.agents/skills/orca-adapter/ORCA-ADAPTER.md` (local Orca adapter)

### Gaps and conflicts

  - Playbook paths may still say `pstack/skills/...`; compare with ORCA-ADAPTER.md.

### Recommended owner actions

  - Run `agent-team.sh sync` on projects after merging the pstack PR.

## Matt Pocock vendored skills

### Diff stat

```
 .agents/skills/.mattpocock-local.patch | 115 +++++++++++++++++++++++++++++++++
 .agents/skills/.mattpocock-upstream    |   2 +-
 2 files changed, 116 insertions(+), 1 deletion(-)
```

### Changed paths

  - .agents/skills/.mattpocock-upstream
  - .agents/skills/.mattpocock-local.patch (adds the 20 label triage-labels.md and the AGENT-BRIEF.md rule/guide section, which upstream does not carry)

### Citation map

  - `docs/agents/sdlc-skill-map.md` cites `code-review`
  - `docs/agents/skills-inventory.md` cites `code-review`
  - `docs/agents/team-reference.md` cites `code-review`
  - `.agents/claude/CLAUDE.md` cites `code-review`
  - `docs/agents/sdlc-skill-map.md` cites `codebase-design`
  - `docs/agents/skills-inventory.md` cites `codebase-design`
  - `docs/agents/sdlc-skill-map.md` cites `diagnosing-bugs`
  - `docs/agents/skills-inventory.md` cites `diagnosing-bugs`
  - `.agents/claude/CLAUDE.md` cites `diagnosing-bugs`
  - `docs/agents/sdlc-skill-map.md` cites `domain-modeling`
  - `docs/agents/skills-inventory.md` cites `domain-modeling`
  - `docs/agents/sdlc-skill-map.md` cites `grill-me`
  - `docs/agents/skills-inventory.md` cites `grill-me`
  - `.agents/claude/CLAUDE.md` cites `grill-me`
  - `docs/agents/sdlc-skill-map.md` cites `grill-with-docs`
  - `docs/agents/skills-inventory.md` cites `grill-with-docs`
  - `docs/agents/team-reference.md` cites `grill-with-docs`
  - `.agents/claude/CLAUDE.md` cites `grill-with-docs`
  - `docs/agents/sdlc-skill-map.md` cites `grilling`
  - `docs/agents/skills-inventory.md` cites `grilling`
  - `docs/agents/team-reference.md` cites `grilling`
  - `.agents/claude/CLAUDE.md` cites `grilling`
  - `docs/agents/sdlc-skill-map.md` cites `handoff`
  - `docs/agents/skills-inventory.md` cites `handoff`
  - `.agents/claude/CLAUDE.md` cites `handoff`
  - `docs/agents/sdlc-skill-map.md` cites `implement`
  - `docs/agents/skills-inventory.md` cites `implement`
  - `.agents/claude/CLAUDE.md` cites `implement`
  - `docs/agents/sdlc-skill-map.md` cites `improve-codebase-architecture`
  - `docs/agents/skills-inventory.md` cites `improve-codebase-architecture`
  - `.agents/claude/CLAUDE.md` cites `improve-codebase-architecture`
  - `docs/agents/sdlc-skill-map.md` cites `prototype`
  - `docs/agents/skills-inventory.md` cites `prototype`
  - `.agents/claude/CLAUDE.md` cites `prototype`
  - `docs/agents/skills-inventory.md` cites `research`
  - `docs/agents/team-reference.md` cites `research`
  - `.agents/claude/CLAUDE.md` cites `research`
  - `docs/agents/sdlc-skill-map.md` cites `retro`
  - `docs/agents/skills-inventory.md` cites `retro`
  - `.agents/claude/CLAUDE.md` cites `retro`
  - `docs/agents/skills-inventory.md` cites `setup-matt-pocock-skills`
  - `.agents/claude/CLAUDE.md` cites `setup-matt-pocock-skills`
  - `docs/agents/sdlc-skill-map.md` cites `to-spec`
  - `docs/agents/skills-inventory.md` cites `to-spec`
  - `docs/agents/team-reference.md` cites `to-spec`
  - `.agents/claude/CLAUDE.md` cites `to-spec`
  - `docs/agents/sdlc-skill-map.md` cites `to-tickets`
  - `docs/agents/skills-inventory.md` cites `to-tickets`
  - `docs/agents/team-reference.md` cites `to-tickets`
  - `.agents/claude/CLAUDE.md` cites `to-tickets`
  - `templates/agent-team/.claude/agents/architect-pm.md` cites `to-tickets`
  - `docs/agents/sdlc-skill-map.md` cites `triage`
  - `docs/agents/skills-inventory.md` cites `triage`
  - `docs/agents/team-reference.md` cites `triage`
  - `.agents/claude/CLAUDE.md` cites `triage`
  - `templates/agent-team/.claude/agents/architect-pm.md` cites `triage`
  - `templates/agent-team/.claude/agents/elon.md` cites `triage`
  - `templates/agent-team/.claude/agents/support-csm.md` cites `triage`
  - `docs/agents/sdlc-skill-map.md` cites `wayfinder`
  - `docs/agents/skills-inventory.md` cites `wayfinder`
  - `.agents/claude/CLAUDE.md` cites `wayfinder`
  - `docs/agents/skills-inventory.md` cites `wizard`
  - `docs/agents/skills-inventory.md` cites `writing-for-agents`

### Gaps and conflicts

  - `resolving-merge-conflicts` is vendored locally but is not in `.mattpocock-upstream` skills=; upstream sync never touches it.
  - Upstream skills not vendored include `implement-spec` and `pr` (see skills-inventory.md).

### Recommended owner actions

  - Re-run team-audit on affected projects if behavior skills changed.
  - Update `.mattpocock-local.patch` if apply fails on the next sync.
