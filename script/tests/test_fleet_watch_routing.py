"""Family pick, sticky verifier, role preamble, and the builder finish bounce."""
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
import unittest.mock
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('fleet_watch_routing', ROOT / 'fleet-watch.py')
fw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fw)

HEAD = 'a' * 40
NEW = 'b' * 40
REPO = 'o/r'


def _load(name):
    path = ROOT / name
    mod_spec = importlib.util.spec_from_file_location(name.replace('.py', '').replace('-', '_'), path)
    module = importlib.util.module_from_spec(mod_spec)
    mod_spec.loader.exec_module(module)
    return module


preamble = _load('worker-preamble.py')
gate = _load('pr-body-gate.py')


class FamilyCli(unittest.TestCase):
    def test_family_command_prints_the_shared_map(self):
        out = subprocess.run(
            [sys.executable, str(ROOT / 'usage-gate.py'), 'family', '--agent', 'cursor', '--model', 'grok-4.7-high'],
            capture_output=True, text=True, check=False,
        )
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertEqual(out.stdout.strip(), 'grok')
        unknown = subprocess.run(
            [sys.executable, str(ROOT / 'usage-gate.py'), 'family', '--agent', 'codex', '--model', 'opus'],
            capture_output=True, text=True, check=False,
        )
        self.assertEqual(unknown.stdout.strip(), 'unknown')


class ChoosePick(unittest.TestCase):
    def test_skips_the_same_family(self):
        data = {
            'selected': {'provider': 'claude', 'model': 'sonnet', 'eligible': True},
            'candidates': [{'provider': 'cursor', 'model': 'grok-4.7-high', 'eligible': True}],
        }
        self.assertEqual(
            fw.choose_pick(data, avoid=('claude', 'opus')),
            ('cursor', 'grok-4.7-high', ''),
        )

    def test_fallback_is_a_different_claude_model(self):
        data = {
            'selected': {'provider': 'claude', 'model': 'opus', 'eligible': False, 'same_family_fallback': True},
            'candidates': [
                {'provider': 'claude', 'model': 'opus', 'eligible': False, 'same_family_fallback': True},
                {'provider': 'claude', 'model': 'sonnet', 'eligible': False, 'same_family_fallback': True},
            ],
        }
        self.assertEqual(
            fw.choose_pick(data, avoid=('claude', 'opus')),
            ('claude', 'sonnet', 'same-family-different-model'),
        )

    def test_exact_pair_never_wins(self):
        data = {'selected': {'provider': 'claude', 'model': 'opus', 'eligible': True, 'same_family_fallback': True}}
        self.assertIsNone(fw.choose_pick(data, avoid=('claude', 'opus')))

    def test_pick_role_passes_avoid_family(self):
        seen = []

        def run(command, **_kwargs):
            seen.append(command)
            class Proc:
                returncode = 0
                stdout = '{"selected": null, "candidates": []}'
                stderr = ''
            return Proc()

        fw.pick_role('qa-sdet', run=run, avoid_family='claude')
        self.assertIn('--avoid-family', seen[0])
        self.assertIn('claude', seen[0])
        self.assertIn('--auto', seen[0])


class BodyGate(unittest.TestCase):
    def test_unchecked_and_missing_self_check(self):
        self.assertEqual(gate.finish_block_reason('## Acceptance\n- [ ] open\n'), 'unchecked Acceptance items')
        self.assertEqual(
            gate.finish_block_reason('## Acceptance\n- [x] done\n'),
            'PR body needs ## Self-check with a command and its output',
        )
        self.assertIsNone(gate.finish_block_reason(
            '## Acceptance\n- [x] done\n\n## Self-check\n$ bash script/checks-local.sh\nexit 0\n'
        ))


class Preamble(unittest.TestCase):
    def test_resolved_paths_are_in_the_block(self):
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp) / 'home'
            for rel in (
                '.agents/skills/poteto-mode/SKILL.md',
                '.agents/skills/orca-adapter/ORCA-ADAPTER.md',
                '.claude/agents/qa-sdet.md',
                '.claude/agents/fullstack-dev.md',
            ):
                path = home / rel
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text('x\n', encoding='utf-8')
            text = preamble.prepend('Refs o/r#1\n', 'qa-sdet', home=str(home), dotfiles=str(home))
            poteto, adapter, role_file = preamble.paths('qa-sdet', home=str(home), dotfiles=str(home))
            for path in (poteto, adapter, role_file):
                self.assertTrue(os.path.isfile(path), path)
                self.assertIn(path, text)
            self.assertLess(text.find('poteto-mode/SKILL.md'), text.find('Refs o/r#1'))
            self.assertEqual(preamble.prepend(text, 'qa-sdet', home=str(home)), text)

    def test_every_brief_builder_names_the_three_paths(self):
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp) / 'home'
            root = Path(tmp) / 'repo'
            root.mkdir()
            for rel in (
                '.agents/skills/poteto-mode/SKILL.md',
                '.agents/skills/orca-adapter/ORCA-ADAPTER.md',
                '.claude/agents/qa-sdet.md',
                '.claude/agents/fullstack-dev.md',
            ):
                path = home / rel
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text('x\n', encoding='utf-8')
            config = {
                'issue_scan': {
                    'run': 'run_x', 'from_terminal': 'term_c',
                    'repo_roots': {REPO: str(root)}, 'role': 'fullstack-dev',
                },
            }
            issue = {'number': 4, 'body': 'do the thing'}
            pr = {'number': 4, 'headRefOid': HEAD, 'comments': [{'body': 'Checks: FAIL head=%s\nbroke' % HEAD}]}
            env = {'HOME': str(home), 'DOTFILES': str(home)}
            with unittest.mock.patch.dict(os.environ, env):
                commands = [
                    fw.build_issue_start_command(config, REPO, issue),
                    fw.build_rework_start_command(config, REPO, pr),
                    fw.build_backlog_sweep_command(config, REPO, 'fullstack-dev'),
                    fw.build_babysit_command(
                        config, REPO, {'number': 4, 'headRefOid': HEAD}, 'verifier',
                        'cursor', 'grok-4.7-high', ('claude', 'opus'), 'same-family-different-model',
                    ),
                ]
                for command in commands:
                    text = Path(command[command.index('--spec') + 1]).read_text(encoding='utf-8')
                    self.assertIn('poteto-mode/SKILL.md', text)
                    self.assertIn('ORCA-ADAPTER.md', text)
                    self.assertTrue('fullstack-dev.md' in text or 'qa-sdet.md' in text, text[:400])
            verifier = Path(commands[-1][commands[-1].index('--spec') + 1]).read_text(encoding='utf-8')
            self.assertIn('same-family-different-model', verifier)


class Sticky(unittest.TestCase):
    def pr(self, head=NEW, mergeable='MERGEABLE'):
        return {
            'number': 7, 'state': 'OPEN', 'isDraft': False, 'headRefOid': head, 'headRefName': 'b',
            'statusCheckRollup': [{'name': 'checks', 'conclusion': 'SUCCESS', 'status': 'COMPLETED'}],
            'comments': [], 'labels': [], 'mergeable': mergeable,
            'body': 'Builder: agent=claude model=opus',
        }

    def worker(self):
        return {
            'dispatchId': 'ctx_v', 'terminal': 'term_v',
            'workerState': 'ready', 'dispatchStatus': 'dispatched', 'terminalState': 'active',
            'projection': {
                'role': 'worker', 'outcome': 'in_progress',
                'liveness': {'verdict': 'live'},
                'stage': {'worker': 'ready', 'dispatch': 'dispatched'},
            },
            '_task_title': 'qa-sdet - verify PR #7',
        }

    def run_pass(self, pr, state, now, last, mergeable_worker=True):
        notes = []
        released = []
        starts = []
        with tempfile.TemporaryDirectory() as root:
            config = {
                'issue_scan': {'run': 'run_live', 'from_terminal': 'term_live', 'repo_roots': {REPO: root}},
                'babysit': {'repos': [REPO], 'startup': '/bin/true'},
            }
            fw.babysit_pass(
                config, state, [self.worker()] if mergeable_worker else [],
                pr_fetch=lambda _repo: [pr],
                start_worker=lambda command: starts.append(command) or 0,
                pick=lambda role, avoid_family=None: {
                    'selected': {'provider': 'cursor', 'model': 'grok-4.7-high', 'eligible': True},
                },
                owner_check=lambda _pr: None,
                release_worker=lambda dispatch: released.append(dispatch),
                notify_worker=lambda terminal, text: notes.append((terminal, text)),
                now=now,
                term_times={'term_v': last} if last is not None else {},
            )
        return notes, released, starts

    def test_new_head_stays_with_the_live_verifier(self):
        now = 1_700_000_000
        state = {'verifier_head': {REPO: {'7': HEAD}}}
        notes, released, starts = self.run_pass(self.pr(), state, now, now - 10)
        self.assertEqual(starts, [])
        self.assertEqual(released, [])
        self.assertEqual(notes[0][0], 'term_v')
        self.assertIn(NEW, notes[0][1])

    def test_idle_verifier_is_released(self):
        now = 1_700_000_000
        state = {'verifier_head': {REPO: {'7': HEAD}}}
        notes, released, starts = self.run_pass(self.pr(), state, now, now - 3601)
        self.assertEqual(starts, [])
        self.assertEqual(notes, [])
        self.assertEqual(released, ['ctx_v'])

    def test_red_head_releases_an_idle_verifier_without_a_new_brief(self):
        now = 1_700_000_000
        state = {'verifier_head': {REPO: {'7': HEAD}}}
        _notes, released, starts = self.run_pass(self.pr(HEAD, 'CONFLICTING'), state, now, now - 3601)
        self.assertEqual(starts, [])
        self.assertEqual(released, ['ctx_v'])

    def test_missing_timestamp_does_not_release(self):
        now = 1_700_000_000
        state = {'verifier_head': {REPO: {'7': HEAD}}}
        notes, released, starts = self.run_pass(self.pr(), state, now, None)
        self.assertEqual(released, [])
        self.assertEqual(starts, [])
        self.assertIn(NEW, notes[0][1])


class Bounce(unittest.TestCase):
    def worker(self, title='fullstack-dev - build the thing', number=8):
        return {
            'dispatchId': 'ctx_b', 'terminal': 'term_b',
            'githubPullRequestNumber': number,
            '_task_title': title,
            'projection': {'role': 'worker', 'workspace': {'id': 'wt::/tmp/not-a-checkout'}},
        }

    def bounce(self, body, message=None, worker=None):
        sent = []
        state = {}
        config = {'issue_scan': {'repo_roots': {REPO: '/tmp/not-a-checkout'}}}
        message = message or {
            'id': 'm1', 'type': 'worker_done',
            'payload': json.dumps({'dispatchId': 'ctx_b', 'outcome': 'succeeded'}),
        }
        lines = fw.bounce_builder_dones(
            [message], [worker or self.worker()],
            lambda repo, number: body,
            lambda terminal, text: sent.append((terminal, text)),
            state, config,
        )
        return lines, sent, state

    def test_unchecked_acceptance_bounces_once(self):
        lines, sent, state = self.bounce('## Acceptance\n- [ ] open\n')
        self.assertIn('unchecked Acceptance items', lines[0])
        self.assertEqual(sent[0][0], 'term_b')
        self.assertIn('worker_done bounced:', sent[0][1])
        sent2 = []
        lines2 = fw.bounce_builder_dones(
            [{'id': 'm1', 'type': 'worker_done', 'payload': {'dispatchId': 'ctx_b'}}],
            [self.worker()], lambda _r, _n: '## Acceptance\n- [ ] open\n',
            lambda terminal, text: sent2.append((terminal, text)),
            state, {'issue_scan': {'repo_roots': {REPO: '/tmp/not-a-checkout'}}},
        )
        self.assertEqual(lines2, [])
        self.assertEqual(sent2, [])

    def test_missing_self_check_bounces_and_a_verifier_does_not(self):
        lines, sent, _state = self.bounce('## Acceptance\n- [x] done\n')
        self.assertIn('Self-check', lines[0])
        self.assertTrue(sent)
        lines, sent, _state = self.bounce(
            '## Acceptance\n- [ ] open\n',
            worker=self.worker('qa-sdet - verify PR #8'),
        )
        self.assertEqual(lines, [])
        self.assertEqual(sent, [])

    def test_a_failed_done_is_left_alone(self):
        lines, sent, _state = self.bounce(
            '## Acceptance\n- [ ] open\n',
            {'id': 'm9', 'type': 'worker_done', 'outcome': 'failed', 'payload': {'dispatchId': 'ctx_b'}},
        )
        self.assertEqual(lines, [])
        self.assertEqual(sent, [])


if __name__ == '__main__':
    unittest.main()
