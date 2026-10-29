"""What leaves this device: the switches in Settings for each kind of outbound connection that
can be turned off, in config.json under "privacy". Everything is on unless switched off.

    paper_details:  doi.org, Crossref and arXiv, for a saved paper's citation details, abstract,
                    retraction status and LaTeX source or HTML version.
    update_checks:  GitHub, once a day, for a newer release (read by the Mac app).
    note_lines:     Anthropic, for the one-line summary when a search result is added to Notes.
    note_topics:    Anthropic, for sorting notes into topics (Notes → Filter).

Claim checks, to-do apps, Notion and the rest are controlled where they're chosen; this file
only covers what has no other off switch.
"""

import json
from pathlib import Path
from typing import Dict

CONFIG = Path.home() / ".referee" / "config.json"
SWITCHES = ("paper_details", "update_checks", "note_lines", "note_topics")


def settings() -> Dict[str, bool]:

    try:
        saved = json.loads(CONFIG.read_text(encoding="utf-8")).get("privacy", {})
    except (OSError, ValueError):
        saved = {}
    # Claude writing note lines is off unless chosen: writing them yourself is part of learning.
    return {name: bool(saved.get(name, name != "note_lines")) for name in SWITCHES}


def allowed(name: str) -> bool:

    return settings().get(name, True)


def set_switch(name: str, on: bool) -> Dict[str, bool]:

    if name in SWITCHES:
        config = json.loads(CONFIG.read_text(encoding="utf-8")) if CONFIG.exists() else {}
        config.setdefault("privacy", {})[name] = bool(on)
        CONFIG.write_text(json.dumps(config, indent=2), encoding="utf-8")
    return settings()
