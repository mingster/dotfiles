---
name: stripe
description: Stripe payments, prices, subscriptions, and riben.life platform billing integration. Use when working with Stripe API, checkout, subscriptions, webhooks, unit_amount/currency pitfalls, PlatformSettings stripePriceId, or bin/install.ts subscription setup.
---

# Stripe (riben.life + general)

## Quick reference: `unit_amount`

- **`unit_amount` is always in the smallest currency unit** Stripe uses for that currency (same mental model as “cents” for USD).
- **USD:** `300` = **US$3.00**, `30000` = US$300.00.
- **TWD (`twd`):** Stripe uses **1/100 of a dollar** (two decimal places). Example: **NT$100** → `10000`, **NT$300** → **`30000`**. Using **`300`** creates **NT$3.00**, not NT$300.

Do **not** assume a currency is “zero-decimal” without checking the live Stripe docs / Dashboard for that currency.

## riben.life — where things live

| Area | Location |
|------|----------|
| Stripe client | `web/src/lib/stripe/config.ts` (`STRIPE_SECRET_KEY`) |
| Platform product/price IDs | `PlatformSettings.stripeProductId`, `stripePriceId` (Prisma) |
| Install: ensure price + upsert settings | `web/bin/install.ts` — `ensurePlatformStripeSubscriptionPrice()` |
| Store subscribe API | `web/src/app/api/storeAdmin/[storeId]/subscribe/route.ts` |

## Install script defaults (`web/bin/install.ts`)

- **Default subscription:** `twd` + `unit_amount` **30000** → **NT$300/month**.
- Env: `INSTALL_SUBSCRIPTION_CURRENCY`, `INSTALL_SUBSCRIPTION_UNIT_AMOUNT`, `INSTALL_SUBSCRIPTION_PRODUCT_NAME`, `INSTALL_STRIPE_PRICE_ID` (existing `price_…`).
- Flags: `--skip-stripe` if no key / CI.
- Install **refuses** `twd` + `300` to avoid accidentally creating **NT$3/mo**.
- Invalid DB placeholder (e.g. `new` as price id) → install creates or pins a real price when Stripe key is set.

## Common failures

- **`No such price: 'new'`** — `stripePriceId` in DB is not a real Stripe id; run install or set a valid `price_…` in sysAdmin / `INSTALL_STRIPE_PRICE_ID`.
- **“Charged NT$3 instead of NT$300”** — price used **`unit_amount` 300** with **`twd`**. Use **`30000`** for NT$300 (or fix the Price in Stripe and update `PlatformSettings`).

## Workflow checklist

1. Confirm **test vs live** key matches the Dashboard mode.
2. For new default platform price: run `bun run bin/install.ts` from `web/` with `STRIPE_SECRET_KEY` (omit `--skip-stripe`).
3. Verify in Stripe Dashboard: currency, amount, recurring interval.
4. Ensure `PlatformSettings.stripePriceId` matches that Price id.

## Docs

Use Context7 / Stripe docs for API version-specific fields (`apiVersion` in `config.ts`).
