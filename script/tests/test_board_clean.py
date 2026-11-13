#!/usr/bin/env python3
"""Rules for cleaning a Done card after 30 minutes."""
import importlib.util
import json
import os
import pathlib
import subprocess
import tempfile
import textwrap
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("board_clean", ROOT / "script" / "board-clean.py")
clean = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(clean)

NOW = 1_800_000_000_000
WINDOW = 30 * 60 * 1000
OLD = NOW - WINDOW


def tree(**kwargs):
    base = {
        "path": "/w/a",
        "branch": "refs/heads/feat",
        "workspaceStatus": "completed",
        "isMainWorktree": False,
        "projectId": "github:acme/app",
        "lastActivityAt": OLD,
    }
    base.update(kwargs)
    return base


def released(path="/w/a"):
    return {"state": "succeeded", "liveness": "exited", "terminalState": "released", "workspace": "repo::" + path}


def failed(path="/w/a"):
    return {"state": "failed", "liveness": "exited", "terminalState": "released", "workspace": "repo::" + path}


def stopped(path="/w/a"):
    return {"state": "stopped", "liveness": "exited", "workspace": "repo::" + path}


def working(path="/w/a"):
    return {"state": "ready", "outcome": "in_progress", "liveness": "live", "terminalState": "active", "workspace": "repo::" + path}


def facts(dirty=False, unpushed=False, unmerged=False, pr=None):
    found = {"dirty": dirty, "unpushed": unpushed, "unmerged": unmerged}
    if pr is not None:
        found["pr"] = pr
    return found


def decide(card, workers, card_facts=None, since=OLD, now=NOW):
    return clean.keep_reason(card, workers, card_facts if card_facts is not None else facts(), now, since, WINDOW)


class KeepOrClean(unittest.TestCase):
    def test_young_card_stays(self):
        self.assertEqual(decide(tree(), [released()], since=NOW - 60_000), "Done for less than 30 minutes")

    def test_card_done_for_exactly_30_minutes_is_cleaned(self):
        self.assertIsNone(decide(tree(), [released()], since=NOW - WINDOW))

    def test_one_millisecond_early_stays(self):
        self.assertEqual(
            decide(tree(), [released()], since=NOW - WINDOW + 1),
            "Done for less than 30 minutes",
        )

    def test_main_checkout_stays(self):
        self.assertEqual(decide(tree(isMainWorktree=True), [released()]), "main checkout")

    def test_archive_branch_stays(self):
        self.assertEqual(decide(tree(branch="refs/heads/archive/old"), [released()]), "archive branch")

    def test_protected_branch_stays(self):
        self.assertEqual(decide(tree(branch="refs/heads/staging"), [released()]), "protected branch")

    def test_coordinator_worktree_stays(self):
        row = released()
        row["projection"] = {"role": "elon"}
        self.assertEqual(decide(tree(), [row]), "coordinator worktree")

    def test_lead_worktree_stays(self):
        self.assertEqual(decide(tree(path="/trees/lead-queue"), [released("/trees/lead-queue")]), "lead worktree")

    def test_unreleased_worker_stays(self):
        self.assertEqual(decide(tree(), [working()]), "unreleased worker")

    def test_unknown_worker_stays(self):
        self.assertEqual(decide(tree(), [{"state": "mystery", "workspace": "repo::/w/a"}]), "unreleased worker")

    def test_unsaved_changes_stay(self):
        self.assertEqual(decide(tree(), [released()], facts(dirty=True)), "unsaved changes")

    def test_unreadable_changes_stay(self):
        self.assertEqual(decide(tree(), [released()], {"dirty": None, "unpushed": False}), "unsaved changes unreadable")

    def test_commits_not_on_any_remote_stay(self):
        self.assertEqual(decide(tree(), [released()], facts(unpushed=True)), "commits not on any remote")

    def test_unreadable_commits_stay(self):
        self.assertEqual(decide(tree(), [released()], {"dirty": False, "unpushed": None}), "commit reachability unreadable")

    def test_pushed_unmerged_branch_with_no_pr_stays(self):
        for row in (released(), failed(), stopped()):
            self.assertEqual(
                decide(tree(), [row], facts(unmerged=True, pr="none")),
                "pushed branch not merged and has no PR",
            )

    def test_pushed_branch_with_an_open_pr_stays(self):
        self.assertEqual(decide(tree(), [released()], facts(unmerged=True, pr="open")), "open PR")

    def test_unknown_pr_state_stays(self):
        self.assertEqual(decide(tree(), [released()], facts(unmerged=True)), "PR state unreadable")

    def test_unreadable_unmerged_stays(self):
        self.assertEqual(
            decide(tree(), [released()], {"dirty": False, "unpushed": False, "unmerged": None}),
            "commit reachability unreadable",
        )

    def test_squash_merged_or_closed_pr_branch_is_cleaned(self):
        for pr in ("merged", "closed"):
            self.assertIsNone(decide(tree(), [released()], facts(unmerged=True, pr=pr)), pr)

    def test_rm_worktree_stays_until_release_of_a_throwaway_branch(self):
        self.assertEqual(
            decide(tree(path="/trees/rm-keep", branch="refs/heads/feat"), [released("/trees/rm-keep")]),
            "rm worktree",
        )

    def test_clean_released_card_goes(self):
        self.assertIsNone(decide(tree(), [released()]))

    def test_failed_card_is_cleaned_when_the_guards_pass(self):
        self.assertIsNone(decide(tree(), [failed()]))

    def test_stopped_card_is_cleaned_when_the_guards_pass(self):
        self.assertIsNone(decide(tree(), [stopped()]))

    def test_failed_card_with_unpushed_work_stays(self):
        self.assertEqual(decide(tree(), [failed()], facts(unpushed=True)), "commits not on any remote")

    def test_stopped_card_with_unsaved_changes_stays(self):
        self.assertEqual(decide(tree(), [stopped()], facts(dirty=True)), "unsaved changes")

    def test_throwaway_branch_is_deleted_after_release_even_with_local_commits(self):
        for branch in ("verify-1", "qa-7", "rm-3"):
            card = tree(branch="refs/heads/" + branch)
            self.assertIsNone(decide(card, [released()], facts(unpushed=True)), branch)

    def test_throwaway_branch_with_unsaved_changes_stays(self):
        card = tree(branch="refs/heads/verify-1")
        self.assertEqual(decide(card, [released()], facts(dirty=True, unpushed=True)), "unsaved changes")

    def test_unreleased_throwaway_branch_stays(self):
        card = tree(branch="refs/heads/qa-1")
        self.assertEqual(decide(card, [working()]), "unreleased worker")

    def test_failed_throwaway_with_local_commits_stays(self):
        card = tree(branch="refs/heads/rm-9")
        self.assertEqual(decide(card, [failed()], facts(unpushed=True)), "commits not on any remote")

    def test_released_rm_worktree_on_an_rm_branch_is_cleaned(self):
        card = tree(path="/trees/rm-3", branch="refs/heads/rm-3")
        self.assertIsNone(decide(card, [released("/trees/rm-3")], facts(unpushed=True)))


class HostAndAge(unittest.TestCase):
    def test_dispatch_host_wins(self):
        row = released()
        row["projection"] = {"host": {"id": "blueDevil"}}
        self.assertEqual(clean.dispatch_environment([row], "local"), ("blueDevil", None))

    def test_listed_environment_is_the_fallback(self):
        self.assertEqual(clean.dispatch_environment([released()], ""), ("local", None))

    def test_local_host_id_keeps_the_listed_environment(self):
        row = released()
        row["projection"] = {"host": {"id": "local"}}
        row["host"] = "local"
        self.assertEqual(clean.dispatch_environment([row], "up"), ("up", None))

    def test_top_level_host_names_the_machine(self):
        row = released()
        row["host"] = "blueDevil"
        self.assertEqual(clean.dispatch_environment([row], "local"), ("blueDevil", None))

    def test_disagreeing_dispatch_hosts_stay(self):
        one = released()
        one["projection"] = {"host": {"id": "up"}}
        two = released()
        two["projection"] = {"host": {"id": "down"}}
        self.assertEqual(clean.dispatch_environment([one, two], "up"), ("up", "dispatch hosts disagree"))

    def test_stamp_beats_a_later_last_activity(self):
        stamps = {"local\t/w/a": OLD}
        card = tree(lastActivityAt=NOW)
        self.assertEqual(clean.resolve_since(card, "local", stamps, NOW), OLD)

    def test_last_activity_is_the_age_when_there_is_no_stamp(self):
        self.assertEqual(clean.resolve_since(tree(lastActivityAt=OLD), "local", {}, NOW), OLD)

    def test_missing_age_starts_at_now(self):
        card = tree()
        del card["lastActivityAt"]
        self.assertEqual(clean.resolve_since(card, "local", {}, NOW), NOW)


class Probe(unittest.TestCase):
    def test_text_from_a_real_terminal_read(self):
        # Captured from `orca terminal read --json` on a paired host (mini6).
        data = json.loads((ROOT / "script" / "tests" / "fixtures" / "orca-terminal-read-probe.json").read_text())
        text = clean.text_from_read(data)
        self.assertIn("dirty:1\nunpushed:1", text)
        self.assertEqual(clean.parse_probe(text)["dirty"], True)
        self.assertEqual(clean.parse_probe(text)["unpushed"], True)

    def test_parse_probe(self):
        self.assertEqual(
            clean.parse_probe("dirty:0\nunpushed:4\nunmerged:4\n"),
            {"dirty": False, "unpushed": True, "unmerged": True, "done": True},
        )
        self.assertEqual(
            clean.parse_probe("dirty:2\nunpushed:unknown\n"),
            {"dirty": True, "unpushed": None, "unmerged": None, "done": False},
        )
        self.assertEqual(clean.parse_probe("unmerged:unknown")["done"], True)

    def test_probe_command_keeps_the_shell_open(self):
        self.assertNotIn("exit", clean.PROBE_COMMAND)

    def test_remote_probe_reads_and_closes_the_terminal(self):
        with tempfile.TemporaryDirectory() as tmp:
            log = pathlib.Path(tmp) / "orca.log"
            fake = pathlib.Path(tmp) / "orca"
            fake.write_text(textwrap.dedent("""\
                #!/usr/bin/env bash
                printf '%s\\n' "$*" >> "$ORCA_LOG"
                reads="$(dirname "$ORCA_LOG")/reads"
                case "$*" in
                  'terminal create '*) echo '{"ok":true,"result":{"terminal":{"handle":"probe-1"}}}' ;;
                  'terminal read '*)
                    if [ -f "$reads" ]; then
                      echo '{"ok":true,"result":{"terminal":{"handle":"probe-1","status":"running","tail":["$ d=...","dirty:0","unpushed:2","unmerged:2","",">"]}}}'
                    else
                      touch "$reads"
                      echo '{"ok":true,"result":{"terminal":{"handle":"probe-1","status":"running","tail":["$ d=..."]}}}'
                    fi ;;
                  'terminal close '*) echo '{"ok":true,"result":{}}' ;;
                  *) echo "unexpected $*" >&2; exit 1 ;;
                esac
                """))
            fake.chmod(0o755)
            previous = os.environ.get("ORCA_CLI_COMMAND")
            os.environ["ORCA_CLI_COMMAND"] = str(fake)
            os.environ["ORCA_LOG"] = str(log)
            original_pause = clean.pause
            clean.pause = lambda: None
            try:
                found = clean.remote_facts("/remote/verify", "up")
            finally:
                clean.pause = original_pause
                if previous is None:
                    os.environ.pop("ORCA_CLI_COMMAND", None)
                else:
                    os.environ["ORCA_CLI_COMMAND"] = previous
                os.environ.pop("ORCA_LOG", None)
            self.assertEqual(found, {"dirty": False, "unpushed": True, "unmerged": True})
            text = log.read_text()
            self.assertEqual(text.count("terminal read "), 2)
            self.assertIn("terminal create --worktree path:/remote/verify --command", text)
            self.assertIn("--environment up", text)
            self.assertIn("terminal close --terminal probe-1 --environment up", text)
            self.assertNotIn("unexpected", text)


class LocalGit(unittest.TestCase):
    def test_dirty_and_unpushed(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = pathlib.Path(tmp) / "repo"
            origin = pathlib.Path(tmp) / "origin"
            subprocess.run(["git", "init", "-q", "--bare", str(origin)], check=True)
            subprocess.run(["git", "init", "-q", "-b", "main", str(repo)], check=True)
            subprocess.run(["git", "-C", str(repo), "config", "user.email", "t@example.invalid"], check=True)
            subprocess.run(["git", "-C", str(repo), "config", "user.name", "T"], check=True)
            subprocess.run(["git", "-C", str(repo), "commit", "-qm", "initial", "--allow-empty"], check=True)
            subprocess.run(["git", "-C", str(repo), "remote", "add", "origin", str(origin)], check=True)
            subprocess.run(["git", "-C", str(repo), "push", "-q", "-u", "origin", "main"], check=True)
            subprocess.run(["git", "-C", str(repo), "switch", "-qc", "feat"], check=True)
            self.assertEqual(
                clean.local_git_facts(str(repo)), {"dirty": False, "unpushed": False, "unmerged": False},
            )
            (repo / "note").write_text("dirty\n")
            self.assertEqual(clean.local_git_facts(str(repo))["dirty"], True)
            (repo / "note").unlink()
            subprocess.run(["git", "-C", str(repo), "commit", "-qm", "local", "--allow-empty"], check=True)
            self.assertEqual(
                clean.local_git_facts(str(repo)), {"dirty": False, "unpushed": True, "unmerged": True},
            )
            # Pushed but never merged: on a remote ref, yet only on its own.
            subprocess.run(["git", "-C", str(repo), "push", "-q", "-u", "origin", "feat"], check=True)
            self.assertEqual(
                clean.local_git_facts(str(repo)), {"dirty": False, "unpushed": False, "unmerged": True},
            )
            subprocess.run(["git", "-C", str(repo), "push", "-q", "origin", "feat:main"], check=True)
            subprocess.run(["git", "-C", str(repo), "fetch", "-q", "origin"], check=True)
            self.assertEqual(
                clean.local_git_facts(str(repo)), {"dirty": False, "unpushed": False, "unmerged": False},
            )

    def test_remote_probe_command_agrees_with_local_facts(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = pathlib.Path(tmp) / "repo"
            origin = pathlib.Path(tmp) / "origin"
            subprocess.run(["git", "init", "-q", "--bare", str(origin)], check=True)
            subprocess.run(["git", "init", "-q", "-b", "main", str(repo)], check=True)
            subprocess.run(["git", "-C", str(repo), "config", "user.email", "t@example.invalid"], check=True)
            subprocess.run(["git", "-C", str(repo), "config", "user.name", "T"], check=True)
            subprocess.run(["git", "-C", str(repo), "commit", "-qm", "initial", "--allow-empty"], check=True)
            subprocess.run(["git", "-C", str(repo), "remote", "add", "origin", str(origin)], check=True)
            subprocess.run(["git", "-C", str(repo), "push", "-q", "-u", "origin", "main"], check=True)
            subprocess.run(["git", "-C", str(repo), "switch", "-qc", "feat"], check=True)
            subprocess.run(["git", "-C", str(repo), "commit", "-qm", "local", "--allow-empty"], check=True)
            subprocess.run(["git", "-C", str(repo), "push", "-q", "-u", "origin", "feat"], check=True)
            out = subprocess.run(
                ["bash", "-c", clean.PROBE_COMMAND], cwd=repo, capture_output=True, text=True, check=True,
            ).stdout
            self.assertEqual(out, "dirty:0\nunpushed:0\nunmerged:1\n")


class WorkerInventory(unittest.TestCase):
    def setUp(self):
        self.original = clean.call

    def tearDown(self):
        clean.call = self.original

    def test_an_unbound_list_is_the_whole_inventory(self):
        def fake(_environment, *args):
            self.assertNotIn("--run", args)
            return {"ok": True, "result": {"scope": {"source": "all"}, "workers": [{"dispatchId": "d1"}]}}, ""

        clean.call = fake
        rows, err = clean.workers_for_host("")
        self.assertEqual(err, "")
        self.assertEqual(rows, [{"dispatchId": "d1"}])

    def test_a_bound_list_walks_every_run(self):
        def fake(_environment, *args):
            if args[:2] == ("orchestration", "run-list"):
                return {"ok": True, "result": {"runs": [{"id": "run-a"}, {"id": "run-b"}]}}, ""
            if "--run" in args:
                run = args[args.index("--run") + 1]
                return {"ok": True, "result": {"workers": [{"dispatchId": run}]}}, ""
            return {"ok": True, "result": {"scope": {"source": "bound"}, "workers": [{"dispatchId": "only-mine"}]}}, ""

        clean.call = fake
        rows, err = clean.workers_for_host("")
        self.assertEqual(err, "")
        self.assertEqual({row["dispatchId"] for row in rows}, {"run-a", "run-b"})

    def test_a_bound_caller_keeps_cards_when_the_run_list_fails(self):
        def fake(_environment, *args):
            if args[:2] == ("orchestration", "run-list"):
                return None, "unreachable"
            return {"ok": True, "result": {"scope": {"source": "bound"}, "workers": []}}, ""

        clean.call = fake
        rows, err = clean.workers_for_host("up")
        self.assertIsNone(rows)
        self.assertEqual(err, "unreachable")


class Report(unittest.TestCase):
    def test_dry_run_names_the_card(self):
        line = clean.report_line(False, "keep", "/w/a", "unsaved changes", "blueDevil")
        self.assertEqual(line, "[dry-run] would keep /w/a (unsaved changes) environment=blueDevil")

    def test_shell_quote_rejects_a_quote(self):
        self.assertIsNone(clean.shell_quote("bad'name"))
        self.assertEqual(clean.branch_script("/remote/main", "verify-1", True),
                         "git -C '/remote/main' branch -D 'verify-1'; git -C '/remote/main' push origin --delete 'verify-1'; exit")


if __name__ == "__main__":
    unittest.main()
