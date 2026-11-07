#!/usr/bin/env python3
"""Remove finished git worktrees on this host. Preview unless --apply."""
from __future__ import annotations

import json
import os
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
HOOK = ".cursor/hooks/state/continual-learning.json"
PROT = frozenset({"staging", "production", "gh-pages"})
BUDGET = float(os.environ.get("CLEAN_FINISHED_REPO_SECONDS", "60"))
def run(cmd: list[str], cwd: str | None = None, limit: float | None = None) -> tuple[int, str]:
    kw = {"cwd": cwd, "text": True, "capture_output": True}
    if limit is not None:
        kw["timeout"] = max(0.1, limit)
    try:
        p = subprocess.run(cmd, **kw)
        return p.returncode, (p.stdout or "") + (p.stderr or "")
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return 124, ""


def gitc(repo: str, *args: str, limit: float = 30) -> tuple[int, str]:
    return run(["git", "-C", repo, *args], limit=limit)


def worktrees(repo: str) -> list[tuple[str, str | None, str, bool]]:
    rc, out = gitc(repo, "worktree", "list", "--porcelain")
    if rc:
        return []
    rows, path, br, head, locked = [], "", "", "", False
    for line in out.splitlines():
        if line.startswith("worktree "):
            path and rows.append((path, br or None, head, locked))
            path, br, head, locked = line[9:], "", "", False
        elif line.startswith("branch refs/heads/"):
            br = line[18:]
        elif line.startswith("HEAD "):
            head = line[5:].strip()
        elif line == "locked":
            locked = True
    path and rows.append((path, br or None, head, locked))
    return rows
def fetch_prs(repo: str, end: float) -> tuple[bool, dict[str, dict]]:
    gh, size, rank = os.environ.get("GH", "gh"), 1000, {"OPEN": 3, "MERGED": 2, "CLOSED": 1}
    rc, out = run([gh, "pr", "list", "--state", "all", "--limit", str(size),
                   "--json=number,state,headRefName,closedAt"], repo, max(1.0, end - time.monotonic()))
    if rc:
        return False, {}
    try:
        all_p = json.loads(out or "[]")
    except json.JSONDecodeError:
        return False, {}
    if not isinstance(all_p, list):
        return False, {}
    by: dict[str, dict] = {}
    for pr in all_p:
        br, st = pr.get("headRefName") or "", pr.get("state") or ""
        if br and rank.get(st, 0) > rank.get((by.get(br) or {}).get("state"), 0):
            by[br] = pr
    return True, by
def status_ok(path: str) -> tuple[bool, str]:
    rc, out = run(["git", "-C", path, "status", "--porcelain", "-uall"])
    if rc:
        return False, "status unreadable"
    lines = [x for x in out.splitlines() if x.strip()]
    return (True, "") if not lines or all(x[3:].strip().strip('"') == HOOK for x in lines) else (False, "uncommitted changes")
def unpushed(repo: str, br: str | None, head: str) -> bool:
    ref = f"refs/heads/{br}" if br else head
    rc, out = gitc(repo, "rev-list", "--count", ref, "--not", "--remotes=origin")
    return rc != 0 or not out.strip().isdigit() or int(out.strip()) > 0
def on_origin(repo: str, sha: str) -> bool:
    rc, out = gitc(repo, "for-each-ref", "--contains", sha, "--format=%(refname)", "refs/remotes/origin")
    return rc == 0 and bool(out.strip())
def in_main(repo: str, ref: str) -> bool:
    return gitc(repo, "merge-base", "--is-ancestor", ref, "origin/main")[0] == 0
def all_main(repo: str, br: str) -> bool:
    rc, out = gitc(repo, "rev-list", f"refs/heads/{br}", "--not", "origin/main")
    return rc == 0 and not out.strip()
def cherry_ok(repo: str, ref: str) -> bool:
    rc, out = gitc(repo, "cherry", "origin/main", ref)
    return rc == 0 and not any(x.startswith("+") for x in out.splitlines())
def under(parent: str, child: str) -> bool:
    try:
        Path(child).resolve().relative_to(Path(parent).resolve())
        return True
    except ValueError:
        return Path(child).resolve() == Path(parent).resolve()
def lsof_bin() -> str | None:
    raw = os.environ.get("CLEAN_FINISHED_LSOF", "lsof")
    if not raw or raw == "missing":
        return None
    return raw
def path_busy(path: str, terms: set[str], end: float) -> tuple[bool, str | None]:
    if any(under(path, b) for b in terms):
        return True, "running process"
    lb = lsof_bin()
    if not lb:
        return False, "could not check processes"
    rc, out = run([lb, "-t", "+D", path], limit=max(0.2, end - time.monotonic()))
    if rc > 1:
        return False, "could not check processes"
    if out.strip():
        return True, "running process"
    return False, None
def terminal_cwds(end: float) -> set[str] | None:
    rc, out = run([os.environ.get("ORCA_CLI_COMMAND", "orca"), "terminal", "list", "--json"], limit=end - time.monotonic())
    if rc:
        return None
    try:
        terms = (json.loads(out).get("result") or {}).get("terminals") or []
    except json.JSONDecodeError:
        return None
    return {t.get(k) for t in terms if isinstance(t, dict) for k in ("cwd", "worktreePath") if t.get(k)}
def pinned(end: float) -> set[str] | None:
    rc, out = run([os.environ.get("ORCA_CLI_COMMAND", "orca"), "worktree", "list", "--json"], limit=end - time.monotonic())
    if rc:
        return None
    try:
        items = (json.loads(out).get("result") or {}).get("worktrees") or []
    except (json.JSONDecodeError, AttributeError):
        return None
    return {p for it in items if isinstance(it, dict) and it.get("pinned")
            for p in (it.get("path"), it.get("workspacePath")) if p}
def repos(end: float) -> list[str]:
    env = os.environ.get("CLEAN_FINISHED_REPOS")
    if env:
        return [p for p in env.split(os.pathsep) if p]
    oc = os.environ.get("ORCA_CLI_COMMAND", "orca")
    rc, out = run([oc, "repo", "list", "--json"], limit=end - time.monotonic())
    if rc:
        return []
    try:
        data = json.loads(out)
    except json.JSONDecodeError:
        return []
    return [e["path"] for e in (data.get("result") or {}).get("repos") or []
            if isinstance(e, dict) and e.get("kind") == "git" and e.get("path")
            and (Path(e["path"]) / ".agents/head-checks.conf").is_file()]
def decide(repo: str, wt: tuple, main: str, dflt: str, pr_ok: bool, pr: dict, pins: set[str],
           terms: set[str] | None, kept_br: set[str], end: float) -> tuple[str, str, bool | str]:
    path, br, head, locked = wt
    if path == main:
        return "keep", "main checkout", False
    why = br if br and (br == dflt or br in PROT) else ("archive branch" if br and br.startswith("archive/") else None)
    if why is not None:
        return "keep", why, False
    if str(Path(path).resolve()) in {str(Path(p).resolve()) for p in pins}:
        return "keep", "pinned", False
    if locked:
        return "keep", "locked", False
    ok, swhy = status_ok(path)
    if not ok:
        return "keep", swhy, False
    if terms is None:
        return "keep", "could not check processes", False
    busy, pwhy = path_busy(path, terms, end)
    if pwhy:
        return "keep", pwhy, False
    if busy:
        return "keep", "running process", False
    if not pr_ok:
        return "keep", "pull request list unavailable", False
    row = pr.get(br or "")
    if row and row.get("state") == "OPEN":
        return "keep", "open pull request", False
    if br and br in kept_br:
        return "keep", "checked out in a kept worktree", False
    if unpushed(repo, br, head):
        return "keep", "unpushed commits", False
    if not br and not on_origin(repo, head):
        return "keep", "detached, commits not on a remote", False
    ref = f"refs/heads/{br}" if br else head
    if br:
        if row and row.get("state") == "MERGED":
            return "delete", "merged pull request", True
        if all_main(repo, br) or in_main(repo, ref) or cherry_ok(repo, ref):
            return "delete", "already in main", True
        if row and row.get("state") == "CLOSED":
            return ("delete", "closed pull request", True if in_main(repo, head) or cherry_ok(repo, head) else "delayed")
        return "keep", "no pull request", False
    if in_main(repo, head) or cherry_ok(repo, head):
        return "delete", "detached at merged commit", False
    return "keep", "detached, commits not on a remote", False
def remote_age(pr: dict) -> tuple[bool, str]:
    raw = pr.get("closedAt") or ""
    if not raw:
        return False, "unknown"
    try:
        days = (datetime.now(timezone.utc) - datetime.fromisoformat(raw.replace("Z", "+00:00"))).days
    except ValueError:
        return False, raw[:10]
    return days >= 7, raw[:10]
def do_repo(repo: str, apply: bool, end: float, s: dict[str, int], failed: list[bool]) -> None:
    def keep(target: str, why: str) -> None:
        print(f"Kept {target} ({why})")
        s["kept"] += 1

    wts = worktrees(repo)
    if not wts:
        return
    main, dflt, pins = wts[0][0], "main", pinned(end)
    rc, out = gitc(repo, "symbolic-ref", "--quiet", "refs/remotes/origin/HEAD")
    if rc == 0 and out.strip():
        dflt = out.strip().split("/")[-1]
    if pins is None:
        for wt in wts[1:]:
            keep(wt[0], "orca worktree list unavailable")
        return
    now = time.monotonic()
    terms = terminal_cwds(min(end, now + 8))
    pr_ok, pr = fetch_prs(repo, min(end, now + 40))
    kept_br, plan = set(), []
    for wt in wts[1:]:
        if time.monotonic() >= end:
            keep(wt[0], "time budget")
            continue
        act, why, remote = decide(repo, wt, main, dflt, pr_ok, pr, pins, terms, kept_br, end)
        if act == "keep" and wt[1]:
            kept_br.add(wt[1])
        plan.append((wt, act, why, remote))
    for wt, act, why, remote in plan:
        if time.monotonic() >= end:
            keep(wt[0], "time budget")
            continue
        path, br, head, _ = wt
        if act == "keep":
            keep(path, why)
            continue
        if not apply:
            print(f"Remove worktree {path} ({why})")
            s["removed"] += 1
            if br and remote is True:
                s["dr"] += 1
            continue
        busy, pwhy = path_busy(path, terms or set(), end)
        if pwhy or busy:
            keep(path, pwhy or "running process")
            failed.append(True)
            continue
        ok, sw = status_ok(path)
        if not ok:
            keep(path, sw)
            failed.append(True)
            continue
        if gitc(repo, "worktree", "remove", path)[0]:
            keep(path, "remove failed")
            failed.append(True)
            continue
        s["removed"] += 1
        if br and not any(w[1] == br for w in worktrees(repo)) and not unpushed(repo, br, head):
            if gitc(repo, "branch", "-d", br)[0]:
                keep(f"local {br}", "delete failed")
                failed.append(True)
                continue
            s["dl"] += 1
        if br and remote is True and not gitc(repo, "push", "origin", "--delete", br)[0]:
            s["dr"] += 1
        elif br and remote == "delayed":
            ok_age, when = remote_age(pr.get(br) or {})
            if ok_age and not gitc(repo, "push", "origin", "--delete", br)[0]:
                s["dr"] += 1
            else:
                print(f"Kept remote {br} (closed {when}, deleted after 7 days)")
        if not run([os.environ.get("ORCA_CLI_COMMAND", "orca"), "worktree", "rm", path], repo)[0]:
            s["orca"] += 1

def main() -> int:
    apply = "--apply" in sys.argv[1:]
    s = {"removed": 0, "dl": 0, "dr": 0, "orca": 0, "kept": 0}
    failed: list[bool] = []
    t0 = time.monotonic()
    for r in repos(t0 + BUDGET * 20):
        do_repo(r, apply, time.monotonic() + BUDGET, s, failed)
    print(f"removed worktrees={s['removed']} deleted local={s['dl']} deleted remote={s['dr']} "
          f"orca records={s['orca']} kept={s['kept']}")
    return 1 if failed else 0
if __name__ == "__main__":
    sys.exit(main())
