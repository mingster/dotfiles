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
PLACEHOLDER_DATABASE = 'postgresql://test:test@localhost:5432/test'


def is_test(path):
    # Playwright specs (*.spec.*) under an e2e directory are not bun tests.
    # *.test.* files there stay bun tests (for example app/api/e2e route tests).
    if 'e2e' in path.parts and '.spec.' in path.name:
        return False
    # *.db.spec.* files are integration specs that need a test database.
    if '.db.spec.' in path.name:
        return False
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


def select_changed_tests(root, files, on_test_change=()):
    root = root.resolve()
    changed = [Path(name).resolve() for name in files if Path(name).resolve().is_relative_to(root)]
    tests = set()
    # Repo-wide contract suites scan every test file, so any added, renamed or deleted test triggers them.
    if any(is_test(path) for path in changed):
        for pattern in on_test_change:
            tests.update(item for item in root.glob(pattern) if item.is_file() and is_test(item))
    modules = {source_key(path) for path in changed if path.suffix in SOURCE_SUFFIXES}
    for path in changed:
        if path.is_file() and is_test(path):
            tests.add(path)
        if path.suffix in SOURCE_SUFFIXES:
            for pattern in (path.stem + '.test.*', path.stem + '.spec.*', '__tests__/*.test.*', '__tests__/*.spec.*'):
                tests.update(item for item in path.parent.glob(pattern) if item.is_file() and is_test(item))
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


def ensure_dependencies(root):
    """Install packages and generate the Prisma client in a fresh checkout. 0 means ready."""
    root = Path(root)
    if not (root / 'package.json').is_file() or (root / 'node_modules').exists():
        return 0
    env = dict(os.environ, DATABASE_URL=PLACEHOLDER_DATABASE)
    commands = [['bun', 'install', '--frozen-lockfile', '--ignore-scripts']]
    if (root / 'prisma' / 'schema.prisma').is_file() or (root / 'prisma.config.ts').is_file():
        commands.append(['bunx', '--no-install', 'prisma', 'generate'])
    for command in commands:
        print('Component check:', shlex.join(command), 'cwd=' + str(root), flush=True)
        result = subprocess.run(command, cwd=root, env=env)
        if result.returncode and command[:2] == ['bunx', '--no-install']:
            fallback = ['bunx', 'prisma', 'generate']
            print('Component check:', shlex.join(fallback), 'cwd=' + str(root), flush=True)
            result = subprocess.run(fallback, cwd=root, env=env)
        if result.returncode:
            return result.returncode
    return 0


def browser_test(path):
    return bool(re.search(r"(?:from\s*|require\s*\()?[\"'](?:@playwright/test|playwright(?:-core)?)[\"']|chromium\.launch", path.read_text()))


def browser_available(root):
    # Probe the installed browser path without launching a browser.
    try:
        probe = subprocess.run(['bun', '-e', 'const {chromium}=await import("playwright"); process.exit(require("fs").existsSync(chromium.executablePath())?0:1)'], cwd=root, capture_output=True, timeout=10)
        return probe.returncode == 0
    except (OSError, subprocess.SubprocessError):
        return False


def run_scoped_tests(root, runner, files, on_test_change=()):
    tests = select_changed_tests(root, files, on_test_change)
    browser = [path for path in tests if browser_test(path)]
    if browser and not browser_available(root):
        for path in browser:
            print('UNCHECKED: ' + str(path.relative_to(root.resolve())) + ' (Playwright browser unavailable; rerun on browser host)', flush=True)
        tests = [path for path in tests if path not in browser]
    paths = ['./' + str(path.relative_to(root.resolve())) for path in tests]
    print('Scoped tests:', len(paths), flush=True)
    for path in paths:
        print('Selected:', path, flush=True)
    if not paths:
        return 0
    result = ensure_dependencies(root)
    if result:
        return result
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
    parser.add_argument('--on-test-change', action='append', default=[], metavar='GLOB',
                        help='tests under --root to add whenever any changed file is a test')
    parser.add_argument('files', nargs='*')
    args = parser.parse_args()
    try:
        if args.components:
            return component_checks(args.root, args.components, args.files)
        return run_scoped_tests(args.root, args.runner, args.files, args.on_test_change)
    except subprocess.CalledProcessError as error:
        return error.returncode


if __name__ == '__main__':
    raise SystemExit(main())
