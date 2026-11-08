#!/usr/bin/env bash
# Submit command text to the real PreToolUse hook; no workload is executed.
set -euo pipefail
python3 - "$(cd "$(dirname "$0")/../.." && pwd)" <<'PY'
import json
import pathlib
import subprocess
import sys
import unittest

hook = pathlib.Path(sys.argv[1]) / 'templates/agent-team/.claude/hooks/guard-bash.py'
GATE = '~/dotfiles/script/heavy-gate.sh'
MEASURE = f'{GATE} --measure -- '
HEAVY = f'{GATE} --weight {{}} -- '


class HeavyGuardTests(unittest.TestCase):
    def check_command(self, command, *, weight=None, measure=False, original=None):
        result = subprocess.run([sys.executable, '-I', str(hook)],
                                input=json.dumps({'tool_name': 'Bash', 'tool_input': {'command': command}}),
                                capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, '')
        if weight is None and not measure:
            self.assertEqual(result.stdout, '')
            return
        self.assertTrue(result.stdout)
        reason = json.loads(result.stdout)['hookSpecificOutput']['permissionDecisionReason']
        if measure:
            self.assertIn('--measure --', reason)
            self.assertIn(original or command, reason)
        else:
            self.assertEqual(json.loads(result.stdout), {'hookSpecificOutput': {
                'hookEventName': 'PreToolUse', 'permissionDecision': 'deny',
                'permissionDecisionReason': 'Heavy jobs must run through the shared machine gate. '
                f'Run: {HEAVY.format(weight)}{original or command}'}})

    def test_bun_test_is_free(self):
        self.check_command('bun test x')


def command_test(command, *, weight=None, measure=False, original=None):
    def test(self):
        self.check_command(command, weight=weight, measure=measure, original=original)
    return test


heavy_denied = [
    ('bun_x_playwright', 'bun x playwright test', 2),
    ('bun_x_next_build', 'bun x next build', 2),
    ('next_build', 'next build', 2),
    ('bun_build', 'bun run build', 2),
    ('playwright', 'playwright test x.spec.ts', 2),
    ('bunx_playwright', 'bunx playwright test', 2),
    ('regression', 'bun run test:regression', 2),
    ('regression_variant', 'bun run test:regression:mobile x', 2),
    ('npx_playwright', 'npx playwright test', 2),
    ('bunx_next', 'bunx next build', 2),
]
for name, command, weight in heavy_denied:
    setattr(HeavyGuardTests, 'test_deny_' + name, command_test(command, weight=weight))
    setattr(HeavyGuardTests, 'test_gated_' + name,
            command_test(f'{HEAVY.format(weight)}{command}'))

measure_denied = [
    ('bun_x_tsc', 'bun x tsc --noEmit'),
    ('bun_run_tsc', 'bun run tsc --noEmit'),
    ('bunx_tsc', 'bunx tsc --noEmit'),
    ('tsc', 'tsc --noEmit'),
    ('npx_tsc', 'npx tsc --noEmit'),
]
for name, command in measure_denied:
    setattr(HeavyGuardTests, 'test_deny_' + name, command_test(command, measure=True))
    setattr(HeavyGuardTests, 'test_gated_' + name, command_test(f'{MEASURE}{command}'))

allowed = [
    ('bun_test', 'bun --cwd web test'),
    ('bun_run_test', 'bun run test x'),
    ('python_gate', 'python3 ~/dotfiles/script/heavy-gate.py gate --weight 2 -- bunx playwright test'),
    ('direct_python_measure', f'{MEASURE}bunx tsc --noEmit'),
    ('shell_gate', 'bash ~/dotfiles/script/heavy-gate.sh --weight 2 -- next build'),
    ('remote_heavy', '~/dotfiles/script/remote-heavy.sh -- bunx playwright test'),
    ('head_checks', '~/dotfiles/script/head-checks.sh --ref deadbeef'),
    ('ssh', 'ssh other-host bun test x'),
    ('grep', 'grep "bun test" README.md'),
    ('light_bun', 'bun install'),
    ('bun_dev', 'bun run dev'),
]
for name, command in allowed:
    setattr(HeavyGuardTests, 'test_allow_' + name, command_test(command))

chained = [
    ('semicolon_build', 'git status; next build', 2, 'next build'),
    ('semicolon_tsc', 'git status; bunx tsc --noEmit', None, 'bunx tsc --noEmit'),
    ('pipe_tsc', 'bunx tsc --noEmit | tail -20', None, 'bunx tsc --noEmit'),
]
for name, command, weight, original in chained:
    if weight:
        setattr(HeavyGuardTests, 'test_deny_chain_' + name, command_test(command, weight=weight, original=original))
    else:
        setattr(HeavyGuardTests, 'test_deny_chain_' + name, command_test(command, measure=True, original=original))


unittest.main(argv=[sys.argv[0]], verbosity=2)
PY
