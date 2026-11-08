### Fixed

- `agent-team.sh project` moves a role pin forked in `.claude/model-routing.md` into `.orca/presets.project.json` and the `## Model routing` section of `docs/agents/team-facts.md` before it rewrites the file. A second run changes nothing.
- `agent-team.sh project` writes `docs/agents/team.md`, `elon-dispatch.md`, `release-manager-work.md`, `bin/changelog-compile.sh`, its test and `changelog.d/README.md` only when they are missing. A project copy that differs prints `skip (project owned): <path>` and stays, as does `.agent/skills`. `check` now asks only that these files exist.
- An allow rule copied from `.claude/settings.json` that runs a project file the same run removes (such as `.claude/bin/env-peek.py`) is dropped with a printed `drop` line, since the shared copy under `~/.claude/bin` replaces it.
