"""Meeting action points in the person's to-do app, both ways: Things 3, Apple Reminders,
Todoist or Notion, one at a time (Settings → Integrations, "tasks_app" in config.json), so a
task never lands in two apps.

Your own action points (their "who" is your name, "me" or everyone) become tasks with their due
dates, in a list or project named after the Referee project. Ticking one off in either place
ticks it off in the other. A task deleted in the app is left alone in Referee and no longer
synced. Changing app starts afresh: tasks already sent stay where they are.

    things:     Things 3 on this Mac, through AppleScript (macOS asks once for permission).
    reminders:  Apple Reminders on this Mac, through AppleScript; shows in Fantastical too.
    todoist:    Todoist's API, with the token from todoist.py.
    notion:     a Notion database, with an integration token and the database's ID (notion.py).
"""

import json
import subprocess
import threading
import time
from datetime import datetime
from pathlib import Path
from typing import Dict, Optional

import requests
import paths

import notion
import todoist

CONFIG = Path.home() / ".referee" / "config.json"
EVERY = 180  # seconds between syncs; a meeting change syncs straight away
APPS = ("things", "reminders", "todoist", "notion")


def chosen_app() -> Optional[str]:

    try:
        app = json.loads(CONFIG.read_text(encoding="utf-8")).get("tasks_app")
    except (OSError, ValueError):
        app = None
    # Todoist users from before there was a choice: still Todoist.
    if app is None and todoist.token():
        return "todoist"
    return app if app in APPS else None


def due_date(due: str) -> Optional[datetime]:

    """
    "Friday", "24 Oct", "2026-10-24", "next week": a date, or None if it can't be read.
    """

    if not due.strip():
        return None
    try:
        return datetime.fromisoformat(due.strip())
    except ValueError:
        pass
    try:
        import dateparser
        return dateparser.parse(due, languages=["en"], settings={"PREFER_DATES_FROM": "future", "DATE_ORDER": "DMY"})
    except Exception:
        return None


# AppleScript, for Things and Reminders. Text goes in as arguments, never into the script itself.

def _osascript(script: str, *args: str) -> str:

    done = subprocess.run(["osascript", "-e", script, *args], capture_output=True, text=True, timeout=30)
    if done.returncode != 0:
        raise RuntimeError(done.stderr.strip() or "AppleScript failed")
    return done.stdout.strip()


def _applescript_date(when: Optional[datetime]) -> str:

    return when.strftime("%Y-%m-%d") if when else ""


DATE_FROM_TEXT = """
on dateFrom(t)
    if t is "" then return missing value
    set d to current date
    set day of d to 1
    set year of d to (text 1 thru 4 of t) as integer
    set month of d to (text 6 thru 7 of t) as integer
    set day of d to (text 9 thru 10 of t) as integer
    set time of d to 9 * hours
    return d
end dateFrom
"""


class Things:

    def create(self, text: str, notes: str, due: Optional[datetime], project: str) -> str:
        return _osascript(DATE_FROM_TEXT + """
on run argv
    set {theName, theNotes, theDue, theProject} to argv
    tell application "Things3"
        if theProject is not "" and not (exists project theProject) then make new project with properties {name:theProject}
        set t to make new to do with properties {name:theName, notes:theNotes}
        if theProject is not "" then set project of t to project theProject
        set d to my dateFrom(theDue)
        if d is not missing value then set due date of t to d
        return id of t
    end tell
end run""", text, notes, _applescript_date(due), project)

    def state(self, task_id: str) -> Optional[bool]:
        """True if done, False if open, None if it's gone."""
        try:
            status = _osascript('on run argv\ntell application "Things3" to return status of to do id (item 1 of argv) as text\nend run', task_id)
        except RuntimeError:
            return None
        return None if status == "canceled" else status == "completed"

    def complete(self, task_id: str) -> None:
        _osascript('on run argv\ntell application "Things3" to set status of to do id (item 1 of argv) to completed\nend run', task_id)

    def update(self, task_id: str, text: str, due: Optional[datetime]) -> None:
        _osascript(DATE_FROM_TEXT + """
on run argv
    tell application "Things3"
        set t to to do id (item 1 of argv)
        set name of t to item 2 of argv
        set d to my dateFrom(item 3 of argv)
        if d is not missing value then set due date of t to d
    end tell
end run""", task_id, text, _applescript_date(due))


class Reminders:

    def create(self, text: str, notes: str, due: Optional[datetime], project: str) -> str:
        return _osascript(DATE_FROM_TEXT + """
on run argv
    set {theName, theNotes, theDue, theList} to argv
    if theList is "" then set theList to "Referee"
    tell application "Reminders"
        if not (exists list theList) then make new list with properties {name:theList}
        set r to make new reminder at end of list theList with properties {name:theName, body:theNotes}
        set d to my dateFrom(theDue)
        if d is not missing value then set due date of r to d
        return id of r
    end tell
end run""", text, notes, _applescript_date(due), project)

    def state(self, task_id: str) -> Optional[bool]:
        try:
            done = _osascript('on run argv\ntell application "Reminders" to return completed of reminder id (item 1 of argv)\nend run', task_id)
        except RuntimeError:
            return None
        return done == "true"

    def complete(self, task_id: str) -> None:
        _osascript('on run argv\ntell application "Reminders" to set completed of reminder id (item 1 of argv) to true\nend run', task_id)

    def update(self, task_id: str, text: str, due: Optional[datetime]) -> None:
        _osascript(DATE_FROM_TEXT + """
on run argv
    tell application "Reminders"
        set r to reminder id (item 1 of argv)
        set name of r to item 2 of argv
        set d to my dateFrom(item 3 of argv)
        if d is not missing value then set due date of r to d
    end tell
end run""", task_id, text, _applescript_date(due))


class Todoist:

    def __init__(self):
        self.projects: Dict[str, str] = {}

    def attach(self, task_id: str, path: Path) -> None:
        """
        Uploads a file to Todoist and adds it to the task as a comment with the file attached.
        """
        with open(path, "rb") as f:
            uploaded = todoist._call("POST", "uploads", self._key(), files={"file": (path.name, f)})
        uploaded.raise_for_status()
        info = uploaded.json()
        todoist._call("POST", "comments", self._key(), json={
            "task_id": task_id, "content": path.name,
            "attachment": {"resource_type": "file", "file_name": info.get("file_name", path.name),
                           "file_type": info.get("file_type"), "file_url": info.get("file_url")},
        }).raise_for_status()

    def _key(self) -> str:
        key = todoist.token()
        if not key:
            raise RuntimeError("Todoist isn't connected.")
        return key

    def _project(self, name: str) -> str:
        key = self._key()
        if not self.projects:
            cursor = None
            while True:
                page = todoist._call("GET", "projects", key, params={"cursor": cursor} if cursor else {}).json()
                self.projects.update({p["name"]: p["id"] for p in page.get("results", [])})
                cursor = page.get("next_cursor")
                if not cursor:
                    break
        if name not in self.projects:
            self.projects[name] = todoist._call("POST", "projects", key, json={"name": name}).json()["id"]
        return self.projects[name]

    # An action point's "by when" is the task's deadline in Todoist (when it must be done), not its
    # due date (when to work on it): you schedule the work yourself in Todoist.
    def create(self, text: str, notes: str, due: Optional[datetime], project: str) -> str:
        body = {"content": text, "description": notes, "project_id": self._project(project or "Referee")}
        response = self._send("tasks", body, due)
        return response.json()["id"]

    def _send(self, path: str, body: dict, due: Optional[datetime]):
        """
        Posts with the deadline as deadline_date (Todoist's API v1 name); if Todoist refuses that
        field, once more with "deadline", then without one, so the task is never lost over it.
        """
        tries = [{}] if not due else [{"deadline_date": due.strftime("%Y-%m-%d")}, {"deadline": due.strftime("%Y-%m-%d")}, {}]
        for extra in tries:
            response = todoist._call("POST", path, self._key(), json={**body, **extra})
            if response.status_code != 400:
                break
        response.raise_for_status()
        return response

    def state(self, task_id: str) -> Optional[bool]:
        response = todoist._call("GET", f"tasks/{task_id}", self._key())
        if response.status_code == 404 or (response.ok and response.json().get("is_deleted")):
            return None
        response.raise_for_status()
        task = response.json()
        return bool(task.get("completed_at") or task.get("checked"))

    def complete(self, task_id: str) -> None:
        todoist._call("POST", f"tasks/{task_id}/close", self._key()).raise_for_status()

    def update(self, task_id: str, text: str, due: Optional[datetime]) -> None:
        self._send(f"tasks/{task_id}", {"content": text}, due)


BACKENDS = {"things": Things, "reminders": Reminders, "todoist": Todoist, "notion": notion.Tasks}


class Sync:

    """
    Keeps your action points and their tasks in step, in the background.
    """

    def __init__(self, meetings):

        self.meetings = meetings
        self.wake = threading.Event()
        self.backends: Dict[str, object] = {}
        self.last = {"at": None, "error": None, "tasks": 0}

    def start(self) -> None:

        threading.Thread(target=self._loop, daemon=True).start()

    def soon(self) -> None:

        self.wake.set()

    def _send_files(self, backend, app, meeting, action, changed) -> None:
        """
        The meeting attachments chosen for this action point, uploaded to its Todoist task once each.
        Only Todoist takes files; other apps keep the link back to the meeting.
        """
        if app != "todoist" or not action.get("task_id"):
            return
        sent = set(action.get("files_sent") or [])
        for name in action.get("send_files") or []:
            path = paths.data("meeting-files") / meeting["id"] / name
            if name in sent or not path.is_file():
                continue
            backend.attach(action["task_id"], path)
            sent.add(name)
            changed.add(meeting.get("project") or "")
        action["files_sent"] = sorted(sent)

    def _loop(self) -> None:

        while True:
            self.wake.wait(EVERY)
            self.wake.clear()
            time.sleep(2)  # let a run of edits settle
            try:
                self.run()
            except (requests.RequestException, RuntimeError, subprocess.SubprocessError) as error:
                self.last["error"] = str(error) or type(error).__name__

    def run(self) -> None:

        app = chosen_app()
        if app is None:
            return
        backend = self.backends.setdefault(app, BACKENDS[app]())
        name = todoist.your_name()
        changed, synced = set(), 0
        for meeting in self.meetings.items:
            for action in meeting.get("actions", []):
                # Todoist links made before there was a choice of app.
                if action.get("todoist_id") and not action.get("task_id"):
                    action.update(task_app="todoist", task_id=action["todoist_id"],
                                  task_sent=action.get("todoist_sent"), task_gone=action.get("todoist_gone"))
                if not action.get("text") or action.get("task_gone"):
                    continue
                if action.get("task_id") and action.get("task_app") != app:
                    continue  # sent to another app before the switch: left there
                due_text = action.get("due") or ""
                project = meeting.get("project") or "Referee"
                if not action.get("task_id"):
                    if action.get("done") or not todoist.is_mine(action.get("who", ""), name):
                        continue
                    # The action point's own notes first, then where it came from.
                    origin = (f"Added in Referee: referee://meeting/{meeting['id']}" if meeting.get("kind") == "tasks" else
                              f"From {meeting.get('title') or 'a meeting'} ({meeting.get('date')}): referee://meeting/{meeting['id']}")
                    notes = f"{action['notes'].strip()}\n\n{origin}" if (action.get("notes") or "").strip() else origin
                    action["task_id"] = backend.create(action["text"], notes, due_date(due_text), project)
                    action["task_app"], action["task_sent"] = app, [action["text"], due_text]
                    changed.add(meeting.get("project") or "")
                    self._send_files(backend, app, meeting, action, changed)
                    synced += 1
                    continue
                self._send_files(backend, app, meeting, action, changed)
                done_there = backend.state(action["task_id"])
                if done_there is None:
                    action["task_gone"] = True  # deleted in the app: stop syncing it
                    changed.add(meeting.get("project") or "")
                    continue
                synced += 1
                if done_there and not action.get("done"):
                    action["done"] = True
                    changed.add(meeting.get("project") or "")
                elif action.get("done") and not done_there:
                    backend.complete(action["task_id"])
                elif not action.get("done") and action.get("task_sent") != [action["text"], due_text]:
                    backend.update(action["task_id"], action["text"], due_date(due_text))
                    action["task_sent"] = [action["text"], due_text]
                    changed.add(meeting.get("project") or "")
        if changed:
            self.meetings._save(changed)  # also rewrites the workspace's who-did-what
        self.last = {"at": time.time(), "error": None, "tasks": synced}

    def status(self) -> Dict:

        return {"app": chosen_app(), "name": todoist.your_name(), "todoist": bool(todoist.token()),
                "notion": notion.status(), **self.last}
