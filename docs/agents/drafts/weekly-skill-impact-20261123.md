# Weekly skill impact (20261123)

Report only. No role or team file edits by this script.

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
