"""Earlier versions of notes, meetings and AI use entries, so an edit can be gone back on, not only
a deletion. Each save keeps the version it replaced (at most one a minute while typing, the last 20
per item, for 90 days), in history.json; restoring one saves it as the current version, which keeps
the one it replaced too, so a restore can itself be undone.
"""

import json
import time
from pathlib import Path
from typing import Dict, List, Optional

KEEP, DAYS, GAP = 20, 90, 60


class History:

    def __init__(self, path: Path):

        self.path = path
        try:
            self.items: Dict[str, List[Dict]] = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            self.items = {}

    def _save(self) -> None:

        cutoff = time.time() - DAYS * 86400
        self.items = {k: [v for v in vs if v["at"] > cutoff][-KEEP:] for k, vs in self.items.items()}
        self.items = {k: vs for k, vs in self.items.items() if vs}
        self.path.write_text(json.dumps(self.items), encoding="utf-8")

    def replaced(self, kind: str, old: Optional[Dict], new: Dict) -> None:

        """
        Called before a save: keeps the old version if it really differs, and not more than once a
        minute (so a stretch of typing makes one version, not hundreds).
        """

        if not old:
            return
        content = lambda item: {k: v for k, v in item.items() if k not in ("created",)}
        if content(old) == content(new):
            return
        versions = self.items.setdefault(old["id"], [])
        if versions and time.time() - versions[-1]["at"] < GAP:
            return
        versions.append({"kind": kind, "at": time.time(), "item": old})
        self._save()

    def versions(self, item_id: str) -> List[Dict]:

        return list(reversed(self.items.get(item_id, [])))
