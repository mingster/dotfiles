# Copy-only sensitive vocabulary

`script/copy-only.config.json` groups the owner-held topic vocabulary by prices
and money, refunds and cancellation, legal/contracts/privacy, and promises and
guarantees, with separate en, tw and jp word arrays. Currency markers have their
own group. Each group has a provenance comment. `lead-merge.sh` flattens only the
word arrays and rejects malformed or empty groups; matching and approval rules
are unchanged. Terms are global across eligible surfaces, regardless of locale.

The vocabulary combines the owner's standard synonyms, every explicit round-6
omission, the earlier policy, and a 2026-10-19 scan of riben.life's 21 locale JSON
files (including `marketing.json`) and text sources under `marketing/`. It includes
Traditional/Simplified Chinese and Japanese kanji variants; substring matching
also covers many inflections and compounds. This is a maintained heuristic.

Examples of mined values (under `web/src/app/i18n/locales/`):

| Locale/file/key | Value | Added topic vocabulary |
| --- | --- | --- |
| en/translation.json: billing | Billing | billing |
| tw/translation.json: billing | 帳務 | 帳務 |
| tw/translation.json: billing_cycle | 訂閱週期 | 訂閱 |
| tw/translation.json: stored_value_contract_accept_customer | 我已閱讀並同意儲值契約 | 契約, 同意, 儲值 |
| tw/translation.json: stored_value_guarantee_method | 履約保障方式 | 履約, 保障 |
| tw/marketing.json: cost_section_heading | 怎麼收費 | 收費 |
| jp/translation.json: fee | 手数料 | 手数料 |
| jp/translation.json: manage_billing | 請求管理 | 請求 |
| jp/translation.json: shop_subscription_next_run | 次回課金：{{date}} | 課金 |
| jp/translation.json: shop_subscription_status_cancel_requested | 解約確認中 | 解約 |

The author evidence report for #3819 links the complete path/key/value/topic-word
inventory, the keyword-key scan, and sampled historical commits. Marketing copy
currently lives mainly in locale `marketing.json` files; scanning `marketing/`
does not imply eligible `.md` or `.txt` marketing files exist.

A conservative refusal means current-head owner Copy approval is required. It
can catch unrelated UI cancellation, `rate` inside `generate`, or `fee` inside
`coffee`; report convenience-sample results separately from real historical
copy edits. A copy-only projection of a mixed historical commit measures wording
classification, not the original commit's complete route or merge readiness.

Known limitations: spelled-out quantities such as `one hundred`, `一百`, and `百`
are not recognized by the quantity guard. A configured nearby topic can still
require approval, but generic spelled-out quantity changes remain outside scope.
Cyrillic homoglyphs and rendered concatenation across physical files are not
modeled; screenshot receipt words do not establish actual image inspection.
