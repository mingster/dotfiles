#!/usr/bin/env python3
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
                   "--json=number,state,headRefName,headRefOid,closedAt"], repo, max(1.0, end - time.monotonic()))
    try:
        all_p = json.loads(out or "[]") if not rc else []
    except json.JSONDecodeError:
        return False, {}
    if rc or not isinstance(all_p, list):
        return False, {}
    by: dict[str, dict] = {}
    for pr in all_p:
        br, st = pr.get("headRefName") or "", pr.get("state") or ""
        if br and rank.get(st, 0) > rank.get((by.get(br) or {}).get("state"), 0):
            by[br] = pr
    return True, by
def wt_dirty(path: str) -> tuple[bool, str, bool]:
    rc, out = run(["git", "-C", path, "status", "--porcelain", "-uall"])
    lines = [] if rc else [x for x in out.splitlines() if x.strip()]
    hook = bool(lines) and all(x[3:].strip().strip('"') == HOOK for x in lines)
    return (not lines or hook, "" if not lines or hook else "uncommitted changes", hook)
def status_ok(path: str) -> tuple[bool, str]:
    ok, why, _ = wt_dirty(path)
    return ok, why
def unpushed(repo: str, br: str | None, head: str) -> bool:
    ref = f"refs/heads/{br}" if br else head
    rc, out = gitc(repo, "rev-list", "--count", ref, "--not", "--remotes=origin")
    return rc != 0 or not out.strip().isdigit() or int(out.strip()) > 0
def on_origin(repo: str, sha: str) -> bool:
    rc, out = gitc(repo, "for-each-ref", "--contains", sha, "--format=%(refname)", "refs/remotes/origin")
    return rc == 0 and bool(out.strip())
def in_main(repo: str, ref: str) -> bool:
    return gitc(repo, "merge-base", "--is-ancestor", ref, "origin/main")[0] == 0
def cherry_ok(repo: str, ref: str) -> bool:
    rc, out = gitc(repo, "cherry", "origin/main", ref)
    return rc == 0 and not any(x.startswith("+") for x in out.splitlines())
def remote_age(pr: dict) -> tuple[bool, str]:
    raw = pr.get("closedAt") or ""
    if not raw:
        return False, "unknown"
    try:
        days = (datetime.now(timezone.utc) - datetime.fromisoformat(raw.replace("Z", "+00:00"))).days
    except ValueError:
        return False, raw[:10]
    return days >= 7, raw[:10]
def commits_safe(repo: str, sha: str) -> bool:
    return in_main(repo, sha) or cherry_ok(repo, sha)


def archive_push(repo: str, br: str, sha: str) -> tuple[int, str]:
    return gitc(repo, "push", "origin", f"{sha}:refs/tags/archive/{br}")


def remote_keep_line(br: str, remote: bool | str) -> str | None:
    if remote == "newer":
        return f"Kept remote {br} (remote has newer commits)"
    if remote == "unsafe":
        return f"Kept remote {br} (commits not in main)"
    return None


def archive_line(br: str, sha: str) -> str:
    return f"Archive remote {br} (git push origin {sha}:refs/tags/archive/{br})"
def origin_branches(repo: str) -> list[str]:
    rc, out = gitc(repo, "for-each-ref", "--format=%(refname:short)", "refs/remotes/origin")
    if rc:
        return []
    return [ln[7:] for ln in out.splitlines() if ln.startswith("origin/") and ln != "origin/HEAD"]


def decide_remote_only(repo: str, br: str, dflt: str, pr_ok: bool, pr: dict) -> tuple[str, str, bool | str]:
    if br == dflt or br in PROT:
        return "keep", "default branch" if br == dflt else br, False
    if br.startswith("archive/"):
        return "keep", "archive branch", False
    if not pr_ok:
        return "keep", "pull request list unavailable", False
    row = pr.get(br)
    if not row:
        return "keep", "no pull request", False
    if row.get("state") == "OPEN":
        return "keep", "open pull request", False
    ref = f"refs/remotes/origin/{br}"
    if gitc(repo, "show-ref", "--verify", ref)[0]:
        return "keep", "no remote branch", False
    rc, tip = gitc(repo, "rev-parse", ref)
    tip = tip.strip() if rc == 0 else ""
    if not tip:
        return "keep", "no remote branch", False
    if row.get("state") == "MERGED":
        if not commits_safe(repo, tip):
            return "keep", "commits not in main", False
        return "delete", "merged pull request", remote_plan(repo, br, "", row)
    if row.get("state") == "CLOSED":
        if in_main(repo, tip) or cherry_ok(repo, tip):
            return "delete", "closed pull request", remote_plan(repo, br, "", row)
        return "delete", "closed pull request", "delayed"
    return "keep", "no pull request", False


def remote_plan(repo: str, br: str, head: str, row: dict | None) -> bool | str:
    ref = f"refs/remotes/origin/{br}"
    if not br or gitc(repo, "show-ref", "--verify", ref)[0]:
        return False
    if head:
        rc, out = gitc(repo, "rev-list", ref, "--not", head)
        if rc == 0 and out.strip():
            return "newer"
    rc, tip = gitc(repo, "rev-parse", ref)
    tip = tip.strip() if rc == 0 else ""
    if not tip or not commits_safe(repo, tip):
        return "unsafe"
    return True
def under(parent: str, child: str) -> bool:
    try:
        Path(child).resolve().relative_to(Path(parent).resolve())
        return True
    except ValueError:
        return Path(child).resolve() == Path(parent).resolve()
def path_busy(path: str, terms: set[str], end: float) -> tuple[bool, str | None]:
    if any(under(path, b) for b in terms):
        return True, "running process"
    raw = os.environ.get("CLEAN_FINISHED_LSOF", "lsof")
    lb = None if not raw or raw == "missing" else raw
    if not lb:
        return False, "could not check processes"
    rc, out = run([lb, "-t", "+D", path], limit=max(0.2, end - time.monotonic()))
    if rc > 1:
        return False, "could not check processes"
    if out.strip():
        return True, "running process"
    return False, None
def orca_set(end: float, args: list[str], key: str, pin: bool = False) -> set[str] | None:
    rc, out = run([os.environ.get("ORCA_CLI_COMMAND", "orca"), *args], limit=end - time.monotonic())
    if rc:
        return None
    try:
        items = (json.loads(out).get("result") or {}).get(key) or []
    except (json.JSONDecodeError, AttributeError):
        return None
    return ({p for it in items if isinstance(it, dict) and it.get("pinned")
             for p in (it.get("path"), it.get("workspacePath")) if p} if pin else
            {t.get(k) for t in items if isinstance(t, dict) for k in ("cwd", "worktreePath") if t.get(k)})
def repos(end: float) -> list[str]:
    env = os.environ.get("CLEAN_FINISHED_REPOS")
    if env:
        return [p for p in env.split(os.pathsep) if p]
    rc, out = run([os.environ.get("ORCA_CLI_COMMAND", "orca"), "repo", "list", "--json"], limit=end - time.monotonic())
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
            if not commits_safe(repo, head):
                return "keep", "commits not in main", False
            return "delete", "merged pull request", remote_plan(repo, br, head, row)
        rc, ahead = gitc(repo, "rev-list", f"refs/heads/{br}", "--not", "origin/main")
        if (rc == 0 and not ahead.strip()) or in_main(repo, ref) or cherry_ok(repo, ref):
            return "delete", "already in main", remote_plan(repo, br, head, row)
        if row and row.get("state") == "CLOSED":
            r = remote_plan(repo, br, head, row) if in_main(repo, head) or cherry_ok(repo, head) else "delayed"
            return "delete", "closed pull request", r
        return "keep", "no pull request", False
    if in_main(repo, head) or cherry_ok(repo, head):
        return "delete", "detached at merged commit", False
    if on_origin(repo, head):
        return "keep", "no pull request", False
    return "keep", "detached, commits not on a remote", False
def do_repo(repo: str, apply: bool, end: float, s: dict[str, int], failed: list[bool]) -> None:
    def keep(target: str, why: str) -> None:
        print(f"Kept {target} ({why})"); s["kept"] += 1

    def keep_remote(br: str, why: str) -> None:
        print(f"Kept remote {br} ({why})"); s["kept"] += 1
    def del_remote(br: str) -> None:
        rc, err = gitc(repo, "push", "origin", "--delete", br)
        if rc:
            keep(f"remote {br}", f"delete failed: {err.strip()}" if err.strip() else "delete failed")
            failed.append(True)
        else:
            s["deleted_remote"] += 1

    def plan_remote(br: str, head: str, remote: bool | str, why: str) -> None:
        if remote == "delayed":
            ok_age, when = remote_age(pr.get(br) or {})
            if not ok_age:
                print(f"Kept remote {br} (closed {when}, deleted after 7 days)")
                s["kept"] += 1
                return
            rc, tip = gitc(repo, "rev-parse", f"refs/remotes/origin/{br}")
            tip = tip.strip() if rc == 0 and tip.strip() else head
            print(archive_line(br, tip))
            if apply:
                rc, err = archive_push(repo, br, tip)
                if rc:
                    keep(f"remote {br}", f"archive failed: {err.strip()}" if err.strip() else "archive failed")
                    failed.append(True)
                    return
                del_remote(br)
            else:
                print(f"Remove remote {br} ({why})")
                s["deleted_remote"] += 1
            return
        line = remote_keep_line(br, remote)
        if line:
            print(line)
            s["kept"] += 1
            return
        if remote is True:
            if not apply:
                print(f"Remove remote {br} ({why})")
                s["deleted_remote"] += 1
            else:
                del_remote(br)
    wts = worktrees(repo)
    if not wts:
        return
    main, dflt = wts[0][0], "main"
    pins = orca_set(end, ["worktree", "list", "--json"], "worktrees", pin=True)
    rc, out = gitc(repo, "symbolic-ref", "--quiet", "refs/remotes/origin/HEAD")
    if rc == 0 and out.strip():
        dflt = out.strip().split("/")[-1]
    if pins is None:
        for wt in wts[1:]:
            keep(wt[0], "orca worktree list unavailable")
        return
    if gitc(repo, "fetch", "origin", limit=max(0.1, end - time.monotonic()))[0]:
        for wt in wts[1:]:
            keep(wt[0], "fetch failed")
        return
    now = time.monotonic()
    terms = orca_set(min(end, now + 8), ["terminal", "list", "--json"], "terminals")
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
            print(f"Remove worktree {path} ({why})"); s["removed"] += 1
            if br and not unpushed(repo, br, head) and len([w for w in worktrees(repo) if w[1] == br]) == 1:
                s["deleted_local"] += 1
            if br and remote:
                plan_remote(br, head, remote, why)
            continue
        busy, pwhy = path_busy(path, terms or set(), end)
        ok, sw = status_ok(path)
        if pwhy or busy or not ok:
            keep(path, pwhy or ("running process" if busy else sw))
            failed.append(True)
            continue
        rm = ["worktree", "remove"] + (["--force"] if wt_dirty(path)[2] else []) + [path]
        rc, err = gitc(repo, *rm)
        if rc:
            keep(path, f"remove failed: {err.strip()}" if err.strip() else "remove failed")
            failed.append(True)
            continue
        s["removed"] += 1
        if br and not any(w[1] == br for w in worktrees(repo)) and not unpushed(repo, br, head):
            rc, err = gitc(repo, "branch", "-d", br)
            if rc:
                keep(f"local {br}", f"delete failed: {err.strip()}" if err.strip() else "delete failed")
                failed.append(True)
            else:
                s["deleted_local"] += 1
        if br and remote:
            plan_remote(br, head, remote, why)
        rc, err = run([os.environ.get("ORCA_CLI_COMMAND", "orca"), "worktree", "rm", path], repo)
        if rc:
            why_orca = err.strip() if err.strip() else f"orca worktree rm exited {rc}"
            keep(f"orca record {path}", why_orca)
            failed.append(True)
        else:
            s["orca"] += 1
    checked_out = {wt[1] for wt in wts if wt[1]} | kept_br
    for br in origin_branches(repo):
        if time.monotonic() >= end:
            keep_remote(br, "time budget")
            continue
        if br in checked_out:
            continue
        act, why, remote = decide_remote_only(repo, br, dflt, pr_ok, pr)
        if act == "keep":
            keep_remote(br, why)
            continue
        ref = f"refs/remotes/origin/{br}"
        rc, tip = gitc(repo, "rev-parse", ref)
        head = tip.strip() if rc == 0 else ""
        plan_remote(br, head, remote, why)

def main() -> int:
    apply = "--apply" in sys.argv[1:]
    s = {"removed": 0, "deleted_local": 0, "deleted_remote": 0, "orca": 0, "kept": 0}
    failed: list[bool] = []
    t0 = time.monotonic()
    for r in repos(t0 + BUDGET * 20):
        do_repo(r, apply, time.monotonic() + BUDGET, s, failed)
    v, dl, dr = ("removed", "deleted local", "deleted remote") if apply else ("would remove", "would delete local", "would delete remote")
    print(f"{v} worktrees={s['removed']} {dl}={s['deleted_local']} {dr}={s['deleted_remote']} orca records={s['orca']} kept={s['kept']}")
    return 1 if failed else 0
if __name__ == "__main__":
    sys.exit(main())
