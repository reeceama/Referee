"""Projects and how long unsaved reading is kept, saved in reading.json.

Reading captured during a Focus or while writing is temporary: it can be checked against
straight away, and is forgotten after keep_minutes unless it is saved for later or cited.
The current project applies everywhere: captures, and checks in Word.
"""

import json
from pathlib import Path
from typing import Dict, List

KEEP_MINUTES = 15


class ReadingSettings:

    def __init__(self, path: Path):

        self.path = path
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            data = {}
        self.project: str = data.get("project", "")
        self.projects: List[str] = data.get("projects", [])
        self.keep_minutes: int = data.get("keep_minutes", KEEP_MINUTES)
        # project -> other projects whose references it may also use
        self.links: Dict[str, List[str]] = data.get("links", {})
        # Archived projects: out of every menu, with everything in them kept.
        self.archived: List[str] = data.get("archived", [])

    def as_dict(self) -> Dict:

        return {"project": self.project, "projects": self.projects, "keep_minutes": self.keep_minutes, "links": self.links,
                "archived": self.archived}

    def archive(self, name: str, archived: bool) -> Dict:

        """
        Takes a project out of the menus (or puts it back). Nothing in it is changed or removed.
        """

        if archived and name in self.projects:
            self.projects = [p for p in self.projects if p != name]
            self.archived = list(dict.fromkeys(self.archived + [name]))
            if self.project == name:
                self.project = ""
        elif not archived and name in self.archived:
            self.archived = [p for p in self.archived if p != name]
            self.projects = list(dict.fromkeys(self.projects + [name]))
        self.path.write_text(json.dumps(self.as_dict()), encoding="utf-8")
        return self.as_dict()

    def rename(self, old: str, new: str) -> Dict:

        """
        Renames a project everywhere it's named; an empty new name deletes it.
        """

        self.projects = [new if p == old else p for p in self.projects if new or p != old]
        self.projects = list(dict.fromkeys(p for p in self.projects if p))
        self.archived = [new if p == old else p for p in self.archived if new or p != old]
        if self.project == old:
            self.project = new
        links = {}
        for project, others in self.links.items():
            name = new if project == old else project
            if name:
                links[name] = [new if o == old else o for o in others if new or o != old]
        self.links = links
        self.path.write_text(json.dumps(self.as_dict()), encoding="utf-8")
        return self.as_dict()

    def allowed(self, project: str):

        """
        The projects whose sources a piece of writing in this project may cite: its own,
        plus any it has been linked to. With no project, every source.
        """

        if not project:
            return None
        return {project, *self.links.get(project, [])}

    def update(self, changes: Dict) -> Dict:

        if "project" in changes:
            self.project = (changes["project"] or "").strip()
            if self.project and self.project not in self.projects:
                self.projects.append(self.project)
            self.archived = [p for p in self.archived if p != self.project]   # choosing one brings it back
        if "projects" in changes:
            self.projects = [p for p in changes["projects"] if p]
        if "links" in changes:
            self.links = {p: [o for o in others if o != p] for p, others in changes["links"].items()}
        if changes.get("keep_minutes"):
            self.keep_minutes = int(changes["keep_minutes"])
        self.path.write_text(json.dumps(self.as_dict()), encoding="utf-8")
        return self.as_dict()
