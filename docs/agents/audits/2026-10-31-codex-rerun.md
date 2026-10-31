# Team audit rerun: worker delivery accountability

Status: documentation corrections checked locally; revised-head canonical Checks and independent QA must pass before merge. This rerun continues the existing three audit PRs rather than creating duplicate work. Engineering integration, runtime startup coverage, Strong SecOps and production remain gated.

## Window and sources

Previous completed audit merges remain dotfiles #418, riben.life #6448 and PSTV #950 on October 29, as recorded in [the preceding report](2026-10-31-codex.md). Its last judgement cutoff was October 31 11:38Z; this incremental review ends at 12:01:21Z. All times are UTC. The earlier audit PRs are still open, so this is an incremental rerun, not a claim that the previous audit merged.

Reviewed changed Elon roles, affected model-routing recovery paragraphs, new owner corrections, native worker-show receipts and Teddy status reports. Fresh inbox coverage: latest 1,000 messages, October 30 23:57:18Z through October 31 12:00:25Z; complete only for the incremental interval and available recipients. Older lead handles and earlier missing messages remain coverage gaps. GitHub API snapshots and native terminal inventories were collected in this run. Raw private observations/transcripts remain outside Git.

## Findings and structural corrections

| Finding | Evidence and authority | Correction |
| --- | --- | --- |
| Launch counted without ensuring task work; retry before readiness; prohibited host/provider combination. | Native ctx_4039ad2f8dfe: requested Codex on niteking, `dispatch_input` failure `agent_not_in_foreground`; terminal reported no configured Node version. Native ctx_b4afd9c95f68 and ctx_060e474c083f: `agent_readiness`, `agent-trust-workspace`. Owner holds Elon accountable for delivery. | Shared Elon role now requires preflight, within-two-minute task-specific progress proof, ongoing recovery ownership, provenance-preserving retries and checked delivery/disposition. Current temporary owner routing overrides static defaults. |
| Root Elon additions exceed the 800-word role budget. | Initial deterministic audit: riben.life 856 words, PSTV 853. | Condensed the accountability contract in the audit branches; both roles fit the existing budget. No budget raised. |
| Model-routing Start 3 treats `outcome_unknown` as failed and prescribes stop/abandon/retry from screen symptoms. | Conflicts with installed Orca orchestration Authority and safety floor / Canonical supervised loop: unverifiable is absence, never exit authority. | Removed the embedded stop/abandon recipe; require receipt stage, residual resources, native liveness and supported recovery before retry. |
| Model-routing Start 6 closes terminals sharing a worktree and then prunes after task failure. Watching 3, 5 and 7 repeat unsafe transitions. | Installed Orca Outcome requires accepted settlement for release and positive process-state evidence for recovery; owner requires preserving current/unknown resources and unmerged work. | Replaced five duplicated recovery/cleanup paragraphs with native-authority pointers and explicit preservation of shared/live/unknown resources. No real cleanup, lifecycle bypass or helper installation performed. |
| Role demands filling hosts using stale hard-coded caps. | Current owner limits and fresh host/provider admission have higher authority. | Removed fixed blueDevil5/niteking4/miniu2 and unconditional-fill instruction; current limits govern, heavy work holds on relevant load unknown or >=12. |
| Two generated wrap-up skills are stale in main checkouts. | Initial deterministic audit reports exactly those two sync findings. | Existing audit branches already carry source-derived copies; sync checks validate them. Main checkouts and unmerged branches are preserved. |

Canonical changes live in dotfiles template; matching policy paragraphs and accountability section are copied into both product audit branches. Product-specific role context remains. Actual pruning: removed unconditional-fill rule and five duplicate unsafe lifecycle recipes; replaced them with shorter evidence-bound instructions. This is a docs correction, not proof that launchers or native runtime behavior are repaired.

## Every role: outcome and next action

Rows cover the shared role in all three repositories. Runtime evidence is riben.life/dotfiles; PSTV-specific role execution remains an explicit gap.

| Role | Incremental decision/outcome | Structural result or evidence gap |
| --- | --- | --- |
| elon | Owner identified failure to ensure workers; live receipts confirm invalid routing and failed startup, while earlier retry preceded readiness. Fresh inventory distinguishes two coordinators from active Dispatch counts. | Accountability and routing rules corrected. Elon must verify real task work and own recovery; an alert is not supervision completion. New role changes still require independent review. |
| tech-lead | Preserved trust `50c5e9b3ec2755d0ff39d117cd7043d0b48cb969` and wrap-up `090431677d86c78a8c3fde9c89937b61bbae8667`; requested compliant independent review, explicitly retained Strong security gate. | Local reports: trust 24/24 boundary tests and 19/19 launcher cases; wrap-up 12 scenario groups including five uncertain-close modes, syntax/lint pass. Reviewed commit metadata, not independently rerun. Source QA and Strong SecOps remain open; no integration. |
| fullstack-dev | No new builder Dispatch in this interval; existing rejected trust-startup work remains preserved. | No change, no activity; runtime-readiness and remote/direct launch coverage remain gaps. |
| qa-sdet | ctx_59252cd3d24b completed a negative review of frozen `3661a66...`; this was an intentional failed outcome, not a crash. Later ctx_c1abf9010976 completed PASS on the earlier docs heads and was released. | Revised heads invalidate that PASS. A fresh different-family reviewer must read actual three-dot diffs and current Checks. Frozen audit FAIL remains unchanged. |
| architect-pm | No new PM activity in the incremental window; earlier rejected audit remains blocked. | No change, no activity; no new adoption or policy expansion. |
| sales-marketing | No new role activity; historical same-terminal Cursor recovery is evidence that not every worker failed. | No change, no activity; no outreach or sales outcome claim. |
| secops-finops | No new independent Strong approval; Claude is quota-blocked and temporary owner routing limits other model choices. | No change, no activity; Strong review remains required for engineering/gate-script integration. Docs QA cannot waive it. |
| release-manager | Screen remains exited, no fresh release result. | No change, no activity; production HOLD, regression/browser and fixture-cleanup gates remain open. |
| support-csm | No fresh mailbox/access or support outcome. | No change, no activity; earlier read-only money-mail coverage requirement remains unverified. |

## Metrics and throughput

Fresh GitHub snapshots show zero merged PRs in the incremental interval in all three repositories. The adjacent rerun TSV records observed updated PRs plus every open PR, with API timestamps and source URLs. Earlier whole-interval daily merge totals stay in the preceding report; no throughput improvement is claimed from this short window.

| Project | Incremental merges | Open PRs | Ready-for-agent | Unique ready-for-human / owner-action / blocked union |
| --- | ---: | --- | ---: | ---: |
| dotfiles | 0 | #450, #399 | 0 | 0 |
| riben.life | 0 | #6701, #6700, #6699, #6213 | 8 | 26 |
| PSTV | 0 | #955, #903 | 16 | 25 |

Ticket-first-work-to-merge per ticket and median remain UNKNOWN (verified samples n=0); PR creation is not a work-start timestamp. Unmerged tickets/PRs are listed separately in the TSV. Post-merge reopens/hotfixes linked to original merged tickets remain UNKNOWN: issue-event timelines and incident joins were not collected. Zero incremental merges does not establish zero post-merge incidents. Engineering commits without PRs are additional unmerged work.

Current Teddy-handle `escalation` messages since 11:38Z: 0 in the covered inbox; rule-covered=0, owner-decision=0, hard-stop=0, cross-project=0, unknown=0 for this subset only. Its capacity request was type `status`, not an escalation. Earlier-period totals/gaps remain as recorded previously.

Same-run usage: Codex 77% weekly, reset Nov4 14:38 CST; Cursor Auto+Composer 11.1667%, reset Nov25 10:32 CST; Claude 99% blocked until Nov2 03:00 CST; Antigravity unknown. Native terminal inventory: blueDevil two Codex coordinators (Elon/Teddy), niteking zero provider agents, miniu zero; active Dispatch query has zero rows and hasMore=false. Shells remain separate. Current temporary owner caps remain blueDevil Codex medium <=3 inclusive coordinators, niteking Composer2.5 <=2, no Codex niteking, no new miniu agents. No cap, quota or model-policy override.

Fresh measured loads: blueDevil1.25, niteking1.48, miniu0.10. Recheck before each admission; unknown or >=12 holds heavy work, and the installed stricter host gate still applies.

- More workers: reuse positively settled capacity for one bounded docs reviewer, verify actual task progress before counting it as started. Expected benefit is avoiding false starts and duplicate seats; measured gain UNKNOWN; cost one allowed Composer seat. Strong engineering review remains gated.
- Faster tickets: remove five duplicated recovery recipes and centralize runtime transitions in native Orca authority. Expected benefit is avoiding premature retries and shared-path cleanup; runtime recovery improvement remains UNVERIFIED.
- More merges: continue the existing three audit PRs, refresh exact-head Checks and independent QA after these changes, then use the normal guarded merge route. Separate generated-only PRs where the merge contract requires them. Actual merge gain UNKNOWN until receipts exist.

## Verification, limits and observations

Initial audit: four findings (two generated sync, two role budget). Revised branches: `team-audit: clean`; source-derived skill sync and document links are checked before commits. Different-family exact-head QA and canonical Checks are refreshed after publication. No product tests are appropriate for these reversible docs edits; no application code, protected hooks/settings, DB, production, browser, mailbox or deployed helper changes.

Unused-skill review: this rerun has no additional 30-day session corpus beyond the preceding report's incomplete candidate inventory/content sample. Direct SKILL.md reads count as possible use; no skill removal proposed from absent slash commands. No clean-usage claim.

Two new sanitized coordinator observations (worker delivery accountability and stale routing recovery authority) were reviewed and marked consumed in the private observations log. Existing unreviewed observations remain unchanged. Documentation checks and role rules do not close the provider startup incident or constitute independent engineering/security acceptance.


## Final delivery correction

Independent Composer review of the preceding heads completed Standards PASS and Spec FAIL. The two findings were missing attached deterministic-check output and mixed generated skill copies with general audit documentation. Preserve that review as prior-head evidence.

The product PRs now carry general audit documentation and role/routing changes only. Generated staging-review and wrap-up skills are isolated on each product's `mingster/team-sync-audit-1031` branch, with exactly those two generated files. Merge order is canonical dotfiles source first, generated-only copies using the source Verdict, then the product audit documentation; each new head still requires its own applicable Checks/review receipts. This split addresses the existing merge contract without weakening it. These branches are not deployed helper changes.

Actual pre-split deterministic verification receipt (2026-10-31):

```text
DOTFILES=/Users/mtsai/orca/workspaces/dotfiles/team-audit-1031-codex
/Users/mtsai/dotfiles/script/team-audit.sh <riben audit worktree> <PSTV audit worktree>
exit 0
team-audit: clean
sync-team-skills.sh --check: PASS for both source-derived product copies
check-doc-links.sh: riben.life 1156 files, 0 broken; PSTV 578 files, 0 broken
```

The paths above are expanded under `/Users/mtsai/orca/workspaces/`; the product audit worktrees are `<project>/team-audit-1031-codex`. This is static verification evidence, not a current-head QA Verdict. Previous canonical Checks PASS receipts: [dotfiles #450](https://github.com/mingster/dotfiles/pull/450#issuecomment-6543188583), [riben.life #6701](https://github.com/mingster/riben.life/pull/6701#issuecomment-6543148381), [PSTV #955](https://github.com/mingster/pstv/pull/955#issuecomment-6543148883). New commits supersede those heads and require refreshed receipts. Engineering startup/trust/cleanup and required Strong security review remain separate open gates.
