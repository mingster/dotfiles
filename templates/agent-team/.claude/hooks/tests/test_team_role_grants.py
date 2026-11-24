"""A team.md rule that lets a role do something must be proven by a test that the guard lets that role do it (#1747).

Rows are team.md table rows whose Enforced-by column names a guard hook (`guard-bash.py` or
`check-shared-db-write.py`) and whose rule text names a role. Each such row is in ROLE_GRANTS with a test that
drives the guard as the granted role and a test that drives it as another role, or in UNENFORCED with the reason
the guard cannot honour it. A new row that is in neither fails here, so a rule and its guard cannot drift apart
silently. Run: python3 -m unittest discover -s templates/agent-team/.claude/hooks/tests -p 'test_*.py'
"""
import os
import re
import subprocess
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, *[os.pardir] * 5))
TEAM_MD = os.path.join(ROOT, "templates/agent-team/docs/agents/team.md")
AGENTS = os.path.join(ROOT, "templates/agent-team/.claude/agents")
GUARD_MARK = re.compile(r"guard-bash\.py|check-shared-db-write\.py")

# row title -> (granted role, (module, class, test) that allows it, (module, class, test) that refuses another role)
# A "sh:" entry is a line of script/check-shared-db-write.test.sh output.
ROLE_GRANTS = {
    "Pre-build grill gate": (
        "coordinator",
        ("test_team_gates", "GrillGate", "test_coordinator_grill_record_allows_the_build"),
        ("test_team_gates", "GrillGate", "test_a_builder_cannot_record_the_grill"),
    ),
    "Gated actions": (
        "release-manager",
        ("test_guard_bash", "ProductionTestData", "test_release_manager_pushes_production_while_test_data"),
        ("test_guard_bash", "ProductionTestData", "test_another_role_still_needs_the_go"),
    ),
    "Shared dev databases": (
        "release-manager",
        ("sh", "ok   allows release-manager role after the Orca preamble"),
        ("sh", "ok   blocks builder role after the Orca preamble"),
    ),
    "Heavy jobs": (
        "coordinator",
        ("test_guard_bash", "CalibrateCoordinatorOnly", "test_coordinator_session_calibrates"),
        ("test_guard_bash", "CalibrateCoordinatorOnly", "test_a_worker_cannot_calibrate"),
    ),
}
# Rows that grant a role an action the named guard does not implement. Fixing one edits a hook, which needs the owner.
UNENFORCED = {}


def roles():
    names = {f[:-3] for f in os.listdir(AGENTS) if f.endswith(".md")}
    return names | {"coordinator"}


def guard_rows():
    found = {}
    with open(TEAM_MD) as f:
        for line in f:
            cells = [c.strip() for c in line.strip().strip("|").split("|")] if line.startswith("|") else []
            if len(cells) < 2 or not GUARD_MARK.search(cells[-1]):
                continue
            title = re.match(r"\*\*(.+?)(?::\*\*|\*\*)", cells[0])
            if not title:
                continue
            text = cells[0].lower()
            if any(re.search(rf"(?<![\w-]){re.escape(r)}(?![\w-])", text) for r in roles()):
                found[title.group(1).strip(":")] = cells[0]
    return found


def load(module, cls, name):
    mod = __import__(module)
    return getattr(mod, cls)(name)


class RoleGrants(unittest.TestCase):
    def test_every_guarded_role_row_is_covered_or_listed(self):
        rows = guard_rows()
        self.assertTrue(rows, "no guard rows found: the row parser is out of date")
        missing = set(rows) - set(ROLE_GRANTS) - set(UNENFORCED)
        self.assertFalse(missing, f"team.md rows grant a role an action with no guard test: {sorted(missing)}")
        stale = (set(ROLE_GRANTS) | set(UNENFORCED)) - set(rows)
        self.assertFalse(stale, f"rows no longer in team.md or no longer name a role: {sorted(stale)}")

    def test_the_guard_allows_each_granted_role_and_refuses_another(self):
        sh_out = None
        for title, (role, allow, refuse) in ROLE_GRANTS.items():
            for kind, spec in (("allows", allow), ("refuses", refuse)):
                with self.subTest(row=title, role=role, expect=kind):
                    if spec[0] == "sh":
                        if sh_out is None:
                            proc = subprocess.run(["bash", os.path.join(ROOT, "script/check-shared-db-write.test.sh")],
                                                  capture_output=True, text=True)
                            sh_out = proc.stdout
                        self.assertIn(spec[1], sh_out.splitlines())
                        continue
                    result = unittest.TestResult()
                    load(*spec).run(result)
                    self.assertEqual(result.testsRun, 1, f"{spec} did not run")
                    self.assertTrue(result.wasSuccessful(), f"{spec}: {result.failures + result.errors}")


if __name__ == "__main__":
    unittest.main()
