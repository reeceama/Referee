"""Reading notes, by project, each linked to the page of a saved source it's about.

Not a notes app: a note is a line of your own ("Def 4.35, basis") plus, optionally, the saved
source and page it refers to, so the app can open the source right there. Referee also uses them:
a theorem you cite from a page you haven't noted is pointed out, as a nudge to check you've
read what you cite.
"""

import json
import time
import uuid
from pathlib import Path
from typing import Dict, List, Optional


class Notes:

    def __init__(self, path: Path):

        self.path = path
        try:
            self.items: List[Dict] = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            self.items = []

    def _save(self) -> None:

        self.path.write_text(json.dumps(self.items, indent=1), encoding="utf-8")

    def all(self, project: Optional[str] = None) -> List[Dict]:

        """
        In the order they were written. project: None for every note, "" for notes in no project.
        """

        found = [n for n in self.items if project is None or (n.get("project") or "") == project]
        return sorted(found, key=lambda n: n.get("created") or 0)

    def save(self, note: Dict) -> Dict:

        page = note.get("page")
        try:
            page = int(page) if page not in (None, "") else None
        except (TypeError, ValueError):
            page = None
        clean = {
            "id": note.get("id") or uuid.uuid4().hex,
            "project": note.get("project") or "",
            "text": note.get("text") or "",
            "url": note.get("url") or "",      # the saved source it's about, if any
            "page": page if page and page > 0 else None,
            "created": note.get("created") or time.time(),
        }
        self.items = [n for n in self.items if n["id"] != clean["id"]] + [clean]
        self._save()
        return clean

    def delete(self, note_id: str) -> bool:

        before = len(self.items)
        self.items = [n for n in self.items if n["id"] != note_id]
        self._save()
        return len(self.items) < before

    def forget_source(self, url: str) -> None:

        """
        A source was removed from the library: its notes stay, unlinked.
        """

        for note in self.items:
            if note.get("url") == url:
                note["url"], note["page"] = "", None
        self._save()

    def rename_project(self, old: str, new: Optional[str]) -> None:

        for note in self.items:
            if note.get("project") == old:
                note["project"] = new or ""
        self._save()

    def noted(self, url: str, page: Optional[int], project: Optional[str] = None) -> Optional[bool]:

        """
        Whether there's a note on this source (and page, give or take one, as results run across
        pages). None when the project has no linked notes at all: someone who doesn't use notes
        isn't nudged about them.
        """

        linked = [n for n in self.items if n.get("url") and (project is None or (n.get("project") or "") == project)]
        if not linked:
            return None
        for note in linked:
            if note.get("url") != url or (project is not None and (note.get("project") or "") != project):
                continue
            if page is None or note.get("page") is None or abs(note["page"] - page) <= 1:
                return True
        return False
