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


# Todoist inside Referee's calendar: your tasks with dates, edited in place, new tasks in any project,
# and new projects. Each change goes to Todoist at once.

REPEATS = {"daily": "day", "weekly": "week", "monthly": "month", "yearly": "year"}


def _pages(path: str, key: str) -> List[Dict]:
    found, cursor = [], None
    while True:
        page = _call("GET", path, key, params={"cursor": cursor} if cursor else {}).json()
        found += page.get("results", [])
        cursor = page.get("next_cursor")
        if not cursor:
            return found


def projects() -> List[Dict]:
    """Your Todoist projects: [{"id", "name"}]."""
    key = token()
    if not key:
        return []
    try:
        return [{"id": p["id"], "name": p.get("name", "")} for p in _pages("projects", key) if not p.get("is_archived")]
    except (requests.RequestException, ValueError):
        return []


def all_tasks() -> Optional[List[Dict]]:
    """
    Every open task, with what the calendar shows and edits: [{"id", "content", "description",
    "date", "time", "repeat", "priority" (1 most urgent to 4), "labels", "project_id", "project",
    "deadline"}]. None when Todoist can't be reached.
    """
    key = token()
    if not key:
        return None
    try:
        names = {p["id"]: p["name"] for p in projects()}
        found = []
        for t in _pages("tasks", key):
            due = t.get("due") or {}
            when = due.get("datetime") or due.get("date") or ""
            repeat = next((k for k, unit in REPEATS.items() if due.get("is_recurring") and f"every {unit}" in (due.get("string") or "").lower()), "custom" if due.get("is_recurring") else "never")
            found.append({"id": t["id"], "content": t.get("content", ""), "description": t.get("description", ""),
                          "date": when[:10] or None, "time": when[11:16] if len(when) > 10 else None,
                          "repeat": repeat, "repeat_text": due.get("string") if due.get("is_recurring") else None,
                          "priority": 5 - int(t.get("priority") or 1), "labels": t.get("labels") or [],
                          "project_id": t.get("project_id"), "project": names.get(t.get("project_id"), ""),
                          "deadline": (t.get("deadline") or {}).get("date")})
        return found
    except (requests.RequestException, ValueError):
        return None


def new_project(name: str) -> Dict:
    key = token()
    if not key or not name.strip():
        return {"ok": False}
    try:
        made = _call("POST", "projects", key, json={"name": name.strip()})
        made.raise_for_status()
        return {"ok": True, "id": made.json()["id"], "name": name.strip()}
    except (requests.RequestException, ValueError, KeyError):
        return {"ok": False}


def save_task(body: Dict) -> Dict:
    """
    Creates a task (no "id") or changes one: {"content", "description", "date" (YYYY-MM-DD or none),
    "time" (HH:MM or none), "repeat" (never, daily, weekly, monthly, yearly; custom keeps Todoist's),
    "priority" 1-4, "labels", "project_id"}. No reminders: those are left to your calendar app.
    """
    key = token()
    if not key:
        return {"ok": False, "reason": "not_connected"}
    task = {"content": body.get("content") or "", "description": body.get("description") or "",
            "priority": 5 - int(body.get("priority") or 4), "labels": body.get("labels") or []}
    if body.get("project_id") and not body.get("id"):
        task["project_id"] = body["project_id"]
    date, at, repeat = body.get("date"), body.get("time"), body.get("repeat") or "never"
    if not date:
        task["due_string"] = "no date"
    elif repeat in REPEATS:
        day = datetime.strptime(date, "%Y-%m-%d")
        task["due_string"] = f"every {REPEATS[repeat]} starting {day.strftime('%b')} {day.day} {day.year}" + (f" at {at}" if at else "")
        task["due_lang"] = "en"
    elif repeat == "custom" and body.get("repeat_text"):
        task["due_string"] = body["repeat_text"]
    elif at:
        task["due_datetime"] = f"{date}T{at}:00"
    else:
        task["due_date"] = date
    try:
        sent = _call("POST", f"tasks/{body['id']}" if body.get("id") else "tasks", key, json=task)
        sent.raise_for_status()
        task_id = sent.json()["id"]
        # A project change is a move in Todoist's API, separate from the edit.
        if body.get("id") and body.get("project_id") and body.get("project_id") != body.get("was_project"):
            _call("POST", f"tasks/{task_id}/move", key, json={"project_id": body["project_id"]}).raise_for_status()
    except (requests.RequestException, ValueError, KeyError):
        return {"ok": False, "reason": "todoist"}
    return {"ok": True, "id": task_id}


def close_task(task_id: str) -> bool:
    key = token()
    try:
        return bool(key) and _call("POST", f"tasks/{task_id}/close", key).ok
    except requests.RequestException:
        return False


def delete_task(task_id: str) -> bool:
    key = token()
    try:
        return bool(key) and _call("DELETE", f"tasks/{task_id}", key).ok
    except requests.RequestException:
        return False
