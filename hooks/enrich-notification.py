#!/usr/bin/env python3
"""Rewrite cmux notifications to lead with WHICH workspace and WHAT is needed.

cmux notification hooks receive the notification policy as JSON on stdin and
must return updated JSON on stdout. Default banners read like:

    Claude Code
    Claude is waiting for your input

...which does not say which of a dozen workspaces is asking, or what for. This
rewrites them to:

    Research — permission needed          (title: space + action)
    ⠂ Claude Code                          (subtitle: which tab)
    Claude needs your permission to use Bash   (body: the original detail)

Names are resolved by reading cmux's own session file rather than calling the
cmux CLI: this hook runs inside cmux's notification delivery path, so calling
back into the control socket risks re-entrancy and burns the hook timeout.

FAILURE CONTRACT: cmux falls back to default behaviour AND posts a hook-failure
alert on any error, timeout, or invalid JSON. So every failure path here must
still emit the untouched input. Never let an exception escape.
"""

import json
import os
import re
import sys

# Agent CLIs prefix the terminal title with an animated spinner frame (braille
# cells, ✳/✻/✽ …). Live in a tab strip, meaningless in a static banner — and it
# differs frame to frame, so identical notifications look different.
SPINNER = re.compile(r"^[⠀-⣿✲-✿∗·\*•\s]+")

# Agents write markdown; macOS banners render plain text, so "**Delete 12**"
# arrives with the asterisks visible. Strip the syntax, keep the words.
# Ordering matters: images before links, bold before italic, fences before code.
MD = [
    (re.compile(r"!\[([^\]]*)\]\([^)]*\)"), r"\1"),            # ![alt](url)
    (re.compile(r"\[([^\]]+)\]\([^)]*\)"), r"\1"),             # [text](url)
    (re.compile(r"```[A-Za-z0-9_+-]*\n?"), " "),               # fenced block
    (re.compile(r"^\s{0,3}([-*_])\s*(?:\1\s*){2,}$", re.M), " "),  # --- rule
    # Headings must match mid-string, not just at line start: cmux flattens the
    # body's newlines before the hook sees it, so "…out of it.\n## The finding"
    # arrives as one line. Requiring whitespace AFTER the hashes keeps "PR #138"
    # and "issue #3" intact.
    (re.compile(r"(?:^|(?<=\s))#{1,6}[ \t]+", re.M), ""),      # ### heading
    (re.compile(r"^\s{0,3}>\s?", re.M), ""),                   # > quote
    (re.compile(r"^\s{0,3}[-*+]\s+", re.M), "• "),             # - bullet
    (re.compile(r"^\s{0,3}\d+[.)]\s+", re.M), "• "),           # 1. bullet
    (re.compile(r"(\*\*)(?=\S)(.+?)(?<=\S)\1", re.S), r"\2"),  # **bold**
    (re.compile(r"~~(?=\S)(.+?)(?<=\S)~~", re.S), r"\1"),      # ~~strike~~
    # Asterisk only — never underscore. Agents write **bold**, but they also
    # write __init__.py, __main__.py and __tests__, and treating _ as emphasis
    # silently rewrote those to init.py / main.py / tests. Losing the rare
    # _italic_ is a far cheaper mistake than corrupting a filename.
    # The lookarounds also protect shell globs like `rm -rf build/*`.
    (re.compile(r"(?<![A-Za-z0-9\\])(\*)(?=\S)([^*\n]+?)(?<=\S)\1(?![A-Za-z0-9])"), r"\2"),
    (re.compile(r"`+([^`]+)`+"), r"\1"),                       # `code`
]


def strip_markdown(text):
    """Markdown syntax -> plain text. Never raises; returns input on trouble."""
    if not text:
        return text
    try:
        for pattern, repl in MD:
            text = pattern.sub(repl, text)
        return " ".join(text.split())
    except Exception:
        return text

SESSION = os.path.expanduser(
    "~/Library/Application Support/cmux/session-com.cmuxterm.app.json"
)

# cmux keeps only the newest notification per surface, so the generic idle
# reminder (~60s after a turn ends) destroys the detailed turn-end message that
# preceded it — "Delete 12, keep 6?" becomes "Claude is waiting for your input".
# This hook sees every notification, so it keeps its own record of the last
# informative one per surface and hands the detail back to the reminder.
# cmux's session file is not usable for this: it is written periodically and
# lags real delivery. Calling the cmux CLI is not usable either — this runs
# inside cmux's notification delivery path.
RECALL_DIR = os.path.expanduser("~/.cache/cmux-notify")
RECALL_MAX_AGE = 60 * 60  # an hour; older context is not worth resurrecting

GENERIC = re.compile(
    r"waiting for your input|is waiting|awaiting input|^idle\b|needs your attention",
    re.I,
)


def is_generic(text):
    """True for boilerplate that carries no information about what is wanted."""
    return bool(text) and bool(GENERIC.search(text))


def recall_path(surface_id):
    safe = re.sub(r"[^A-Za-z0-9._-]", "", surface_id or "")
    return os.path.join(RECALL_DIR, safe + ".json") if safe else None


def load_recall(surface_id):
    path = recall_path(surface_id)
    if not path:
        return None
    try:
        with open(path) as fh:
            saved = json.load(fh)
        import time

        if time.time() - float(saved.get("ts", 0)) > RECALL_MAX_AGE:
            return None
        return saved
    except Exception:
        return None


def save_recall(surface_id, body):
    path = recall_path(surface_id)
    if not path or not body:
        return
    try:
        import time

        os.makedirs(RECALL_DIR, exist_ok=True)
        tmp = path + ".tmp"
        with open(tmp, "w") as fh:
            json.dump({"body": body, "ts": time.time()}, fh)
        os.replace(tmp, path)
    except Exception:
        pass


def find_context(surface_id):
    """surface_id -> (workspace title, tab title, sibling tab count).

    Panels in the session file are keyed by surface UUID, so locate the
    workspace that owns this surface. Returns (None, None, 0) on any miss.
    """
    if not surface_id:
        return None, None, 0
    try:
        with open(SESSION) as fh:
            data = json.load(fh)
    except Exception:
        return None, None, 0

    for window in data.get("windows") or []:
        tm = window.get("tabManager") or {}
        for ws in tm.get("workspaces") or []:
            panels = ws.get("panels") or []
            for panel in panels:
                if panel.get("id") != surface_id:
                    continue
                title = (
                    ws.get("customTitle")
                    or ws.get("processTitle")
                    or os.path.basename(ws.get("currentDirectory") or "")
                    or None
                )
                return title, panel.get("title"), len(panels)
    return None, None, 0


# A permission or approval prompt is written by Claude Code, not by the model:
# the title is "Claude permission" and the body is "<Tool> needs approval" (or
# "Claude needs your permission to use <Tool>"). Match that exact shape.
SYSTEM_PERMISSION_BODY = re.compile(
    r"^\s*(?:claude\s+)?(?:\S+\s+)?needs (?:your )?(?:approval|permission)\b",
    re.I,
)
# Failed turns carry the API's own error text, which always opens the body.
SYSTEM_ERROR_BODY = re.compile(
    r"^\s*(?:api[ _]?error|connection[ _]dropped|stopfailure)\b", re.I
)


def classify(title, subtitle, body, agent=None):
    """The action the human must take, preferring cmux's own agent category.

    For agent notifications cmux supplies `agent.category` (turn-complete,
    needs-permission or idle-reminder) and `agent.pending` (the turn ended with
    background work still running). Those come from the agent hooks, not from
    the message text, so they win. The text rules in classify_text() are the
    fallback for notifications with no agent block (plain `cmux notify`, OSC
    sequences) and for categories this hook does not know.
    """
    agent = agent if isinstance(agent, dict) else {}
    category = agent.get("category")
    pending = bool(agent.get("pending"))

    if category == "needs-permission":
        return "permission needed"
    if category == "idle-reminder":
        return "waiting for you"

    action = classify_text(title, subtitle, body)

    if category == "turn-complete":
        # A finished turn is never a permission prompt, whatever its text says.
        # Questions and errors are still worth naming.
        if action in (None, "permission needed", "waiting for you", "turn complete"):
            return "done, background tasks running" if pending else "turn complete"
    return action


def classify_text(title, subtitle, body):
    """Reduce the notification to the action the human must take.

    The body of a turn-end notification is the agent's own last message, so it
    can say anything: "permission", "approved", "waiting", "failed". Matching
    those words anywhere in the blob labelled ordinary replies "permission
    needed" (7 banners, 5 of them just messages). So: the title that Claude
    Code and cmux write is authoritative, system-shaped bodies are matched by
    their exact opening, and free text only gets the softer checks below.
    """
    t = (title or "").lower()
    b = (body or "").lower()

    # 1. System-authored titles ("Claude permission", "Claude question").
    if "permission" in t:
        return "permission needed"
    if "question" in t:
        return "needs a decision"

    # 2. System-shaped bodies, matched by their opening words only.
    if SYSTEM_PERMISSION_BODY.match(body or ""):
        return "permission needed"
    if SYSTEM_ERROR_BODY.match(body or ""):
        return "error"
    if is_generic(body) or "needs your input" in b:
        return "waiting for you"

    blob = " ".join(x for x in (title, subtitle, body) if x).lower()
    # Check BEFORE "complete": cmux reports a turn that ends with a question as
    # turn-complete, but if the agent stopped to ask something, the action the
    # human must take is a decision — not nothing.
    if any(
        k in blob
        for k in (
            "confirm", "should i", "shall i", "proceed?", "would you like",
            "let me know", "y/n", "question", "plan", "before i",
        )
    ):
        return "needs a decision"
    if "complete" in blob or "finished" in blob or "done" in blob:
        return "turn complete"
    return None


def main():
    raw = sys.stdin.read()
    # Anything after this point must not raise; fall back to raw on error.
    try:
        payload = json.loads(raw)
        note = payload.get("notification") or {}

        title = strip_markdown(note.get("title") or "")
        subtitle = strip_markdown(note.get("subtitle") or "")
        body = strip_markdown(note.get("body") or "")

        # Nothing worth rewriting, and returning a hollowed-out notification
        # object could blank the banner. Hand back exactly what we were given.
        if not (title or subtitle or body):
            sys.stdout.write(raw)
            return

        ws_title, tab_title, tab_count = find_context(note.get("surfaceId"))
        if not ws_title:
            cwd = ((payload.get("context") or {}).get("cwd")) or ""
            ws_title = os.path.basename(cwd.rstrip("/")) or None

        agent = payload.get("agent")
        action = classify(title, subtitle, body, agent)

        # Title carries the two things worth seeing before a banner truncates:
        # which space, and what it wants.
        if ws_title and action:
            note["title"] = f"{ws_title} — {action}"
        elif ws_title:
            note["title"] = ws_title
        elif action:
            note["title"] = f"{title or 'Agent'} — {action}"

        # Subtitle disambiguates the tab, but only when the workspace has more
        # than one — otherwise it is noise repeating the workspace name.
        if tab_title and tab_count > 1:
            cleaned = strip_markdown(SPINNER.sub("", tab_title)).strip()
            if cleaned:
                note["subtitle"] = cleaned
        elif title and title.strip() and title.strip() != note.get("title"):
            note["subtitle"] = title.strip()

        # Keep the original detail; fall back to the old subtitle if empty.
        detail = body.strip() or subtitle.strip()

        surface_id = note.get("surfaceId") or ""
        if is_generic(detail):
            # A bare reminder: re-attach the detail from the message it is
            # reminding us about.
            #
            # Do NOT set effects["record"] = False here. An earlier version did,
            # to stop the reminder overwriting the detailed entry — but cmux can
            # only withdraw notifications it recorded, so unrecorded banners
            # never cleared when you focused the surface and piled up on screen.
            # Overwriting is harmless now anyway: the replacement entry carries
            # the same detail the original one did.
            prev = load_recall(surface_id)
            prev_body = (prev or {}).get("body") or ""
            if prev_body and not is_generic(prev_body):
                detail = prev_body
        elif detail:
            save_recall(surface_id, detail)

        if detail:
            note["body"] = detail

        payload["notification"] = note
        sys.stdout.write(json.dumps(payload))
    except Exception:
        sys.stdout.write(raw)


if __name__ == "__main__":
    main()
