---
name: staging-review
description: Page by page review of the staging site after a deploy. Elon sends one reviewer per area through every page (function, wording in each locale, layout at the target devices), then architect-pm and sales-marketing grill the findings into ready-for-agent tickets on disjoint files, and the tech-lead builds them at full fleet. Use with /staging-review, "review staging page by page", or after a staging deploy when the owner asks for a review round.
---

# Staging review

Run by Elon. Goal: find what is broken, unclear or badly worded on staging, and turn it into tickets the fleet can build in parallel, without the owner. Repeat in rounds; each round reviews the latest deploy.

Product facts (staging URL, demo store, sign-in helper, areas, devices, locales, Owner-Reserved list) come from the project's `docs/agents/staging-review.md`. If that file is missing, write it first from the project's deploy and team docs.

## 0. Before

- Staging runs the latest main (the `deploy` skill). Read its build sha and name the round `<date>-<sha8>`.
- Make a round folder outside the repo (the project file names the parent). Briefs, findings, screenshots and grill files go there.
- Round 2 and later: give each reviewer the previous round's findings for its area. It first rechecks what was fixed since, then reviews the pages changed since the last round sha (`git diff --stat <last sha>..<sha> -- <area paths>`), then the rest.

## 1. Review (one worker per area)

Split the app into the areas the project file lists, one read only worker each, roles as the project file says (product areas architect-pm, public and marketing pages sales-marketing). Each gets its own browser session: a unique CDP port and a unique `AGENT_BROWSER_SESSION`, never the owner's browser ports. Start reviewers only while the host load gate allows; when a deploy-critical worker needs the host, pause a reviewer first.

Brief, in English, per area:

```
Role: <role> (read .claude/agents/<role>.md). Staging page by page review, round <round>, no code.
Your area: <area and its source paths>. Act as <customer | store staff | platform operator> on <devices>.
Staging only: <staging URL>, never production. Browser: your own agent-browser, CDP port <port>, AGENT_BROWSER_SESSION=<name>. Sign in with the project's sign-in helper (it never prints the password; never read the secrets directory).
Page list: build it from the route files under your area so no page is skipped.
For each page: loads with no error and no console error; every button, form, filter, tab and dialog does what it says (create, edit, delete only your own test rows, named "QA-<round>"); empty, error and long text states; wording in every locale reads native (switch locale on each page); layout at each device size; links and back navigation; anything a first-time user would not understand.
Output: <round folder>/findings-<area>.md, one line per finding: URL | P0-P3 | broken, wording, layout, missing, confusing | what you saw | proposed fix. Screenshots <area>-<n>.png beside it. Search open issues first and cite the number instead of a duplicate. Do not file issues.
Rules: no code, no commits, no heartbeats, never touch production, never press maintenance or destructive platform controls, never change other stores or platform settings, never message real customers, sandbox payments and test cards only. Close your browser at the end. Finish within 60 minutes; if the area is larger, cover the P0 paths first and list the pages not reached.
worker_done: counts per severity, top 10 findings, pages not reached, the findings file path.
```

A P0 (data loss, payment wrong, sign-in or checkout broken) goes to the tech-lead as a hotfix at once, before the grill.

## 2. Grill (architect-pm and sales-marketing)

When every findings file is in, start both roles on the same input:

```
Role: <role>. Peer grill on the round <round> staging findings, no code.
Input: every findings-*.md in <round folder>.
1. Challenge the other role's findings: real (recheck on staging with your own browser session if unsure), right severity, smallest fix, duplicate of an open issue. Write grill-<role>.md in the folder; answer the other role's challenges once.
2. Group the agreed findings into tickets, one per independent fix on disjoint files so many workers run at once. Each ticket: title, page, severity, acceptance criteria, the proving test (unit or e2e spec path), files likely touched. Wording tickets carry the exact strings for every locale, native, never a direct translation.
3. File your side's tickets (search first; the issue budget and triage label docs apply), ready-for-agent when fully specified. A product, scope or copy call goes to Elon with `orca orchestration ask` (A recommended, B); record "Elon decision (owner to review)" on the issue. Only Owner-Reserved items become ready-for-human.
Never change priorities of existing issues, never close issues, never read secrets. No heartbeats. Finish within 40 minutes.
worker_done: issues filed (number, severity, label), open disagreements as a numbered A/B list, Owner-Reserved questions (expect none).
```

Elon answers each ask within minutes and decides every disagreement. Legal text follows the project file (the source locale is the truth; other locales are rewritten from it).

## 3. Build

Send the new ready-for-agent numbers to the tech-lead in one message, P0/P1 first, grouped by shared files. Builders and reviewers come from different model families. Each PR with new or changed strings sends Elon a `key | <locales>` table; Elon approves or edits it on the PR before merge. Two or more passing PRs merge as one batch.

## 4. Close the round

The round is done when every ticket is merged or has a named blocker. Deploy to staging (quick path, no full regression), then start the next round from step 0 if the owner asked for more rounds or the last round found any P0 or P1. Stop when a round finds no P0 or P1.

Report to the owner once per round: findings by severity, tickets filed and merged, and only the items that need him.
