"""Regression harness for guard-bash.py: the guard on this tree never allows a shape the base guard denies.

Every shape from guard-regression-shapes.json (the PR #1382 Reviews and Verdicts, #1383 and probes) and every
fixture runs alone, after a python heredoc, before one, and after a `find -exec stat` line, through the base
guard (`git show $GUARD_BASE_REF`, default origin/main) and through this tree's guard. A shape the base denies
and this tree allows fails the test. Only the allow fixtures (alone, or beside one more read only `find -exec stat` or python heredoc
line) may move from deny to allow.

Run `python3 test_guard_regression.py` for the summary line.
"""
import concurrent.futures
import json
import os
import subprocess
import sys
import tempfile
import unittest

TESTS = os.path.dirname(os.path.abspath(__file__))
HOOKS = os.path.dirname(TESTS)
ROOT = os.path.abspath(os.path.join(HOOKS, "..", "..", "..", ".."))
REL = "templates/agent-team/.claude/hooks/guard-bash.py"
FIXTURES = os.path.join(TESTS, "fixtures")
PY_HEREDOC = "python3 - <<'PY'\nprint(1)\nPY"
FIND_STAT = "find . -exec stat {} + > s.txt"


def read(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


def shapes():
    """(name, command) pairs, and the set of commands allowed to move from deny to allow."""
    raw = [(s["name"], s["command"]) for s in json.loads(read(os.path.join(TESTS, "guard-regression-shapes.json")))]
    intended = set()
    for kind in ("allow", "deny"):
        folder = os.path.join(FIXTURES, kind)
        for name in sorted(os.listdir(folder)):
            command = read(os.path.join(folder, name))
            raw.append((f"{kind}/{name}", command))
            if kind == "allow":  # the #1360 forms, also beside one more read only `find -exec stat` or python heredoc
                intended |= {command, f"{FIND_STAT}\n{command}", f"{PY_HEREDOC}\n{command}", f"{command}\n{PY_HEREDOC}"}
    out = []
    for name, command in raw:
        out += [(name, command), (f"{name}+py-after", f"{PY_HEREDOC}\n{command}"),
                (f"{name}+py-before", f"{command}\n{PY_HEREDOC}"),
                (f"{name}+find-stat-before", f"{FIND_STAT}\n{command}")]
    return out, intended


class Harness:
    def __init__(self, base_ref):
        self.tmp = tempfile.TemporaryDirectory(prefix="guard-regression-")
        root = self.tmp.name
        base = os.path.join(root, "base")
        os.makedirs(os.path.join(base, os.path.dirname(REL)))
        self.base_sha = subprocess.run(["git", "-C", ROOT, "rev-parse", "--short", base_ref], capture_output=True,
                                       text=True, check=True).stdout.strip()
        source = subprocess.run(["git", "-C", ROOT, "show", f"{base_ref}:{REL}"], capture_output=True, check=True)
        with open(os.path.join(base, REL), "wb") as f:
            f.write(source.stdout)
        os.symlink(os.path.join(ROOT, "script"), os.path.join(base, "script"))
        self.guards = {"base": os.path.join(base, REL), "head": os.path.join(ROOT, REL)}
        self.project = os.path.join(root, "project")
        os.makedirs(os.path.join(self.project, ".claude", "hooks"))
        with open(os.path.join(self.project, ".claude", "hooks", "guard-config.json"), "w") as f:
            f.write('{"blocked_scripts": ["deploy-raw.sh"]}\n')
        self.home = os.path.join(root, "home")
        os.makedirs(self.home)

    def verdict(self, which, command):
        payload = json.dumps({"tool_name": "Bash", "cwd": self.project, "tool_input": {"command": command}})
        env = dict(os.environ, HOME=self.home)
        out = subprocess.run([sys.executable, self.guards[which]], input=payload, capture_output=True, text=True,
                             env=env, cwd=self.project).stdout
        return "deny" if '"permissionDecision": "deny"' in out else "allow"

    def run(self):
        for which in self.guards:
            if self.verdict(which, "bash bin/deploy-raw.sh") != "deny":
                raise RuntimeError(f"the {which} guard does not deny a blocked script, so it did not run")
        cases, intended = shapes()
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            base = list(pool.map(lambda c: self.verdict("base", c[1]), cases))
            head = list(pool.map(lambda c: self.verdict("head", c[1]), cases))
        regressions, moved = [], []
        for (name, command), b, h in zip(cases, base, head):
            if b == "deny" and h == "allow":
                (moved if command in intended else regressions).append(name)
        summary = (f"guard-regression: {len(cases)} shapes, base {self.base_sha} denies {base.count('deny')}, "
                   f"head denies {head.count('deny')}, base deny and head allow: {len(regressions)}, "
                   f"allow fixtures moved to allow: {len(moved)}")
        return summary, regressions


class GuardRegression(unittest.TestCase):
    def test_head_never_allows_a_shape_the_base_denies(self):
        base_ref = os.environ.get("GUARD_BASE_REF", "origin/main")
        try:
            harness = Harness(base_ref)
        except subprocess.CalledProcessError:
            self.skipTest(f"{base_ref} is not available to compare against")
        try:
            summary, regressions = harness.run()
        finally:
            harness.tmp.cleanup()
        self.assertEqual(regressions, [], summary)


if __name__ == "__main__":
    h = Harness(os.environ.get("GUARD_BASE_REF", "origin/main"))
    try:
        text, bad = h.run()
    finally:
        h.tmp.cleanup()
    print(text)
    for name in bad:
        print(f"  regression: {name}")
    sys.exit(1 if bad else 0)
