"""Meeting action points in Todoist, both ways.

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
import threading
import time
from pathlib import Path
from typing import Dict, List, Optional

import keyring
import requests

API = "https://api.todoist.com/api/v1"
SERVICE, ACCOUNT = "Referee", "todoist-token"
CONFIG = Path.home() / ".referee" / "config.json"
EVERY = 180  # seconds between syncs; a meeting change syncs straight away
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
    "Reece", "Reece and Sam", "me", "everyone": yours. "Sam", "": not.
    """

    people = [p.strip().lower() for p in re.split(r",|&|/|\band\b", who or "") if p.strip()]
    mine = {"me", "everyone", "all", "all of us", "whole group"}
    if name:
        mine |= {name.lower(), name.split()[0].lower()}
    return any(p in mine for p in people)


class Sync:

    """
    Keeps your action points and their Todoist tasks in step, in the background.
    """

    def __init__(self, meetings):

        self.meetings = meetings
        self.wake = threading.Event()
        self.projects: Dict[str, str] = {}  # Todoist project name -> id
        self.last = {"at": None, "error": None, "tasks": 0}

    def start(self) -> None:

        threading.Thread(target=self._loop, daemon=True).start()

    def soon(self) -> None:

        self.wake.set()

    def _loop(self) -> None:

        while True:
            self.wake.wait(EVERY)
            self.wake.clear()
            time.sleep(2)  # let a run of edits settle
            try:
                self.run()
            except requests.RequestException as error:
                self.last["error"] = f"Couldn't reach Todoist ({type(error).__name__})."

    def _project(self, key: str, name: str) -> str:

        if not self.projects:
            cursor = None
            while True:
                page = _call("GET", "projects", key, params={"cursor": cursor} if cursor else {}).json()
                self.projects.update({p["name"]: p["id"] for p in page.get("results", [])})
                cursor = page.get("next_cursor")
                if not cursor:
                    break
        if name not in self.projects:
            self.projects[name] = _call("POST", "projects", key, json={"name": name}).json()["id"]
        return self.projects[name]

    def run(self) -> None:

        key = token()
        if not key:
            return
        name = your_name()
        changed = set()
        synced = 0
        for meeting in self.meetings.items:
            for action in meeting.get("actions", []):
                if not action.get("text") or action.get("todoist_gone"):
                    continue
                task_id = action.get("todoist_id")
                due = action.get("due") or ""
                if not task_id:
                    if action.get("done") or not is_mine(action.get("who", ""), name):
                        continue
                    body = {"content": action["text"],
                            "description": f"From {meeting.get('title') or 'a meeting'} ({meeting.get('date')}): referee://meeting/{meeting['id']}",
                            "project_id": self._project(key, meeting.get("project") or "Referee")}
                    if due:
                        body["due_string"] = due
                    response = _call("POST", "tasks", key, json=body)
                    if not response.ok and due:  # a due date Todoist can't read: add it without one
                        body.pop("due_string")
                        response = _call("POST", "tasks", key, json=body)
                    response.raise_for_status()
                    action["todoist_id"], action["todoist_sent"] = response.json()["id"], [action["text"], due]
                    changed.add(meeting.get("project") or "")
                    synced += 1
                    continue
                response = _call("GET", f"tasks/{task_id}", key)
                if response.status_code == 404 or (response.ok and response.json().get("is_deleted")):
                    action["todoist_gone"] = True  # deleted in Todoist: stop syncing it
                    changed.add(meeting.get("project") or "")
                    continue
                response.raise_for_status()
                task = response.json()
                done_there = bool(task.get("completed_at") or task.get("checked"))
                synced += 1
                if done_there and not action.get("done"):
                    action["done"] = True
                    changed.add(meeting.get("project") or "")
                elif action.get("done") and not done_there:
                    _call("POST", f"tasks/{task_id}/close", key).raise_for_status()
                elif not action.get("done") and action.get("todoist_sent") != [action["text"], due]:
                    body = {"content": action["text"], **({"due_string": due} if due else {})}
                    _call("POST", f"tasks/{task_id}", key, json=body).raise_for_status()
                    action["todoist_sent"] = [action["text"], due]
                    changed.add(meeting.get("project") or "")
        if changed:
            self.meetings._save(changed)  # also rewrites the workspace's who-did-what
        self.last = {"at": time.time(), "error": None, "tasks": synced}

    def status(self) -> Dict:

        return {"connected": bool(token()), "name": your_name(), **self.last}
