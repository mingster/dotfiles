# architect-pm work reference

## Work

- **Unit contract:** one body/comment has `## Acceptance criteria` (observable cases and proving command), `Requirement owner: <requester and reason>` and `Deleted: <removed requirement or nothing, because ...>`. evidence and predicate also define done.


- **Ready queue:** keep at least 3 `ready-for-agent` units ahead of the coordinator; when fewer remain, tell the coordinator and start the next spec or triage round (2026-10-22: builds sat idle on an empty queue).
- **Triage:** run the `triage` skill (`~/.agents/skills/triage/SKILL.md`) on each `needs-triage` issue the coordinator hands you, the coordinator acting as maintainer; every `ready-for-agent` issue gets its agent brief.
- **Competing prototypes:** before building 2 or 3, send the coordinator the options and cost; it asks the user in Chinese and proceeds only on an explicit yes. Zero-Env: no raw secrets in specs.
- **Caller usage first:** when a spec touches a shared module (wallet or ledger, notifications, auth or permissions, any lib others call), its first Design section shows the caller's usage, then types and signatures, then the module map.
- **Risk checklist, not a review:** the spec keeps a short checklist (tenancy, money, auth, data deletion). secops-finops and cross-family review read the first built slice, not the abstract spec.
- **Test plan and test cases** (user rule 2026-10-21): every spec has a `## Test plan` section of numbered Functional test cases, one or more per requirement; every unit lists the cases it owns. A unit is done when its listed tests pass, shown as an observable result (command output, screenshot, DB row), never only "tests pass". Never put Regression (the full suite) in a plan or unit.
- **Shared input rule (user rule 2026-10-28):** phone, email and amount entry in a spec uses the shared component that normalizes pasted text. A spec that adds a new raw input for these is sent back (pasted dashes were cut).
- **State matrix rule (user rule 2026-10-28):** every flow spec lists each state (for example signed out, signed in, linked, failure) as a row with one test case each in its `## Test plan`; a missing state needs a one line reason (a happy path once hid a sign-in link loop).
- **Design tier at triage:** label each `ready-for-agent` issue with one of `design:none`, `design:review` (cross-family review of the built diff), `design:architect` (usage-first sketch plus review), `design:arena` (competing sketches, user approval). Run triage and routine specs at medium effort; use high only for `design:architect` and `design:arena`.
- **Redesign on request:** the coordinator may return a unit after 2 failed correction passes on the same premise.
