"""GitHub repositories VAR may read, chosen by the person: each a set to practise on.

Uses the GitHub CLI (gh) already signed in on this Mac, so Referee never sees or keeps a token. A chosen
repository is cloned read-only into Referee's data folder and its text read: the write-up (.tex, R
Markdown or Quarto) and the code and notes around it for the academic side, the README, code and
notebooks for the professional side. Pulling it again updates
the set's text, so VAR shows the work has changed.
"""

import json
import shutil
import subprocess
from pathlib import Path
from typing import Dict, List, Optional

GH = next((p for p in ("/opt/homebrew/bin/gh", "/usr/local/bin/gh", shutil.which("gh") or "") if p and Path(p).exists()), None)
CODE = {".md", ".txt", ".py", ".ipynb", ".r", ".rmd", ".qmd", ".sql", ".jl", ".js", ".ts", ".swift", ".java", ".scala", ".tex"}
SKIPPED = {".git", "node_modules", ".venv", "venv", "__pycache__", "build", "dist", ".ipynb_checkpoints"}


def _gh(*args: str, timeout: float = 60) -> Optional[str]:
    if not GH:
        return None
    try:
        done = subprocess.run([GH, *args], capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired):
        return None
    return done.stdout if done.returncode == 0 else None


def _text(path: Path) -> str:
    if path.suffix.lower() == ".ipynb":
        try:
            cells = json.loads(path.read_text(encoding="utf-8")).get("cells", [])
        except (OSError, ValueError):
            return ""
        return "\n\n".join(("" if c.get("cell_type") == "markdown" else "# [code]\n")
                           + "".join(c.get("source") if isinstance(c.get("source"), list) else [c.get("source") or ""])
                           for c in cells)
    try:
        return path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        return ""


def read_repository(folder: Path, academic: bool) -> List[Dict]:
    """The files worth reading, as {"name", "latex"}: the write-up first (academic), or the README first."""
    found = []
    for path in sorted(folder.rglob("*")):
        if any(part in SKIPPED for part in path.relative_to(folder).parts) or not path.is_file():
            continue
        suffix = path.suffix.lower()
        if suffix not in CODE or path.stat().st_size > 400_000:
            continue
        text = _text(path)
        if text.strip():
            name = str(path.relative_to(folder))
            found.append({"name": name, "latex": text if academic and suffix == ".tex" else f"=== {name} ===\n{text}"})
    # Academic: the write-up (a main .tex, or an R Markdown or Quarto report) first, the code after it.
    write_up = lambda f: "\\documentclass" in f["latex"] or f["name"].lower().endswith((".rmd", ".qmd"))
    first = (lambda f: not write_up(f)) if academic else (lambda f: not f["name"].lower().startswith("readme"))
    return sorted(found, key=lambda f: (first(f), f["name"].count("/"), f["name"]))


class GitHubRepos:

    def __init__(self, path: Path, folder: Path, var):
        self.path, self.folder, self.var = path, folder, var
        try:
            self.chosen: Dict[str, Dict] = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            self.chosen = {}

    def _save(self) -> None:
        self.path.write_text(json.dumps(self.chosen, indent=1), encoding="utf-8")

    def status(self) -> Dict:
        if not GH:
            return {"installed": False, "login": None}
        login = (_gh("api", "user", "-q", ".login", timeout=15) or "").strip()
        return {"installed": True, "login": login or None}

    def repositories(self) -> List[Dict]:
        found = json.loads(_gh("repo", "list", "--limit", "200", "--json", "nameWithOwner,isPrivate,updatedAt,description") or "[]")
        return [r | {"chosen": self.chosen.get(r["nameWithOwner"])} for r in found]

    def choose(self, repo: str, side: Optional[str], project: str = "") -> Dict:
        """Lets VAR read a repository (side "academic" or "professional"), or stops it (side None)."""
        if not side:
            self.chosen.pop(repo, None)
            self._save()
            return {"ok": True}
        self.chosen[repo] = {"side": side, "project": project}
        self._save()
        return self.sync(repo)

    def _folder(self, repo: str) -> Path:
        return self.folder / repo.replace("/", "__")

    def sync(self, repo: Optional[str] = None) -> Dict:
        """Clones or pulls the chosen repositories, and gives VAR their text as it is now."""
        done, failed = [], []
        for name, choice in list(self.chosen.items()):
            if repo and name != repo:
                continue
            folder = self._folder(name)
            if (folder / ".git").exists():
                ok = subprocess.run(["git", "-C", str(folder), "pull", "--ff-only", "-q"], capture_output=True).returncode == 0
            else:
                self.folder.mkdir(parents=True, exist_ok=True)
                ok = _gh("repo", "clone", name, str(folder), "--", "--depth", "1", "-q", timeout=300) is not None
            files = read_repository(folder, choice["side"] == "academic") if ok else []
            if not files:
                failed.append(name)
                continue
            purpose = "viva" if choice["side"] == "academic" else "interview"
            self.var.set_files(name.split("/")[-1], files, choice.get("project") or "", purpose)
            done.append(name)
        return {"ok": not failed, "synced": done, "failed": failed}
