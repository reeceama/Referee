"""Referee on an iPhone, through a folder in iCloud Drive. Off until switched on in Settings
("phone_sync" in config.json).

The Mac stays in charge. Every minute, when something has changed, it writes a copy of what the
phone shows to iCloud Drive/Referee:

    library.json    saved sources: name, title, authors, date, site, link, project, cite key
    notes.json      reading notes          meetings.json   meetings with action points
    ai-use.json     the AI use log         evidence.json   checked claims by document
    projects.json   the projects, and which is current

The phone never edits those. Each change made on the phone (a new or edited note, a ticked
action point, a link to save, a meeting, an AI use entry) is a small file in Referee/Inbox,
named so they sort in the order they were made. The Mac applies them, deletes them, and the next
copy shows the result. Two devices never write the same file, so nothing is overwritten.
Passages, search vectors and PDFs stay on the Mac.
"""

import json
import threading
import time
from pathlib import Path
from typing import Callable, Dict, List, Optional

CONFIG = Path.home() / ".referee" / "config.json"
FOLDER = Path.home() / "Library" / "Mobile Documents" / "com~apple~CloudDocs" / "Referee"
EVERY = 60  # seconds


def enabled() -> bool:

    try:
        return bool(json.loads(CONFIG.read_text(encoding="utf-8")).get("phone_sync"))
    except (OSError, ValueError):
        return False


def available() -> bool:

    return FOLDER.parent.is_dir()


class Sync:

    """
    snapshot() returns {file name: data} for the copy; apply(change) applies one Inbox change
    and returns a short description, or raises ValueError for one it doesn't understand.
    """

    def __init__(self, snapshot: Callable[[], Dict[str, object]], apply: Callable[[Dict], str]):

        self.snapshot, self.apply = snapshot, apply
        self.last = ""
        self.wake = threading.Event()
        self.status_ = {"at": None, "applied": 0, "error": None}

    def start(self) -> None:

        threading.Thread(target=self._loop, daemon=True).start()

    def soon(self) -> None:

        self.wake.set()

    def _loop(self) -> None:

        while True:
            try:
                self.run()
            except OSError as error:
                self.status_["error"] = str(error)
            self.wake.wait(EVERY)
            self.wake.clear()

    def run(self) -> None:

        if not (enabled() and available()):
            return
        inbox = FOLDER / "Inbox"
        inbox.mkdir(parents=True, exist_ok=True)
        applied = 0
        for path in sorted(inbox.glob("*.json")):
            try:
                change = json.loads(path.read_text(encoding="utf-8"))
                self.apply(change)
                applied += 1
            except (OSError, ValueError, KeyError, TypeError) as error:
                # Not readable yet (iCloud still downloading it), or not understood: keep it aside.
                if time.time() - path.stat().st_mtime < 600:
                    continue
                failed = inbox / "Not applied"
                failed.mkdir(exist_ok=True)
                path.rename(failed / path.name)
                self.status_["error"] = f"{path.name}: {error}"
                continue
            path.unlink()
        data = self.snapshot()
        snapshot = json.dumps(data, sort_keys=True, default=str)
        if snapshot != self.last or applied:
            for name, value in data.items():
                target = FOLDER / name
                text = json.dumps(value, indent=1, ensure_ascii=False, default=str)
                if not target.exists() or target.read_text(encoding="utf-8") != text:
                    temporary = target.with_suffix(".tmp")
                    temporary.write_text(text, encoding="utf-8")
                    temporary.replace(target)  # the phone never sees a half-written file
            (FOLDER / "updated.json").write_text(json.dumps({"at": time.time()}), encoding="utf-8")
            self.last = snapshot
        self.status_ = {"at": time.time(), "applied": self.status_["applied"] + applied, "error": None}

    def status(self) -> Dict:

        return {"on": enabled(), "available": available(), "folder": str(FOLDER), **self.status_}
