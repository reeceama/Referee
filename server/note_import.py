"""Brings notes in from elsewhere: a folder of Markdown files (an Obsidian vault, Bear or iA Writer
export, anything), or Apple Notes (the app reads those, since macOS asks its permission, and sends
their HTML here). Each becomes a Referee note in the chosen project: the title from the first
heading or the file name, the body as Markdown, images as the note's files. A note already in the
project with the same title and body is skipped, so importing twice doesn't double anything up.
"""

import base64
import re
import shutil
import uuid
from html import unescape
from html.parser import HTMLParser
from pathlib import Path
from typing import Dict, List, Tuple

IMAGES = {".png", ".jpg", ".jpeg", ".gif", ".heic", ".webp", ".pdf"}
SKIP = {".obsidian", ".trash", ".git", "node_modules"}


class Importer:

    def __init__(self, notes, files: Path):

        self.notes = notes          # the Notes store
        self.files = files          # note-files/, one folder per note

    def _exists(self, project: str, title: str, body: str) -> bool:

        return any((n.get("project") or "") == project and n.get("title") == title and n.get("body") == body
                   for n in self.notes.items)

    def _add(self, project: str, title: str, body: str, files: List[Tuple[str, bytes]]) -> bool:

        body = re.sub(r"\n{3,}", "\n\n", body).strip()
        if not title and not body:
            return False
        if self._exists(project, title, body):
            return False
        note_id = uuid.uuid4().hex
        names = []
        if files:
            folder = self.files / note_id
            folder.mkdir(parents=True, exist_ok=True)
            for name, data in files:
                name = Path(name).name or "image"
                while name in names:
                    name = "copy-" + name
                (folder / name).write_bytes(data)
                names.append(name)
        self.notes.save({"id": note_id, "project": project, "title": title, "body": body, "files": names})
        return True

    def markdown_folder(self, folder: str, project: str) -> Dict:

        root = Path(folder).expanduser()
        if not root.is_dir():
            return {"ok": False, "reason": "That folder isn't there."}
        added = skipped = 0
        for path in sorted(root.rglob("*.md")):
            if any(part in SKIP for part in path.relative_to(root).parts):
                continue
            try:
                text = path.read_text(encoding="utf-8")
            except (OSError, UnicodeDecodeError):
                skipped += 1
                continue
            text = re.sub(r"\A---\n.*?\n---\n", "", text, flags=re.S)       # front matter
            title, body = path.stem, text.strip()
            heading = re.match(r"#\s+(.+)\n?", body)
            if heading:
                title, body = heading.group(1).strip(), body[heading.end():]
            files = []

            def image(match):
                target = (match.group(1) or match.group(2) or "").split("|")[0].strip()
                found = next((p for p in [path.parent / target, root / target] if p.is_file()), None)
                if found is None:
                    found = next(root.rglob(Path(target).name), None) if target else None
                if found is not None and found.suffix.lower() in IMAGES:
                    files.append((found.name, found.read_bytes()))
                    return ""
                return match.group(0)

            body = re.sub(r"!\[\[([^\]]+)\]\]|!\[[^\]]*\]\(([^)\s]+)\)", image, body)
            body = re.sub(r"\[\[([^\]|]+)\|([^\]]+)\]\]", r"\2", body)     # [[link|shown]] -> shown
            body = re.sub(r"\[\[([^\]]+)\]\]", r"\1", body)                # [[link]] -> link
            if self._add(project, title, body, files):
                added += 1
            else:
                skipped += 1
        return {"ok": True, "added": added, "skipped": skipped}

    def apple_notes(self, items: List[Dict], project: str) -> Dict:

        added = skipped = 0
        for item in items:
            body, files = to_markdown(item.get("html") or "")
            title = (item.get("title") or "").strip()
            lines = body.split("\n", 1)
            if lines and lines[0].lstrip("# *").strip() == title:     # Notes repeats the title as the first line
                body = lines[1] if len(lines) > 1 else ""
            if self._add(project, title, body, files):
                added += 1
            else:
                skipped += 1
        return {"ok": True, "added": added, "skipped": skipped}


class _ToMarkdown(HTMLParser):

    def __init__(self):

        super().__init__(convert_charrefs=True)
        self.out: List[str] = []
        self.files: List[Tuple[str, bytes]] = []
        self.lists: List[str] = []
        self.link = None

    def handle_starttag(self, tag, attrs):

        attrs = dict(attrs)
        if tag in ("h1", "h2", "h3"):
            self.out.append("\n\n" + "#" * int(tag[1]) + " ")
        elif tag in ("b", "strong"):
            self.out.append("**")
        elif tag in ("i", "em"):
            self.out.append("*")
        elif tag in ("ul", "ol"):
            self.lists.append(tag)
        elif tag == "li":
            self.out.append("\n" + "  " * (len(self.lists) - 1) + ("1. " if self.lists and self.lists[-1] == "ol" else "- "))
        elif tag == "br":
            self.out.append("\n")
        elif tag in ("div", "p"):
            self.out.append("\n")
        elif tag == "a":
            self.link = attrs.get("href")
            self.out.append("[")
        elif tag == "img":
            m = re.match(r"data:image/(\w+);base64,(.+)", attrs.get("src") or "", re.S)
            if m:
                self.files.append((f"image-{len(self.files) + 1}.{m.group(1).replace('jpeg', 'jpg')}",
                                   base64.b64decode(m.group(2))))

    def handle_endtag(self, tag):

        if tag in ("b", "strong"):
            self.out.append("**")
        elif tag in ("i", "em"):
            self.out.append("*")
        elif tag in ("ul", "ol") and self.lists:
            self.lists.pop()
            self.out.append("\n")
        elif tag in ("h1", "h2", "h3"):
            self.out.append("\n")
        elif tag == "a":
            self.out.append(f"]({self.link})" if self.link else "]")
            self.link = None

    def handle_data(self, data):

        self.out.append(data.replace("\xa0", " "))


def to_markdown(html: str) -> Tuple[str, List[Tuple[str, bytes]]]:

    parser = _ToMarkdown()
    parser.feed(html)
    text = unescape("".join(parser.out))
    text = re.sub(r"\*\*\s*\*\*|\*\*\*\*", "", text)
    text = re.sub(r"[ \t]+\n", "\n", text)
    return re.sub(r"\n{3,}", "\n\n", text).strip(), parser.files
