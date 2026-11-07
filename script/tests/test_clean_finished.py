#!/usr/bin/env python3
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "script" / "clean-finished.py"


def load_cf():
    spec = importlib.util.spec_from_file_location("clean_finished", SCRIPT)
    mod = importlib.util.module_from_spec(spec)
    assert spec.loader
    spec.loader.exec_module(mod)
    return mod


cf = load_cf()


class GitFix:
    def __init__(self):
        self.tmp = tempfile.mkdtemp()
        self.origin = Path(self.tmp) / "origin.git"
        self.main = Path(self.tmp) / "main"
        subprocess.run(["git", "init", "--bare", str(self.origin)], check=True, capture_output=True)
        subprocess.run(["git", "clone", str(self.origin), str(self.main)], check=True, capture_output=True)
        self._run(self.main, "config", "user.email", "t@example.com")
        self._run(self.main, "config", "user.name", "t")
        (self.main / ".agents").mkdir()
        (self.main / ".agents/head-checks.conf").write_text("1\n")
        (self.main / "f").write_text("base\n")
        self._run(self.main, "add", "f")
        self._run(self.main, "commit", "-m", "base")
        self._run(self.main, "branch", "-M", "main")
        self._run(self.main, "push", "-u", "origin", "main")
        self.wts = []

    def _run(self, cwd, *args):
        return subprocess.run(["git", "-C", str(cwd), *args], capture_output=True, text=True, check=True)

    def branch(self, name, parent="main"):
        self._run(self.main, "branch", name, parent)

    def worktree(self, name, branch=None, detach=None):
        path = Path(self.tmp) / name
        if detach:
            self._run(self.main, "worktree", "add", "--detach", str(path), detach)
        else:
            br = branch or name
            if br not in self.branches():
                self._run(self.main, "branch", br, "main")
            self._run(self.main, "worktree", "add", str(path), br)
        self.wts.append(path)
        return path

    def branches(self):
        rc = subprocess.run(["git", "-C", str(self.main), "branch", "--format=%(refname:short)"], capture_output=True, text=True)
        return rc.stdout.split()

    def merge_to_main(self, branch):
        self._run(self.main, "merge", "--ff-only", branch)
        self._run(self.main, "push", "origin", "main")

    def cleanup(self):
        shutil.rmtree(self.tmp, ignore_errors=True)


class StubEnv:
    def __init__(self, fix: GitFix, prs=None, *, lsof="true", pins=None, term_cwds=None, fail_remove=None):
        self.fix = fix
        self.bin = Path(fix.tmp) / "bin"
        self.bin.mkdir(exist_ok=True)
        self.prs = prs or []
        self.pins = pins or []
        self.term_cwds = term_cwds or []
        self.fail_remove = fail_remove
        gh = self.bin / "gh"
        gh.write_text('#!/bin/sh\nif [ "$1" = pr ]; then cat "$GH_PR_FILE"; else exit 1; fi\n')
        gh.chmod(0o755)
        oc = self.bin / "orca"
        oc.write_text(f'''#!/bin/sh
case "$1 $2" in
"repo list") echo '{{"result":{{"repos":[{{"kind":"git","path":"{fix.main}"}}]}}}}' ;;
"worktree list") python3 -c "import json,os; print(json.dumps({{'result':{{'worktrees':[{{'path':p,'pinned':True}} for p in json.loads(os.environ.get('ORCA_PINS','[]'))]}}}}))" ;;
"terminal list") python3 -c "import json,os; print(json.dumps({{'result':{{'terminals':[{{'cwd':c}} for c in json.loads(os.environ.get('ORCA_CWDS','[]'))]}}}}))" ;;
"worktree rm") exit 0 ;;
*) exit 0 ;;
esac
''')
        oc.chmod(0o755)
        lsof_bin = self.bin / "lsof"
        if lsof == "missing":
            pass
        elif lsof == "fail":
            lsof_bin.write_text("#!/bin/sh\nexit 2\n")
            lsof_bin.chmod(0o755)
        else:
            lsof_bin.write_text("#!/bin/sh\nexit 0\n")
            lsof_bin.chmod(0o755)
        pr_file = Path(fix.tmp) / "prs.json"
        pr_file.write_text(json.dumps(self.prs))
        self.env = os.environ.copy()
        self.env.update(
            PATH=str(self.bin) + os.pathsep + os.environ.get("PATH", ""),
            GH="gh",
            ORCA_CLI_COMMAND=str(oc),
            GH_PR_FILE=str(pr_file),
            ORCA_PINS=json.dumps(self.pins),
            ORCA_CWDS=json.dumps(self.term_cwds),
            CLEAN_FINISHED_REPOS=str(fix.main),
            CLEAN_FINISHED_REPO_SECONDS="30",
        )
        if lsof == "missing":
            self.env["CLEAN_FINISHED_LSOF"] = "missing"
        else:
            self.env["CLEAN_FINISHED_LSOF"] = str(lsof_bin) if (self.bin / "lsof").exists() else "missing"
        if fail_remove:
            gitsh = self.bin / "git"
            name = Path(fail_remove).name
            real_git = subprocess.run(["sh", "-c", "command -v git"], capture_output=True, text=True).stdout.strip()
            gitsh.write_text(
                f"#!/bin/sh\n"
                f'if [ \"$3\" = worktree ] && [ \"$4\" = remove ]; then case \"$5\" in *{name}*) exit 1 ;; esac; fi\n'
                f'exec {real_git} \"$@\"\n'
            )
            gitsh.chmod(0o755)
            self.env["PATH"] = str(self.bin) + os.pathsep + self.env["PATH"]

    def run(self, apply=False):
        cmd = [sys.executable, str(SCRIPT)] + (["--apply"] if apply else [])
        return subprocess.run(cmd, env=self.env, text=True, capture_output=True, cwd=str(ROOT))


class CleanFinishedTests(unittest.TestCase):
    def test_merged_in_main_deletes_preview(self):
        g = GitFix()
        self.addCleanup(g.cleanup)
        g.branch("done")
        wt = g.worktree("wt-done", "done")
        (wt / "x").write_text("1\n")
        g._run(wt, "add", "x")
        g._run(wt, "commit", "-m", "c")
        g._run(wt, "push", "-u", "origin", "done")
        g.merge_to_main("done")
        prs = [{"headRefName": "done", "state": "MERGED", "closedAt": "2026-01-01T00:00:00Z"}]
        out = StubEnv(g, prs).run()
        self.assertEqual(out.returncode, 0)
        self.assertIn("Remove worktree", out.stdout)
        self.assertIn("merged pull request", out.stdout)

    def test_main_checkout_kept(self):
        g = GitFix()
        self.addCleanup(g.cleanup)
        g.branch("extra")
        g.worktree("wt-extra", "extra")
        out = StubEnv(g, [{"headRefName": "extra", "state": "OPEN"}]).run()
        self.assertNotIn(f"Remove worktree {g.main}", out.stdout)
        self.assertIn("open pull request", out.stdout)

    def test_hook_only_clean_allows_delete(self):
        g = GitFix()
        self.addCleanup(g.cleanup)
        g.branch("hooky")
        wt = g.worktree("wt-hook", "hooky")
        hook = wt / ".cursor/hooks/state"
        hook.mkdir(parents=True)
        (hook / "continual-learning.json").write_text("{}")
        g._run(wt, "add", ".cursor/hooks/state/continual-learning.json")
        g.merge_to_main("hooky")
        out = StubEnv(g, [{"headRefName": "hooky", "state": "MERGED"}]).run()
        self.assertIn("Remove worktree", out.stdout)

    def test_second_dirty_file_kept(self):
        g = GitFix()
        self.addCleanup(g.cleanup)
        g.branch("dirty")
        wt = g.worktree("wt-dirty", "dirty")
        (wt / "other").write_text("x")
        out = StubEnv(g, [{"headRefName": "dirty", "state": "MERGED"}]).run()
        self.assertIn("uncommitted changes", out.stdout)

    def test_no_pr_not_in_main_kept(self):
        g = GitFix()
        self.addCleanup(g.cleanup)
        g.branch("orphan")
        wt = g.worktree("wt-orphan", "orphan")
        (wt / "n").write_text("1\n")
        g._run(wt, "add", "n")
        g._run(wt, "commit", "-m", "n")
        g._run(wt, "push", "-u", "origin", "orphan")
        out = StubEnv(g).run()
        self.assertIn("no pull request", out.stdout)

    def test_in_main_no_pr_deletes(self):
        g = GitFix()
        self.addCleanup(g.cleanup)
        g.branch("landed")
        wt = g.worktree("wt-landed", "landed")
        (wt / "n").write_text("1\n")
        g._run(wt, "add", "n")
        g._run(wt, "commit", "-m", "n")
        g._run(wt, "push", "-u", "origin", "landed")
        g.merge_to_main("landed")
        out = StubEnv(g).run()
        self.assertIn("already in main", out.stdout)

    def test_closed_pr_young_remote_kept_line(self):
        g = GitFix()
        self.addCleanup(g.cleanup)
        g.branch("closed")
        wt = g.worktree("wt-closed", "closed")
        (wt / "n").write_text("1\n")
        g._run(wt, "add", "n")
        g._run(wt, "commit", "-m", "n")
        g._run(wt, "push", "-u", "origin", "closed")
        when = (datetime.now(timezone.utc) - timedelta(days=3)).strftime("%Y-%m-%dT%H:%M:%SZ")
        prs = [{"headRefName": "closed", "state": "CLOSED", "closedAt": when}]
        out = StubEnv(g, prs).run(apply=True)
        self.assertIn("deleted after 7 days", out.stdout)

    def test_closed_pr_old_remote_deleted(self):
        g = GitFix()
        self.addCleanup(g.cleanup)
        g.branch("oldc")
        wt = g.worktree("wt-oldc", "oldc")
        (wt / "n").write_text("1\n")
        g._run(wt, "add", "n")
        g._run(wt, "commit", "-m", "n")
        g._run(wt, "push", "-u", "origin", "oldc")
        when = (datetime.now(timezone.utc) - timedelta(days=8)).strftime("%Y-%m-%dT%H:%M:%SZ")
        prs = [{"headRefName": "oldc", "state": "CLOSED", "closedAt": when}]
        out = StubEnv(g, prs).run(apply=True)
        self.assertEqual(out.returncode, 0)

    def test_lsof_missing_keeps_repo(self):
        g = GitFix()
        self.addCleanup(g.cleanup)
        g.branch("x")
        g.worktree("wt-x", "x")
        env = StubEnv(g, lsof="missing")
        out = env.run()
        self.assertIn("could not check processes", out.stdout)

    def test_lsof_fail_keeps_repo(self):
        g = GitFix()
        self.addCleanup(g.cleanup)
        g.branch("x")
        g.worktree("wt-x", "x")
        out = StubEnv(g, lsof="fail").run()
        self.assertIn("could not check processes", out.stdout)

    def test_pinned_kept(self):
        g = GitFix()
        self.addCleanup(g.cleanup)
        g.branch("p")
        wt = g.worktree("wt-p", "p")
        g.merge_to_main("p")
        out = StubEnv(g, [{"headRefName": "p", "state": "MERGED"}], pins=[str(wt.resolve())]).run()
        self.assertIn("pinned", out.stdout)

    def test_detach_merged_delete(self):
        g = GitFix()
        self.addCleanup(g.cleanup)
        sha = subprocess.check_output(["git", "-C", str(g.main), "rev-parse", "main"], text=True).strip()
        g.worktree("wt-det", detach=sha)
        out = StubEnv(g).run()
        self.assertIn("Remove worktree", out.stdout)

    def test_open_pr_kept(self):
        g = GitFix()
        self.addCleanup(g.cleanup)
        g.branch("open")
        g.worktree("wt-open", "open")
        out = StubEnv(g, [{"headRefName": "open", "state": "OPEN"}]).run()
        self.assertIn("open pull request", out.stdout)

    def test_unpushed_kept(self):
        g = GitFix()
        self.addCleanup(g.cleanup)
        g.branch("pushless")
        wt = g.worktree("wt-pushless", "pushless")
        (wt / "u").write_text("1\n")
        g._run(wt, "add", "u")
        g._run(wt, "commit", "-m", "u")
        out = StubEnv(g).run()
        self.assertIn("unpushed commits", out.stdout)

    def test_running_process_kept(self):
        g = GitFix()
        self.addCleanup(g.cleanup)
        g.branch("busy")
        wt = g.worktree("wt-busy", "busy")
        g.merge_to_main("busy")
        # lsof stub returns no paths; terminal cwd inside worktree
        out = StubEnv(g, [{"headRefName": "busy", "state": "MERGED"}], term_cwds=[str(wt.resolve())]).run()
        self.assertIn("running process", out.stdout)

    def test_apply_remove_failure_exit_one(self):
        g = GitFix()
        self.addCleanup(g.cleanup)
        g.branch("stuck")
        wt = g.worktree("wt-stuck", "stuck")
        g.merge_to_main("stuck")
        out = StubEnv(g, [{"headRefName": "stuck", "state": "MERGED"}], fail_remove=str(wt)).run(apply=True)
        self.assertEqual(out.returncode, 1)
        self.assertIn("remove failed", out.stdout)

    def test_time_budget_keeps_rest(self):
        g = GitFix()
        self.addCleanup(g.cleanup)
        for i in range(5):
            g.branch(f"b{i}")
            g.worktree(f"wt-budget-{i}", f"b{i}")
        env = StubEnv(g)
        env.env["CLEAN_FINISHED_REPO_SECONDS"] = "0.001"
        cmd = [sys.executable, str(SCRIPT)]
        out = subprocess.run(cmd, env=env.env, text=True, capture_output=True, cwd=str(ROOT))
        self.assertIn("time budget", out.stdout)

    def test_summary_line(self):
        g = GitFix()
        self.addCleanup(g.cleanup)
        out = StubEnv(g).run()
        self.assertRegex(out.stdout.strip().splitlines()[-1], r"^removed worktrees=\d+ deleted local=\d+")

    def test_decide_archive_protected(self):
        g = GitFix()
        self.addCleanup(g.cleanup)
        g.branch("archive/snap")
        g.worktree("wt-arch", "archive/snap")
        head = subprocess.check_output(["git", "-C", str(g.wts[-1]), "rev-parse", "HEAD"], text=True).strip()
        act, why, _ = cf.decide(
            str(g.main), (str(g.wts[-1]), "archive/snap", head, False), str(g.main), "main",
            True, {}, set(), set(), set(), time.time() + 60
        )
        self.assertEqual(act, "keep")
        self.assertEqual(why, "archive branch")

    def test_squash_merged_via_cherry(self):
        g = GitFix()
        self.addCleanup(g.cleanup)
        g.branch("sq")
        wt = g.worktree("wt-sq", "sq")
        (wt / "sq").write_text("1\n")
        g._run(wt, "add", "sq")
        g._run(wt, "commit", "-m", "feature")
        g._run(wt, "push", "-u", "origin", "sq")
        tip = subprocess.check_output(["git", "-C", str(wt), "rev-parse", "HEAD"], text=True).strip()
        g._run(g.main, "checkout", "main")
        g._run(g.main, "commit", "--allow-empty", "-m", "squash-placeholder")
        g._run(g.main, "cherry-pick", "--no-commit", tip)
        g._run(g.main, "commit", "-m", "squashed")
        g._run(g.main, "push", "origin", "main")
        out = StubEnv(g, [{"headRefName": "sq", "state": "MERGED"}]).run()
        self.assertIn("Remove worktree", out.stdout)


if __name__ == "__main__":
    unittest.main()
