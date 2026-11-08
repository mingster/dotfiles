### Changed
* Dotfiles pull requests now rely on GitHub Actions (`script-tests` and `shellcheck`) for checks instead of spawning `head-checks.sh` through `heavy-gate.py`, and `post-verdict.sh` posts a `review` commit status at the reviewed head so GitHub auto merge can require both Actions and `review`.
