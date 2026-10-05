# Lead report, daily run steps 1 to 3, Monday 2026-10-05

Run mode: Orca worker, no team spawned. Digest read only through agent-sql. No code edited, nothing merged or deployed.

## 1. Threshold breaches (team.md)
1. EPG: import has not written for 26 hours (digest 8b flag). Last import 2026-10-01 05:12 UTC. Channels 6 and 7 (two 民視 feeds) have schedules that ended 2026-10-05 00:00 UTC and were not refreshed. Channel 83 still has no guide source (known). Filed incident web2 #924 (the earlier #808 was closed when the cron route #923 merged; the crontab install is an owner step, so it may just not be scheduled).
2. Not breached: payments skipped or failed (queue shows 4 processed, 4 failed in 24h, no hour over 5), cancellations (section 2 returned no rows), email queue (0 unsent over 1h, 0 with 3 tries, 5 sent), channels offline (none), triage drafts (none exist, web2 #701 not shipped, so this is not a healthy check).
3. Digest defect: section 9 (sessions) still fails with Msg 102 near 'SUM'. Session and ghost session numbers are unknown. Already open as pstv_op #21 (incident); relabelled ready-for-agent and commented.

## Abnormal lines by owner (not dispatched)
- support-csm: nothing abnormal. Open tickets none, 1 contact form message in 7 days, no triage drafts (feature not wired).
- secops-finops: payment queue shows 4 failed rows (status 2) in 24h, none stuck incoming over 1h, no spike hour. Worth a look, below the threshold.
- stream-health: EPG breach above (8a, 8b). 15 online live channels have no automated guide source. Sessions (section 9) unknown, digest bug #21. No channels offline.
- qa-sdet: application errors: "Jellyfin validate-session failed" 10 times (web, last 2026-10-05 05:11 UTC). "NetworkError when attempting to fetch resource" 4 times each in DisplayWowzaSessions and DisplayAllOnlinePeers (last 2026-10-04 14:18 UTC). Digest section 9 fix is pstv_op #21.
- sales-marketing: trial funnel (section 10) returned 0 accounts created 24 to 48 hours ago. 1 new account in 24h. Cancellations: none flagged.

## Revenue pulse (exact from digest, UTC 24h)
- Gross paid 24h: 235.03 USD (4 paid orders)
- New paid 24h: 0
- Renewals: not measured as a 24h count. The digest only has renewals due in the next 3 days: 3. Renewals in the last 24 hours: unknown.
- Refunds: 0 (orders created in the last 30 days now refunded; no refund date is stored, so this is not a 24h figure)
- Paid subscribers: 201
- Trials started: unknown (section 10 shows accounts created 24 to 48h ago = 0; 1 new account in the last 24h)
- Cancellations 24h: 0 flagged (section 2 empty)
- Net change: unknown (no churn count to net against)

## 2. Triage decisions (every needs-triage issue)
| Issue | Decision | Reason |
| --- | --- | --- |
| web2 #883 | ready-for-agent | A second reader verified a field build can reach the 429 (initial 401, forced retry limited, empty cache). Server side fix, compatibility covered, P2 mrr:medium already set |
| web2 #840 | blocked | Enforcement held under owner decision 47; untestable until #839 and the Roku and Android secret tickets ship |
| pstv_op #21 | ready-for-agent (incident kept) | Reproduced in today's digest |
| pstv_op #30 | ready-for-human | Owner must agree the proposal. Recommendation: yes to the docs note now, hold the script sha check |
| pstv_op #24 | ready-for-human | Waits on web2 #834 and three crontab lines are an owner install. Recommendation: install after #834 is verified |
| Roku #113 | blocked | Waits on web2 #839 (itself blocked) |
| Android #164 | blocked (label created in the repo) | Same as Roku #113 |

No product change needing an intent was found, so architect-pm was not spawned. Needs owner (ready-for-human) in the repos: pstv_op #30, #24 (new), plus web2 #127, #727, #749, #807, #874 (already ready-for-human, unchanged).

## 3. Issue budget
Closed as completed: none. Reason: I checked #834, #829, #842, #839, #846, #848, #870, #877, #720, #727 against merged PRs #909 to #923. Every one is only partly fixed and the lead's own last comment says it remains open:
- #834: PR #912 and #914 are dry run source only; comment says remains OPEN, runtime proof and arming outstanding.
- #829: PR #913 prepares policy only, activation needs owner storage.
- #842: PR #916 is source A and B; C1 policy and Jellyfin privacy pending.
- #839: PR #921 is one slice; issue is blocked on owner prerequisites.
- #846, #848: no merged PR for them.
- #870: PR #915 is step 2 only; steps 1 and 3 outstanding.
- #877: PR #917 is Slice A only; atomic unique index is an owner schema change.
- #720: PR #902 earlier scope; server boundary checkpoint has no PR.
- #727: PR #920 did the code step (fail closed); the owner step (set CRON_SECRET and crontab headers) is still open and #848 depends on it.
Merged PRs that did close their issues (#805, #808, #811, #835, #735, #781, #847) are already closed.

Label drift fixed: web2 #848 (ready-for-agent plus ready-for-human, body names open prerequisites #826, #727, plugin trusted address) now blocked. web2 #845 (both labels, owner holds the purge, dry run waits on #843) now blocked. Both commented with who and what.

Moved to backlog #886: none. Rule is no PR and no activity for 7 days. The oldest open web2 issues (#127, #727, #749) were last touched 2026-09-29, 6 days ago, so none qualify today. They qualify on 2026-10-06 if untouched. Not forcing it.

web2 stays over the cap: 37 open excluding backlog #886 (38 counting #886 and the new #924), cap 30. Pillar 3 item. Candidate lines for a waiver decision (lowest priority first, all with an open dependency chain or low value): #703, #692, #691 (iOS and alert badge, mrr:low), #795, #740 (P3 mrr:low), #771 (P2 mrr:low). Recommendation: let them age out tomorrow under the rule, or the owner may waive the 7 day wait.

## Issue counts, last 24 hours
| Repo | Opened | Closed | Net | Open now |
| --- | --- | --- | --- | --- |
| web2 | 1 (#924) | 5 | -4 | 37 (+ backlog #886) |
| jellyfin | 0 | 0 | 0 | 0 |
| fileServer | 0 | 0 | 0 | 3 |
| pstv_op | 0 | 0 | 0 | 5 |
| streaminator | 0 | 0 | 0 | 0 |
| Roku | 0 | 0 | 0 | 2 (one is backlog #118) |
| Android | 0 | 0 | 0 | 3 |
Open PRs: none in any repo (all 15 web2 PRs #909 to #923 merged 2026-10-03/04).
web2 #924 has no ready label yet. It is an incident awaiting stream-health and owner checks on the crontab, label it when someone confirms the cause.

## Ranked ready-for-agent, no open PR, unblocked and unfinished (step 6 order)
1. pstv_op #21 (incident): fix digest section 9 (add missing comma, declare or drop @cutoff) and add a check that the whole digest runs without a Msg error. File: pstv_op/sql/agent/morning-digest.sql.
2. web2 #852 (Security:, P3): throttle per IP and per serial on POST get-pin-result, answers unchanged so Roku 5.9 is unaffected. Files: src/app/api/pstv/devices/get-pin-result/route.ts and the existing throttle helper used by get-pin (see #874 for PIN_THROTTLE_MODE, start in count mode).
3. web2 #883 (bug P2, mrr:medium): map the limited, empty cache refresh to a failure shape field Roku 5.9 and Android release-213 handle. Files: src/lib/jellyfin/get-jellyfin-access-token-for-user.ts, jellyfin-client-config.ts, src/app/api/pstv/devices/jellyfin-config/route.ts, plus a test.
4. Android #155 (bug P2, mrr:medium): clear stored session and device id when a revoked device row (513) is acknowledged, not for HTTP 200 SESSION_REVOKED (owner decision 2026-10-02). Files: TvMainActivity.kt, PhoneMainActivity.kt, TvVodActivity.kt, StartupNavigationResolver.kt. Larger, touches three screens.
5. web2 #795 (bug P3, mrr:low): per IP rate limit on jellyfin-config, consider collapsing pre-session answers only where players do not need the distinction (compat check first). File: src/app/api/pstv/devices/jellyfin-config/route.ts.
Not listed: #829, #831, #832, #843, #844 and #834 are unfinished but their activation or completion waits on owner prerequisites or a dependency chain; #870 waits on SQL proof and dated activation.
