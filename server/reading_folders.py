"""Linked reading folders: folders on this Mac (a module's folder on OneDrive, say) whose PDFs become
sources in a chosen project by themselves, and stay up to date. Looked over at start and every five
minutes; a PDF is read again only when it changes. Nothing is copied: each source is the file where
it is.
"""

import json
import threading
import time
from pathlib import Path
from typing import Callable, Dict, List

EVERY = 5 * 60
SKIP = {".Trash", "node_modules", ".git"}


class ReadingFolders:

    def __init__(self, path: Path, add: Callable[[str, str, str], Dict]):

        self.path, self.add = path, add          # add(pdf path, title, project)
        try:
            saved = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            saved = {}
        self.folders: List[Dict] = saved.get("folders", [])   # [{"path", "project"}]
        self.seen: Dict[str, float] = saved.get("seen", {})   # pdf path -> modified time when read
        self.lock = threading.Lock()
        self.wake = threading.Event()

    def _save(self) -> None:

        self.path.write_text(json.dumps({"folders": self.folders, "seen": self.seen}, indent=1), encoding="utf-8")

    def link(self, folder: str, project: str) -> Dict:

        folder = str(Path(folder).expanduser())
        if not Path(folder).is_dir():
            return {"ok": False, "reason": "That folder isn't there."}
        self.folders = [f for f in self.folders if f["path"] != folder] + [{"path": folder, "project": project}]
        self._save()
        self.wake.set()
        return {"ok": True}

    def unlink(self, folder: str) -> None:

        self.folders = [f for f in self.folders if f["path"] != folder]
        self._save()

    def start(self) -> None:

        threading.Thread(target=self._loop, daemon=True).start()

    def _loop(self) -> None:

        while True:
            try:
                self.run()
            except Exception:
                pass
            self.wake.wait(EVERY)
            self.wake.clear()

    def run(self) -> None:

        with self.lock:
            for folder in list(self.folders):
                root = Path(folder["path"])
                if not root.is_dir():
                    continue
                for pdf in sorted(root.rglob("*.pdf")):
                    if any(part in SKIP or part.startswith(".") for part in pdf.relative_to(root).parts):
                        continue
                    try:
                        modified = pdf.stat().st_mtime
                    except OSError:
                        continue
                    if self.seen.get(str(pdf)) == modified:
                        continue
                    try:
                        result = self.add(str(pdf), pdf.stem, folder["project"])
                    except Exception:
                        continue
                    if result.get("ok"):
                        self.seen[str(pdf)] = modified
                        self._save()

    def status(self) -> List[Dict]:

        return [{**f, "pdfs": sum(1 for p in self.seen if p.startswith(f["path"] + "/"))} for f in self.folders]
