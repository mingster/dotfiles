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


class BatchVerifier(unittest.TestCase):
    """dotfiles #1082: a verifier start skips a PR that a live batch verifier lists."""

    def worker(self, title):
        return {'dispatchId': 'ctx_v', 'terminal': 'term_v', 'workerState': 'ready',
                'dispatchStatus': 'dispatched', 'terminalState': 'active',
                'projection': {'role': 'worker', 'liveness': {'verdict': 'live'}},
                '_task_title': title}

    def test_every_pr_in_a_batch_title_has_a_live_verifier(self):
        workers = [self.worker('qa-sdet - verify PRs #8107, #8109 and o/r#8111')]
        for number in (8107, 8109, 8111):
            with self.subTest(number=number):
                self.assertTrue(fw.live_verifier_for_pr({'number': number}, workers))
        self.assertFalse(fw.live_verifier_for_pr({'number': 8110}, workers))

    def test_single_pr_title_still_matches_only_that_pr(self):
        workers = [self.worker('qa-sdet - verify PR #7')]
        self.assertTrue(fw.live_verifier_for_pr({'number': 7}, workers))
        self.assertFalse(fw.live_verifier_for_pr({'number': 8}, workers))


class FamilyCli(unittest.TestCase):
    def test_family_command_prints_the_shared_map(self):
        out = subprocess.run(
            [sys.executable, str(ROOT / 'usage-gate.py'), 'family', '--agent', 'cursor', '--model', 'grok-4.7-high'],
            capture_output=True, text=True, check=False,
        )
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertEqual(out.stdout.strip(), 'grok')
        unknown = subprocess.run(
            [sys.executable, str(ROOT / 'usage-gate.py'), 'family', '--agent', 'no-such-agent', '--model', 'no-such-model'],
            capture_output=True, text=True, check=False,
        )
        self.assertEqual(unknown.stdout.strip(), 'unknown')

    def test_family_maps_model_by_prefix_regardless_of_agent(self):
        ug = _load('usage-gate.py')
        cases = [
            ('fullstack-dev', 'gemini-4-argon', 'gemini'),
            ('antigravity', 'gemini-4-argon-medium', 'gemini'),
            ('fullstack-dev', 'claude-sonnet-5-5-medium', 'claude'),
            ('no-such-agent', 'sonnet', 'claude'),
            ('no-such-agent', 'opus', 'claude'),
            ('fullstack-dev', 'grok-4.7-high', 'grok'),
            ('cursor', 'grok-4.7-high', 'grok'),
        ]
        for agent, model, expected in cases:
            with self.subTest(agent=agent, model=model):
                self.assertEqual(ug.model_family(agent, model), expected)
                proc = subprocess.run(
                    [sys.executable, str(ROOT / 'usage-gate.py'), 'family', '--agent', agent, '--model', model],
                    capture_output=True, text=True, check=False,
                )
                self.assertEqual(proc.returncode, 0, proc.stderr)
                self.assertEqual(proc.stdout.strip(), expected)


class RoutingPick(unittest.TestCase):
    def test_pick_never_returns_codex(self):
        # Deliberate refuse (#1074): the routing pick never returns Codex or ChatGPT.
        ug = _load('usage-gate.py')
        presets = ROOT.parent / '.orca' / 'presets.json'

        def allowed(*_args, **_kwargs):
            return {"verdict": "allowed", "ceiling": 95, "weekly_used": 10,
                    "reserve": 0, "resets_at": 2_000_000_000}

        with unittest.mock.patch.dict(os.environ, {"USAGE_GATE_PRESETS": str(presets)}), \
                unittest.mock.patch.object(ug, "run", side_effect=allowed), \
                unittest.mock.patch.object(ug, "antigravity_models", return_value=None):
            roles = ug.load_presets()["roles"]
            self.assertGreater(len(roles), 0)
            for role in roles:
                with self.subTest(role=role):
                    result = ug.pick(role, None, None, None, None)
                    selected = result["selected"]
                    self.assertIsNotNone(selected, role)
                    chosen = f"{selected['provider']} {selected['model']}".lower()
                    self.assertNotIn("codex", chosen)
                    self.assertNotIn("chatgpt", chosen)
                    for candidate in result["candidates"]:
                        text = f"{candidate['provider']} {candidate['model']}".lower()
                        self.assertNotIn("codex", text)
                        self.assertNotIn("chatgpt", text)


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

    def test_unlinked_acceptance_issue_and_issue_arg(self):
        body = (
            '## Acceptance\n#42 acceptance:\n- [x] done\n\n'
            '## Self-check\n$ bash script/checks-local.sh\nexit 0\n'
        )
        self.assertEqual(gate.finish_block_reason(body), 'PR body needs Closes #42 or Refs #42')
        self.assertIsNone(gate.finish_block_reason('Closes #42\n\n' + body))
        self.assertIsNone(gate.finish_block_reason('Refs o/r#42\n\n' + body))
        plain = '## Acceptance\n- [x] done\n\n## Self-check\n$ bash script/checks-local.sh\nexit 0\n'
        self.assertEqual(gate.finish_block_reason(plain, issue=42), 'PR body needs Closes #42 or Refs #42')
        self.assertIsNone(gate.finish_block_reason('Fixes #42\n\n' + plain, issue=42))


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
    def pr(self, head=NEW, mergeable='MERGEABLE', review='PASS'):
        comments = []
        if review:
            comments.append({'body': 'Review: %s head=%s' % (review, head)})
        return {
            'number': 7, 'state': 'OPEN', 'isDraft': False, 'headRefOid': head, 'headRefName': 'b',
            'statusCheckRollup': [{'name': 'checks', 'conclusion': 'SUCCESS', 'status': 'COMPLETED'}],
            'comments': comments, 'labels': [], 'mergeable': mergeable,
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

    def test_merged_or_closed_releases_the_live_verifier(self):
        now = 1_700_000_000
        rows = [
            ('MERGED', {'mergedAt': '2026-11-13T20:01:52Z'}),
            ('CLOSED', {'closedAt': '2026-11-13T20:01:52Z'}),
            ('OPEN', {'mergedAt': '2026-11-13T20:01:52Z'}),
        ]
        for state_name, extra in rows:
            pr = self.pr()
            pr['state'] = state_name
            pr.update(extra)
            notes, released, starts = self.run_pass(pr, {}, now, now)
            self.assertEqual(starts, [], state_name)
            self.assertEqual(released, ['ctx_v'], state_name)
            self.assertEqual(notes, [], state_name)

    def test_closed_list_releases_a_verifier_the_open_list_omits(self):
        now = 1_700_000_000
        merged = self.pr()
        merged['state'] = 'MERGED'
        merged['mergedAt'] = '2026-11-13T20:01:52Z'
        released = []
        starts = []
        with tempfile.TemporaryDirectory() as root:
            config = {
                'issue_scan': {'run': 'run_live', 'from_terminal': 'term_live', 'repo_roots': {REPO: root}},
                'babysit': {'repos': [REPO], 'startup': '/bin/true'},
            }
            fw.babysit_pass(
                config, {}, [self.worker()],
                pr_fetch=lambda _repo: [],
                closed_fetch=lambda _repo: [merged],
                start_worker=lambda command: starts.append(command) or 0,
                pick=lambda role, avoid_family=None: {
                    'selected': {'provider': 'cursor', 'model': 'grok-4.7-high', 'eligible': True},
                },
                owner_check=lambda _pr: None,
                release_worker=lambda dispatch: released.append(dispatch),
                notify_worker=lambda _terminal, _text: None,
                now=now,
                term_times={'term_v': now},
            )
        self.assertEqual(starts, [])
        self.assertEqual(released, ['ctx_v'])

    def test_unknown_builder_family_stops_without_dispatching_verifier(self):
        now = 1_700_000_000
        for body in ('Builder: agent=fullstack-dev model=mystery-1', 'Why\n\nNo builder line here.\n'):
            with self.subTest(body=body), tempfile.TemporaryDirectory() as root:
                pr = self.pr()
                pr['body'] = body
                starts = []
                picks = []
                config = {
                    'issue_scan': {'run': 'run_live', 'from_terminal': 'term_live', 'repo_roots': {REPO: root}},
                    'babysit': {'repos': [REPO], 'startup': '/bin/true'},
                }
                _notices, lines, log = fw.babysit_pass(
                    config, {}, [],
                    pr_fetch=lambda _repo, row=pr: [row],
                    start_worker=lambda command: starts.append(command) or 0,
                    pick=lambda role, avoid_family=None: picks.append((role, avoid_family)) or {
                        'selected': {'provider': 'antigravity', 'model': 'gemini-4-argon-high', 'eligible': True},
                    },
                    owner_check=lambda _pr: None,
                    now=now,
                )
                self.assertEqual(starts, [])
                self.assertEqual(picks, [])
                self.assertTrue(any('action=skip unknown-builder-family' in line for line in lines), lines)
                self.assertIn('unknown_builder=7', log)

    def test_verifier_waits_for_review_pass_and_review_fail_sends_back_with_no_verifier(self):
        now = 1_700_000_000
        with tempfile.TemporaryDirectory() as root:
            config = {
                'issue_scan': {'run': 'run_live', 'from_terminal': 'term_live', 'repo_roots': {REPO: root}},
                'babysit': {'repos': [REPO], 'startup': '/bin/true'},
            }
            for review_status, expected_skip in ((None, 'pending'), ('FAIL', 'needs-fix')):
                with self.subTest(review=review_status):
                    starts = []
                    _notices, lines, _log = fw.babysit_pass(
                        config, {}, [],
                        pr_fetch=lambda _repo, rs=review_status: [self.pr(review=rs)],
                        runner_fetch=lambda _repo: {'runners': [
                            {'status': 'online', 'labels': [{'name': 'review'}]},
                        ]},
                        start_worker=lambda command: starts.append(command) or 0,
                        pick=lambda _role, avoid_family=None: {
                            'selected': {'provider': 'cursor', 'model': 'grok-4.7-high', 'eligible': True},
                        },
                        owner_check=lambda _pr: None,
                        now=now,
                    )
                    self.assertEqual(starts, [])
                    self.assertTrue(any(('action=skip %s' % expected_skip) in line for line in lines), lines)
            starts = []
            _notices, lines, _log = fw.babysit_pass(
                config, {}, [],
                pr_fetch=lambda _repo: [self.pr(review='PASS')],
                start_worker=lambda command: starts.append(command) or 0,
                pick=lambda _role, avoid_family=None: {
                    'selected': {'provider': 'cursor', 'model': 'grok-4.7-high', 'eligible': True},
                },
                owner_check=lambda _pr: None,
                now=now,
            )
            self.assertEqual(len(starts), 1)
            self.assertTrue(any('action=verifier' in line for line in lines), lines)

    def test_verifier_requires_same_head_unedited_review_pass_and_skips_status_context_review_fail(self):
        now = 1_700_000_000
        with tempfile.TemporaryDirectory() as root:
            config = {
                'issue_scan': {'run': 'run_live', 'from_terminal': 'term_live', 'repo_roots': {REPO: root}},
                'babysit': {'repos': [REPO], 'startup': '/bin/true'},
            }
            stale_pr = self.pr(head=NEW, review=None)
            stale_pr['comments'] = [{'body': 'Review: PASS head=%s' % HEAD}]
            edited_pr = self.pr(head=NEW, review=None)
            edited_pr['comments'] = [{'body': 'Review: PASS head=%s' % NEW, 'includesCreatedEdit': True}]
            status_fail_pr = self.pr(head=NEW, review=None)
            status_fail_pr['statusCheckRollup'].append({'context': 'review', 'state': 'FAILURE'})
            for case_name, row, expected_skip in (
                ('stale-head-review-pass', stale_pr, 'pending'),
                ('edited-review-pass', edited_pr, 'pending'),
                ('status-context-review-fail', status_fail_pr, 'needs-fix'),
            ):
                with self.subTest(case=case_name):
                    starts = []
                    _notices, lines, _log = fw.babysit_pass(
                        config, {}, [],
                        pr_fetch=lambda _repo, r=row: [r],
                        runner_fetch=lambda _repo: {'total_count': 0, 'runners': []},
                        start_worker=lambda command: starts.append(command) or 0,
                        pick=lambda _role, avoid_family=None: {
                            'selected': {'provider': 'cursor', 'model': 'grok-4.7-high', 'eligible': True},
                        },
                        owner_check=lambda _pr: None,
                        now=now,
                    )
                    self.assertEqual(starts, [], case_name)
                    self.assertTrue(any(('action=skip %s' % expected_skip) in line for line in lines), lines)

    def review_gate_pass(self, runners):
        """One babysit pass on a green PR with no Review receipt; returns (starts, lines, log, fetches)."""
        fetches = []

        def runner_fetch(repo):
            fetches.append(repo)
            if isinstance(runners, Exception):
                raise runners
            return runners

        starts = []
        with tempfile.TemporaryDirectory() as root:
            config = {
                'issue_scan': {'run': 'run_live', 'from_terminal': 'term_live', 'repo_roots': {REPO: root}},
                'babysit': {'repos': [REPO], 'startup': '/bin/true'},
            }
            _notices, lines, log = fw.babysit_pass(
                config, {}, [],
                pr_fetch=lambda _repo: [self.pr(review=None), dict(self.pr(review=None), number=8)],
                start_worker=lambda command: starts.append(command) or 0,
                pick=lambda _role, avoid_family=None: {
                    'selected': {'provider': 'cursor', 'model': 'grok-4.7-high', 'eligible': True},
                },
                owner_check=lambda _pr: None,
                runner_fetch=runner_fetch,
                now=1_700_000_000,
            )
        return starts, lines, log, fetches

    def test_repo_with_no_online_review_runner_falls_back_to_green_checks(self):
        offline = {'total_count': 1, 'runners': [
            {'status': 'offline', 'labels': [{'name': 'self-hosted'}, {'name': 'review'}]},
            {'status': 'online', 'labels': [{'name': 'self-hosted'}, {'name': 'build'}]},
        ]}
        for runners in ({'total_count': 0, 'runners': []}, offline):
            with self.subTest(runners=runners):
                starts, lines, log, fetches = self.review_gate_pass(runners)
                self.assertTrue(starts, lines)
                self.assertTrue(any('action=verifier' in line for line in lines), lines)
                self.assertEqual(log.count('review_gate_no_runner_%s' % REPO), 1, log)
                self.assertEqual(fetches, [REPO])

    def test_repo_with_online_review_runner_still_waits_for_review_pass(self):
        runners = {'total_count': 1, 'runners': [
            {'status': 'online', 'labels': [{'name': 'self-hosted'}, {'name': 'review'}]},
        ]}
        starts, lines, log, _fetches = self.review_gate_pass(runners)
        self.assertEqual(starts, [])
        self.assertTrue(any('action=skip pending' in line for line in lines), lines)
        self.assertNotIn('review_gate_no_runner', str(log))

    def test_runner_api_error_keeps_waiting_and_logs_it(self):
        for runners in (RuntimeError('boom'), None):
            with self.subTest(runners=runners):
                starts, lines, log, _fetches = self.review_gate_pass(runners)
                self.assertEqual(starts, [])
                self.assertTrue(any('action=skip pending' in line for line in lines), lines)
                self.assertEqual(log.count('review_gate_runner_error_%s' % REPO), 1, log)
                self.assertNotIn('review_gate_no_runner', str(log))

    def test_reverify_after_fix_briefs_only_prior_fail_items_and_diff_since_last_verified_head(self):
        now = 1_700_000_000
        pr = self.pr(head=NEW, review='PASS')
        pr['comments'].insert(0, {
            'body': 'Verdict: FAIL head=%s verifier=ctx_v author=ctx_a\n- button click fails\n- missing aria label' % HEAD,
            'createdAt': '2026-11-14T10:00:00Z',
        })
        with tempfile.TemporaryDirectory() as root:
            spec_path = fw.build_babysit_spec(REPO, pr, 'verifier', ('claude', 'opus'), root)
            spec_text = Path(spec_path).read_text(encoding='utf-8')
            self.assertIn('%s..%s' % (HEAD, NEW), spec_text)
            self.assertIn('button click fails', spec_text)
            self.assertIn('missing aria label', spec_text)
            self.assertIn('prior FAIL items', spec_text)
            state = {'verifier_head': {REPO: {'7': HEAD}}}
            notes, released, starts = self.run_pass(pr, state, now, now - 10)
            self.assertEqual(starts, [])
            self.assertEqual(released, [])
            self.assertIn('%s..%s' % (HEAD, NEW), notes[0][1])
            self.assertIn('prior FAIL items', notes[0][1])


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

    def test_issue_builder_without_closes_or_refs_bounces(self):
        body = '## Acceptance\n- [x] done\n\n## Self-check\n$ bash script/checks-local.sh\nexit 0\n'
        lines, sent, _state = self.bounce(body, worker=self.worker('fullstack-dev - #42'))
        self.assertIn('PR body needs Closes #42 or Refs #42', lines[0])
        self.assertTrue(sent)
        lines2, sent2, _state2 = self.bounce(
            'Closes #42\n\n' + body, worker=self.worker('fullstack-dev - #42'),
        )
        self.assertEqual(lines2, [])
        self.assertEqual(sent2, [])


class OwnerReceiptGate(unittest.TestCase):
    def test_pr_owner_only_reason_checks_owner_receipt_in_repo_root(self):
        with tempfile.TemporaryDirectory() as tmp:
            subprocess.run(['git', 'init', '-q', '-b', 'main', tmp], check=True)
            subprocess.run(['git', '-C', tmp, 'config', 'user.email', 't@example.invalid'], check=True)
            subprocess.run(['git', '-C', tmp, 'config', 'user.name', 'Test'], check=True)
            (Path(tmp) / 'AGENTS.md').write_text('base\n', encoding='utf-8')
            subprocess.run(['git', '-C', tmp, 'add', 'AGENTS.md'], check=True)
            subprocess.run(['git', '-C', tmp, 'commit', '-q', '-m', 'init'], check=True)
            base = subprocess.check_output(['git', '-C', tmp, 'rev-parse', 'HEAD'], text=True).strip()
            subprocess.run(['git', '-C', tmp, 'checkout', '-q', '-b', 'feat'], check=True)
            (Path(tmp) / 'AGENTS.md').write_text('changed\n', encoding='utf-8')
            subprocess.run(['git', '-C', tmp, 'commit', '-qam', 'edit agents'], check=True)
            head_unapproved = subprocess.check_output(['git', '-C', tmp, 'rev-parse', 'HEAD'], text=True).strip()
            pr = {
                'number': 12,
                'baseRefOid': base,
                'headRefOid': head_unapproved,
                'files': [{'path': 'AGENTS.md'}],
            }
            reason = fw.pr_owner_only_reason(pr, repo_root=tmp)
            self.assertIsNotNone(reason)
            self.assertIn('without Owner-approved trailer', reason)
            subprocess.run(
                ['git', '-C', tmp, 'commit', '--amend', '-q', '-m', 'edit agents\n\nOwner-approved: owner 2026-11-15 (chat)'],
                check=True,
            )
            pr['headRefOid'] = subprocess.check_output(['git', '-C', tmp, 'rev-parse', 'HEAD'], text=True).strip()
            self.assertIsNone(fw.pr_owner_only_reason(pr, repo_root=tmp))


if __name__ == '__main__':
    unittest.main()
