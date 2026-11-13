#!/usr/bin/env python3
"""Resolved poteto-mode, ORCA-ADAPTER, and role-file paths for a worker brief."""
import argparse
import os
import sys


def _existing(paths):
    for path in paths:
        full = os.path.expanduser(path)
        if os.path.isfile(full):
            return os.path.abspath(full)
    return ''


def paths(role, home=None, dotfiles=None):
    home = home or os.path.expanduser('~')
    dotfiles = dotfiles or os.environ.get('DOTFILES') or os.path.join(home, 'dotfiles')
    team = os.path.join(dotfiles, 'templates', 'agent-team')
    poteto = _existing([
        os.path.join(home, '.agents', 'skills', 'poteto-mode', 'SKILL.md'),
        os.path.join(team, '.agents', 'skills', 'poteto-mode', 'SKILL.md'),
        os.path.join(dotfiles, '.agents', 'skills', 'poteto-mode', 'SKILL.md'),
    ])
    adapter = _existing([
        os.path.join(home, '.agents', 'skills', 'orca-adapter', 'ORCA-ADAPTER.md'),
        os.path.join(team, '.agents', 'skills', 'orca-adapter', 'ORCA-ADAPTER.md'),
        os.path.join(dotfiles, '.agents', 'skills', 'orca-adapter', 'ORCA-ADAPTER.md'),
    ])
    role_file = ''
    if role:
        role_file = _existing([
            os.path.join(home, '.claude', 'agents', '%s.md' % role),
            os.path.join(team, '.claude', 'agents', '%s.md' % role),
            os.path.join(dotfiles, '.claude', 'agents', '%s.md' % role),
        ])
    return poteto, adapter, role_file


def block(role, home=None, dotfiles=None):
    poteto, adapter, role_file = paths(role, home, dotfiles)
    lines = ['Read these files before any work:']
    if poteto:
        lines.append('- %s' % poteto)
    if adapter:
        lines.append('- %s' % adapter)
    if role_file:
        lines.append('- %s' % role_file)
    return '\n'.join(lines) + '\n'


def prepend(text, role, home=None, dotfiles=None):
    if 'poteto-mode/SKILL.md' in text and 'ORCA-ADAPTER.md' in text:
        return text
    return block(role, home, dotfiles) + '\n' + text


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument('--role', default='')
    parser.add_argument('--home', default='')
    parser.add_argument('--dotfiles', default='')
    args = parser.parse_args(argv)
    sys.stdout.write(block(args.role, args.home or None, args.dotfiles or None))
    return 0


if __name__ == '__main__':
    sys.exit(main())
