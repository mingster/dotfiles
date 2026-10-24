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


class HeavyGuardTests(unittest.TestCase):
    def check_command(self, command, weight=None, original=None):
        result = subprocess.run([sys.executable, '-I', str(hook)],
                                input=json.dumps({'tool_name': 'Bash', 'tool_input': {'command': command}}),
                                capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, '')
        if weight is None:
            self.assertEqual(result.stdout, '')
        else:
            self.assertTrue(result.stdout, 'heavy command was allowed')
            self.assertEqual(json.loads(result.stdout), {'hookSpecificOutput': {
                'hookEventName': 'PreToolUse', 'permissionDecision': 'deny',
                'permissionDecisionReason': 'Heavy jobs must run through the shared machine gate. '
                f'Run: ~/dotfiles/script/heavy-gate.sh --weight {weight} -- {original or command}'}})

    def test_direct_bun_test_requires_gate(self):
        self.check_command('bun test x', 1)


def command_test(command, weight=None, original=None):
    def test(self):
        self.check_command(command, weight, original)
    return test


denied = [
    ('bun_cwd_test', 'bun --cwd web test', 1),
    ('bun_cwd_equals_test', 'bun --cwd=web test', 1),
    ('bun_global_flags', 'bun --silent --cwd "web app" test', 1),
    ('bun_x_tsc', 'bun x tsc --noEmit', 1),
    ('bun_x_playwright', 'bun x playwright test', 2),
    ('bun_x_next_build', 'bun x next build', 2),
    ('bun_run_tsc', 'bun run tsc --noEmit', 1),
    ('bun_cwd_run_tsc', 'bun --cwd web run tsc', 1),
    ('bun_run_test', 'bun run test x', 1),
    ('bunx_tsc', 'bunx tsc --noEmit', 1),
    ('tsc', 'tsc --noEmit', 1),
    ('next_build', 'next build', 2),
    ('bun_build', 'bun run build', 2),
    ('playwright', 'playwright test x.spec.ts', 2),
    ('bunx_playwright', 'bunx playwright test', 2),
    ('regression', 'bun run test:regression', 2),
    ('regression_variant', 'bun run test:regression:mobile x', 2),
    ('absolute_program', '/opt/bin/bun test x', 1),
    ('env_wrapper', 'env CI=1 bun test x', 1),
    ('command_wrapper', 'command bun test x', 1),
    ('npx_tsc', 'npx tsc --noEmit', 1),
    ('npx_playwright', 'npx playwright test', 2),
    ('bunx_next', 'bunx next build', 2),
]
for name, command, weight in denied:
    setattr(HeavyGuardTests, 'test_deny_' + name, command_test(command, weight))
    setattr(HeavyGuardTests, 'test_gated_' + name,
            command_test(f'~/dotfiles/script/heavy-gate.sh --weight {weight} -- {command}'))

allowed = [
    ('python_gate', 'python3 ~/dotfiles/script/heavy-gate.py gate --weight 1 -- bun test x'),
    ('direct_python_gate', '~/dotfiles/script/heavy-gate.py gate -- bunx tsc --noEmit'),
    ('shell_gate', 'bash ~/dotfiles/script/heavy-gate.sh --weight 2 -- next build'),
    ('remote_heavy', '~/dotfiles/script/remote-heavy.sh -- bun test x'),
    ('head_checks', '~/dotfiles/script/head-checks.sh -- bun test x'),
    ('ssh', 'ssh other-host bun test x'),
    ('ssh_quoted', 'ssh other-host "cd web && bunx playwright test"'),
    ('grep', 'grep "bun test" README.md'),
    ('rg', 'rg "bunx tsc|playwright" docs'),
    ('git_add', 'git add bun test playwright'),
    ('cat', 'cat playwright.config.ts'),
    ('edit', "sed -i '' 's/bun test/bun run test/' README.md"),
    ('echo', "echo 'bun test; next build'"),
    ('unparseable', "bun test 'unterminated"),
    ('light_bun', 'bun install'),
    ('bun_cwd_lint', 'bun --cwd web run lint'),
    ('bun_dev', 'bun run dev'),
    ('light_next', 'next --version'),
    ('shell_gated', "sh -c '~/dotfiles/script/heavy-gate.sh -- bun test x'"),
]
for name, command in allowed:
    setattr(HeavyGuardTests, 'test_allow_' + name, command_test(command))

chained = [
    ('cd', 'cd web && bun test x', 'bun test x', 1),
    ('pipe', 'bunx tsc --noEmit | tail -20', 'bunx tsc --noEmit', 1),
    ('semicolon', 'git status; next build', 'next build', 2),
    ('shell', "bash -c 'cd web && bun test x'", 'bun test x', 1),
    ('gate_is_segment_local', '~/dotfiles/script/heavy-gate.sh -- bun test x && bun test y', 'bun test y', 1),
    ('ssh_is_segment_local', 'ssh other-host true && bun test x', 'bun test x', 1),
]
for name, command, original, weight in chained:
    setattr(HeavyGuardTests, 'test_deny_chain_' + name, command_test(command, weight, original))

control_flow = [
    ('if_condition', 'if bun test; then true; fi', 'if bun test'),
    ('then', 'if true; then bun test; fi', 'then bun test'),
    ('else', 'if false; then true; else bun test; fi', 'else bun test'),
    ('elif', 'if false; then true; elif bun test; then true; fi', 'elif bun test'),
    ('while', 'while bun test; do true; done', 'while bun test'),
    ('until', 'until bun test; do true; done', 'until bun test'),
    ('do', 'while true; do bun test; done', 'do bun test'),
    ('negated', '! bun test', '! bun test'),
    ('nested_keywords', 'if ! bun test; then true; fi', 'if ! bun test'),
    ('then_env', 'if true; then CI=1 command bun test; fi', 'then CI=1 command bun test'),
    ('then_and', 'if true; then echo ready && bun test; fi', 'bun test'),
    ('then_semicolon', 'if true; then echo ready; bun test; fi', 'bun test'),
    ('do_and', 'while true; do echo ready && bun test; done', 'bun test'),
    ('do_semicolon', 'while true; do echo ready; bun test; done', 'bun test'),
]
for name, command, original in control_flow:
    setattr(HeavyGuardTests, 'test_deny_control_' + name, command_test(command, 1, original))
    gated = command.replace('bun test', '~/dotfiles/script/heavy-gate.sh --weight 1 -- bun test')
    setattr(HeavyGuardTests, 'test_gated_control_' + name, command_test(gated))


unittest.main(argv=[sys.argv[0]], verbosity=2)
PY
