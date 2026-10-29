"""Reading notes, by project, each linked to the pages of the saved sources it's about.

A note has a title ("4.3 Span"), a body in Markdown with $LaTeX$ maths (paragraphs, lists,
headings: whatever suits it), its sources (saved sources,
each at a page or range of pages, in "attachments") and files: photos or documents of your own,
kept in Referee's data folder under note-files/<note id>/. "url", "page" and "to" mirror the first attachment, so
code that knows one source per note keeps working; "text" holds the title.

Not a notes app: a note is a line of your own ("Def 4.35, basis") plus, optionally, the saved
source and page it refers to, so the app can open the source right there. Referee also uses them:
a theorem you cite from a page you haven't noted is pointed out, as a nudge to check you've
read what you cite.
"""

import json
import re
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
        if any("title" not in n for n in self.items):
            # Notes from before titles: kept as they were, beside the converted copy.
            try:
                path.with_name(path.stem + ".before-titles.json").write_text(path.read_text(encoding="utf-8"), encoding="utf-8")
            except OSError:
                pass
            self.items = [convert(n) if "title" not in n else n for n in self.items]
            self._save()
        if any("body" not in n for n in self.items):
            # Notes from before Markdown bodies: their description and lines become the body.
            try:
                path.with_name(path.stem + ".before-bodies.json").write_text(path.read_text(encoding="utf-8"), encoding="utf-8")
            except OSError:
                pass
            for n in self.items:
                if "body" not in n:
                    n["body"] = body_of(n)
            self._save()

    def _save(self) -> None:

        self.path.write_text(json.dumps(self.items, indent=1), encoding="utf-8")

    def all(self, project: Optional[str] = None) -> List[Dict]:

        """
        In the order they were written. project: None for every note, "" for notes in no project.
        """

        found = [n for n in self.items if project is None or (n.get("project") or "") == project]
        return sorted(found, key=lambda n: n.get("created") or 0)

    def save(self, note: Dict) -> Dict:

        def number(value):
            try:
                value = int(value) if value not in (None, "") else None
            except (TypeError, ValueError):
                return None
            return value if value and value > 0 else None

        if "title" not in note:
            note = convert(note)    # an older app, or the iPhone, sending a one-line note
        attachments = []
        for a in note.get("attachments") or []:
            page, to = number(a.get("page")), number(a.get("to"))
            if a.get("url"):
                attachments.append({"url": a["url"], "page": page, "to": to if page and to and to > page else None})
        first = attachments[0] if attachments else {"url": "", "page": None, "to": None}
        title = (note.get("title") or "").strip()
        clean = {
            "id": note.get("id") or uuid.uuid4().hex,
            "project": note.get("project") or "",
            "title": title,
            # The note itself, in Markdown with $LaTeX$ maths: paragraphs, lists, headings, anything.
            "body": body_of(note),
            "attachments": attachments,
            # Photos and files added to the note, kept in Referee's note-files folder, by name.
            "files": [f for f in note.get("files") or [] if isinstance(f, str) and "/" not in f and f.strip()],
            "text": title,
            "url": first["url"],
            "page": first["page"],
            "to": first["to"],
            "created": note.get("created") or time.time(),
            # A folder of the person's own ("Viva prep"), for Notes → Group → By folder.
            "folder": (note.get("folder") or "").strip(),
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
            note["attachments"] = [a for a in note.get("attachments", []) if a.get("url") != url]
            first = (note["attachments"] or [{"url": "", "page": None, "to": None}])[0]
            note["url"], note["page"], note["to"] = first["url"], first["page"], first["to"]
        self._save()

    def rename_project(self, old: str, new: Optional[str]) -> None:

        for note in self.items:
            if note.get("project") == old:
                note["project"] = new or ""
        self._save()

    def noted(self, url: str, page: Optional[int], project: Optional[str] = None) -> Optional[bool]:

        """
        Whether there's a note on this source covering this page (its page or range, give or take
        one, as results run across pages). None when the project has no linked notes at all: someone who doesn't use notes
        isn't nudged about them.
        """

        linked = [n for n in self.items if n.get("attachments") and (project is None or (n.get("project") or "") == project)]
        if not linked:
            return None
        for note in linked:
            for a in note["attachments"]:
                if a.get("url") != url:
                    continue
                first = a.get("page")
                if page is None or first is None or first - 1 <= page <= (a.get("to") or first) + 1:
                    return True
        return False


ITEM = re.compile(r"^(Def(?:inition)?s?|Thm|Theorem|Lem(?:ma)?|Prop(?:osition)?|Cor(?:ollary)?|Ex(?:ample)?|Rem(?:ark)?)\.?\s+([\d.,\s()a-z–-]*\d[)\da-z]*)\s*(.*)$", re.I)


def convert(note: Dict) -> Dict:

    """
    A one-line note from before titles, as a titled one. "MTH5112 4.3 Span (pp. 49–53): Def 4.17
    linear combination and span, Thm 4.20" becomes the title "MTH5112 4.3 Span", the lines
    "Def 4.17: linear combination and span" and "Thm 4.20", and its page as an attachment.
    """

    text = (note.get("text") or "").strip()
    head, _, rest = text.partition(":") if re.search(r"\)\s*:", text) or ":" in text[:80] else (text, "", "")
    title = re.sub(r"\s*\((?:pp?\.)[^)]*\)\s*$", "", head).strip() or "Note"
    items = []
    for part in [p.strip() for p in rest.split(",") if p.strip()]:
        m = ITEM.match(part)
        items.append(f"{m.group(1)} {m.group(2).strip()}: {m.group(3).strip()}".rstrip(": ") if m and m.group(3) else part)
    attachments = [{"url": note["url"], "page": note.get("page"), "to": note.get("to")}] if note.get("url") else []
    return {**note, "title": title, "description": "", "items": items, "attachments": attachments}


def body_of(note: Dict) -> str:

    """
    A note's Markdown body. Notes from before bodies had a description and a list of lines:
    the description becomes the first paragraph and the lines become bullets.
    """

    if note.get("body") is not None:
        return note["body"].rstrip()
    parts = []
    if (note.get("description") or "").strip():
        parts.append(note["description"].strip())
    lines = [i.strip() for i in note.get("items") or [] if i and i.strip()]
    if lines:
        parts.append("\n".join(f"- {line}" for line in lines))
    return "\n\n".join(parts)
