#!/usr/bin/env python3
"""Clean Orca board cards that have been Done for 30 minutes.

The coordinator's scheduled wrap-up runs this after board-done. A card that just
became Done stays until a later round. Cleanup runs on the host named by the
dispatch record (`--environment`): worktree, local branch, remote branch,
terminals and session. A host that cannot be reached is skipped and tried again
next round. It is not treated as gone.

Guards that keep a card, with a board comment naming the reason: unsaved
changes, commits that are not on main and not on any remote, an unreleased
worker, the coordinator's own worktree, a lead-* worktree, an rm-* worktree,
the main checkout, a protected branch, or an archive/ branch. Once its worker
is released, a verify-*, qa-* or rm-* branch is deleted even with local
commits. A failed or stopped card is cleaned under those same guards.

Dry run is the default and names every Done card it would clean or keep.
"""
from __future__ import annotations

import importlib.util
import json
import os
import re
import subprocess
import sys
from pathlib import Path

CLEAN_DETAIL = "worktree, local branch, remote branch, terminals, session"
THROWAWAY_PREFIXES = ("verify-", "qa-", "rm-")
PROTECTED_BRANCHES = frozenset({"main", "master", "staging", "production", "HEAD"})
_MODULE = None


def board():
    global _MODULE
    if _MODULE is None:
        path = Path(__file__).resolve().parent / "board-done.py"
        spec = importlib.util.spec_from_file_location("board_done", path)
        if spec is None or spec.loader is None:
            raise RuntimeError("cannot load board-done.py")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        _MODULE = module
    return _MODULE


def clock_ms() -> int:
    override = os.environ.get("BOARD_CLEAN_NOW_MS")
    if override and override.isdigit():
        return int(override)
    import time
    return int(time.time() * 1000)


def window_ms() -> int:
    override = os.environ.get("BOARD_CLEAN_DONE_MS")
    if override and override.isdigit():
        return int(override)
    return 30 * 60 * 1000


def as_ms(value: object) -> int | None:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    number = int(value)
    if number <= 0:
        return None
    if number < 10_000_000_000:
        return number * 1000
    return number


def normalize(environment: str) -> str:
    return environment or "local"


def plain_branch(tree: dict) -> str:
    return board().branch_name(tree)


def is_throwaway(branch: str) -> bool:
    return any(branch.startswith(prefix) for prefix in THROWAWAY_PREFIXES)


def leaf(path: str) -> str:
    return os.path.basename(path.rstrip("/"))


def is_coordinator(tree: dict, workers: list[dict]) -> bool:
    if tree.get("coordinator") is True:
        return True
    name = leaf(str(tree.get("path") or ""))
    if name.startswith("elon-") or name.startswith("coord-"):
        return True
    for row in workers:
        projection = row.get("projection") if isinstance(row.get("projection"), dict) else {}
        role = projection.get("role") or row.get("role") or ""
        if isinstance(role, str) and role.lower() in ("elon", "coordinator"):
            return True
    return False


def named_host(value: object) -> str:
    """A remote environment id. "local" only means the machine the list was taken from."""
    if not isinstance(value, str):
        return ""
    text = value.strip()
    if text in ("", "local"):
        return ""
    return text


def dispatch_environment(workers: list[dict], listed: str) -> tuple[str, str | None]:
    """Host from the dispatch record. The listed environment is the fallback."""
    found: list[str] = []
    for row in workers:
        projection = row.get("projection") if isinstance(row.get("projection"), dict) else {}
        host = projection.get("host") if isinstance(projection.get("host"), dict) else {}
        ident = named_host(host.get("id")) or named_host(projection.get("environment")) or named_host(row.get("host"))
        if ident:
            found.append(ident)
    unique = set(found)
    if len(unique) > 1:
        return normalize(listed), "dispatch hosts disagree"
    if len(unique) == 1:
        return normalize(next(iter(unique))), None
    return normalize(listed), None


def resolve_since(tree: dict, environment: str, stamps: dict[str, int], now: int) -> int:
    key = board().stamp_key(environment, str(tree.get("path") or ""))
    if key in stamps:
        return stamps[key]
    activity = as_ms(tree.get("lastActivityAt"))
    if activity is not None:
        return activity
    return now


def keep_reason(
    tree: dict,
    workers: list[dict],
    facts: dict,
    now_ms: int,
    done_since_ms: int,
    limit_ms: int,
) -> str | None:
    """Why this Done card stays. None means clean it."""
    if now_ms - done_since_ms < limit_ms:
        minutes = max(1, limit_ms // 60000)
        return "Done for less than %s minutes" % minutes
    if tree.get("isMainWorktree") is True:
        return "main checkout"
    branch = plain_branch(tree)
    if branch.startswith("archive/"):
        return "archive branch"
    if branch in PROTECTED_BRANCHES:
        return "protected branch"
    if is_coordinator(tree, workers):
        return "coordinator worktree"
    name = leaf(str(tree.get("path") or ""))
    if name.startswith("lead-"):
        return "lead worktree"
    kinds = [board().worker_kind(row) for row in workers]
    if any(kind in ("working", "other") for kind in kinds):
        return "unreleased worker"
    dirty = facts.get("dirty")
    unpushed = facts.get("unpushed")
    if dirty is None:
        return "unsaved changes unreadable"
    if dirty:
        return "unsaved changes"
    released = not workers or all(kind == "released" for kind in kinds)
    if is_throwaway(branch) and released:
        return None
    if name.startswith("rm-"):
        return "rm worktree"
    if unpushed is None:
        return "commit reachability unreadable"
    if unpushed:
        return "commits not on any remote"
    return None


def report_line(apply: bool, action: str, path: str, detail: str, environment: str) -> str:
    host = normalize(environment)
    if apply:
        return "%s %s (%s) environment=%s" % (action, path, detail, host)
    return "[dry-run] would %s %s (%s) environment=%s" % (action, path, detail, host)


def parse_probe(text: str) -> dict:
    dirty = None
    unpushed = None
    for line in text.splitlines():
        if ":" not in line:
            continue
        key, raw = line.split(":", 1)
        raw = raw.strip()
        if key.strip() == "dirty" and raw.isdigit():
            dirty = int(raw) > 0
        elif key.strip() == "unpushed":
            if raw.isdigit():
                unpushed = int(raw) > 0
            elif raw == "unknown":
                unpushed = None
    return {"dirty": dirty, "unpushed": unpushed}


def text_from_read(data: dict) -> str:
    result = data.get("result") if isinstance(data.get("result"), dict) else {}
    for key in ("output", "text", "content", "screen"):
        if isinstance(result.get(key), str):
            return result[key]
    terminal = result.get("terminal") if isinstance(result.get("terminal"), dict) else {}
    for key in ("preview", "output", "text"):
        if isinstance(terminal.get(key), str):
            return terminal[key]
    lines = result.get("lines")
    if isinstance(lines, list):
        parts = []
        for line in lines:
            if isinstance(line, dict):
                parts.append(str(line.get("text") or ""))
            else:
                parts.append(str(line))
        return "\n".join(parts)
    return ""


def handle_of(data: dict) -> str:
    result = data.get("result") if isinstance(data.get("result"), dict) else {}
    if isinstance(result.get("handle"), str):
        return result["handle"]
    terminal = result.get("terminal") if isinstance(result.get("terminal"), dict) else {}
    if isinstance(terminal.get("handle"), str):
        return terminal["handle"]
    return ""


def call(environment: str, *args: str):
    cmd = list(args)
    if environment and environment != "local":
        cmd += ["--environment", environment]
    return board().orca_json(*cmd)


def tri(value: object) -> bool | None:
    if isinstance(value, bool):
        return value
    return None


def load_fact_table() -> dict | None:
    path = os.environ.get("BOARD_CLEAN_FACTS")
    if not path:
        return None
    try:
        with open(path, encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, json.JSONDecodeError) as exc:
        print("board-clean: cannot read facts (%s); cards stay" % exc, file=sys.stderr)
        return {}
    return data if isinstance(data, dict) else {}


def local_git_facts(path: str) -> dict:
    if not os.path.isdir(path):
        return {"dirty": None, "unpushed": None}
    try:
        status = subprocess.run(
            ["git", "-C", path, "status", "--porcelain", "--untracked-files=all"],
            capture_output=True, text=True, timeout=30, check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return {"dirty": None, "unpushed": None}
    if status.returncode != 0:
        return {"dirty": None, "unpushed": None}
    dirty = bool(status.stdout.strip())
    try:
        count = subprocess.run(
            ["git", "-C", path, "rev-list", "--count", "HEAD", "--not", "--remotes=origin"],
            capture_output=True, text=True, timeout=30, check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return {"dirty": dirty, "unpushed": None}
    text = count.stdout.strip()
    if count.returncode != 0 or not text.isdigit():
        return {"dirty": dirty, "unpushed": None}
    return {"dirty": dirty, "unpushed": int(text) > 0}


def remote_facts(path: str, environment: str) -> dict:
    command = (
        "d=$(git status --porcelain --untracked-files=all 2>/dev/null | wc -l | tr -d ' '); "
        "u=$(git rev-list --count HEAD --not --remotes=origin 2>/dev/null || echo unknown); "
        "printf 'dirty:%s\\nunpushed:%s\\n' \"$d\" \"$u\"; exit"
    )
    data, _err = call(environment, "terminal", "create", "--worktree", "path:%s" % path, "--command", command)
    if data is None:
        return {"dirty": None, "unpushed": None}
    handle = handle_of(data)
    text = text_from_read(data)
    if handle:
        call(environment, "terminal", "wait", "--terminal", handle, "--for", "tui-idle", "--timeout-ms", "15000")
        read, _err = call(environment, "terminal", "read", "--terminal", handle)
        if read is not None:
            text = text_from_read(read) or text
        call(environment, "terminal", "close", "--terminal", handle)
    parsed = parse_probe(text)
    if parsed["dirty"] is None and parsed["unpushed"] is None:
        return {"dirty": None, "unpushed": None}
    return parsed


def facts_for(path: str, environment: str, table: dict | None) -> dict:
    if table is not None:
        row = table.get(path)
        if not isinstance(row, dict):
            return {"dirty": None, "unpushed": None}
        return {"dirty": tri(row.get("dirty")), "unpushed": tri(row.get("unpushed"))}
    if normalize(environment) == "local":
        return local_git_facts(path)
    return remote_facts(path, environment)


def shell_quote(value: str) -> str | None:
    if not value or re.search(r"[\n\r']", value):
        return None
    return "'%s'" % value


def branch_script(main: str, branch: str, throwaway: bool) -> str | None:
    if not main or not branch:
        return None
    quoted_main = shell_quote(main)
    quoted_branch = shell_quote(branch)
    if not quoted_main or not quoted_branch:
        return None
    flag = "-D" if throwaway else "-d"
    return "git -C %s branch %s %s; git -C %s push origin --delete %s; exit" % (
        quoted_main, flag, quoted_branch, quoted_main, quoted_branch,
    )


def main_checkout(trees: list[dict], project_id: object) -> str:
    for tree in trees:
        if tree.get("isMainWorktree") is True and tree.get("projectId") == project_id:
            path = tree.get("path") or ""
            if isinstance(path, str) and path:
                return path
    return ""


def comment(path: str, environment: str, reason: str, current: object) -> None:
    if isinstance(current, str) and current == reason:
        return
    data, err = call(environment, "worktree", "set", "--worktree", "path:%s" % path, "--comment", reason)
    if data is None:
        print("board-clean: could not comment on %s (%s)" % (path, err or "failed"), file=sys.stderr)


def sessions_closed(path: str, environment: str) -> bool:
    data, err = call(environment, "terminal", "list", "--worktree", "path:%s" % path)
    if data is None:
        print("board-clean: terminal list failed for %s (%s)" % (path, err or "failed"), file=sys.stderr)
        return False
    result = data.get("result") if isinstance(data.get("result"), dict) else {}
    if result.get("truncated") is True:
        print("board-clean: terminal list truncated for %s" % path, file=sys.stderr)
        return False
    terminals = result.get("terminals")
    if not isinstance(terminals, list):
        print("board-clean: terminal list unreadable for %s" % path, file=sys.stderr)
        return False
    if not terminals:
        return True
    closed, err = call(environment, "terminal", "close", "--worktree", "path:%s" % path, "--all")
    if closed is None:
        print("board-clean: terminal close failed for %s (%s)" % (path, err or "failed"), file=sys.stderr)
        return False
    return True


def delete_local_branches(main: str, branch: str, throwaway: bool) -> None:
    if not main or not branch or not os.path.isdir(main):
        return
    flag = "-D" if throwaway else "-d"
    try:
        deleted = subprocess.run(
            ["git", "-C", main, "branch", flag, branch],
            capture_output=True, text=True, timeout=30, check=False,
        )
        pushed = subprocess.run(
            ["git", "-C", main, "push", "origin", "--delete", branch],
            capture_output=True, text=True, timeout=30, check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        print("board-clean: branch delete failed for %s (%s)" % (branch, exc), file=sys.stderr)
        return
    if deleted.returncode != 0:
        print("board-clean: local branch delete failed for %s" % branch, file=sys.stderr)
    if pushed.returncode != 0:
        print("board-clean: remote branch delete failed for %s" % branch, file=sys.stderr)


def delete_remote_branches(environment: str, main: str, branch: str, throwaway: bool) -> None:
    script = branch_script(main, branch, throwaway)
    if script is None:
        if branch:
            print("board-clean: branch delete skipped for %s" % branch, file=sys.stderr)
        return
    data, err = call(environment, "terminal", "create", "--worktree", "path:%s" % main, "--command", script)
    if data is None:
        print("board-clean: branch delete failed for %s (%s)" % (branch, err or "failed"), file=sys.stderr)
        return
    handle = handle_of(data)
    if not handle:
        return
    call(environment, "terminal", "wait", "--terminal", handle, "--for", "exit", "--timeout-ms", "20000")
    call(environment, "terminal", "close", "--terminal", handle)


def act_clean(path: str, environment: str, branch: str, main: str, throwaway: bool) -> str | None:
    if not sessions_closed(path, environment):
        return "terminal close failed"
    data, err = call(environment, "worktree", "rm", "--worktree", "path:%s" % path, "--delete-branch")
    if data is None:
        print("board-clean: could not remove %s (%s)" % (path, err or "failed"), file=sys.stderr)
        return "remove failed"
    if normalize(environment) == "local":
        delete_local_branches(main, branch, throwaway)
    else:
        delete_remote_branches(environment, main, branch, throwaway)
    return None


def _next_cursor(result: dict) -> str:
    nxt = result.get("nextCursor")
    if not nxt and isinstance(result.get("page"), dict):
        page = result["page"]
        nxt = page.get("nextCursor") if page.get("hasMore") is True else ""
    return nxt if isinstance(nxt, str) else ""


def collect_pages(environment: str, base: list[str], field: str) -> tuple[list | None, str, str]:
    """Read every page. A missing or repeated cursor stops the walk; a failed page fails the walk."""
    rows: list = []
    cursor = ""
    seen: set[str] = set()
    scope = ""
    for _ in range(50):
        args = list(base)
        if cursor:
            args += ["--cursor", cursor]
        data, err = call(environment, *args)
        if data is None:
            return None, err or (field + " unreadable"), ""
        result = data.get("result") if isinstance(data.get("result"), dict) else {}
        if result.get("truncated") is True:
            return None, field + " truncated", ""
        page = result.get(field)
        if not isinstance(page, list):
            return None, field + " unreadable", ""
        if not scope:
            reported = result.get("scope") if isinstance(result.get("scope"), dict) else {}
            if isinstance(reported.get("source"), str):
                scope = reported["source"]
        rows.extend(page)
        nxt = _next_cursor(result)
        if not nxt or nxt in seen:
            break
        seen.add(nxt)
        cursor = nxt
    return rows, "", scope


def dedupe_workers(rows: list) -> list[dict]:
    kept: list[dict] = []
    seen: set[str] = set()
    for row in rows:
        if not isinstance(row, dict):
            continue
        ident = row.get("dispatchId") if isinstance(row.get("dispatchId"), str) else ""
        if ident and ident in seen:
            continue
        if ident:
            seen.add(ident)
        kept.append(row)
    return kept


def workers_for_host(environment: str) -> tuple[list[dict] | None, str]:
    """Workers on this host. A bound caller only sees its own run, so that list is not trusted."""
    direct, err, scope = collect_pages(
        environment, ["orchestration", "worker-list", "--limit", "100"], "workers"
    )
    if direct is None:
        return None, err
    if scope == "all":
        return dedupe_workers(direct), ""
    runs, err, _scope = collect_pages(environment, ["orchestration", "run-list"], "runs")
    if runs is None:
        return None, err or "worker list unavailable"
    rows: list = []
    for run in runs:
        if not isinstance(run, dict):
            continue
        run_id = run.get("id")
        if not isinstance(run_id, str) or not run_id:
            continue
        page, err, _page_scope = collect_pages(
            environment,
            ["orchestration", "worker-list", "--run", run_id, "--limit", "100"],
            "workers",
        )
        if page is None:
            return None, err
        rows.extend(page)
    return dedupe_workers(rows), ""


def workers_by_path(workers: list[dict]) -> dict[str, list[dict]]:
    grouped: dict[str, list[dict]] = {}
    for row in workers:
        path = board().row_path(row)
        if path:
            grouped.setdefault(path, []).append(row)
    return grouped


def consider(tree: dict, listed: str, grouped: dict[str, list[dict]] | None, trees: list[dict],
             stamps: dict[str, int], table: dict | None, apply: bool, now: int, limit: int,
             unreachable: set[str]) -> str:
    """Print one clean or keep line. Returns 'clean' or 'keep'."""
    path = str(tree.get("path") or "")
    workers = [] if grouped is None else grouped.get(path, [])
    if grouped is None:
        host, blocked = normalize(listed), "worker list unavailable"
    else:
        host, blocked = dispatch_environment(workers, listed)
    since = resolve_since(tree, listed, stamps, now)
    if apply and board().stamp_key(listed, path) not in stamps:
        board().remember_done(listed, path, since)
        stamps[board().stamp_key(listed, path)] = since
    if blocked:
        reason = blocked
    elif host in unreachable:
        reason = "host unreachable, retry next round"
    else:
        reason = keep_reason(tree, workers, facts_for(path, host, table), now, since, limit)
    if reason:
        print(report_line(apply, "keep", path, reason, host))
        if apply:
            comment_host = listed if host in unreachable or blocked == "worker list unavailable" else host
            comment(path, comment_host, reason, tree.get("comment"))
        return "keep"
    branch = plain_branch(tree)
    main = main_checkout(trees, tree.get("projectId"))
    throwaway = is_throwaway(branch)
    if throwaway and branch and normalize(host) != "local" and branch_script(main, branch, True) is None:
        why = "main checkout unknown" if not main else "branch name is not safe to delete"
        print(report_line(apply, "keep", path, why, host))
        if apply:
            comment(path, host, why, tree.get("comment"))
        return "keep"
    if not apply:
        print(report_line(False, "clean", path, CLEAN_DETAIL, host))
        return "clean"
    failed = act_clean(path, host, branch, main, throwaway)
    if failed:
        print(report_line(True, "keep", path, failed, host))
        comment(path, host, failed, tree.get("comment"))
        return "keep"
    print(report_line(True, "clean", path, CLEAN_DETAIL, host))
    return "clean"


def main(argv: list[str] | None = None) -> int:
    import argparse
    parser = argparse.ArgumentParser(description="Clean Done Orca board cards after 30 minutes.")
    parser.add_argument("--apply", action="store_true", help="Clean the cards. The default is a dry run.")
    parser.add_argument("--dry-run", action="store_true", help="Name every Done card that would be cleaned or kept.")
    parser.add_argument("--environment", default="", help="One paired Orca environment. Empty means this machine.")
    parser.add_argument("--fleet", action="store_true", help="This machine and every paired environment.")
    args = parser.parse_args(argv)
    if args.apply and args.dry_run:
        print("board-clean: --apply and --dry-run are exclusive", file=sys.stderr)
        return 2
    if args.fleet and args.environment:
        print("board-clean: --fleet and --environment are exclusive", file=sys.stderr)
        return 2
    apply = args.apply
    targets = [args.environment]
    if args.fleet:
        targets = [""]
        ids, err = board().environment_ids()
        if ids is None:
            print("board-clean: environment list unavailable; remote hosts retry next round")
            if err:
                print("board-clean: %s" % err, file=sys.stderr)
        else:
            targets.extend(ids)
    table = load_fact_table()
    stamps = board().load_stamps()
    now = clock_ms()
    limit = window_ms()
    unreachable: set[str] = set()
    gathered: list[tuple[str, list[dict], list[dict] | None]] = []
    skipped = 0
    for environment in targets:
        label = normalize(environment)
        trees, err = board().worktrees_for(environment)
        if trees is None:
            unreachable.add(label)
            skipped += 1
            print("board-clean: skip %s (unreachable), retry next round" % label)
            if err:
                print("board-clean: %s: %s" % (label, err), file=sys.stderr)
            continue
        workers, werr = workers_for_host(environment)
        if workers is None:
            print("board-clean: worker list unavailable on %s; cards stay this round" % label, file=sys.stderr)
            if werr:
                print("board-clean: %s: %s" % (label, werr), file=sys.stderr)
            gathered.append((label, trees, None))
        else:
            gathered.append((label, trees, workers))
    cleaned = 0
    kept = 0
    for label, trees, workers in gathered:
        grouped = None if workers is None else workers_by_path(workers)
        for tree in trees:
            if (tree.get("workspaceStatus") or "") != "completed":
                continue
            path = tree.get("path") or tree.get("workspacePath") or ""
            if not isinstance(path, str) or not path:
                continue
            outcome = consider(tree, label, grouped, trees, stamps, table, apply, now, limit, unreachable)
            if outcome == "clean":
                cleaned += 1
            else:
                kept += 1
    mode = "applied" if apply else "dry-run"
    print("%s: clean=%s keep=%s skipped_hosts=%s" % (mode, cleaned, kept, skipped))
    return 0


if __name__ == "__main__":
    sys.exit(main())
