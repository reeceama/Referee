"""Writing kept as files: an Obsidian vault, or R Markdown and Quarto documents, in the writing
folder chosen in Referee's settings.

Every few seconds the folder is looked over for Markdown (.md), R Markdown (.Rmd) and Quarto
(.qmd) files that changed. Each changed file is split into its prose, maths and code: the prose
sentences are checked against the reading like a sentence in Word, so they appear in the Evidence
report under the file's name; code chunks are checked like the code folder (libraries that ask to
be cited). Nothing in the files is ever changed.

Markdown that isn't prose is left out before sentences are found: YAML front matter, code blocks
and chunks, display maths, tables, headings, HTML comments, Obsidian embeds and callout titles.
Inline maths stays in the sentence, as TeX, as it does for Overleaf. Citations written as [@key]
or @key (Pandoc's, used by R Markdown, Quarto and Obsidian's citation plugins) are noted for each
sentence, so a sentence that cites something counts as cited.
"""

import json
import os
import re
import threading
import time
from pathlib import Path
from typing import Callable, Dict, List, Optional, Tuple

CONFIG = Path.home() / ".referee" / "config.json"
SUFFIXES = {".md", ".markdown", ".rmd", ".qmd"}
SKIP_FOLDERS = {".git", ".obsidian", ".trash", "node_modules", "_site", "_book", ".quarto", "renv"}
MAX_FILES = 2000
MAX_BYTES = 2_000_000
EVERY = 5  # seconds between looks at the folder


def folder() -> Optional[Path]:

    try:
        chosen = json.loads(CONFIG.read_text(encoding="utf-8")).get("writing_folder")
    except (OSError, ValueError):
        return None
    return Path(chosen) if chosen and Path(chosen).is_dir() else None


FRONT_MATTER = re.compile(r"\A---\n.*?\n(---|\.\.\.)\n", re.S)
FENCE = re.compile(r"^(```|~~~)(.*?)\n(.*?)^\1[ \t]*$", re.S | re.M)  # ```{r}, ```python, ~~~
DISPLAY_MATHS = re.compile(r"\$\$.*?\$\$", re.S)
COMMENT = re.compile(r"<!--.*?-->|%%.*?%%", re.S)  # HTML comments, and Obsidian's %% comments %%
CITATION = re.compile(r"\[(?:[^\[\]]*?;\s*)?-?@[\w:.#$%&+?<>~/-]+[^\[\]]*\]|(?<![\w@])@[\w][\w:.#$%&+?<>~/-]*")
KEY = re.compile(r"-?@([\w][\w:.#$%&+?<>~/-]*?)(?=[\s;,\]]|[.:]?$|[.:]\s)")


def chunks(text: str) -> List[Tuple[str, str]]:

    """
    The code in a file, as (language, code): R Markdown and Quarto chunks (```{r}), and fenced
    code blocks with a language (```python).
    """

    found = []
    for match in FENCE.finditer(text):
        info = match.group(2).strip().strip("{}").split(",")[0].split()[0].lower() if match.group(2).strip() else ""
        if info in {"r", "python", "py", "c", "cpp", "c++", "julia", "stan"}:
            found.append((info, match.group(3)))
    return found


def prose(text: str) -> str:

    """
    The file with everything that isn't prose taken out, keeping one paragraph per blank line.
    """

    text = text.replace("\r\n", "\n")
    text = FRONT_MATTER.sub("", text)
    text = FENCE.sub("\n", text)
    text = COMMENT.sub(" ", text)
    text = DISPLAY_MATHS.sub("\n\n", text)
    kept = []
    for line in text.split("\n"):
        stripped = line.strip()
        if (stripped.startswith(("#", "|", "![[", "<", "\\begin", "\\end", "```", ":::"))
                or re.match(r"^>\s*\[!\w+\]", stripped)        # an Obsidian callout's title
                or re.match(r"^[-*_]{3,}$", stripped)):        # a horizontal rule
            kept.append("")
            continue
        line = re.sub(r"^\s*>\s?", "", line)                    # quote and callout bodies
        line = re.sub(r"^\s*(?:[-*+]|\d+[.)])\s+(\[.\]\s+)?", "", line)  # list markers and tasks
        line = re.sub(r"!\[[^\]]*\]\([^)]*\)", "", line)        # images
        line = re.sub(r"\[([^\]]+)\]\([^)]*\)", r"\1", line)    # links keep their text
        line = re.sub(r"\[\[([^\]|]+\|)?([^\]]+)\]\]", r"\2", line)  # Obsidian [[links|text]]
        line = re.sub(r"`r [^`]*`", "", line)                  # inline R
        line = re.sub(r"`([^`]*)`", r"\1", line)
        line = re.sub(r"(\*\*|__|\*|_|==|~~)(?=\S)(.+?)(?<=\S)\1", r"\2", line)  # emphasis, highlights
        line = re.sub(r"\^\[[^\]]*\]|\[\^[^\]]+\]:?", "", line)  # footnotes
        kept.append(line)
    return "\n".join(kept)


ABBREVIATIONS = ("e.g.", "i.e.", "et al.", "cf.", "Fig.", "fig.", "Eq.", "eq.", "Thm.", "Prop.", "Lem.",
                 "Def.", "vs.", "approx.", "resp.", "Sec.", "Ch.", "p.", "pp.", "No.", "Dr.", "Prof.")


def sentences(text: str) -> List[Dict]:

    """
    The prose sentences of a Markdown, R Markdown or Quarto file, each with the citation keys it
    cites, its text without them (what's checked), and the line it starts on.
    """

    found = []
    lines = text.replace("\r\n", "\n").split("\n")
    body = prose(text)
    for paragraph in re.split(r"\n\s*\n", body):
        flat = " ".join(paragraph.split())
        if not flat:
            continue
        # Protect full stops that don't end a sentence, inside maths and after abbreviations.
        guarded = re.sub(r"\$[^$]+\$", lambda m: m.group(0).replace(".", "\u2024"), flat)
        for short in ABBREVIATIONS:
            guarded = guarded.replace(short, short.replace(".", "\u2024"))
        guarded = re.sub(r"(\d)\.(\d)", "\\1\u2024\\2", guarded)
        for part in re.split(r"(?<=[.!?])\s+(?=[A-Z\"“(\[$\\])", guarded):
            sentence = part.replace("\u2024", ".").strip()
            keys = [k for c in CITATION.findall(sentence) for k in KEY.findall(c)]
            plain = " ".join(CITATION.sub("", sentence).split()).replace(" .", ".").replace(" ,", ",").replace("..", ".")
            if len(plain.split()) < 5 or not re.search(r"[A-Za-z]{3}", plain):
                continue
            found.append({"sentence": plain, "keys": keys, "line": _line(lines, sentence)})
    return found


def _line(lines: List[str], sentence: str) -> Optional[int]:

    start = " ".join(sentence.split()[:3])
    for i, line in enumerate(lines):
        if start and start in " ".join(line.split()):
            return i + 1
    return None


class Watcher:

    """
    Looks over the writing folder every few seconds and checks the new sentences in files that
    changed, with `check(sentence, document)` (the same check as for Word and Overleaf).
    Results are kept per file for the Mac app's Evidence report; sentences already checked
    aren't checked again, so editing a paragraph costs only the sentences that changed.
    """

    def __init__(self, path: Path, check: Callable[[str, str], Dict], forget: Callable[[List[str]], None]):

        self.path = path
        self.check = check
        self.forget = forget
        self.lock = threading.Lock()
        try:
            saved = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            saved = {}
        self.files: Dict[str, Dict] = saved.get("files", {})   # path -> {mtime, results}
        self.root = saved.get("root")
        self.thread: Optional[threading.Thread] = None

    def start(self):

        if self.thread is None:
            self.thread = threading.Thread(target=self._run, daemon=True)
            self.thread.start()

    def _run(self):

        while True:
            try:
                self.scan()
            except Exception as error:  # a bad file mustn't stop the watcher
                print(f"Writing folder: {error}")
            time.sleep(EVERY)

    def _documents(self, root: Path):

        count = 0
        for directory, folders, names in os.walk(root):
            folders[:] = [f for f in folders if f not in SKIP_FOLDERS and not f.startswith(".")]
            for name in names:
                path = Path(directory) / name
                if path.suffix.lower() in SUFFIXES:
                    count += 1
                    if count > MAX_FILES:
                        return
                    yield path

    def name(self, path: Path, root: Path) -> str:

        kind = {".rmd": "R Markdown", ".qmd": "Quarto"}.get(path.suffix.lower(), "Obsidian" if (root / ".obsidian").is_dir() else "Markdown")
        return f"{path.relative_to(root)} ({kind})"

    def scan(self):

        root = folder()
        if root is None:
            return
        if str(root) != self.root:   # another folder chosen: start again
            self.files, self.root = {}, str(root)
        seen = set()
        for path in self._documents(root):
            key = str(path)
            seen.add(key)
            try:
                stat = path.stat()
            except OSError:
                continue
            if stat.st_size > MAX_BYTES or self.files.get(key, {}).get("mtime") == stat.st_mtime:
                continue
            # Wait until the file has been still for a few seconds: someone is probably typing.
            if time.time() - stat.st_mtime < EVERY:
                continue
            self._check_file(path, root, stat.st_mtime)
        with self.lock:
            for gone in set(self.files) - seen:
                self.files.pop(gone, None)
            self._save()

    def _check_file(self, path: Path, root: Path, mtime: float):

        text = path.read_text(encoding="utf-8", errors="replace")
        document = self.name(path, root)
        before = self.files.get(str(path), {}).get("results", {})
        found = sentences(text)
        results = {}
        for item in found:
            sentence = item["sentence"]
            result = before.get(sentence, {}).get("result")
            if result is None:
                result = self.check(sentence, document)
                if result is None:     # no answer (no key, or offline): try again next change
                    return
            results[sentence] = {"keys": item["keys"], "line": item["line"], "result": result}
        removed = [s for s in before if s not in results]
        if removed:
            self.forget(removed)     # reworded or deleted: out of the reports, as in Word
        with self.lock:
            self.files[str(path)] = {"mtime": mtime, "document": document, "results": results,
                                     "code": [lang for lang, _ in chunks(text)]}
            self._save()

    def _save(self):

        try:
            self.path.write_text(json.dumps({"root": self.root, "files": self.files}), encoding="utf-8")
        except OSError:
            pass

    def summary(self) -> Dict:

        root = folder()
        with self.lock:
            return {"folder": str(root) if root else None,
                    "files": [{"path": p, "document": f.get("document"), "sentences": len(f.get("results", {})),
                               "code": f.get("code", [])} for p, f in sorted(self.files.items())]}
