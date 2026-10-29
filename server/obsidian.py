"""Referee's notes and meetings in an Obsidian vault, as Markdown, kept up to date.

The person chooses a folder inside their vault (Settings → Integrations, "obsidian_folder" in
config.json). Referee writes, once a minute when something has changed:

    Reading/<source>.md     the reading notes on one source, in page order, each with a link
                            that opens the source at its page (referee://source?...)
    Meetings/<date> <title>.md   one meeting: attendees, notes, decisions and tasks
                            as Obsidian tasks

Front matter (project, source, date) lets Dataview and Obsidian's properties use them. These
files are Referee's: edits made to them in Obsidian are overwritten, so a note to keep goes in
a file of your own. Files for notes or meetings deleted in Referee are removed, and only files
Referee wrote (marked "referee: true") are ever touched.
"""

import json
import re
import threading
import time
from pathlib import Path
from typing import Callable, Dict, List, Optional
from urllib.parse import quote

CONFIG = Path.home() / ".referee" / "config.json"
EVERY = 60  # seconds


def folder() -> Optional[Path]:

    try:
        chosen = json.loads(CONFIG.read_text(encoding="utf-8")).get("obsidian_folder")
    except (OSError, ValueError):
        return None
    return Path(chosen) if chosen and Path(chosen).is_dir() else None


def _safe(name: str) -> str:

    # Characters Obsidian (and Windows) won't have in a file name.
    return re.sub(r'[\\/:*?"<>|#^\[\]]', "-", name).strip(" .")[:120] or "Untitled"


def _link(url: str, page: Optional[int]) -> str:

    return f"referee://source?url={quote(url, safe='')}" + (f"&page={page}" if page else "")


def reading_files(notes: List[Dict], title: Callable[[str], str]) -> Dict[str, str]:

    """
    One file per source, its notes in page order: each note's title, its Markdown body as it
    is, and a link that opens the source at its pages.
    """

    by_source: Dict[str, List[tuple]] = {}
    for note in notes:
        for a in note.get("attachments") or []:
            if (note.get("title") or "").strip():
                by_source.setdefault(a["url"], []).append((note, a))
    files = {}
    for url, group in by_source.items():
        name = title(url)
        group.sort(key=lambda pair: (pair[1].get("page") or 0, pair[0].get("created") or 0))
        lines = ["---", "referee: true", f"source: {json.dumps(name)}", f"url: {json.dumps(url)}",
                 f"project: {json.dumps(group[0][0].get('project') or '')}", "---", "", f"# {name}", ""]
        for note, a in group:
            pages = ((f"pp. {a['page']}–{a['to']}" if a.get("to") else f"p. {a['page']}") if a.get("page") else "source")
            lines += [f"## {note['title'].strip()}", ""]
            if (note.get("body") or "").strip():
                lines += [note["body"].strip(), ""]
            lines += [f"[{pages}]({_link(url, a.get('page'))})", ""]
        files[f"Reading/{_safe(name)}.md"] = "\n".join(lines) + "\n"
    return files


def meeting_files(meetings: List[Dict]) -> Dict[str, str]:

    files = {}
    for m in meetings:
        blank = not any((m.get(k) or "").strip() for k in ("title", "attendees", "notes", "decisions"))
        if blank and not any((a.get("text") or "").strip() for a in m.get("actions", [])):
            continue  # an empty draft
        title = (m.get("title") or "").strip() or "Meeting"
        lines = ["---", "referee: true", f"date: {m.get('date')}", f"project: {json.dumps(m.get('project') or '')}",
                 f"attendees: {json.dumps(m.get('attendees') or '')}", "---", "", f"# {title}", ""]
        for heading, key in (("Notes", "notes"), ("Decisions", "decisions")):
            if (m.get(key) or "").strip():
                lines += [f"## {heading}", "", m[key].strip(), ""]
        actions = [a for a in m.get("actions", []) if (a.get("text") or "").strip()]
        if actions:
            lines += ["## Tasks", ""]
            for a in actions:
                extra = ", ".join(x for x in (a.get("who"), f"by {a['due']}" if a.get("due") else "") if x)
                lines.append(f"- [{'x' if a.get('done') else ' '}] {a['text'].strip()}" + (f" ({extra})" if extra else ""))
            lines.append("")
        lines.append(f"[Open in Referee](referee://meeting/{m['id']})")
        files[f"Meetings/{m.get('date')} {_safe(title)}.md"] = "\n".join(lines) + "\n"
    return files


class Export:

    def __init__(self, notes, meetings, title: Callable[[str], str]):

        self.notes, self.meetings, self.title = notes, meetings, title
        self.last = ""

    def start(self) -> None:

        threading.Thread(target=self._loop, daemon=True).start()

    def _loop(self) -> None:

        while True:
            try:
                self.run()
            except OSError as error:
                print(f"Obsidian: {error}")
            time.sleep(EVERY)

    def run(self) -> None:

        root = folder()
        if root is None:
            return
        files = {**reading_files(self.notes.items, self.title), **meeting_files(self.meetings.items)}
        snapshot = json.dumps(files, sort_keys=True)
        if snapshot == self.last:
            return
        for relative, text in files.items():
            path = root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            if not path.exists() or path.read_text(encoding="utf-8") != text:
                path.write_text(text, encoding="utf-8")
        # Remove files for notes and meetings deleted in Referee: only Referee's own files.
        for sub in ("Reading", "Meetings"):
            for path in (root / sub).glob("*.md") if (root / sub).is_dir() else []:
                relative = f"{sub}/{path.name}"
                if relative not in files and path.read_text(encoding="utf-8").startswith("---\nreferee: true\n"):
                    path.unlink()
        self.last = snapshot
