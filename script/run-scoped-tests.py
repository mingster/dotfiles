#!/usr/bin/env python3
"""Select changed, adjacent and direct importer suites, then run from their root."""
import argparse
import json
import os
from pathlib import Path
import re
import shlex
import subprocess

SOURCE_SUFFIXES = ('.ts', '.tsx', '.js', '.jsx', '.mts', '.mjs')
PLACEHOLDER_DATABASE = 'postgresql://placeholder:placeholder@localhost:5432/placeholder'


def is_test(path):
    return any(marker in path.name for marker in ('.test.', '.spec.')) and path.suffix in SOURCE_SUFFIXES


def source_key(path):
    # TS imports may use JS extensions, or no extension at all.
    return path.with_suffix('') if path.suffix in SOURCE_SUFFIXES else path


def read_aliases(root):
    config = root / 'tsconfig.json'
    if not config.exists():
        return root, {}
    # tsconfig permits comments and trailing commas. Preserve strings such as @/*.
    text = re.sub(r'"(?:\\.|[^"\\])*"|//[^\n]*|/\*[\s\S]*?\*/',
                  lambda match: match[0] if match[0].startswith('"') else '', config.read_text())
    options = json.loads(re.sub(r',\s*([}\]])', r'\1', text)).get('compilerOptions', {})
    return root / options.get('baseUrl', '.'), options.get('paths', {})


def import_targets(specifier, test, base, aliases):
    if specifier.startswith('.'):
        return [test.parent / specifier]
    targets = []
    for alias, replacements in aliases.items():
        prefix, star, suffix = alias.partition('*')
        if (star and specifier.startswith(prefix) and specifier.endswith(suffix)) or specifier == alias:
            middle = specifier[len(prefix):len(specifier) - len(suffix) if suffix else None] if star else ''
            targets.extend(base / value.replace('*', middle) for value in replacements)
    return targets


def select_changed_tests(root, files):
    root = root.resolve()
    changed = [Path(name).resolve() for name in files if Path(name).resolve().is_relative_to(root)]
    tests = set()
    modules = {source_key(path) for path in changed if path.suffix in SOURCE_SUFFIXES}
    for path in changed:
        if path.is_file() and is_test(path):
            tests.add(path)
        if path.suffix in SOURCE_SUFFIXES:
            for pattern in (path.stem + '.test.*', path.stem + '.spec.*', '__tests__/*.test.*', '__tests__/*.spec.*'):
                tests.update(item for item in path.parent.glob(pattern) if item.is_file())
    if modules:
        base, aliases = read_aliases(root)
        for directory, dirs, names in os.walk(root):
            dirs[:] = [name for name in dirs if name not in ('node_modules', '.git', '.next', 'generated', 'dist')]
            for name in names:
                test = Path(directory) / name
                if not is_test(test):
                    continue
                # Includes import/export-from, require, import(), mock.module and vi.mock.
                specifiers = re.findall(r'''["']([^"'\n]+)["']''', test.read_text(errors='replace'))
                for specifier in specifiers:
                    candidates = import_targets(specifier, test, base, aliases)
                    if any(source_key(candidate.resolve()) in modules or source_key((candidate / 'index').resolve()) in modules for candidate in candidates):
                        tests.add(test)
                        break
    return sorted(tests)


def run_scoped_tests(root, runner, files):
    tests = select_changed_tests(root, files)
    paths = ['./' + str(path.relative_to(root.resolve())) for path in tests]
    print('Scoped tests:', len(paths), flush=True)
    for path in paths:
        print('Selected:', path, flush=True)
    if not paths:
        return 0
    env = dict(os.environ, DATABASE_URL=PLACEHOLDER_DATABASE)
    return subprocess.run(shlex.split(runner) + paths, cwd=root, env=env).returncode


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--runner', required=True)
    parser.add_argument('files', nargs='*')
    args = parser.parse_args()
    return run_scoped_tests(args.root, args.runner, args.files)


if __name__ == '__main__':
    raise SystemExit(main())
