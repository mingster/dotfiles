#!/usr/bin/env python3
"""Move Orca board cards to Done.

A card becomes completed when any one holds: its pull request is merged or closed, its linked
issue is closed, its worker is released and the worktree has no pull request, or its worker
failed or stopped. A worker that is still live keeps the card, except when a pull request or
issue rule already applies. Dry run is the default.

--fleet visits this Orca and every paired environment. A host that cannot be reached is skipped
and left for the next round. The coordinator's wrap-up --scheduled round is what runs --fleet:
fleet-watch is frozen and only alerts, and wrap-up is already the pass that reads the board.
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time

FINAL = frozenset({"succeeded", "completed", "failed", "cancelled", "released", "stopped"})
FAILED = frozenset({"failed"})
STOPPED = frozenset({"stopped"})
RELEASED = frozenset({"succeeded", "completed", "released"})


def orca_bin() -> str:
    return os.environ.get("ORCA_CLI_COMMAND") or "orca"


def _states(row: dict) -> set[str]:
    vals = [row.get("state"), row.get("workerState"), row.get("dispatchStatus"), row.get("outcome"), row.get("terminalState")]
    stage = row.get("stage")
    if isinstance(stage, str):
        vals.append(stage)
    proj = row.get("projection") if isinstance(row.get("projection"), dict) else {}
    vals.append(proj.get("outcome"))
    nested = proj.get("stage") if isinstance(proj.get("stage"), dict) else {}
    vals.extend([nested.get("worker"), nested.get("dispatch")])
    dispatch = row.get("dispatch") if isinstance(row.get("dispatch"), dict) else {}
    vals.append(dispatch.get("status"))
    return {v for v in vals if isinstance(v, str) and v}


def _liveness(row: dict) -> str:
    live = row.get("liveness")
    if isinstance(live, dict):
        live = live.get("verdict")
    return live if isinstance(live, str) else ""


def worker_kind(row: dict) -> str:
    """working, failed, stopped, released, or other."""
    states = _states(row)
    if states & FAILED:
        return "failed"
    if states & STOPPED:
        return "stopped"
    live = _liveness(row)
    terminal = row.get("terminalState") if isinstance(row.get("terminalState"), str) else ""
    ended = bool(states & FINAL) or terminal == "released" or live == "exited"
    if live in ("live", "running") and not ended:
        return "working"
    if states & {"ready", "running", "accepted", "dispatched", "in_progress"} and not ended:
        return "working"
    if terminal == "released" or states & RELEASED or live == "exited":
        return "released"
    return "other"


def row_path(row: dict) -> str:
    candidates = []
    workspace = row.get("workspace")
    if isinstance(workspace, str):
        candidates.append(workspace)
    resource = row.get("resource") if isinstance(row.get("resource"), dict) else {}
    for key in ("worktreeId",):
        if isinstance(resource.get(key), str):
            candidates.append(resource[key])
        if isinstance(row.get(key), str):
            candidates.append(row[key])
    proj = row.get("projection") if isinstance(row.get("projection"), dict) else {}
    pws = proj.get("workspace") if isinstance(proj.get("workspace"), dict) else {}
    if isinstance(pws.get("id"), str):
        candidates.append(pws["id"])
    for value in candidates:
        if "::" in value:
            return value.split("::", 1)[1]
    return ""


def branch_name(worktree: dict) -> str:
    branch = worktree.get("branch") or ""
    if not isinstance(branch, str):
        return ""
    prefix = "refs/heads/"
    return branch[len(prefix):] if branch.startswith(prefix) else branch


def pr_reason(prs: list[dict]) -> str | None:
    states = [(p.get("state") or "").upper() for p in prs]
    if "OPEN" in states:
        return None
    merged = [p for p in prs if (p.get("state") or "").upper() == "MERGED"]
    if merged:
        return "PR #%s merged" % merged[0].get("number")
    closed = [p for p in prs if (p.get("state") or "").upper() == "CLOSED"]
    if closed:
        return "PR #%s closed" % closed[0].get("number")
    return None


def issue_reason(issues: list[dict]) -> str | None:
    for issue in issues:
        if (issue.get("state") or "").upper() == "CLOSED" and issue.get("number") is not None:
            return "issue #%s closed" % issue.get("number")
    return None


def decide(worktree: dict, workers: list[dict], prs: list[dict], issues: list[dict], prs_known: bool = True) -> str | None:
    """Why this card should become Done, or None to leave it."""
    if worktree.get("isMainWorktree") is True:
        return None
    if (worktree.get("workspaceStatus") or "") == "completed":
        return None
    kinds = [worker_kind(row) for row in workers]
    working = "working" in kinds
    if prs_known:
        reason = pr_reason(prs)
        if reason:
            return reason
    reason = issue_reason(issues)
    if reason:
        return reason
    if working:
        return None
    # An open PR stays In review when some worker on this worktree was released.
    # A card whose workers only failed or stopped is Done even if that PR is still open.
    open_pr = prs_known and any((pr.get("state") or "").upper() == "OPEN" for pr in prs)
    released = "released" in kinds
    if "failed" in kinds and not (open_pr and released):
        return "worker failed"
    if "stopped" in kinds and not (open_pr and released):
        return "worker stopped"
    if prs_known and workers and kinds and all(kind == "released" for kind in kinds) and not prs:
        return "worker released, no PR"
    return None


def run_json(cmd: list[str], timeout: int) -> tuple[dict | list | None, str]:
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, check=False)
    except (OSError, subprocess.TimeoutExpired) as exc:
        return None, str(exc)
    if proc.returncode != 0:
        return None, (proc.stderr or proc.stdout or "exit %s" % proc.returncode).strip()
    try:
        return json.loads(proc.stdout), ""
    except json.JSONDecodeError:
        return None, "unreadable json"


def orca_json(*args: str) -> tuple[dict | None, str]:
    data, err = run_json([orca_bin(), *args, "--json"], 45)
    if not isinstance(data, dict):
        return None, err or "unreadable json"
    if data.get("ok") is False:
        message = ""
        error = data.get("error")
        if isinstance(error, dict):
            message = str(error.get("message") or error.get("code") or "")
        return None, message or "ok:false"
    return data, ""


def gh_json(args: list[str]) -> dict | list | None:
    data, _err = run_json(["gh", *args], 30)
    return data


def environment_ids() -> tuple[list[str] | None, str]:
    data, err = orca_json("environment", "list")
    if data is None:
        return None, err
    result = data.get("result") if isinstance(data.get("result"), dict) else {}
    envs = result.get("environments")
    if not isinstance(envs, list):
        return None, "environment list unreadable"
    ids = []
    for env in envs:
        if not isinstance(env, dict):
            continue
        ident = env.get("id") or env.get("name") or ""
        if isinstance(ident, str) and ident and ident != "local":
            ids.append(ident)
    return ids, ""


def worktrees_for(environment: str) -> tuple[list[dict] | None, str]:
    args = ["worktree", "list"]
    if environment:
        args += ["--environment", environment]
    data, err = orca_json(*args)
    if data is None:
        return None, err
    result = data.get("result") if isinstance(data.get("result"), dict) else {}
    if result.get("truncated") is True:
        return None, "worktree list truncated"
    rows = result.get("worktrees")
    if not isinstance(rows, list):
        return None, "worktree list unreadable"
    return [row for row in rows if isinstance(row, dict)], ""


def workers_for(environment: str) -> tuple[list[dict] | None, str]:
    rows: list[dict] = []
    cursor = ""
    seen: set[str] = set()
    for _ in range(20):
        args = ["orchestration", "worker-list", "--limit", "100"]
        if environment:
            args += ["--environment", environment]
        if cursor:
            args += ["--cursor", cursor]
        data, err = orca_json(*args)
        if data is None:
            return None, err
        result = data.get("result") if isinstance(data.get("result"), dict) else {}
        if result.get("truncated") is True:
            return None, "worker list truncated"
        page = result.get("workers")
        if not isinstance(page, list):
            return None, "worker list unreadable"
        rows.extend(row for row in page if isinstance(row, dict))
        nxt = result.get("nextCursor")
        if not nxt and isinstance(result.get("page"), dict):
            if result["page"].get("hasMore") is True:
                nxt = result["page"].get("nextCursor")
            else:
                nxt = ""
        if not isinstance(nxt, str) or not nxt or nxt in seen:
            break
        seen.add(nxt)
        cursor = nxt
    return rows, ""


def github_repo(project_id: object) -> str:
    if isinstance(project_id, str) and project_id.startswith("github:"):
        return project_id[len("github:"):]
    return ""


def _number(value: object) -> int | None:
    if isinstance(value, bool):
        return None
    if isinstance(value, int):
        return value
    if isinstance(value, str) and value.isdigit():
        return int(value)
    return None


def issue_candidates(worktree: dict, prs: list[dict], default_repo: str) -> list[tuple[str, int, str | None]]:
    found: list[tuple[str, int, str | None]] = []

    def add(repo: str, number: object, state: object) -> None:
        parsed = _number(number)
        if parsed is None or not repo:
            return
        text = state if isinstance(state, str) and state else None
        found.append((repo, parsed, text))

    linked = worktree.get("linkedIssue")
    if isinstance(linked, dict):
        repo = linked.get("repo") or linked.get("repository") or default_repo
        if isinstance(repo, dict):
            repo = repo.get("nameWithOwner") or default_repo
        add(str(repo or ""), linked.get("number"), linked.get("state"))
    elif isinstance(linked, str) and "#" in linked:
        repo, _, num = linked.rpartition("#")
        add(repo or default_repo, num, None)
    else:
        add(default_repo, linked, None)
    for pr in prs:
        for ref in pr.get("closingIssuesReferences") or []:
            if isinstance(ref, dict):
                add(default_repo, ref.get("number"), ref.get("state"))
    return found


def resolve_issues(candidates: list[tuple[str, int, str | None]], cache: dict[tuple[str, int], str | None]) -> list[dict]:
    issues = []
    for repo, number, state in candidates:
        if state is None:
            key = (repo, number)
            if key not in cache:
                data = gh_json(["issue", "view", str(number), "--repo", repo, "--json", "state,number"])
                cache[key] = data.get("state") if isinstance(data, dict) else None
            state = cache[key]
        if state:
            issues.append({"number": number, "state": state})
    return issues


def prs_for_repo(repo: str, cache: dict[str, list[dict] | None]) -> list[dict] | None:
    if repo not in cache:
        data = gh_json([
            "pr", "list", "--repo", repo, "--state", "all", "--limit", "1000",
            "--json", "number,state,headRefName,closingIssuesReferences",
        ])
        cache[repo] = data if isinstance(data, list) else None
        if cache[repo] is None:
            print("board-done: PR lookup failed for %s; those cards retry next round" % repo, file=sys.stderr)
    return cache[repo]


def stamp_key(environment: str, path: str) -> str:
    return "%s\t%s" % (environment or "local", path)


def stamp_path() -> str:
    override = os.environ.get("BOARD_DONE_STAMP")
    if override:
        return override
    root = os.environ.get("XDG_STATE_HOME") or os.path.expanduser("~/.local/state")
    return os.path.join(root, "agent-team", "board-done-since.json")


def load_stamps() -> dict[str, int]:
    try:
        with open(stamp_path(), encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, json.JSONDecodeError):
        return {}
    if not isinstance(data, dict):
        return {}
    stamps: dict[str, int] = {}
    for key, value in data.items():
        if isinstance(key, str) and isinstance(value, int) and not isinstance(value, bool):
            stamps[key] = value
    return stamps


def remember_done(environment: str, path: str, when_ms: int) -> None:
    """Record when a card became Done. A later cleanup uses this instead of last activity."""
    key = stamp_key(environment, path)
    stamps = load_stamps()
    if key in stamps:
        return
    stamps[key] = when_ms
    target = stamp_path()
    try:
        os.makedirs(os.path.dirname(target), exist_ok=True)
        temporary = target + ".tmp"
        with open(temporary, "w", encoding="utf-8") as handle:
            json.dump(stamps, handle, sort_keys=True)
            handle.write("\n")
        os.replace(temporary, target)
    except OSError as exc:
        print("board-done: could not record Done time for %s (%s)" % (path, exc), file=sys.stderr)


def set_completed(path: str, environment: str) -> bool:
    cmd = [orca_bin(), "worktree", "set", "--worktree", "path:%s" % path, "--workspace-status", "completed"]
    if environment:
        cmd += ["--environment", environment]
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=45, check=False)
    except (OSError, subprocess.TimeoutExpired) as exc:
        print("board-done: could not set completed on %s (%s)" % (path, exc), file=sys.stderr)
        return False
    if proc.returncode != 0:
        print("board-done: could not set completed on %s" % path, file=sys.stderr)
        return False
    remember_done(environment, path, int(time.time() * 1000))
    return True


def visit(environment: str, apply: bool, pr_cache: dict[str, list[dict] | None], issue_cache: dict[tuple[str, int], str | None]) -> tuple[int, int, bool]:
    """Returns moved, unchanged, reachable."""
    label = environment or "local"
    trees, err = worktrees_for(environment)
    if trees is None:
        print("board-done: skip %s (unreachable), retry next round" % label, file=sys.stderr)
        if err:
            print("board-done: %s: %s" % (label, err), file=sys.stderr)
        return 0, 0, False
    workers, werr = workers_for(environment)
    if workers is None:
        print("board-done: worker list unavailable on %s; worker rules skipped this round" % label, file=sys.stderr)
        workers = []
        if werr:
            print("board-done: %s: %s" % (label, werr), file=sys.stderr)
    by_path: dict[str, list[dict]] = {}
    for row in workers:
        path = row_path(row)
        if path:
            by_path.setdefault(path, []).append(row)
    moved = 0
    unchanged = 0
    for tree in trees:
        path = tree.get("path") or tree.get("workspacePath") or ""
        if not isinstance(path, str) or not path:
            unchanged += 1
            continue
        repo = github_repo(tree.get("projectId"))
        branch = branch_name(tree)
        prs: list[dict] = []
        prs_known = True
        if repo and branch:
            listed = prs_for_repo(repo, pr_cache)
            if listed is None:
                prs_known = False
            else:
                prs = [pr for pr in listed if pr.get("headRefName") == branch]
        elif not repo:
            prs_known = True
            prs = []
        issues = resolve_issues(issue_candidates(tree, prs, repo), issue_cache) if repo or tree.get("linkedIssue") else []
        reason = decide(tree, by_path.get(path, []), prs, issues, prs_known)
        if not reason:
            unchanged += 1
            continue
        verb = "set" if apply else "[dry-run] would set"
        print("%s %s completed (%s) environment=%s" % (verb, path, reason, label))
        if apply:
            set_completed(path, environment)
        moved += 1
    return moved, unchanged, True


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Move finished Orca board cards to Done.")
    parser.add_argument("--apply", action="store_true", help="Set the board status. The default is a dry run.")
    parser.add_argument("--dry-run", action="store_true", help="List the cards that would move. This is the default.")
    parser.add_argument("--environment", default="", help="One paired Orca environment. Empty means this machine.")
    parser.add_argument("--fleet", action="store_true", help="This machine and every paired environment.")
    args = parser.parse_args(argv)
    if args.apply and args.dry_run:
        print("board-done: --apply and --dry-run are exclusive", file=sys.stderr)
        return 2
    if args.fleet and args.environment:
        print("board-done: --fleet and --environment are exclusive", file=sys.stderr)
        return 2
    apply = args.apply
    pr_cache: dict[str, list[dict] | None] = {}
    issue_cache: dict[tuple[str, int], str | None] = {}
    targets = [args.environment]
    skipped = 0
    if args.fleet:
        targets = [""]
        ids, err = environment_ids()
        if ids is None:
            print("board-done: environment list unavailable; remote hosts retry next round", file=sys.stderr)
            if err:
                print("board-done: %s" % err, file=sys.stderr)
            skipped += 1
        else:
            targets.extend(ids)
    moved = 0
    unchanged = 0
    for environment in targets:
        count_moved, count_same, reachable = visit(environment, apply, pr_cache, issue_cache)
        moved += count_moved
        unchanged += count_same
        if not reachable:
            skipped += 1
    mode = "applied" if apply else "dry-run"
    print("%s: moved=%s unchanged=%s skipped_hosts=%s" % (mode, moved, unchanged, skipped))
    return 0


if __name__ == "__main__":
    sys.exit(main())
