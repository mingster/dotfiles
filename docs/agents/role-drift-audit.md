# Role drift audit

Read only audit of the agent role files in three places: the generic template (`~/dotfiles/templates/agent-team/.claude/`), <project-a> (`~/projects/<app>/.claude/`) and <project-b> (`~/<project-b>/.claude/`). `tech-lead.md` is skipped because another worker is editing it. `elon.md` is out of scope.

Short names: T is the template, R is <project-a>, P is <project-b>.

## How to read this

Class a means the text should differ because it is product specific (host names, ADR numbers, stack, streaming or entitlement wording, project names). Class b means real drift: one copy has a newer rule, fix or wording that the others lack. Every b row names the newest copy and the port action.

Hunks that only swap `{{PROJECT_NAME}}` for the project name (description line, "You are X on ...", worktree path) are class a. They are grouped into one row per file so the table stays readable.

Last commit times (git log -1 per file, local time):

| File | T | R | P |
| --- | --- | --- | --- |
| fullstack-dev | 10-06 02:42 | 10-06 02:41 | 10-06 02:46 |
| release-manager | 10-06 02:42 | 10-06 02:41 | 10-06 02:46 |
| qa-sdet | 10-05 14:19 | 10-05 14:19 | 10-05 15:02 |
| architect-pm | 10-05 14:19 | 10-05 14:19 | 10-05 14:56 |
| sales-marketing | 10-05 14:19 | 10-05 14:19 | 10-05 15:02 |
| secops-finops | 10-05 13:56 | 10-05 13:56 | 10-05 15:02 |
| support-csm | 10-05 14:19 | 10-05 14:19 | 10-05 15:02 |
| model-routing.md | 10-06 02:42 | 10-06 02:24 | 10-06 02:25 |

A commit time only says when the file was last touched. "Newest copy" below is decided by which copy holds the newer wording, not only by timestamp.

## fullstack-dev

| Hunk | Class | Newest copy | Recommended action |
| --- | --- | --- | --- |
| Name swaps in description, intro and worktree path (T vs R) | a | n/a | None. |
| R: `bun test --isolate <path>` in the targeted testing line | a | n/a | None. Bun is the <project-a> test runner. |
| R: `.claude/bin/env-peek.py web/.env.local DATABASE_URL` and `<app>_dev` in the DB check | a | n/a | None. Template deliberately says "the masked env check named in AGENTS.md". |
| Changelog line: T says "one new file `changelog.d/<issue>-<short-slug>.md` (or `<branch-slug>.md` with no issue) holding only the entry line(s), never edit CHANGELOG.md in a PR". R and P keep the older "read CHANGELOG.md with limit: 5 for the format" wording | b | T | Port the T wording (no issue fallback, "never edit CHANGELOG.md in a PR") to R. Port the same to P, keeping P's `<component>/changelog.d/` path. |
| T changelog line has a typo: "Update update living design notes" | b | T has the typo, R and P do not | Fix the double "update" in T. Do not port to R or P. |
| R and P have a stray blank line before or after the changelog bullet (R line 34, P line 21) | b | T is clean | Remove the blank lines in R and P so the bullet list stays one block. |
| P: description and body describe web2, backend | a | n/a | None. |
| P: intro adds "You run on Codex by default ... the `model:` line applies only under Claude Code ... Never rules and strike rule are yours to keep" | a | n/a | None, but see the next row for the cost gate. |
| P: drops the **Cost Gate (10 Turns)** bullet | b | T | Port the 10 turn cost gate to P. A Codex worker has no hooks, so this rule matters more there, not less. |
| P: `tools:` has no `SendMessage` (same on every P role) | b | T | Add `SendMessage` to every P role `tools:` line, or write one line in P `AGENTS.md` saying why Codex roles omit it. It is not documented today. |
| P: Token Saver says "Read memory only on demand" instead of `learned.md` | a | n/a | None. |
| P: stack list (Next.js 16, Prisma, `_test` DB, PayPal only, Roku 5.9, ADR 0005, 0015, 0018) | a | n/a | None. |
| P: hotfix line says "Suspend other work" instead of "current work" | a | n/a | None. Wording only. |
| P: secondary skills list is shorter (only `resolving-merge-conflicts`) | a | n/a | None. P does not ship those skills. |
| P Never: "default branches" instead of `main`, no "Never edit intents, accepted specs, or ADR decisions" | b | T | Port the "Never edit intents, accepted specs, or ADR decisions" rule to P. |
| P Never: "_test databases" rule instead of local dev DB check | a | n/a | None. |

## release-manager

| Hunk | Class | Newest copy | Recommended action |
| --- | --- | --- | --- |
| Name swaps in description and intro | a | n/a | None. |
| R: `<app>_dev`, `playground.<project-a>`, `store.<project-a>` | a | n/a | None. |
| Staging step: T has the full changelog step (run `bin/changelog-compile.sh` on an up to date `main`, commit "chore: compile changelog fragments" on a branch, open a PR, `gh pr merge --merge`, then promote). R has only "starts by compiling `changelog.d` fragments". P has "see /deploy staging step 0" | b | T | Port the T changelog steps to R. Port to P with the `<component>/changelog.d/` path and keep the pointer to `/deploy staging` step 0. |
| P: description names `<project-b>_op/bin/deploy-stage.sh` | a | n/a | None. |
| P: Local step is "Local & Component Checks" against `_test` DBs | a | n/a | None. |
| P: drops the exact smoke handoff messages (`Ready for qa-sdet smoke check: staging <sha>`, `Ready for owner to approve production: <sha>`) | b | T | Port both message formats to P. |
| P: production step uses the 15:00 to 17:00 Asia/Taipei window | a | n/a | None. |
| P: "Escalate failed promotions" (drops "production") and "Draft rollback steps" (drops "per /deploy skill") | b | T | Port "per `/deploy` skill" to P. The "production" word is cosmetic, port it too for consistency. |
| P: `Memory and routing ... Read memory only on demand` | a | n/a | None. |
| P Never: drops "Never expose secrets in logs or terminal outputs. Use `.claude/bin/env-peek.py`" and adds "no migrations or schema pushes on production" | b | T | Port the secrets rule to P (P already has `.claude/bin/env-peek.py`). Keep P's migration rule. |
| P: `tools:` has no `SendMessage` | b | T | Same fix as the fullstack-dev row. |
| Template gap: T Never section points to `.claude/bin/env-peek.py`, but T `bin/` only has `state-of-play.sh` | b | R and P ship the script | Copy `env-peek.py` from R (or P) into `templates/agent-team/.claude/bin/`, or soften the T rule. |

## qa-sdet

| Hunk | Class | Newest copy | Recommended action |
| --- | --- | --- | --- |
| Name swaps in description and intro (T vs R). R has no other difference | a | n/a | None. R is in sync with T. |
| P: `skills:` is `[tdd, code-review]`, T has `[tdd, code-review, diagnosing-bugs, e2e-test-scaffold, agent-browser]`. P body still says those three load on demand | b | P (15:02) | Treat P as the better shape: the body already says on demand. Port the shorter list to T and R, or add the three back to P. Pick one and make all three match. |
| P: `tools:` has no `SendMessage` | b | T | Same fix as the fullstack-dev row. |
| P: "enforce system boundaries" and no Multi-Tenant Boundary Tests bullet | a | n/a | None. <project-b> has no store tenancy. |
| P: Standards axis mentions session rules, Spec axis adds Roku 5.9 backwards compatibility | a | n/a | None. |
| P: review line drops "Never rely on teammate claims" and `main...<branch>` becomes `<default>...<branch>` | b | T | Port "Never rely on teammate claims" to P. The `<default>` wording is fine as is. |
| P: smoke check is "read-only checks on live endpoints", T uses `agent-browser` on sign in, storefront, checkout | a | n/a | None. |
| P: `bun test --isolate` dropped in two places, Never rule says "outside test files" with no paths | a | n/a | None. Paths are R specific. |
| P: "Read memory only on demand" and "playback regressions" wording | a | n/a | None. |

## architect-pm

| Hunk | Class | Newest copy | Recommended action |
| --- | --- | --- | --- |
| Name swap in description (T vs R) | a | n/a | None. |
| R: spec line adds `docs/intent/<YYYY-MM-DD>-<slug>/` and "Zero-Env: never put raw secrets in specs" | b | R and P both have the Zero-Env sentence, T lacks it | Port the Zero-Env sentence to T. Keep the R path as is, because it is R specific. |
| P: `tools:` has no `SendMessage` | b | T | Same fix as the fullstack-dev row. |
| P: description and intro add <project-b>, "subscriber pain points" | a | n/a | None. |
| P: intent and spec paths under `fileServer/docs/intent/` and `fileServer/docs/specs/`, Roku 5.9 and Android compatibility | a | n/a | None. |
| P: Capture Intent drops "Gather user pain points from support and sales. Use `capture-intent`" | b | T | Port the "use `capture-intent`" and "gather pain points from support and sales" text to P. P names the skill for specs but not for intents. |
| P: tickets line names `web2`, `streaminator`, `player` | a | n/a | None. |
| P: extra blank line near line 18 | b | T | Remove the stray blank line in P. Cosmetic. |

## sales-marketing

| Hunk | Class | Newest copy | Recommended action |
| --- | --- | --- | --- |
| Name swaps (T vs R) | a | n/a | None. |
| R: `<APP>_AGENT_RO_URL` instead of "the read only database URL named in AGENTS.md" | a | n/a | None. |
| P: `skills: [research]` removed, `tools:` has no `SendMessage` | b | T | Add `skills: [research]` back to P (body still says load `research` on demand) and fix `SendMessage` as above. |
| P: description and intro focus on subscribers, trials, live events | a | n/a | None. |
| P: Positioning drops "Ground every claim in verified product behavior" and "Self-Serve Acquisition" becomes "Conversion & Experiments" | b | T | Port "Ground every claim in verified product behavior" to P. Keep the trial conversion framing. |
| P: Metric Definitions drops "Label unavailable metrics as unknown. Never invent estimates." | b | T | Port that sentence to P. It is the honesty rule for numbers. |
| P: Data inputs use `<project-b>_op/bin/agent-sql.sh` and <project-b> tables | a | n/a | None. |
| P: drops the **Churn Analysis** bullet (partner with `support-csm`) and adds the **Taiwan Live Event Calendar** bullet | b | T for churn, P for events | Port Churn Analysis to P. Keep the Events bullet in P only. |
| P: report line says "engineering dependencies", reads `fileServer/docs/agents/learned.md`, "reconcile churn and finances" | a | n/a | None. |
| P: artifacts path and weekly summary list (trial conversions) | a | n/a | None. |
| P Never: adds "extend trials, pay affiliates, create coupons" and drops "alter live pricing", "production tables" | a | n/a | None. Meaning is covered by "write to database tables" and "alter pricing". |

## secops-finops

| Hunk | Class | Newest copy | Recommended action |
| --- | --- | --- | --- |
| Name swaps (T vs R) | a | n/a | None. |
| R: `<APP>_AGENT_RO_URL` | a | n/a | None. |
| P: `skills:` is `[code-review]`, T has `[code-review, research]`. Body still says load `research` on demand | b | T | Add `research` back to the P `skills:` line. |
| P: `tools:` has no `SendMessage` | b | T | Same fix as the fullstack-dev row. |
| P: tenancy and safe-action rules replaced with session limits (ADR 0015, 0018) and PayPal only | a | n/a | None. |
| P: drops the **rate limit** bullet (unauthenticated endpoints, OTP, SMS, email senders) | b | T | Port a rate limit bullet to P and point it at the real <project-b> abuse doc. P has a public sign in and pairing flow, so this applies. |
| P: finance bullets use PayPal, `agent-sql.sh`, Stripe check | a | n/a | None. |
| P: cost bullet is streaming edge, CDN, server and database | a | n/a | None. |
| P: drops the privacy compliance bullet (Taiwan PDPA, GDPR, data residency) and the "validate sales-marketing inputs" bullet | b | T | Port a privacy line to P. <project-b> bills Taiwan subscribers, so PDPA applies. Keep the independent check against marketing numbers (P already says "independently of marketing forecasts"). |
| P: secondary skills line mentions "compliance standards or external payment gateways" | a | n/a | None. |
| P Never: drops "rotate production secrets" and "modify infrastructure" becomes "alter production infrastructure" | b | T | Port "rotate production secrets" to P. |

## support-csm

| Hunk | Class | Newest copy | Recommended action |
| --- | --- | --- | --- |
| Name swaps and mailbox `support@<project-a>` (T vs R) | a | n/a | None. |
| R: `<APP>_AGENT_RO_URL` | a | n/a | None. |
| P: `skills: [diagnosing-bugs]` removed, `tools:` has no `SendMessage` | b | T | Add `skills: [diagnosing-bugs]` back to P (body says load on demand) and fix `SendMessage` as above. |
| P: mailbox `support@5ik.tv`, "subscriber" wording, prices in USD | a | n/a | None. |
| P: escalates severe bugs straight to `architect-pm`, `qa-sdet` and `tech-lead`, and sends channel requests straight to `architect-pm` and churn to `sales-marketing`. T and R route all of it through Elon. The same P file still says in step 3 that requests go to Elon, who routes them | b | P is the newest file (15:02) but contradicts itself | Port the T routing (severe bugs and requests go to Elon, who routes) to P. If the owner wants direct escalation, change step 3 to match and update T and R too. Needs an owner decision. |
| P: ingestion list drops "store admin and sysAdmin" and the `psql` read | a | n/a | None. |
| P: FAQ rule drops ">= 2 times in a month", adds ">= 5 requests" for channels | a | n/a | None. |
| P: Closure Notices drop "After `qa-sdet` and `release-manager` confirm" | b | T | Port the confirmation condition to P. Without it support could draft closure notices before QA confirms. |
| P: severe bug examples use playback and TV pairing | a | n/a | None. |
| P Never: "extend subscriptions" | a | n/a | None. |

## model-routing.md

| Hunk | Class | Newest copy | Recommended action |
| --- | --- | --- | --- |
| Light row: T says "changelog fragment lines", R and P say "changelog lines" | b | T | Port "fragment" to R and P. Wording only. |
| Fallback line 19: P adds "(below)" | b | P | Port "(below)" to T and R. Cosmetic. |
| Line 50: P uses absolute repo paths and adds "Use the absolute path, so the worker reads the role file on the main checkout, not a stale copy in its own branch", and also reads `AGENTS.md` (Token budget) | b | P | Port the stale copy warning to T and R, using the repo root path of each repo. This is a real fix. A worker in a branch worktree could read an old role file. |
| Line 62: T names the worktree location `~/orca/workspaces/<project>`, R and P omit it | b | T | Port the worktree path hint to R and P. |
| Line 74: P says fallback order "starting at the role's default provider and wrapping around (fullstack-dev: Codex, Cursor, Antigravity, Claude)", T and R say a flat Claude, Codex, Cursor, Antigravity order | b | P | Port the wrap around wording to T and R. For T, keep the fullstack-dev example as a placeholder or drop it. |
| Line 80: P says "the role's default provider again", T and R say "the preferred provider again" | b | P | Port "the role's default provider" to T and R. The default provider table already exists in all three. |

## Summary

Hunk counts by class:

| File | a | b |
| --- | --- | --- |
| fullstack-dev | 10 | 6 |
| release-manager | 6 | 6 |
| qa-sdet | 6 | 3 |
| architect-pm | 4 | 4 |
| sales-marketing | 7 | 4 |
| secops-finops | 6 | 5 |
| support-csm | 7 | 3 |
| model-routing.md | 1 | 6 |
| Total | 47 | 37 |

Top five class b items to fix first:

1. model-routing.md line 50 (P): stale role file warning and absolute path, missing in T and R.
2. model-routing.md lines 74 and 80 (P): fallback starts at the role's default provider, missing in T and R.
3. support-csm (P): routes severe bugs and requests around Elon, and drops the QA and release confirmation before closure notices. Owner decision needed.
4. release-manager (R, P): older changelog compile step. Port the T step. Also T is missing `env-peek.py` in `bin/`.
5. P frontmatter drift on all roles: `SendMessage` and `skills:` lines dropped, plus the dropped cost gate and Never rules in fullstack-dev, secops-finops and release-manager.
