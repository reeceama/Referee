"""Archived research trails. Archiving a project's trail records where it ended; the trail from
then on starts empty, and the archived one stays readable, between its dates. Nothing is deleted:
the reading and checks themselves stay where they are, so restoring an archived trail only removes
its end mark and it rejoins the current one.
"""

import json
import time
from pathlib import Path
from typing import Dict, List


class TrailArchive:

    def __init__(self, path: Path):

        self.path = path
        try:
            self.items: Dict[str, List[Dict]] = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            self.items = {}

    def _save(self) -> None:

        self.path.write_text(json.dumps(self.items, indent=1), encoding="utf-8")

    def archived(self, project: str) -> List[Dict]:

        return self.items.get(project, [])

    def current_start(self, project: str) -> float:

        ends = [a["to"] for a in self.archived(project)]
        return max(ends) if ends else 0

    def archive(self, project: str, start: float) -> Dict:

        entry = {"from": start, "to": time.time()}
        self.items.setdefault(project, []).append(entry)
        self._save()
        return entry

    def restore(self, project: str, to: float) -> bool:

        before = len(self.archived(project))
        self.items[project] = [a for a in self.archived(project) if abs(a["to"] - to) > 0.001]
        self._save()
        return len(self.items[project]) < before


def period(start: float, end: float) -> str:

    day = lambda t: f"{time.localtime(t).tm_mday} {time.strftime('%b %Y', time.localtime(t))}"
    return f"{day(start)} – {day(end)}"
