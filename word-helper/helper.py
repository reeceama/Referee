"""Referee for Word, running in the background: no add-in and no panel.

Every few seconds it reads the document open in Word. Once you pause, each new finished
sentence is checked against your reading; supported claims are marked and cited,
problems get a comment, and the reference list at the end is kept up to date. Typing also
tells the server you're writing, so the browser extension captures what you read.

Run: python word-helper/helper.py   (it attaches to Word when Word is open)
Settings: ~/.referee/config.json, {"style": "apa" | "harvard" | "mla" | "ieee" | "ams"}.
The project is the current one chosen in the browser extension.
"""

import json
import re
import socket
import sys
import time
from pathlib import Path
from typing import Dict, List, Optional

import requests

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "server"))
import citations  # noqa: E402  shared with the server, so styles match everywhere

SERVER = "http://localhost:8000"
HEADERS = {"X-Referee": "1"}
POLL_SECONDS = 4          # how often the document is read
PING_SECONDS = 60         # "still writing" signals, at most this often
MIN_WORDS = 5
OLD_SOURCE_YEARS = 10
COMMENT_PREFIX = "Referee: "
HEADINGS = {"References", "Reference list", "Works Cited"}
SENTENCE = re.compile(r"[^.!?\r\n]+[.!?]+[\"”’)\]]*")
CLOSING = re.compile(r"[.!?]+[\"”’)\]]*$")
# Full stops that don't end a sentence: "n.d." in Referee's own citations, "et al.", "p. 4" and so on.
ABBREVIATIONS = re.compile(r"\b(n\.d|et al|pp?|e\.g|i\.e|vol|no|para|cf|ch|ed|eds|fig)\.", re.IGNORECASE)
HOME = Path.home() / ".referee"


class Settings:

    """
    Style and project from ~/.referee/config.json, created with defaults on first run.
    """

    def __init__(self):

        self.path = HOME / "config.json"
        if not self.path.exists():
            HOME.mkdir(exist_ok=True)
            self.path.write_text(json.dumps({"style": "apa"}, indent=2), encoding="utf-8")

    def load(self) -> Dict:

        try:
            settings = json.loads(self.path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            settings = {}
        style = settings.get("style", "apa")
        # An empty project means the server's current project, chosen in the browser extension.
        marks = settings.get("marks") or ("underline" if settings.get("highlight", True) else "none")
        return {"style": style if style in citations.HEADINGS else "apa", "project": settings.get("project", ""),
                "marks": marks if marks in ("underline", "highlight", "none") else "underline",
                # Off: supported sentences get a comment suggesting the citation, which the person
                # types themselves. On: the citation is inserted for them.
                "auto_cite": bool(settings.get("auto_cite", False))}


class DocumentState:

    """
    Per document: sentences already checked, the sources cited and their numbers.
    Saved in ~/.referee/word-helper.json so restarting doesn't re-check everything.
    """

    def __init__(self):

        self.path = HOME / "word-helper.json"
        try:
            self.documents: Dict[str, Dict] = json.loads(self.path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            self.documents = {}

    def get(self, name: str) -> Dict:

        state = self.documents.setdefault(name, {})
        state.setdefault("checked", [])
        state.setdefault("cited", {})     # url -> source metadata
        state.setdefault("numbers", {})   # url -> number, for numbered styles
        state.setdefault("listed", [])    # reference entries already in the document
        state.setdefault("citations", {}) # url -> in-text citations inserted, for the audit
        state.setdefault("entries", {})   # url -> its reference entry, for the audit
        state.setdefault("reported", None) # reference check last sent to the library
        state.setdefault("warnings", {})  # sentence -> its warnings, shown in the library
        state.setdefault("marked", [])    # [sentence, "underline" or "highlight"]: only these are cleared
        state.setdefault("reported_warnings", None)
        return state

    def save(self) -> None:

        HOME.mkdir(exist_ok=True)
        self.path.write_text(json.dumps(self.documents), encoding="utf-8")


def writing_part(text: str) -> str:

    """
    The document up to its reference list heading.
    """

    position = 0
    for line in re.split(r"[\r\n]", text):  # paragraphs end in \r (osascript reports \n)
        if line.strip() in HEADINGS:
            return text[:position]
        position += len(line) + 1
    return text


def finished_sentences(text: str) -> List[Dict]:

    """
    Every finished sentence long enough to carry a claim, with its position.
    """

    found = []
    # Hide abbreviation full stops behind a same-length stand-in, so positions don't change.
    masked = ABBREVIATIONS.sub(lambda m: m.group().replace(".", "\u2024"), writing_part(text))
    for match in SENTENCE.finditer(masked):
        sentence = match.group().strip().replace("\u2024", ".")
        if len(sentence.split()) < MIN_WORDS:
            continue
        start = match.start() + (len(match.group()) - len(match.group().lstrip()))
        found.append({"sentence": sentence, "start": start, "end": start + len(sentence)})
    return found


QUOTED = re.compile(r'"[^"]{3,}"|“[^”]{3,}”')


def not_noted(result: Dict) -> str:

    """
    A hint, not a warning: the supporting page isn't in the person's reading notes. Only given in
    projects that use notes; empty otherwise.
    """

    if result.get("label") != "supports" or result.get("noted") is not False:
        return ""
    where = f"page {result['page']} of " if result.get("page") else ""
    return f" Not in your notes: {where}{citations.clean_title(result.get('source') or {})}."


def notes_for(result: Dict, sentence: str = "") -> List[str]:

    """
    The comments a verdict deserves, the same wording as the other Referee apps.
    """

    if not result.get("match"):
        if not result.get("needs_source"):
            return []
        closest = "; ".join(citations.clean_title(c) for c in result.get("closest") or [])
        search = f" Look for evidence: {result['search']}" if result.get("search") else ""
        return [COMMENT_PREFIX + "This reads like a factual claim, but nothing you've read supports it yet."
                + (f" Closest in your reading: {closest}." if closest else "") + search]
    notes = []
    source = result.get("source") or {}
    if result["label"] == "supports" and QUOTED.search(sentence) and result.get("page") is None and result.get("time") is None:
        notes.append("Direct quotes need a page number, and this source has none. Add a paragraph number or section instead, e.g. (para. 4).")
    if source.get("retracted"):
        notes.append("This paper has been retracted. Check the retraction notice before relying on it.")
    if result["label"] == "contradicts":
        notes.append(f"Your source says otherwise: \"{result.get('quote')}\" ({citations.clean_title(source)})")
    if result.get("misquote"):
        notes.append(f"This quotation doesn't match the source exactly. The source says: \"{result.get('quote')}\"")
    if result.get("too_close"):
        notes.append("Very close to the source's wording. Consider quoting it or rephrasing.")
    for change in (result.get("changes") or [])[:3]:
        if change.get("wrote") and change.get("source"):
            notes.append(f"You quoted \"{change['wrote']}\"; the source says \"{change['source']}\".")
        elif change.get("wrote"):
            notes.append(f"\"{change['wrote']}\" isn't in the source's wording.")
        else:
            notes.append(f"You left out \"{change['source']}\".")
    for figure in result.get("wrong_numbers") or []:
        notes.append(f"\"{figure}\" doesn't appear in the source. Check the figure.")
    if result.get("together_with"):
        notes.append(f"This claim combines two sources: also cite {citations.clean_title(result['together_with'].get('source') or {})}.")
    if result.get("mixed"):
        notes.append(f"Mixed evidence: {citations.clean_title(result['mixed'])} points the other way.")
    year = re.match(r"\d{4}", str(source.get("date") or ""))
    if result["label"] == "supports" and year and time.localtime().tm_year - int(year.group()) > OLD_SOURCE_YEARS:
        notes.append(f"This source is from {year.group()}. Check whether newer evidence agrees.")
    return [COMMENT_PREFIX + note for note in notes]


class Helper:

    def __init__(self, word):

        self.word = word
        self.settings = Settings()
        self.state = DocumentState()
        self.last_text: Optional[str] = None
        self.last_ping = 0.0
        self.last_heartbeat = 0.0

    def post(self, path: str, body: Dict) -> Optional[Dict]:

        try:
            return requests.post(f"{SERVER}{path}", json=body, headers=HEADERS, timeout=30).json()
        except (requests.RequestException, ValueError):
            return None

    def step(self) -> None:

        # Let the app know the helper is running, whether or not Word is open.
        if time.time() - self.last_heartbeat > PING_SECONDS / 2:
            self.last_heartbeat = time.time()
            self.post("/helper", {})
        if not self.word.available():
            self.last_text = None
            return

        document = self.word.document()
        if document is None:
            return
        name, text = document
        if text != self.last_text:
            # Still typing: note it, and wait for a pause before checking anything.
            if self.last_text is not None and time.time() - self.last_ping > PING_SECONDS:
                self.last_ping = time.time()
                self.post("/writing", {})
            self.last_text = text
            return
        self.check(name, text)
        self.audit(name)
        self.follow_requests(name, text)

    def follow_requests(self, name: str, text: str) -> None:

        """
        Carries out requests from Referee's menu, left with the server: "clear-marks" removes the
        underlines or highlights Referee added in the document open in Word, leaving the person's own.
        """

        try:
            request = requests.get(f"{SERVER}/word/request", headers=HEADERS, timeout=5).json().get("request")
        except (requests.RequestException, ValueError):
            return
        if request != "clear-marks":
            return
        state = self.state.get(name)
        writing = writing_part(text)
        cleared = set()
        for sentence, how in state["marked"]:
            start = writing.find(sentence)
            if start == -1:
                continue
            if how == "underline":
                self.word.underline(start, start + len(sentence), "none")
            else:
                self.word.mark(start, start + len(sentence), "none")
            cleared.add(sentence.split(" (")[0])
        state["marked"] = []
        self.state.save()
        count = len(cleared)
        self.post("/word/request", {"request": "", "result": f"Removed Referee's marks from {count} sentence{'' if count == 1 else 's'}."})

    def audit(self, name: str) -> None:

        """
        Keeps checking the reference list against the text, and reports entries whose source is no
        longer cited, or that are missing a date or an author, to the library's Reference check.
        Nothing is written into the reference list itself: commenting there can hang Word.
        """

        document = self.word.document()
        if document is None:
            return
        state = self.state.get(name)
        writing = writing_part(document[1])
        issues = []
        for url, entry in state["entries"].items():
            source = state["cited"].get(url) or {}
            inserted = state["citations"].get(url, [])
            if inserted and not any(citation in writing for citation in inserted):
                issues.append({"entry": entry, "note": "No longer cited in the text: remove it from the reference list, or cite it again."})
            if not source.get("date"):
                issues.append({"entry": entry, "note": "No date found: check the source for one, or keep \"n.d.\"."})
            if not source.get("author"):
                issues.append({"entry": entry, "note": "No author found: check whether a person or organisation is named."})
        if issues != state.get("reported"):
            if self.post("/audit", {"document": Path(name).name, "issues": issues}) is not None:
                state["reported"] = issues
                self.state.save()

    def check(self, name: str, text: str) -> None:

        settings = self.settings.load()
        state = self.state.get(name)
        checked = set(state["checked"])
        finished = finished_sentences(text)
        self.post("/claims/order", {"document": Path(name).name, "sentences": [s["sentence"] for s in finished]})
        fresh = [s for s in finished if s["sentence"] not in checked]
        if not fresh:
            return

        results = []
        for item in fresh:
            result = self.post("/check", {"sentence": item["sentence"], "project": settings["project"],
                                          "document": Path(name).name})
            if result is None:
                return  # server not running: try again on the next pause
            results.append((item, result))

        # Edit from the end of the document backwards, so earlier positions stay valid.
        existing = {(start, note) for start, _, note in self.word.comments()}
        for item, result in sorted(results, key=lambda pair: -pair[0]["start"]):
            sentence, start, end = item["sentence"], item["start"], item["end"]
            if self.word.text_at(start, end) != sentence:
                continue  # the document moved under us: leave it for the next pause
            checked.add(sentence)
            notes = notes_for(result, sentence)
            for note in notes:
                if (start, note) not in existing:
                    self.word.comment(start, end, note)
            if notes:  # also listed in the library's Warnings card
                state["warnings"][sentence] = [note.removeprefix(COMMENT_PREFIX) for note in notes]
            if not result.get("match"):
                continue
            label = result["label"]
            warn = label == "misquote" or (label == "supports" and (result.get("misquote") or result.get("too_close")))
            kind = "warn" if warn else label if label in ("supports", "contradicts") else "warn"
            if settings["marks"] == "underline":
                self.word.underline(start, end, kind)
            elif settings["marks"] == "highlight":
                self.word.mark(start, end, kind)
            if settings["marks"] != "none":
                state["marked"].append([sentence, settings["marks"]])
            if label == "supports":
                suggested = self.preview(state, settings["style"], result)
                if suggested in sentence:  # typed in by the person: list it like any other citation
                    self.cite(state, settings["style"], result)
                    continue
                if not settings["auto_cite"]:
                    note = (f"Supported by {citations.clean_title(result.get('source') or {})}. "
                            f"Suggested citation: {suggested}. Type it at the end of the sentence and Referee adds the reference."
                            + not_noted(result))
                    if (start, note) not in existing:
                        self.word.comment(start, end, note)
                    continue
                cited = self.cite(state, settings["style"], result)
                if cited not in sentence:
                    punctuation = CLOSING.search(sentence)
                    position = end - (len(punctuation.group()) if punctuation else 0)
                    self.word.insert(position, f" {cited}")
                    with_citation = sentence[:position - start] + f" {cited}" + sentence[position - start:]
                    checked.add(with_citation)
                    if settings["marks"] != "none":
                        state["marked"].append([with_citation, settings["marks"]])

        state["checked"] = sorted(checked)
        self.update_references(state, settings["style"])
        self.report_warnings(name, state)
        document = self.word.document()
        if document is not None:  # reworded or deleted sentences leave the reports
            self.post("/claims/current", {"document": Path(name).name, "text": writing_part(document[1])})
        self.state.save()
        document = self.word.document()
        self.last_text = document[1] if document else None  # our own edits aren't typing

    def report_warnings(self, name: str, state: Dict) -> None:

        """
        Sends the warnings for sentences still in the document to the library's Warnings card.
        """

        document = self.word.document()
        if document is None:
            return
        writing = writing_part(document[1])
        current = {sentence: notes for sentence, notes in state["warnings"].items()
                   if sentence.rstrip(".!?\"”’)]") [:60] in writing}
        issues = [{"entry": sentence, "note": note} for sentence, notes in current.items() for note in notes]
        if issues != state.get("reported_warnings"):
            if self.post("/warnings", {"document": Path(name).name, "issues": issues}) is not None:
                state["reported_warnings"] = issues

    def preview(self, state: Dict, style: str, result: Dict) -> str:

        """
        The citation a source would get, without recording it as cited.
        """

        source = result.get("source") or {}
        url = source.get("url") or citations.clean_title(source)
        number = state["numbers"].get(url, len(state["numbers"]) + 1)
        return citations.in_text(style, source, number=number, page=result.get("page"), time=result.get("time"))

    def cite(self, state: Dict, style: str, result: Dict) -> str:

        source = result.get("source") or {}
        url = source.get("url") or citations.clean_title(source)
        state["cited"][url] = source
        state["numbers"].setdefault(url, len(state["numbers"]) + 1)
        citation = citations.in_text(style, source, number=state["numbers"][url],
                                     page=result.get("page"), time=result.get("time"))
        if citation not in state["citations"].setdefault(url, []):
            state["citations"][url].append(citation)
        return citation

    def update_references(self, state: Dict, style: str) -> None:

        """
        Adds entries for newly cited sources under a reference heading at the end.
        """

        sources = list(state["cited"].items())
        if style in citations.NUMBERED:
            sources.sort(key=lambda pair: state["numbers"][pair[0]])
        else:
            sources.sort(key=lambda pair: citations.sort_key(pair[1]))
        entries = [citations.reference(style, source, number=state["numbers"][url]) for url, source in sources]
        state["entries"].update({url: entry for (url, _), entry in zip(sources, entries)})
        new = [entry for entry in entries if entry not in state["listed"]]
        if not new:
            return
        document = self.word.document()
        if document is None:
            return
        has_heading = any(line.strip() in HEADINGS for line in re.split(r"[\r\n]", document[1]))
        block = "\r".join(new)
        if has_heading:
            self.word.append("\r" + block)
        else:
            self.word.page_break()  # Word's own page break: a typed one leaves Word fragile
            self.word.append(citations.HEADINGS[style] + "\r" + block)  # the heading starts the new page
        state["listed"].extend(new)


def driver():

    if sys.platform == "darwin":
        from mac import MacWord
        return MacWord()
    if sys.platform == "win32":
        from windows import WindowsWord
        return WindowsWord()
    raise SystemExit("The Word helper runs on macOS and Windows.")


LOCK_PORT = 8766  # only one helper may edit Word at a time: two at once can hang Word


def single_instance():

    """
    Claims a local port as a lock. A second helper finds it taken and stops, so two never edit
    the same document. The operating system releases it when the helper exits, even after a crash.
    """

    lock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    if sys.platform == "win32":
        lock.setsockopt(socket.SOL_SOCKET, socket.SO_EXCLUSIVEADDRUSE, 1)
    try:
        lock.bind(("127.0.0.1", LOCK_PORT))
    except OSError:
        raise SystemExit("Another Referee Word helper is already running.")
    return lock


def main() -> None:

    lock = single_instance()  # held for as long as the helper runs
    helper = Helper(driver())
    print("Referee Word helper running. It checks the document open in Word as you write.")
    while True:
        try:
            helper.step()
        except Exception as error:  # Word busy, a dialog open, a document closing: try again
            print(f"[helper] {type(error).__name__}: {error}", flush=True)
        time.sleep(POLL_SECONDS)


if __name__ == "__main__":
    main()
