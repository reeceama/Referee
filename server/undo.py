"""Recently deleted notes, meetings and AI use entries, so a deletion can be undone (⌘Z in
Referee, or Undo in the message after deleting). The last 50 are kept for 30 days in
recently-deleted.json; undoing puts the most recent back exactly as it was.
"""

import json
import time
from pathlib import Path
from typing import Callable, Dict, List, Optional

KEEP, DAYS = 500, 30


class Undo:

    def __init__(self, path: Path, restore: Dict[str, Callable[[Dict], object]]):

        self.path, self.restore = path, restore
        try:
            self.items = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            self.items = []

    def _save(self) -> None:

        cutoff = time.time() - DAYS * 86400
        self.items = [i for i in self.items if i["at"] > cutoff][-KEEP:]
        self.path.write_text(json.dumps(self.items), encoding="utf-8")

    def deleted(self, kind: str, item: Optional[Dict]) -> None:

        if item:
            self.items.append({"kind": kind, "item": item, "at": time.time()})
            self._save()

    def last(self) -> Optional[Dict]:

        return self.items[-1] if self.items else None

    def of(self, kind: str, project: Optional[str] = None) -> List[Dict]:

        """
        What's been deleted of one kind (for Meetings' or AI Use's Recently Deleted), newest first.
        """

        return [i for i in reversed(self.items) if i["kind"] == kind
                and (project is None or (i["item"].get("project") or "") == project)]

    def put_back(self, at: float) -> Optional[Dict]:

        entry = next((i for i in self.items if abs(i["at"] - at) < 0.001), None)
        if entry:
            self.restore[entry["kind"]](entry["item"])
            self.items.remove(entry)
            self._save()
        return entry

    def forget(self, at: float) -> None:

        self.items = [i for i in self.items if abs(i["at"] - at) >= 0.001]
        self._save()

    def undo(self) -> Optional[Dict]:

        """
        Puts the most recently deleted item back; returns what it was.
        """

        if not self.items:
            return None
        entry = self.items.pop()
        self.restore[entry["kind"]](entry["item"])
        self._save()
        return entry
