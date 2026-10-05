# PSTV weekly growth report, 2026-09-28 to 2026-10-04 (UTC)

Source: read only production SQL (pstv_agent_ro), queried 2026-10-05. No personal data. Nothing sent, no prices changed.

## 1. Numbers

| Metric | This week | Note |
|---|---|---|
| Signups (pstv_subscriber created) | 6 | Previous week 3 |
| Trials started | unknown | The table stores only the current status, not the status at creation. Of the 6 signups, 2 are still status 2 (free), 1 is status 1, 3 are status 11. Lower bound 2. |
| Trial to paid, 14 days | 1 of 9 (11.1%) | Cohort created 09-14 to 09-20 (matured by 10-04), 1 now paid. Includes any non trial signups, so treat as an upper bound on the denominator. Sample is tiny. |
| New paid (first ever paid order, total above 0) | 1 | PayPal, $36.00 |
| Renewals (paid order from a customer with an earlier paid order) | 11 PayPal ($683.74), plus 20 Manual Processing ($220.20, excluded below) | |
| Cancellations (status 30, row changed this week) | 0 | Also 0 newly OnHold, Expired or PaymentSkipped rows changed this week. Cancel rows are 13 in total, all still unexpired. |
| Paid accounts expiring this week | 0 | |
| Paid subscriber count (end of week) | 201 | Definition below |
| Gross revenue, excluding bulk manual entries | $719.74 (12 PayPal orders) | Total paid including manual would be $939.94 ($719.74 + $220.20) |
| MRR | unknown | Plan mix and billing period per account are not in the queries I ran. Do not derive MRR from weekly gross (orders mix plan lengths, average PayPal order was $59.98). |

Note on the manual entries: 20 "Manual Processing" orders averaging $11.01 each, all renewals. Treated as bulk manual processing and excluded as instructed. I did not confirm with secops-finops what they are.

## 2. Reconciling 201 vs 180

Both numbers are right, they count different statuses:

| Count | Query |
|---|---|
| 180 | status = 1 (PaidSubscriber) and not expired |
| 21 | status = 11 (PaidSubscriberNoPaymentScheduled) and not expired |
| 201 | status IN (1, 11) and expiration in the future (the morning digest definition) |

Other rows that look paid but are not counted: 4 BonusAccount (status 4), 13 Cancel (30) still unexpired, 13 free trials (status 2) still unexpired. Status 11 are people with access but no PayPal charge scheduled (likely cancelled auto renew). They are paying customers today but will lapse unless they resubscribe.

Proposed definition for METRICS.md:

- **Paid subscribers** = accounts with status IN (1, 11) and expiration later than the query time. Report as 201 = 180 (renewing) + 21 (no payment scheduled).
- Always report the two parts, because the 21 is the near term churn risk.
- Bonus (4), sub accounts (3), free (2) and cancelled (30) are never counted, even if unexpired.

## 3. Event calendar, 2026-10-05 to 2026-11-02 (Chinese language audience)

| Date | Event | Source status |
|---|---|---|
| Oct 10 (Sat) | Taiwan National Day (Double Ten), public holiday | Fixed national date |
| Oct 18 (Sun) | Double Ninth Festival (Chung Yeung) | Lunar calendar, 9th day of 9th month, verify |
| Oct 25 (Sun) | Retrocession Day (Taiwan) | Fixed date, a commemoration, not a day off |
| Late Oct | CPBL Taiwan Series. Season runs to Oct 27 per Wikipedia, exact series dates not found | Unverified, check cpbl.com.tw |
| Around Oct 20 | NBA 2026-27 season tip off | Unverified, check nba.com |
| Oct 31 | Halloween | Fixed |
| Nov 1 | US daylight saving ends, shifts live US sports start times by 1 hour for Taiwan viewers | Rule based |
| Nov 22 (outside the window) | 63rd Golden Horse Awards, Taipei Music Center, 18:30 | Official site (goldenhorse.org.tw) |

Events inside the window that I could not verify are marked. EVENTS.md should only get verified dates.

## 4. Next three bets (proposals only, owner approval needed to run anything)

Baseline is tiny: 3 to 6 signups a week, so any result needs 4 weeks of data before it means anything.

1. **Day 3 and day 10 trial nudge email** (Traditional Chinese, how to pair a TV, what to watch). Audience: status 2 accounts. Hypothesis: raises 14 day trial to paid above the current 1 of 9. Measure: paid within 14 days divided by trial starts, per weekly cohort, plus viewing within 24 hours. Stop if no lift after 4 cohorts, or if unsubscribe or complaint rate is over 2 percent. Needs engineering to record the original trial status first (today we cannot count trial starts).
2. **Move the 21 status 11 accounts to a scheduled payment, and the 20 manual processing renewals to PayPal**. Impact: up to 21 accounts (about 10 percent of paid) have no payment scheduled, so the revenue is at risk of lapsing. Measure: count of status 11 accounts at week end (target below 10 in 4 weeks) and renewals paid per week. Needs secops-finops to explain the manual entries first.
3. **Double Ten and Taiwan baseball/NBA landing page for Chinese speakers in the US**, with a free trial link. Measure: signups per week against a baseline of 3 (last week) to 6 (this week), and trial to paid for the Oct 10 to Oct 25 cohorts. Success: at least double the weekly average over the 3 weeks. Stop at the Oct 27 season end if no lift.

Dependencies for Elon: (a) engineering, store trial start status or a status history so trial metrics can be measured, (b) EPG incident #924 (guide import stalled 26 hours) lowers trial experience, fix before campaigns, (c) status 11 meaning to be confirmed by web2 owner.

## 5. mrr: labels added to web2 issues (open, were unlabelled)

Repo mingster/pstv_web2. Estimates are judgment, not data.

- mrr:high: #809 (PayPal events fail the check, 34 in 30 days, risk of unrecorded renewals)
- mrr:medium: #848, #846 (lapse revoke), #834 (EPG completeness), #832, #831, #830, #829 (email verification, risk to signups)
- mrr:low: #886, #878, #877, #874, #870, #860, #852, #845, #844, #843, #842, #840, #839, #749, #727, #127

Issues already labelled (#924, #883) were left alone. 38 issues are open, over the 30 cap in the issue budget.
