"""Session state I/O and routing rules."""
from __future__ import annotations

import json
import logging
import re

from .config import STATE_FILE
from .win32_io import pid_alive

log = logging.getLogger("voice-input.routing")

# A session is "wake-targetable" if its name appears at the start of the
# transcribed command. The wake keyword regex is permissive — Whisper varies.
WAKE_KEYWORD_RE = re.compile(
    r"\b(?:cl[aáo]ude?s?|cl[oó]u?ds?|clau|"
    r"escucha[dme]?|esc[úu]chame|escuch[áa]me|listen|aud[ií]ame)\b"
    r"[\s,.:!?]*",
    re.IGNORECASE,
)


def load_sessions() -> list[dict]:
    """Read sessions, prune dead ones (Claude process gone), and rewrite.

    Robust to BOM (PowerShell often writes UTF-8-BOM). When pruning
    occurs, the file is rewritten without BOM in pretty-printed JSON.
    """
    try:
        raw = STATE_FILE.read_text(encoding="utf-8-sig")
        data = json.loads(raw)
    except Exception as e:
        log.warning("load_sessions read failed: %s", e)
        return []
    sessions = data.get("sessions") or []
    alive = []
    for s in sessions:
        cp = int(s.get("claude_pid") or 0)
        tp = int(s.get("terminal_pid") or 0)
        if cp and pid_alive(cp):
            alive.append(s)
        elif not cp and tp and pid_alive(tp):
            alive.append(s)
    if len(alive) != len(sessions):
        try:
            data["sessions"] = alive
            STATE_FILE.write_text(
                json.dumps(data, indent=2, ensure_ascii=False),
                encoding="utf-8",
            )
            log.info("pruned %d dead sessions", len(sessions) - len(alive))
        except Exception as e:
            log.warning("could not rewrite state: %s", e)
    return alive


def split_name_prefix(text: str, sessions: list[dict]) -> tuple[str, dict | None]:
    """If ``text`` starts with a registered session name, strip it and
    return ``(remainder, session)``. Otherwise return ``(text, None)``."""
    s = text.strip()
    for sess in sessions:
        name = sess.get("name") or ""
        if not name:
            continue
        m = re.match(rf"^\s*{re.escape(name)}\s*[,.:]?\s+", s, re.IGNORECASE)
        if m:
            return s[m.end():].strip(), sess
    return s, None
