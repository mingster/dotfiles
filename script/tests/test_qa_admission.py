#!/usr/bin/env python3
"""Tests for qa-admission.py (mocked Orca and fleet-watch)."""
import importlib.util
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
QA = ROOT / "qa-admission.py"


def load_module():
    spec = importlib.util.spec_from_file_location("qa_admission", QA)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class QaAdmission(unittest.TestCase):
    def setUp(self):
        self.mod = load_module()
        self.tmp = tempfile.mkdtemp()
        self.policy_path = os.path.join(self.tmp, "policy.json")
        self.fleet_config = os.path.join(self.tmp, "fleet.json")
        with open(self.fleet_config, "w") as f:
            json.dump({"host_caps": {"niteking": 2}, "runs": []}, f)

    def write_policy(self, **overrides):
        base = {
            "version": 1,
            "issued_at": "2026-10-31T10:00:00Z",
            "expires_at": "2026-11-01T18:00:00Z",
            "review": {
                "runtime_host": "niteking",
                "repo": "github:o/n",
                "worktree_path": "/wt",
                "head": "a" * 40,
            },
            "hosts": {
                "niteking": {
                    "cap": 2,
                    "load_ceiling": 8.0,
                    "providers": {"codex": {"models": ["gpt-6.1-sol-medium"]}},
                }
            },
        }
        base.update(overrides)
        with open(self.policy_path, "w") as f:
            json.dump(base, f)

    def fake_orca(self, worktrees=None):
        worktrees = worktrees or [{
            "path": "/wt",
            "head": "a" * 40,
            "identity": {"key": "wt2:local:fixture-id"},
        }]
        script = os.path.join(self.tmp, "orca")
        payload = json.dumps({"ok": True, "result": {"worktrees": worktrees, "page": {}}})
        with open(script, "w") as f:
            f.write("#!/usr/bin/env python3\nimport json,sys\n")
            f.write("payload=%r\n" % payload)
            f.write("""
if sys.argv[1:4] == ["environment", "list", "--json"]:
    print('{"ok":true,"result":{"environments":[]}}')
elif len(sys.argv) >= 4 and sys.argv[1] == "worktree" and sys.argv[2] == "list":
    print(payload)
else:
    sys.exit(1)
""")
        os.chmod(script, 0o755)
        return script

    def fake_fleet_watch(self, admitted=True, host="niteking"):
        script = os.path.join(self.tmp, "fw")
        body = json.dumps({
            "admitted": admitted,
            "host": host,
            "cap": 2,
            "occupied": 0 if admitted else 2,
            "reason": "admitted" if admitted else "host cap exceeded",
        })
        with open(script, "w") as f:
            f.write(f'''#!/usr/bin/env bash
[ "$1" = "--config" ] && shift 2
[ "$1" = "--admit" ] || exit 2
printf '%s\\n' '{body}'
exit {0 if admitted else 1}
''')
        os.chmod(script, 0o755)
        return script

    def run_cli(self, orca, fw, extra_env=None, write_policy=True):
        if write_policy:
            self.write_policy()
        env = {
            **os.environ,
            "ORCA_CLI_COMMAND": orca,
            "ON_WORKER_DONE_FLEET_WATCH": fw,
            "QA_ADMISSION_LOCAL_HOST": "niteking",
            "QA_ADMISSION_SELF_LOAD": json.dumps({"load_1m": 1.5}),
            "QA_ADMISSION_FLEET_LOAD": os.path.join(self.tmp, "noop.sh"),
        }
        if extra_env:
            env.update(extra_env)
        with open(env["QA_ADMISSION_FLEET_LOAD"], "w") as f:
            f.write("#!/bin/bash\n")
        os.chmod(env["QA_ADMISSION_FLEET_LOAD"], 0o755)
        return subprocess.run([
            "python3", str(QA),
            "--policy", self.policy_path,
            "--fleet-config", self.fleet_config,
            "--repo", "o/n",
            "--head", "a" * 40,
            "--worktree-path", "/wt",
            "--verifier-provider", "codex",
            "--verifier-model", "gpt-6.1-sol-medium",
        ], env=env, text=True, capture_output=True, timeout=30)

    def test_missing_policy_refuses(self):
        r = subprocess.run(["python3", str(QA), "--policy", "/no/such", "--fleet-config",
                              self.fleet_config, "--repo", "o/n", "--head", "a" * 40,
                              "--worktree-path", "/wt", "--verifier-provider", "codex",
                              "--verifier-model", "gpt-6.1-sol-medium"], capture_output=True, text=True)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("missing", r.stderr)

    def test_string_admitted_false_refuses(self):
        fw = os.path.join(self.tmp, "fw2")
        with open(fw, "w") as f:
            f.write('#!/bin/bash\n[ "$1" = "--config" ] && shift 2; [ "$1" = "--admit" ] || exit 2\n'
                    'echo \'{"admitted":"false","host":"niteking","cap":2,"occupied":0}\'\nexit 0\n')
        os.chmod(fw, 0o755)
        r = self.run_cli(self.fake_orca(), fw)
        self.assertNotEqual(r.returncode, 0)

    def test_stale_head_refuses(self):
        self.write_policy()
        bad = self.fake_orca([{"path": "/wt", "head": "b" * 40, "identity": {"key": "x"}}])
        r = self.run_cli(bad, self.fake_fleet_watch())
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("path and head", r.stderr)

    def test_eligible_fixture_admits(self):
        r = self.run_cli(self.fake_orca(), self.fake_fleet_watch())
        self.assertEqual(r.returncode, 0, r.stderr)
        out = json.loads(r.stdout)
        self.assertEqual(out["worktree_selector"], "identity:wt2:local:fixture-id")
        self.assertEqual(out["environment_id"], "LOCAL")

    def test_expired_policy_refuses(self):
        self.write_policy(expires_at="2020-01-01T00:00:00Z")
        r = self.run_cli(self.fake_orca(), self.fake_fleet_watch(), write_policy=False)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("expired", r.stderr)


if __name__ == "__main__":
    unittest.main()
