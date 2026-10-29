"""Backups of everything Referee keeps, in one file: the library (passages and their search
vectors), notes and the photos and files added to them, meetings, AI use, claims and Evidence
reports, and settings. Keys and tokens
stay in the system's password store and are never included.

A backup is a .zip named "Referee backup 2026-10-17.zip". Restoring one first backs up what's
there now (as "Referee before restore …"), then replaces it; the server reloads afterwards.
Automatic backups, if switched on, are made weekly into a chosen folder, keeping the last four.
"""

import json
import shutil
import threading
import time
import zipfile
from datetime import date
from pathlib import Path
from typing import Dict, List, Optional

import paths

CONFIG = Path.home() / ".referee" / "config.json"
SKIP = {"extension"}              # the browser extension's copy, reinstalled from the app
WEEK = 7 * 24 * 60 * 60
KEEP = 4


def _config() -> Dict:

    try:
        return json.loads(CONFIG.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}


def make(folder: Path, name: Optional[str] = None) -> Path:

    """
    A backup in the folder; returns its path.
    """

    folder.mkdir(parents=True, exist_ok=True)
    target = folder / (name or f"Referee backup {date.today().isoformat()}.zip")
    with zipfile.ZipFile(target, "w", zipfile.ZIP_DEFLATED) as archive:
        archive.writestr("referee-backup.json", json.dumps({"made": time.time(), "version": 1}))
        for path in sorted(paths.DATA.iterdir()):
            if path.is_file() and path.name not in SKIP and not path.name.startswith("."):
                archive.write(path, f"data/{path.name}")
        for path in sorted((paths.DATA / "note-files").rglob("*")) if (paths.DATA / "note-files").is_dir() else []:
            if path.is_file():
                archive.write(path, f"files/{path.relative_to(paths.DATA / 'note-files')}")
        # Meetings' attachments (photos, slides), alongside the notes' own.
        for path in sorted((paths.DATA / "meeting-files").rglob("*")) if (paths.DATA / "meeting-files").is_dir() else []:
            if path.is_file():
                archive.write(path, f"meeting-files/{path.relative_to(paths.DATA / 'meeting-files')}")
        if CONFIG.exists():
            archive.write(CONFIG, "config/config.json")
    return target


def restore(backup: Path) -> Dict:

    """
    Replaces Referee's data and settings with a backup's, after backing up what's there now.
    """

    try:
        archive = zipfile.ZipFile(backup)
    except (OSError, zipfile.BadZipFile):
        return {"ok": False, "reason": "That isn't a Referee backup."}
    with archive:
        names = archive.namelist()
        if "referee-backup.json" not in names:
            return {"ok": False, "reason": "That isn't a Referee backup."}
        safety = make(paths.DATA.parent / "Referee backups", f"Referee before restore {time.strftime('%Y-%m-%d %H.%M')}.zip")
        for name in names:
            if name.startswith("data/") and "/" not in name[5:] and name[5:]:
                with archive.open(name) as source, open(paths.DATA / name[5:], "wb") as out:
                    shutil.copyfileobj(source, out)
            elif name.startswith("meeting-files/") and not name.endswith("/") and ".." not in name:
                target = paths.DATA / "meeting-files" / name[len("meeting-files/"):]
                target.parent.mkdir(parents=True, exist_ok=True)
                with archive.open(name) as source, open(target, "wb") as out:
                    shutil.copyfileobj(source, out)
            elif name.startswith("files/") and not name.endswith("/") and ".." not in name:
                target = paths.DATA / "note-files" / name[6:]
                target.parent.mkdir(parents=True, exist_ok=True)
                with archive.open(name) as source, open(target, "wb") as out:
                    shutil.copyfileobj(source, out)
            elif name == "config/config.json":
                CONFIG.parent.mkdir(parents=True, exist_ok=True)
                with archive.open(name) as source, open(CONFIG, "wb") as out:
                    shutil.copyfileobj(source, out)
    return {"ok": True, "before": str(safety)}


def automatic() -> Dict:

    config = _config()
    return {"on": bool(config.get("backup_folder")), "folder": config.get("backup_folder"),
            "last": config.get("backup_last")}


class Weekly:

    """
    Makes a backup when the last one is a week old, keeping the newest four.
    """

    def start(self) -> None:

        threading.Thread(target=self._loop, daemon=True).start()

    def _loop(self) -> None:

        while True:
            try:
                self.run()
            except OSError as error:
                print(f"Backups: {error}")
            time.sleep(60 * 60)

    def run(self) -> None:

        config = _config()
        folder = config.get("backup_folder")
        if not folder or time.time() - (config.get("backup_last") or 0) < WEEK:
            return
        make(Path(folder))
        config["backup_last"] = time.time()
        CONFIG.write_text(json.dumps(config, indent=2), encoding="utf-8")
        old: List[Path] = sorted(Path(folder).glob("Referee backup *.zip"))
        for path in old[:-KEEP]:
            path.unlink()
