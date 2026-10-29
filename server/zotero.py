"""Papers from Zotero, added to Referee's library with their PDFs.

Uses the local API of Zotero 7 on this computer (Zotero → Settings → Advanced → "Allow other
applications on this computer to communicate with Zotero"), so no account or key is needed and
nothing goes online. The person picks one Zotero collection and the Referee project it feeds
("zotero_collection" and "zotero_project" in config.json). Every few minutes, items new to that
collection are added: the PDF Zotero has for the item if there is one (read from Zotero's own
storage, never copied), otherwise its DOI or link, which Referee fetches like Add Source. Zotero's
details (title, authors, year, journal) are used for the citation.

Items are only ever added, never removed: deleting an item in Zotero leaves it in Referee.
"""

import json
import threading
import time
from pathlib import Path
from typing import Callable, Dict, List, Optional
from urllib.parse import unquote, urlparse

import requests

API = "http://127.0.0.1:23119/api/users/0"
CONFIG = Path.home() / ".referee" / "config.json"
EVERY = 300  # seconds
TIMEOUT = 10


def _config() -> Dict:

    try:
        return json.loads(CONFIG.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}


def _get(path: str, **params):

    response = requests.get(f"{API}/{path}", params={"format": "json", **params}, timeout=TIMEOUT)
    response.raise_for_status()
    return response.json()


def collections() -> Optional[List[Dict]]:

    """
    Zotero's collections as [{"key", "name"}], or None if Zotero isn't running with its local
    API switched on.
    """

    try:
        found = _get("collections", limit=200)
    except (requests.RequestException, ValueError):
        return None
    return sorted(({"key": c["key"], "name": c["data"]["name"]} for c in found), key=lambda c: c["name"].lower())


def details(item: Dict) -> Dict:

    """
    The citation details Referee keeps, from a Zotero item.
    """

    data = item.get("data", {})
    authors = [" ".join(x for x in (c.get("firstName"), c.get("lastName")) if x) or c.get("name", "")
               for c in data.get("creators", []) if c.get("creatorType") in ("author", "editor")]
    return {k: v for k, v in {
        "title": data.get("title"),
        "author": "; ".join(a for a in authors if a),
        "date": data.get("date"),
        "site": data.get("publicationTitle") or data.get("bookTitle") or data.get("publisher"),
        "doi": data.get("DOI"),
    }.items() if v}


def pdf_path(item_key: str) -> Optional[str]:

    """
    The PDF Zotero keeps for an item, as a path on this computer, if it has one.
    """

    try:
        children = _get(f"items/{item_key}/children")
    except (requests.RequestException, ValueError):
        return None
    for child in children:
        data = child.get("data", {})
        if data.get("contentType") != "application/pdf":
            continue
        href = child.get("links", {}).get("enclosure", {}).get("href", "")
        if href.startswith("file://"):
            path = unquote(urlparse(href).path)
            if Path(path).is_file():
                return path
    return None


class Sync:

    def __init__(self, add_pdf: Callable[[str, str, Optional[str]], Dict],
                 add_link: Callable[[str, Optional[str]], Dict], set_details: Callable[[str, Dict], None],
                 state_path: Path):

        self.add_pdf, self.add_link, self.set_details = add_pdf, add_link, set_details
        self.state_path = state_path
        try:
            self.done: Dict[str, str] = json.loads(state_path.read_text(encoding="utf-8"))  # item key -> source URL
        except (OSError, ValueError):
            self.done = {}
        self.wake = threading.Event()
        self.last = {"at": None, "error": None, "added": 0}

    def start(self) -> None:

        threading.Thread(target=self._loop, daemon=True).start()

    def soon(self) -> None:

        self.wake.set()

    def _loop(self) -> None:

        while True:
            try:
                self.run()
            except (requests.RequestException, ValueError) as error:
                self.last["error"] = f"Couldn't reach Zotero ({type(error).__name__})."
            self.wake.wait(EVERY)
            self.wake.clear()

    def run(self) -> None:

        config = _config()
        collection = config.get("zotero_collection")
        if not collection:
            return
        project = config.get("zotero_project") or None
        items = _get(f"collections/{collection}/items/top", limit=100)
        added = 0
        for item in items:
            key = item.get("key")
            data = item.get("data", {})
            if not key or key in self.done or data.get("itemType") in ("note", "attachment"):
                continue
            found = details(item)
            path = pdf_path(key)
            if path:
                result = self.add_pdf(path, found.get("title") or Path(path).stem, project)
                url = f"file://{path}"
            else:
                link = f"https://doi.org/{found['doi']}" if found.get("doi") else data.get("url")
                if not link:
                    self.done[key] = ""  # nothing Referee can read: a book with no link, say
                    continue
                result = self.add_link(link, project)
                url = result.get("url") or link
            if result.get("ok"):
                self.set_details(url, found)
                self.done[key] = url
                added += 1
        self.state_path.write_text(json.dumps(self.done), encoding="utf-8")
        self.last = {"at": time.time(), "error": None, "added": self.last.get("added", 0) + added}

    def status(self) -> Dict:

        config = _config()
        return {"collections": collections(), "collection": config.get("zotero_collection"),
                "project": config.get("zotero_project"), "imported": len([u for u in self.done.values() if u]),
                **self.last}
