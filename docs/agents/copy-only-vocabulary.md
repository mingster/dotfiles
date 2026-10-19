# Copy-only sensitive vocabulary

`script/copy-only.config.json` groups the owner-held topic vocabulary by prices
and money, refunds and cancellation, legal/contracts/privacy, and promises and
guarantees, with separate en, tw and jp word arrays. Currency markers have their
own group. Each group has a provenance comment. `lead-merge.sh` flattens only the
word arrays and rejects malformed or empty groups; matching and approval rules
use the verifier attestation below. Terms are global across eligible surfaces, regardless of locale.

The vocabulary combines the owner's standard synonyms, every explicit round-6 and round-7
omission, the earlier policy, and a 2026-10-19 scan of <project-a>'s 21 locale JSON
files (including `marketing.json`) and text sources under `marketing/`. It includes
Traditional/Simplified Chinese and Japanese kanji variants; substring matching
also covers many inflections and compounds. This list is frozen after pass 8 of #3819: future misses are notes, not blockers.
It is a backstop, not the semantic control.

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

For the light route, the independent verifier judges each changed text against
four topics: prices and money; refunds and cancellation; legal and privacy;
and promises to customers, including delivery and timing. When unsure, choose
owner. The same Verdict comment must have exactly `Copy topics: none` or
`Copy topics: owner` as its second line (case-sensitive), under the Verdict's
existing independent verifier/author check. A separate comment cannot attest.
Every Verdict for the current head (or an equal patch) counts: one `owner`
keeps the owner gate on, a later `none` cannot erase it, and a PASS beside a
FAIL is refused. An edited or minimized Verdict is refused, so post a new one.
Missing or malformed attestation falls back to the normal route.

`Copy topics: owner`, any backstop hit in an old or changed value, or the
quantity/currency rule requires owner Copy approval: the owner runs
`bin/owner-approve.sh copy <current full sha>` in a terminal, which writes
`~/.config/<namespace>/approval.json` (scope `copy`, that sha, 30 minutes).
lead-merge.sh reads the namespace from `APPROVAL_NAMESPACE` in the repo's
`.claude/hooks/guard-bash.py` (or `approval_namespace` in `copy-only.config.json`). When `guard-bash.py` is missing or unreadable, the script falls back to the configured value; with neither it refuses with a `no approval namespace` message naming the missing file.
A GitHub comment approves nothing, because every agent's gh login is the owner's. `Copy topics: none` cannot
turn off the backstop. An unchanged key path alone does not trigger approval;
the old or changed value must itself contain a backstop term. Added or removed
sensitive keys retain the owner gate. Plain Save, Back
and Sign In variants can therefore stay light despite their surrounding keys.
Cancel contains a backstop term even as a UI label and still triggers.

A conservative refusal means current-head owner Copy approval is required. It
can catch unrelated UI cancellation, `rate` inside `generate`, or `fee` inside
`coffee`; report convenience-sample results separately from real historical
copy edits. A copy-only projection of a mixed historical commit measures wording
classification, not the original commit's complete route or merge readiness.

Known limit: Codex workers run without the Claude hooks, so the approval file
is protected from agents only for Claude workers (guard-bash.py denies running
`owner-approve.sh` and writing the file). A Codex worker on the owner's account
could write it. Keep Codex workers out of the lead worktree's merge step and
the owner's home directory until a sandbox rule covers it.

Spelled-out quantities: the quantity guard also counts CJK numeral characters
(`一二三…十百千萬`, financial forms such as `壹` and `佰`) and English number words
(`one`, `hundred`, `thousand`, `half`, `dozen` and similar). A change in how many of
each a value contains routes to owner Copy approval, so `一百` to `二百`, `百` to `千`
and `one hundred` to `two hundred` are caught. This is a conservative tripwire, not
a lexicon. It cannot see a number written as another word (`a couple`, `一打`,
`半額`, `ひゃく`), a swap that keeps the same count of number characters
(`二百` to `百二`), or a number spread across keys. Rewording that adds or drops a
common character such as `一` also trips it, which is accepted.

Semantic review is the control. The independent verifier reads every changed value
for any change of amount, count, duration, date or percentage, spelled with digits
or words, in tw, en and jp, and answers `Copy topics: owner` for any such change.
Examples that need `owner`: `滿一百送一` to `滿二百送一`, `百人限定` to `千人限定`,
`先着百名様` to `先着千名様`, `Open one hundred seats` to `Open two hundred seats`,
`半額` to `三割引`. Examples that stay `none`: a typo fix in a sentence with no
amount, or `Welcome one and all` reworded with the same number words.

Known limitations: Cyrillic homoglyphs and rendered concatenation across physical files are not
modeled; screenshot receipt words do not establish actual image inspection.
