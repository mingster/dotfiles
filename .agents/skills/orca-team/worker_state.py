"""Read Orca worker-show results and worker-list rows in both JSON shapes.

Current Orca is flat: state ("ready", "succeeded", ...), stage ("released", ...), liveness ("live",
"exited", ...), terminal (handle) and workspace ("<repoId>::<path>"). Older Orca nested these under
dispatch.status / dispatch.assigneeHandle / worker.*, and list rows carried dispatchStatus.
The flat fields are read first; the old ones are the fallback.
"""

FINAL_STATES = ("succeeded", "completed", "failed", "cancelled", "released", "stopped")


def _dict(v):
    return v if isinstance(v, dict) else {}


def status(r):
    """Display status: the flat state, else the old dispatch status."""
    r = _dict(r)
    return r.get("state") or r.get("dispatchStatus") or _dict(r.get("dispatch")).get("status") or ""


def is_final(r):
    """True once the dispatch has positively ended."""
    r = _dict(r)
    states = (r.get("state"), r.get("dispatchStatus"), _dict(r.get("dispatch")).get("status"))
    return (any(s in FINAL_STATES for s in states)
            or r.get("stage") == "released" or r.get("terminalState") == "released"
            or r.get("liveness") == "exited")


def is_nested(r):
    """True for the old nested list row, which has dispatchStatus or projection (flat rows have neither)."""
    r = _dict(r)
    return "dispatchStatus" in r or "projection" in r


def terminal(r):
    """The worker's agent terminal handle, or ""."""
    r = _dict(r)
    t = r.get("terminal")
    if isinstance(t, str) and t:
        return t
    return (_dict(t).get("handle") or r.get("agentTerminalHandle")
            or _dict(r.get("worker")).get("agentTerminalHandle")
            or _dict(r.get("dispatch")).get("assigneeHandle")
            or _dict(r.get("resource")).get("terminalHandle") or "")


def workspace_id(r):
    """"<repoId>::<path>" of the worker's workspace, or ""."""
    r = _dict(r)
    w = r.get("workspace")
    if isinstance(w, str) and w:
        return w
    return (_dict(r.get("resource")).get("worktreeId") or r.get("worktreeId")
            or _dict(_dict(r.get("projection")).get("workspace")).get("id")
            or _dict(r.get("worker")).get("worktreeId") or "")


def next_cursor(result):
    """Cursor of the next list page, "" on the last page. Raises ValueError when a page cannot prove it is the last.

    Current Orca puts nextCursor at the top level and omits it on the last page. Older Orca nested it under page
    with a hasMore flag.
    """
    def cursor(v):
        if not isinstance(v, str) or not v:
            raise ValueError("bad cursor")
        return v
    result = _dict(result)
    if "page" in result:
        page = _dict(result["page"])
        if page.get("hasMore") is True:
            return cursor(page.get("nextCursor"))
        if page.get("hasMore") is False:
            return ""
        raise ValueError("bad page")
    if result.get("nextCursor") is not None:
        return cursor(result["nextCursor"])
    return ""


def released(r):
    """True once Orca has released the dispatch (list rows and worker-show, both shapes)."""
    r = _dict(r)
    d = r.get("dispatchStatus") or _dict(r.get("dispatch")).get("status")
    if d:
        return d == "released"
    return "released" in (r.get("stage"), r.get("terminalState"), r.get("state"))


def can_close(r):
    """True when a dispatch's panes may close: it has positively ended. The one rule behind worker-pane-close."""
    return is_final(r)


def _path(r):
    wid = workspace_id(r)
    return wid.split("::", 1)[1] if "::" in wid else ""


def can_remove(rows, path, real=lambda p: p):
    """Whether the worktree at path may be freed, from the rows of every Run and page.

    Returns (ok, reason, released_ids). Needs an owner and every owner released; a worktree no dispatch owns
    stays, so does one with any dispatch not yet released.
    """
    owned = [r for r in rows if _path(r) and real(_path(r)) == path]
    if not owned:
        return False, "no Orca dispatch owns it", []
    if not all(released(r) for r in owned):
        return False, "its dispatch is not released", []
    return True, "", [r.get("dispatchId") for r in owned if r.get("dispatchId")]
