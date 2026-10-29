"""Meeting notes: supervisor meetings and group project meetings, kept by project.

Each meeting has a date, title, attendees, notes, decisions and tasks (what, who, by
when, done). Tasks not yet done are carried into the next meeting, and a project's log
exports as Markdown (to paste into Teams or a shared document) or LaTeX (for Overleaf), so a
group can share it.

A project can be linked to its group's shared folder (a GitHub repository or shared drive). Its
Markdown files then open in Referee to read and edit, and are saved back exactly as you wrote
them: Referee never writes to them by itself or assumes how they're laid out. A save is refused
if the file changed since it was opened (a teammate's edit), so nobody's work is overwritten.
"""

import json
import re
import time
import uuid
from datetime import date
from pathlib import Path
from typing import Dict, List, Optional


class Meetings:

    def __init__(self, path: Path):

        self.path = path
        self.workspaces_path = path.with_name(path.stem + "-workspaces.json")
        try:
            self.items: List[Dict] = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            self.items = []
        try:
            self.workspaces: Dict[str, str] = json.loads(self.workspaces_path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            self.workspaces = {}

    def _save(self, projects: Optional[set] = None) -> None:

        self.path.write_text(json.dumps(self.items, indent=1), encoding="utf-8")

    def set_workspace(self, project: str, folder: str) -> Dict:

        """
        Links a project to its group's shared folder ("" to unlink).
        """

        if folder:
            self.workspaces[project] = folder
        else:
            self.workspaces.pop(project, None)
        self.workspaces_path.write_text(json.dumps(self.workspaces, indent=1), encoding="utf-8")
        return {"folder": folder}

    def _inside(self, project: str, relative: str) -> Optional[Path]:

        folder = self.workspaces.get(project)
        if not folder or not relative:
            return None
        root = Path(folder).resolve()
        target = (root / relative).resolve()
        return target if root in target.parents and target.suffix.lower() in (".md", ".markdown", ".txt") else None

    def shared_files(self, project: str) -> List[Dict]:

        """
        The Markdown files in the project's shared folder (and one level down, such as notes/),
        newest first.
        """

        folder = self.workspaces.get(project)
        if not folder or not Path(folder).is_dir():
            return []
        root = Path(folder)
        found = [p for pattern in ("*.md", "*/*.md", "*.markdown", "*/*.markdown")
                 for p in root.glob(pattern) if not any(part.startswith(".") for part in p.relative_to(root).parts)]
        return sorted(({"path": str(p.relative_to(root)), "modified": p.stat().st_mtime} for p in found),
                      key=lambda f: f["modified"], reverse=True)[:100]

    def read_shared(self, project: str, relative: str) -> Dict:

        target = self._inside(project, relative)
        if target is None or not target.is_file():
            return {"ok": False, "reason": "That file isn't in the shared folder."}
        return {"ok": True, "text": target.read_text(encoding="utf-8", errors="replace"), "modified": target.stat().st_mtime}

    def write_shared(self, project: str, relative: str, text: str, opened: float) -> Dict:

        """
        Saves a file exactly as written, unless it changed since it was opened: then the current
        version comes back instead, so a teammate's edit isn't overwritten.
        """

        target = self._inside(project, relative)
        if target is None:
            return {"ok": False, "reason": "That file isn't in the shared folder."}
        if target.exists() and abs(target.stat().st_mtime - opened) > 0.001:
            return {"ok": False, "conflict": True, "text": target.read_text(encoding="utf-8", errors="replace"),
                    "modified": target.stat().st_mtime}
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text, encoding="utf-8")
        return {"ok": True, "modified": target.stat().st_mtime}

    def my_actions(self, project: str) -> str:

        """
        Your own tasks in this project, as Markdown, for you to place in a shared file.
        """

        return _my_actions(your_name() or "me", list(reversed(self.all(project))))

    def all(self, project: Optional[str] = None) -> List[Dict]:

        """
        Newest first. project: None for every meeting, "" for meetings in no project.
        """

        found = [m for m in self.items if project is None or (m.get("project") or "") == project]
        return sorted(found, key=lambda m: (m.get("date") or "", m.get("created") or 0), reverse=True)

    def save(self, meeting: Dict) -> Dict:

        """
        Adds a meeting, or replaces the one with the same id.
        """

        clean = {
            "id": meeting.get("id") or uuid.uuid4().hex,
            "project": meeting.get("project") or "",
            "date": meeting.get("date") or date.today().isoformat(),
            "title": (meeting.get("title") or "").strip(),
            "attendees": (meeting.get("attendees") or "").strip(),
            "notes": meeting.get("notes") or "",
            "decisions": meeting.get("decisions") or "",
            # Photos and files to look at (a whiteboard, slides), kept in meeting-files/<id>/, by name.
            "files": [f for f in meeting.get("files") or [] if isinstance(f, str) and "/" not in f and f.strip()],
            "actions": [{"id": a.get("id") or uuid.uuid4().hex, "text": (a.get("text") or "").strip(),
                         "who": (a.get("who") or "").strip(), "due": (a.get("due") or "").strip(), "done": bool(a.get("done")),
                         "notes": a.get("notes") or "",
                         "send_files": [f for f in a.get("send_files") or [] if isinstance(f, str) and "/" not in f],
                         **self._todoist(meeting.get("id"), a)}
                        for a in meeting.get("actions") or []],
            "created": meeting.get("created") or time.time(),
        }
        old = next((m.get("project") or "" for m in self.items if m["id"] == clean["id"]), clean["project"])
        self.items = [m for m in self.items if m["id"] != clean["id"]] + [clean]
        self._save({clean["project"], old})
        return clean

    def _todoist(self, meeting_id: Optional[str], action: Dict) -> Dict:

        """
        An task's link to its task in the to-do app. The app doesn't send these back, so they're
        kept from the saved copy of the same task.
        """

        saved = next((a for m in self.items if m["id"] == meeting_id for a in m.get("actions", []) if a.get("id") == action.get("id")), {})
        keys = ("todoist_id", "todoist_sent", "todoist_gone", "task_app", "task_id", "task_sent", "task_gone", "files_sent")
        return {k: action.get(k, saved.get(k)) for k in keys if action.get(k, saved.get(k)) is not None}

    def delete(self, meeting_id: str) -> bool:

        before = len(self.items)
        project = next((m.get("project") or "" for m in self.items if m["id"] == meeting_id), "")
        self.items = [m for m in self.items if m["id"] != meeting_id]
        self._save({project})
        return len(self.items) < before

    def rename_project(self, old: str, new: Optional[str]) -> None:

        for meeting in self.items:
            if meeting.get("project") == old:
                meeting["project"] = new or ""
        if old in self.workspaces:
            folder = self.workspaces.pop(old)
            if new:
                self.workspaces[new] = folder
            self.workspaces_path.write_text(json.dumps(self.workspaces, indent=1), encoding="utf-8")
        self._save()

    def export(self, project: Optional[str], format: str = "markdown") -> str:

        """
        The project's meetings, oldest first, as Markdown or LaTeX.
        """

        meetings = list(reversed(self.all(project)))
        name = project if project else "All meetings" if project is None else "Meetings"
        return _latex(name, meetings) if format == "latex" else _markdown(name, meetings)


def _when(day: str) -> str:

    try:
        return date.fromisoformat(day).strftime("%-d %B %Y")
    except ValueError:
        return day


def _markdown(name: str, meetings: List[Dict]) -> str:

    lines = [f"# Meeting log: {name}", ""]
    for m in meetings:
        lines += [f"## {_when(m['date'])}" + (f": {m['title']}" if m["title"] else ""), ""]
        if m["attendees"]:
            lines += [f"**Attendees:** {m['attendees']}", ""]
        if m["notes"].strip():
            lines += ["**Notes**", "", m["notes"].strip(), ""]
        if m["decisions"].strip():
            lines += ["**Decisions**", "", m["decisions"].strip(), ""]
        if m["actions"]:
            lines += ["**Tasks**", ""]
            for a in m["actions"]:
                extra = ", ".join(v for v in [a["who"], f"by {a['due']}" if a["due"] else ""] if v)
                lines.append(f"- [{'x' if a['done'] else ' '}] {a['text']}" + (f" ({extra})" if extra else ""))
            lines.append("")
    return "\n".join(lines).rstrip() + "\n"


def _tex(text: str) -> str:

    replacements = {"\\": r"\textbackslash{}", "&": r"\&", "%": r"\%", "$": r"\$", "#": r"\#", "_": r"\_",
                    "{": r"\{", "}": r"\}", "~": r"\textasciitilde{}", "^": r"\textasciicircum{}"}
    return re.sub(r"[\\&%$#_{}~^]", lambda m: replacements[m.group()], text)


def _latex(name: str, meetings: List[Dict]) -> str:

    out = ["% Needs \\usepackage{amssymb} for the tick boxes.", r"\section*{Meeting log: " + _tex(name) + "}", ""]
    for m in meetings:
        out.append(r"\subsection*{" + _tex(_when(m["date"]) + (f": {m['title']}" if m["title"] else "")) + "}")
        if m["attendees"]:
            out.append(r"\textbf{Attendees:} " + _tex(m["attendees"]) + "\n")
        for heading, body in (("Notes", m["notes"]), ("Decisions", m["decisions"])):
            if body.strip():
                out.append(r"\paragraph{" + heading + "}\n" + _tex(body.strip()).replace("\n", "\n\n") + "\n")
        if m["actions"]:
            out.append(r"\paragraph{Tasks}" + "\n" + r"\begin{itemize}")
            for a in m["actions"]:
                extra = ", ".join(v for v in [a["who"], f"by {a['due']}" if a["due"] else ""] if v)
                mark = r"[$\boxtimes$]" if a["done"] else r"[$\square$]"
                out.append(rf"  \item{mark} " + _tex(a["text"]) + (f" ({_tex(extra)})" if extra else ""))
            out.append(r"\end{itemize}" + "\n")
    return "\n".join(out).rstrip() + "\n"


def your_name() -> str:

    try:
        return (json.loads((Path.home() / ".referee" / "config.json").read_text(encoding="utf-8")).get("your_name") or "").strip()
    except (OSError, ValueError):
        return ""


def _my_actions(me: str, meetings: List[Dict]) -> str:

    """
    Your own tasks, done and still to do, with the meeting each came from.
    """

    from todoist import is_mine
    lines = []
    for m in meetings:
        for a in m["actions"]:
            if a["text"] and is_mine(a.get("who", ""), me):
                due = f", due {a['due']}" if a["due"] else ""
                lines.append(f"- [{'x' if a['done'] else ' '}] {a['text']} (from {_when(m['date'])}{due})")
    return "\n".join(lines) or "No tasks yet."
