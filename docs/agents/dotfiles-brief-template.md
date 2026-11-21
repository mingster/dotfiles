# Coordinator brief template for dotfiles

Copy this into a worker brief for a dotfiles issue and replace `123` and `<issue>` with the issue number. It carries every part `script/brief-lint.sh` requires, including the Verify line that runs `script/checks-local.sh`, so lint has nothing to refuse (#1324). `script/tests/brief-lint.test.sh` lints this template on every run, so it cannot drift.

```markdown
Refs mingster/dotfiles#123
Type: build

Read the issue in full (`gh issue view <issue> --repo mingster/dotfiles`) and build its "Proposed change".

## Acceptance
- [ ] The Proposed change in the issue is implemented, with a test that fails without it.
- [ ] One `changelog.d/<issue>-<slug>.md` fragment.
- [ ] PR body has a Closes line, a Builder: line and a ## Self-check with the command and its output.

## Out of scope
- Anything the issue does not name.

## Verify
Verify: bash script/checks-local.sh 2>&1 | tail -40
```

The worker title is `#<issue>|<role>`. When `worker-startup.sh` refuses a title and the brief heading or `Refs` line names the issue, the refusal prints the corrected title.
