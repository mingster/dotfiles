#!/usr/bin/env bash
# Install missing provider CLIs. Authentication remains an owner action.
# Official installers: code.claude.com/docs/en/setup,
# help.openai.com/en/articles/11096431, cursor.com/docs/cli/installation,
# antigravity.google/docs/cli/install/.
set -euo pipefail
DOTFILES="${DOTFILES:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)}"
export PATH="$HOME/.local/bin:$PATH:${ASDF_DATA_DIR:-$HOME/.asdf}/shims"
# Keep vendor shell-profile edits out of tracked dotfiles, including symlinked
# rc files. Snapshot the working copy, preserving any existing local changes.
if [ "${1:-}" != --vendor-install ]; then
  exec python3 - "$DOTFILES" "$0" <<'PY'
import os
from pathlib import Path
import subprocess
import sys

root = Path(sys.argv[1]).resolve()
home = Path.home()
names = ('.zshrc', '.zprofile', '.zshenv', '.bashrc', '.bash_profile', '.bash_login', '.profile')
paths = {home / name for name in names}
if os.environ.get('ZDOTDIR'):
    paths.update(Path(os.environ['ZDOTDIR']) / name for name in ('.zshrc', '.zprofile', '.zshenv'))
before = {}
for path in paths:
    target = path.resolve()
    tracked = False
    if target.is_relative_to(root):
        check = subprocess.run(['git', '-C', str(root), 'ls-files', '--error-unmatch',
                                '--', str(target.relative_to(root))], capture_output=True)
        if check.returncode not in (0, 1):
            sys.exit('install-agent-clis: cannot inspect tracked rc files; refusing vendor installers')
        tracked = check.returncode == 0
    before[path] = (target, target.read_bytes() if target.is_file() else None, tracked)
status = 1
try:
    status = subprocess.run(['bash', sys.argv[2], '--vendor-install']).returncode
finally:
    for path, (target, original, tracked) in before.items():
        current = path.read_bytes() if path.is_file() else None
        if current == original:
            continue
        if tracked:
            # Vendors append PATH setup. Never overwrite an unrelated edit or a
            # replaced symlink; report it and fail instead.
            if path.resolve() != target or current is None or original is None or not current.startswith(original):
                print(f'install-agent-clis: unexpected rc edit; inspect {path}', file=sys.stderr)
                status = status or 1
                continue
            target.write_bytes(original)
            print(f'install-agent-clis: removed vendor additions from tracked rc {path}')
        elif not path.resolve().is_relative_to(root):
            print(f'install-agent-clis: vendor touched untracked rc outside dotfiles: {path}')
sys.exit(status)
PY
fi
bash "$DOTFILES/script/install_claude.sh"
if ! command -v agent >/dev/null 2>&1 && ! command -v cursor-agent >/dev/null 2>&1; then
  curl -fsSL https://cursor.com/install | bash
fi
if ! command -v agy >/dev/null 2>&1; then
  curl -fsSL https://antigravity.google/cli/install.sh | bash
fi
