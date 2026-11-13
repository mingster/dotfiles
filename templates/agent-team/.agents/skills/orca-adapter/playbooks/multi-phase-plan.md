# Multi-phase plan (Orca gates)

Read the shared playbook first: pstack `poteto-mode/playbooks/multi-phase-plan.md`. These gates win on conflict.

- Pricing and money rules need the user's go, relayed by the coordinator. New features and pages need the coordinator's go to build and the owner's look before production. Everything else needs the coordinator's go (owner grill 2026-11-13 gap 8).
- Mobile screenshots for a new page come from the prototype step.
- The plan holds the tw, en and jp copy.
- Live lanes queue through `~/dotfiles/script/heavy-gate.sh`.
