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


def import_targets(specifier, test, root, base, aliases):
    if specifier.startswith('.'):
        return [test.parent / specifier]
    # Source-contract suites also name root-relative files as path#symbol keys.
    source_path = Path(specifier.partition('#')[0])
    targets = [root / source_path] if source_path.suffix in SOURCE_SUFFIXES else []
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
                    candidates = import_targets(specifier, test, root, base, aliases)
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


def run_command(command, cwd=Path('.')):
    print('Component check:', shlex.join(command), 'cwd=' + str(cwd), flush=True)
    subprocess.run(command, cwd=cwd, check=True)


def component_checks(root, phase, files):
    paths = [Path(name) for name in files]
    existing = [path for path in paths if path.is_file()]
    marketing = root == Path('web') and any(path.parts[0] == 'marketing' for path in paths)
    if phase == 'lint':
        for path in paths:
            supported = (path.is_relative_to(root) or path.suffix in ('.md', '.sh', '.py')
                         or str(path).startswith(('docs/', 'changelog.d/'))
                         or str(path) == '.agents/head-checks.conf'
                         or (root == Path('web') and (str(path).startswith('marketing/') or (path.parent == Path('bin') and path.suffix == '.ts')))
                         or (path.parent == Path('.github/workflows') and path.suffix in ('.yml', '.yaml')))
            if not supported:
                print('UNCHECKED:', path, flush=True)
        python_files = [str(path) for path in existing if path.suffix == '.py']
        if python_files:
            run_command(['python3', '-m', 'py_compile', *python_files])
        workflows = [str(path) for path in existing if path.parent == Path('.github/workflows') and path.suffix in ('.yml', '.yaml')]
        if workflows:
            run_command(['bun', '-e', 'for (const f of process.argv.slice(1)) { Bun.YAML.parse(await Bun.file(f).text()); console.log("YAML parsed:", f); }', *workflows])
        if marketing:
            run_command(['bun', 'install', '--frozen-lockfile', '--ignore-scripts'], Path('marketing'))
            targets = [str(path.relative_to('marketing')) for path in existing if path.is_relative_to('marketing') and path.suffix in ('.ts', '.tsx', '.js', '.jsx', '.json', '.jsonc', '.css')]
            if targets:
                # Marketing has its own tsconfig and no lint config; use Biome's defaults there.
                run_command(['bunx', '--package', '@biomejs/biome', 'biome', 'check', '--no-errors-on-unmatched', '--', *targets], Path('marketing'))
    elif phase == 'typecheck':
        if marketing:
            run_command(['bunx', '--no-install', 'next', 'typegen'], Path('marketing'))
            run_command(['bunx', '--no-install', 'tsc', '--noEmit'], Path('marketing'))
    elif phase == 'tests':
        directories = set()
        for path in existing:
            if path.suffix == '.py':
                directories.update(directory for directory in (path.parent / 'tests', path.parent.parent / 'tests') if directory.is_dir())
        for directory in sorted(directories):
            run_command(['python3', '-m', 'pytest', str(directory)])
        if root == Path('web'):
            bin_files = [str(path) for path in paths if path.parent == Path('bin') and path.suffix == '.ts']
            if bin_files:
                result = run_scoped_tests(Path('bin'), 'bun test --isolate', bin_files)
                if result:
                    return result
            if marketing:
                result = run_scoped_tests(Path('marketing'), 'bun test --isolate', files)
                if result:
                    return result
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--runner', required=True)
    parser.add_argument('--components', choices=('lint', 'typecheck', 'tests'))
    parser.add_argument('files', nargs='*')
    args = parser.parse_args()
    try:
        if args.components:
            return component_checks(args.root, args.components, args.files)
        return run_scoped_tests(args.root, args.runner, args.files)
    except subprocess.CalledProcessError as error:
        return error.returncode


if __name__ == '__main__':
    raise SystemExit(main())
