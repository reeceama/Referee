"""Notion, for meeting action points: tasks in a Notion database, ticked off in both.

The person makes an internal integration (notion.so/profile/integrations), shares a task
database with it, and gives Referee the token and the database's link. The token is kept in the
system's password store; the database ID in config.json ("notion_database").

Referee finds the database's columns itself: its title column for the task, its first checkbox
for done, its first date column for the due date, and a "Project" column (select or text) if
there is one. A page moved to the bin counts as deleted.
"""

import json
import re
from datetime import datetime
from pathlib import Path
from typing import Dict, Optional

import keyring
import requests

API = "https://api.notion.com/v1"
VERSION = "2022-06-28"
SERVICE, ACCOUNT = "Referee", "notion-token"
CONFIG = Path.home() / ".referee" / "config.json"
TIMEOUT = 15


def token() -> Optional[str]:

    try:
        return keyring.get_password(SERVICE, ACCOUNT)
    except keyring.errors.KeyringError:
        return None


def database() -> Optional[str]:

    try:
        return json.loads(CONFIG.read_text(encoding="utf-8")).get("notion_database")
    except (OSError, ValueError):
        return None


def _call(method: str, path: str, key: str, **kwargs) -> requests.Response:

    return requests.request(method, f"{API}/{path}", timeout=TIMEOUT, headers={
        "Authorization": f"Bearer {key}", "Notion-Version": VERSION}, **kwargs)


def database_id(link: str) -> Optional[str]:

    """
    The 32-character ID from a database's link or its ID as pasted.
    """

    found = re.findall(r"[0-9a-f]{32}", link.replace("-", "").lower())
    return found[-1] if found else None


def connect(secret: str, link: str) -> Dict:

    """
    Checks the token and that the database is shared with it, then stores both.
    """

    secret, found = secret.strip(), database_id(link)
    if not found:
        return {"ok": False, "reason": "That doesn't look like a Notion database link."}
    try:
        response = _call("GET", f"databases/{found}", secret)
    except requests.RequestException:
        return {"ok": False, "reason": "Couldn't reach Notion. Check your connection."}
    if response.status_code == 401:
        return {"ok": False, "reason": "Notion didn't accept this token."}
    if response.status_code in (403, 404):
        return {"ok": False, "reason": "Notion couldn't find that database. Share it with your integration (••• → Connections), then try again."}
    if not response.ok:
        return {"ok": False, "reason": f"Notion answered {response.status_code}."}
    columns = _columns(response.json())
    if not columns.get("done"):
        return {"ok": False, "reason": "The database needs a checkbox column for done."}
    keyring.set_password(SERVICE, ACCOUNT, secret)
    config = json.loads(CONFIG.read_text(encoding="utf-8")) if CONFIG.exists() else {}
    config["notion_database"] = found
    CONFIG.write_text(json.dumps(config, indent=2), encoding="utf-8")
    return {"ok": True, "name": "".join(t.get("plain_text", "") for t in response.json().get("title", []))}


def disconnect() -> None:

    try:
        keyring.delete_password(SERVICE, ACCOUNT)
    except keyring.errors.KeyringError:
        pass
    if CONFIG.exists():
        config = json.loads(CONFIG.read_text(encoding="utf-8"))
        config.pop("notion_database", None)
        CONFIG.write_text(json.dumps(config, indent=2), encoding="utf-8")


def _columns(schema: Dict) -> Dict[str, Optional[tuple]]:

    """
    The database's columns Referee uses: {"title", "done", "due", "project"} -> (name, type).
    """

    found: Dict[str, Optional[tuple]] = {"title": None, "done": None, "due": None, "project": None}
    for name, prop in schema.get("properties", {}).items():
        kind = prop.get("type")
        if kind == "title":
            found["title"] = (name, kind)
        elif kind == "checkbox" and not found["done"]:
            found["done"] = (name, kind)
        elif kind == "date" and not found["due"]:
            found["due"] = (name, kind)
        elif name.lower() == "project" and kind in ("select", "rich_text"):
            found["project"] = (name, kind)
    return found


def status() -> Dict:

    return {"connected": bool(token() and database())}


class Tasks:

    """
    The tasks.py interface: create, state, complete, update.
    """

    def __init__(self):
        self.columns: Optional[Dict] = None

    def _ready(self) -> tuple:
        key, db = token(), database()
        if not (key and db):
            raise RuntimeError("Notion isn't connected.")
        if self.columns is None:
            response = _call("GET", f"databases/{db}", key)
            response.raise_for_status()
            self.columns = _columns(response.json())
        return key, db

    def _properties(self, text: str, due: Optional[datetime], project: str = "") -> Dict:
        c = self.columns
        props = {c["title"][0]: {"title": [{"text": {"content": text}}]}}
        if c["due"] and due:
            props[c["due"][0]] = {"date": {"start": due.strftime("%Y-%m-%d")}}
        if c["project"] and project:
            props[c["project"][0]] = ({"select": {"name": project}} if c["project"][1] == "select"
                                      else {"rich_text": [{"text": {"content": project}}]})
        return props

    def create(self, text: str, notes: str, due: Optional[datetime], project: str) -> str:
        key, db = self._ready()
        body = {"parent": {"database_id": db}, "properties": self._properties(text, due, project),
                "children": [{"object": "block", "type": "paragraph",
                              "paragraph": {"rich_text": [{"text": {"content": notes}}]}}]}
        response = _call("POST", "pages", key, json=body)
        response.raise_for_status()
        return response.json()["id"]

    def state(self, task_id: str) -> Optional[bool]:
        key, _ = self._ready()
        response = _call("GET", f"pages/{task_id}", key)
        if response.status_code == 404:
            return None
        response.raise_for_status()
        page = response.json()
        if page.get("archived") or page.get("in_trash"):
            return None
        return bool(page["properties"].get(self.columns["done"][0], {}).get("checkbox"))

    def complete(self, task_id: str) -> None:
        key, _ = self._ready()
        _call("PATCH", f"pages/{task_id}", key, json={"properties": {self.columns["done"][0]: {"checkbox": True}}}).raise_for_status()

    def update(self, task_id: str, text: str, due: Optional[datetime]) -> None:
        key, _ = self._ready()
        _call("PATCH", f"pages/{task_id}", key, json={"properties": self._properties(text, due)}).raise_for_status()
