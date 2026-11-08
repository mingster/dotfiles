### Changed
* Dotfiles pull requests now rely on GitHub Actions (`script-tests` and `shellcheck`) for checks instead of spawning `head-checks.sh` through `heavy-gate.py`, `post-verdict.sh` posts a `review` commit status at the reviewed head, and the Script tests workflow installs Bun for `test_head_checks_execution.py`.
