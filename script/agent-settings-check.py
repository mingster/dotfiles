#!/usr/bin/env python3
"""Read-only setting coverage audit; never traverse app data or authentication stores."""
import glob
import os
from pathlib import Path
import re
import subprocess
import sys

home = Path.home()
root = Path(os.environ.get('DOTFILES', home / 'dotfiles'))
xdg = Path(os.environ.get('XDG_CONFIG_HOME', home / '.config'))
platform = os.environ.get('OSTYPE', sys.platform)
support = home / 'Library/Application Support' if platform.startswith('darwin') else xdg
# destination directory, explicitly inventoried names, tracked source directory
inventory = [
    (home / '.claude', ['CLAUDE.md', 'keybindings.json', 'settings*.json', '.mcp.json'], '.agents/claude'),
    (home / '.cursor', ['cli-config*.json', 'mcp.json', 'hooks.json'], 'ide/cursor'),
    (home / '.gemini', ['GEMINI.md', 'settings*.json'], '.gemini'),
    (home / '.gemini/antigravity-cli', ['settings*.json'], '.gemini/antigravity-cli'),
    (home / '.gemini/config', ['AGENTS.md', 'skills.json', 'hooks.json'], None),
    (home / '.orca', ['presets.json', 'settings*.json', 'config*.json'], '.orca'),
    (support / 'orca', ['settings*.json', 'config*.json', 'preferences*.json'], None),
    (support / 'Claude', ['claude_desktop_config.json', 'config.json'], None),
]
for app, source in [('Cursor', 'cursor'), ('Antigravity IDE', 'antigravity')]:
    inventory.append((support / app / 'User', ['settings*.json', 'keybindings.json', 'environment.json'], 'ide/' + source))

private = []
manifest = os.environ.get('AGENT_PRIVATE_BACKUP_MANIFEST')
failed = False
if not manifest or not Path(manifest).is_file():
    print('INFO private backup manifest not configured')
else:
    # This is metadata only; never open any private backup payload.
    for line in Path(manifest).read_text().splitlines():
        if not line.strip() or line.lstrip().startswith('#'):
            continue
        fields = line.split(maxsplit=1)
        if len(fields) != 2:
            print('UNMANAGED invalid private backup manifest row')
            failed = True
            continue
        live = fields[1].replace('${HOME}', str(home)).replace('$HOME', str(home))
        if not Path(live).is_absolute() or '..' in Path(live).parts:
            print('UNMANAGED invalid private backup live path')
            failed = True
            continue
        private.append(Path(live))

tracked = subprocess.run(['git', '-C', str(root), 'ls-files', '-z'],
                         capture_output=True, check=True).stdout.decode().split('\0')
# Scan only public tracked configuration templates, never private backup payloads.
credential = re.compile(r'''["']?\b[\w.-]*(?:api[_-]?key|token|password|secret)\b["']?\s*[:=]\s*["']([^"']+)["']''', re.I)
key_value = re.compile(r'\b(?:sk-[A-Za-z0-9_-]{20,}|mk_live_[A-Za-z0-9]{16,}|ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})\b')
sources = {source for _, _, source in inventory if source}
for name in tracked:
    path = Path(name)
    if str(path.parent) not in sources or path.suffix not in ('.json', '.toml'):
        continue
    contents = (root / path).read_text()
    if key_value.search(contents) or any(
        not re.fullmatch(r'\$\{[A-Z_][A-Z_0-9]*\}', match[1])
        for match in credential.finditer(contents)
    ):
        print('UNSAFE tracked settings ' + name)
        failed = True
seen = set()
for directory, patterns, source in inventory:
    for pattern in patterns:
        for name in sorted(glob.glob(str(directory / pattern))):
            path = Path(name)
            if path in seen:
                continue
            seen.add(path)
            label = str(path.relative_to(home)) if path.is_relative_to(home) else str(path)
            if any(path == entry or (entry.is_dir() and path.is_relative_to(entry)) for entry in private):
                print('OK private backup ' + label)
                continue
            relative = source + '/' + path.name if source else None
            template = root / relative if relative else None
            covered = False
            if relative in tracked and path.is_file() and template.is_file():
                # Copies and rendered copies count only when they still match the public source.
                # Do not print file contents, diffs, hashes, or unknown/private values.
                covered = path.read_bytes() == template.read_bytes().replace(b'__HOME__', os.fsencode(home))
            if covered:
                print('OK tracked settings ' + label)
            else:
                print('UNMANAGED ' + label)
                failed = True
sys.exit(int(failed))
