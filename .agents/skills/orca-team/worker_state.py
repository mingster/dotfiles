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
