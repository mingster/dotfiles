# A Claude built PR gets a Grok verifier when a Grok slot is free

Status: Accepted  
Date: 2026-11-27

The rule from 2026-11-21 ([#1305](https://github.com/mingster/dotfiles/issues/1305)) said a verifier comes from a model family other than the builder's, and that between Antigravity and Grok the pick goes to whichever has more usage left. Neither provider reports usage: `usage-gate.py show` gives no reading for Antigravity, and Grok has no usage API at all. With nothing to compare, the pick fell through to the fixed order (Claude, Antigravity, Grok), and since Antigravity always reads as allowed, no verifier reached Grok in over two days. Every Claude built PR was checked by Antigravity, so one provider carried all verifier load and a lapsed Antigravity sign in on a host stalled verification there. The owner accepted this change on 2026-11-27, recorded on [#1970](https://github.com/mingster/dotfiles/issues/1970).

## Decision

1. **Grok first when a slot is free.** For a Claude built PR, the verifier is Grok (`--agent grok --model grok-4.7`) when the target host is listed under `grok_hosts` and has no live Grok worker (the existing one per host limit). Otherwise it is Antigravity (`gemini-4-argon-high`).
2. **The comparison by usage left is dropped** until both providers report usage. The slot check is the whole rule.
3. **Unchanged:** an Antigravity or Grok built PR still gets a Claude verifier; `elon`, `architect-pm` and `secops-finops` never take Grok; a verifier is never the builder's family.
4. The same rule applies to verifiers started by hand and by fleet watch, through one `usage-gate.py pick` path.

## Consequences

Verifier load splits across two providers, and a host whose Antigravity sign in has lapsed can still verify through Grok. Grok quota has no reading, so an exhausted Grok plan shows only as failed starts; on a Grok start that fails or stalls on the folder trust prompt, the pick falls back to Antigravity and one issue is filed. At most one Grok verifier runs per host, so Antigravity still takes the overflow.
