# SecOps-FinOps: revenue at risk and weekly churn and recovery (Mon 2026-10-05)

Read only. Data from `pstv_op/bin/agent-sql.sh pstv` (5iktv, queried 2026-10-05 UTC). Code from `web2/pstv_web` at c1449e6f. Counts and ids only. Money in USD.

## Summary

| # | Finding | USD at stake | Severity |
|---|---------|--------------|----------|
| 1 | Status 11 is "paid, nothing scheduled". It is set by a page visit with no status check, so a free trial can be counted as paid. 20 of the 21 are real prepaid customers who lapse at expiry unless they buy again. | 2,318.45 book (20 paid accounts at last price); 156.00 due in 30 days | Advisory, reporting defect |
| 2 | The 20 "Manual Processing" orders are affiliate 9 (reseller) TV card credits. They draw down a prepaid balance. They are not new cash. The label is a code fallback. | 220.20 overstated if counted as new revenue; prepaid balance about 240.72 left, next reseller payment about 1,111.76 | Advisory, reporting defect |
| 3 | The 4 failed queue rows are all the known #809 pattern (JSON PAYMENT.SALE.COMPLETED). Each sale was credited by its IPN copy. | 235.03 exposure, 0 lost | Known, no action |
| 4 | Week 2026-09-28 to 2026-10-04: 0 paid lapses, 0 new cancellations, 0 failed renewals recorded, 0 dunning recoveries. 12 PayPal payments credited (719.74). The zero failures is partly blindness (see 4d). | 708.62 PayPal renewals due in 30 days with no failure signal | Watch |

## 1. Subscription status 11

**What it means.** `SubscriberStatus.PaidSubscriberNoPaymentScheduled = 11` (`src/types/enum.ts:135`): the account may watch until its expiration date, but nothing is set to charge it again. Entitlement allows it while unexpired (`src/lib/entitlement/get-entitlement.ts:58`).

**How an account reaches it.**
- Account page visit: `src/app/(root)/account/subscription/page.tsx:109-124` sets status 11 whenever expiration is in the future and no billing subscription row resolves. It does not check the current status, so a free trial (2), a bonus account (4) or a cancelled account (30) is also flipped to 11. It does not write `lastModified` or `modifier`, so the database cannot show when it happened.
- Stripe retirement: `src/lib/stripe/sync-subscriber-status.ts:93-101` (sysAdmin action, last changed 2026-03-31) moved Stripe subscribers to 11. No Stripe orders exist after 2026-03 (query: `Nop_Order WHERE PaymentMethodID=43 AND CreatedOn>='2026-03-01'` returns March only, 15 orders, 747.89).
- `src/app/sysAdmin/users/[email]/client-manage-user.tsx:254-258` only changes the displayed status, it writes nothing.

**What happens next.** They lapse. The nightly expiry job moves 1, 11 and 30 to Expired (20) once expiration passes (`src/lib/billing/update-expired-subscriber-status.ts:33-43`). Renewal reminder emails go out 7 days and 1 day before expiry (`src/lib/send-renewal-reminder-emails.ts:291-295`). No path keeps access after expiry for free, with one exception to check (customer 22407, below).

**Counts** (`pstv_subscriber WHERE status=11`, 23 rows; 21 unexpired, which is the sales-marketing number):

| Expiry bucket | Count | Detail |
|---------------|-------|--------|
| Expired (today, job not yet run) | 2 | trials 81686, 81687, never paid |
| Next 7 days | 1 | trial 81691, never paid |
| 8 to 30 days | 2 | 71259 (PayPal one time, 36.00, 2026-10-16), 81346 (Stripe annual, 120.00, 2026-10-30) |
| Later | 18 | 2026-11-10 to 2028-07-11 |

| How they got there | Count | Last paid total |
|--------------------|-------|-----------------|
| Free trial flipped by the account page (created 2026-09-30 and 2026-10-04, 120 hour trials, no orders) | 3 | 0.00 |
| Stripe annual, retired with Stripe (BillingProvider 43) | 8 | 940.32 |
| One time prepaid with no recurring profile (PayPal one time 44, PayPal Standard 2, SquareUp 42, Purchase Order 18) | 12 | 1,378.13 |

So of the 21 counted as paid today, 1 is an unpaid trial and 20 are paid prepaid customers worth 2,318.45 at their last price.

**Wider point.** Status 1 versus 11 is not a reliable split. 40 more status 1 accounts have no PayPal subscription id and no affiliate link (query: `status IN (1,11) AND expiration>now AND PayPalSubscriptionId empty`). Together with the 20, between about 45 and 60 paying accounts will not auto renew. Of these, 9 expire in the next 30 days, worth 787.44 (status 1: 7 accounts, 631.44; status 11: 2 accounts, 156.00).

**Check by an admin.** Customer 22407 expires 2027-01-22. Its 2025-01-22 order (124.32) was followed by a minus 124.32 order on 2025-02-07, and no other paid order since 2024. Last write was 2026-07-15 by "StripePaymentProcessor". If the negative order was a refund, this is up to 248.64 of unpaid access.

**Also affected.** The morning digest counts status 11 as paid in both the paid subscriber count and the trial funnel `paid_now` (`pstv_op/sql/agent/morning-digest.sql:39` and `:254`), so each flipped trial shows up as a trial converted to paid.

## 2. "Manual Processing" orders

**What creates them.** `src/actions/affiliate/credit-affiliate-tv-card.ts` (single credit, line 59 to 66; batch credit, line 484 to 491). It looks for a payment method named TVCard. None exists in `Nop_PaymentMethod`, so `findFirst()` returns id 1, "Manual Processing" (inactive). The code went live 2026-07-17 to 2026-07-31 (git log). It is not an admin action and not a legacy import.

**Whose.** All 44 Manual Processing orders in 2026 are affiliate 9 (`Nop_Order WHERE PaymentMethodID=1 AND CreatedOn>='2026-01-01' GROUP BY AffiliateID`). Each is one month (11.01) for one of the reseller's about 22 customers, paid 30, completed 30, with no PayPal transaction ids. The 2026-09-29 batch: 20 orders, 220.20, 20 customers, none of them status 11. Before July the same monthly credits were labelled "Purchase Order" (18), 22 a month at 242.22.

**Is it money received.** No, not at the time of the order. Affiliate 9 prepays by SquareUp, 1,111.76 a time (2024-08-16, 2024-12-30, 2025-05-29, 2025-09-22, 2026-02-23, 2026-06-29). Since 2024-08-16 it prepaid 6,670.56 and was credited 6,429.84 (5,945.40 Purchase Order plus 484.44 Manual Processing), which leaves about 240.72, about one month at the current 22 customers. This assumes the balance was zero on 2024-08-16.

**Should it count as revenue.** Count one side, not both. On a cash basis the SquareUp payment is the revenue and the 11.01 credits are not. On an earned basis the credits are the revenue and the SquareUp payment is deferred. Adding both double counts. For the WBR, report the 220.20 as reseller usage, not new revenue.

**Watch.** The reseller's next 1,111.76 should arrive by late October or early November. If it does not, 22 accounts keep being credited without cover.

## 3. Payment queue, 4 failed rows (status 2, last 24 hours)

All four are `processor=2`, JSON, `PAYMENT.SALE.COMPLETED`, created 2026-10-04 10:07 to 11:17 UTC: the #809 pattern. Each has a successful IPN row for the same PayPal subscription, a paid order on 2026-10-04 and an extended expiry (query: match `billing_agreement_id` to `pstv_subscriber.PayPalSubscriptionId`, `pstv_paymentQueue.status=1`, `Nop_Order` in 36 hours).

| Queue row | Amount | Credited by IPN |
|-----------|--------|-----------------|
| f683b970 | 36.90 | yes, expires 2027-01-04 |
| f15c771f | 124.32 | yes, 2027-10-04 |
| 5476c9f4 | 62.16 | yes, 2027-10-04 |
| 2c58c272 | 11.65 | yes, 2026-11-04 |

Nothing new. 235.03 exposure, 0 lost. Over the week, 10 JSON failures (670.79), all 10 matched by a successful IPN.

## 4. Churn and recovery, 2026-09-28 to 2026-10-04 (UTC)

| Measure | Count | USD | Evidence |
|---------|-------|-----|----------|
| Renewal and new payments credited (PayPal, method 44) | 12 orders | 719.74 | `Nop_Order` paid in week |
| Distinct PayPal IPN payments | 15 | 733.96 | 2 were old payments (2026-09-26 and 27) resent on 2026-10-01 07:04 to 07:06, already credited and correctly not credited twice |
| Reseller credits (affiliate 9) | 20 orders | 220.20 | prepaid usage, not cash (finding 2) |
| Paid lapses | 0 | 0 | no status 0, 20, 21 or 30 writes in the week; last Expired write 2026-09-26 21:00; no paid account overdue except today's 2 trials |
| Trial lapses | 1 | 0 | a 72 hour trial left at status 2 (correct, entitlement checks the date) |
| New cancellations | 0 | 0 | 2 `subscr_cancel` IPNs, both in the 2026-10-01 resend, for a subscription id not on file |
| Failed renewals | 0 recorded | 0 | no `recurring_payment_failed`, `skipped` or `PAYMENT.SALE.DENIED`, no status 21 |
| Dunning recoveries | 0 | 0 | `paypal_subscription_reactivation_schedule`: 1 pending (2027-05-02), 1 cancelled, none processed in the week |

**4d. Why "0 failed renewals" is weak.** Payment failure notices for PayPal REST subscriptions arrive as JSON webhooks, the path #809 says is broken. A declined renewal today would most likely appear only as a lapse at expiry. 20 PayPal auto renewals are due in the next 30 days, worth 708.62.

**Cancelled but still active.** 13 accounts in status 30. 4 expire in the next 30 days, worth 274.54, expected to lapse unless won back.

**Small open item.** One new PayPal profile on 2026-10-02 (customer 81690) has a 36.00 order but its `recurring_payment` notice shows 19.56. It may be the next scheduled charge rather than this one; compare in the PayPal dashboard before treating it as a difference.

## Proposed actions (none taken)

1. **Account page flip** (`page.tsx:109-124`). Only move status 1 to 11, and write `lastModified` and `modifier`. Options: (a) fix in web2, (b) also change the digest to count paid as "has a paid order" rather than status 1 or 11. Recommend (a) and (b). No new issue filed: web2 has 38 open issues, over the 30 cap, and this is not an incident. Recommend the lead add it to an existing billing issue or file it once under the cap.
2. **TV card label** (`credit-affiliate-tv-card.ts:59-66, 484-491`). Options: (a) fall back to Purchase Order (18), which matches history, (b) add a TVCard payment method row (production data write, owner approval). Recommend (a). Existing orders stay as they are; the WBR treats method 1 with affiliate 9 as reseller usage.
3. **Reseller balance.** Sales should confirm affiliate 9's next prepayment (about 1,111.76) is coming before November.
4. **Prepaid win back.** 9 non recurring accounts expire in 30 days (787.44). Reminder emails are already sent. Sales can decide on a PayPal subscription offer. No subscriber contact from this role.
5. **Owner checks** (Mingster, outside agent access): whether any Stripe subscriptions still charge at Stripe (8 status 11 and about 14 status 1 accounts on Stripe have "active" rows in `subscription`; no Stripe orders since March); customer 22407's refund.
