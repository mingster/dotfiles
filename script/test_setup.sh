#!/usr/bin/env bash
# Entrypoint wrapper for user-level agent team setup tests (refs #731).
# shellcheck disable=SC1091
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=tests/lib/asdf-pin.sh
. "$here/tests/lib/asdf-pin.sh"
exec bash "$here/tests/setup-user-level-team.test.sh" "$@"
