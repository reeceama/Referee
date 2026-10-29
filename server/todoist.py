"""Todoist's connection: its token, your name, and whose action points are yours. The syncing
itself, for Todoist and the other to-do apps, is in tasks.py.

Meeting action points in Todoist, both ways.

Your own action points (their "who" is your name, "me" or everyone) become tasks in a Todoist
project named after the Referee project, with their due dates. Ticking one off in either place
ticks it off in the other, so who-did-what stays accurate without doing anything twice. Other
people's action points stay out of your list.

The personal API token (Todoist: Settings → Integrations → Developer) is kept in the system's
password store, like the Anthropic key. Todoist's API v1; a task deleted in Todoist is left
alone in Referee and no longer synced.
"""

import json
import re
from pathlib import Path
from typing import Dict, List, Optional

import keyring
import requests
from datetime import datetime, timedelta

API = "https://api.todoist.com/api/v1"
SERVICE, ACCOUNT = "Referee", "todoist-token"
CONFIG = Path.home() / ".referee" / "config.json"
TIMEOUT = 15


def token() -> Optional[str]:

    try:
        return keyring.get_password(SERVICE, ACCOUNT)
    except keyring.errors.KeyringError:
        return None


def your_name() -> str:

    try:
        return (json.loads(CONFIG.read_text(encoding="utf-8")).get("your_name") or "").strip()
    except (OSError, ValueError):
        return ""


def _call(method: str, path: str, key: str, **kwargs) -> requests.Response:

    return requests.request(method, f"{API}/{path}", headers={"Authorization": f"Bearer {key}"}, timeout=TIMEOUT, **kwargs)


def connect(key: str) -> Dict:

    """
    Checks a token with Todoist, then stores it.
    """

    key = key.strip()
    try:
        response = _call("GET", "projects", key, params={"limit": 1})
    except requests.RequestException:
        return {"ok": False, "reason": "Couldn't reach Todoist. Check your connection."}
    if response.status_code in (401, 403):
        return {"ok": False, "reason": "Todoist didn't accept this token. Copy it from Todoist: Settings, Integrations, Developer."}
    if not response.ok:
        return {"ok": False, "reason": f"Todoist answered {response.status_code}."}
    keyring.set_password(SERVICE, ACCOUNT, key)
    return {"ok": True}


def disconnect() -> None:

    try:
        keyring.delete_password(SERVICE, ACCOUNT)
    except keyring.errors.KeyringError:
        pass


def is_mine(who: str, name: str) -> bool:

    """
    "Reece", "Reece and Sam", "me", "everyone", "" (no one named: action points no longer have a
    "who" field, so they're yours): yours. "Sam": not.
    """

    people = [p.strip().lower() for p in re.split(r",|&|/|\band\b", who or "") if p.strip()]
    if not people:
        return True
    mine = {"me", "everyone", "all", "all of us", "whole group"}
    if name:
        mine |= {name.lower(), name.split()[0].lower()}
    return any(p in mine for p in people)



def dated() -> List[Dict]:

    """
    Open Todoist tasks with due dates, soonest first: [{"id", "content", "due"}], for choosing which
    one is a project's deadline. Empty when Todoist isn't connected.
    """

    key = token()
    if not key:
        return []
    found, cursor = [], None
    try:
        while True:
            page = _call("GET", "tasks", key, params={"cursor": cursor} if cursor else {}).json()
            for task in page.get("results", []):
                due = (task.get("deadline") or {}).get("date") or (task.get("due") or {}).get("date")
                if due:
                    found.append({"id": task["id"], "content": task.get("content", ""), "due": due[:10]})
            cursor = page.get("next_cursor")
            if not cursor:
                break
    except (requests.RequestException, ValueError):
        return []
    return sorted(found, key=lambda t: t["due"])


def due_of(task_id: str) -> Optional[str]:

    """
    One task's due date ("2026-11-23"), or None if it has none, is done, or Todoist can't be reached.
    """

    key = token()
    if not key:
        return None
    try:
        task = _call("GET", f"tasks/{task_id}", key).json()
    except (requests.RequestException, ValueError):
        return None
    if task.get("checked") or task.get("completed_at"):
        return None
    return ((task.get("deadline") or {}).get("date") or (task.get("due") or {}).get("date") or "")[:10] or None
