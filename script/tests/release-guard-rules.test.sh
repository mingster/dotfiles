#!/usr/bin/env bash
# Release guard rules (mingster/projb#563): the templates carry them, and agent-team.sh installs and checks them.
# Text assertions only; the guard hooks are not driven. Run: bash script/tests/release-guard-rules.test.sh
set -u
# shellcheck source=lib/asdf-pin.sh
# shellcheck disable=SC1091
. "$(cd "$(dirname "$0")" && pwd)/lib/asdf-pin.sh"
D="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail=0
bash "$D/script/tests/release-guard-rules.sh" "$D/templates/agent-team" >/dev/null || { echo "FAIL templates miss a rule"; fail=1; }
mkdir -p "$T/home" "$T/proj"
HOME="$T/home" DOTFILES="$D" bash "$D/script/agent-team.sh" machine >/dev/null || { echo "FAIL machine"; fail=1; }
bash "$D/script/tests/release-guard-rules.sh" "$T/home" >/dev/null || { echo "FAIL synced project misses a rule"; fail=1; }
git -C "$T/proj" init -q
DOTFILES="$D" bash "$D/script/agent-team.sh" project "$T/proj" --project-name acme >/dev/null || { echo "FAIL sync"; fail=1; }
DOTFILES="$D" bash "$D/script/agent-team.sh" check "$T/proj" >/dev/null || { echo "FAIL sync --check"; fail=1; }
[ $fail -eq 0 ] && echo "ok   templates and synced project carry the release guard rules"
exit $fail
