import json
import threading
import time
from datetime import date
from pathlib import Path
from typing import Optional

import requests
import trafilatura
from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import HTMLResponse, JSONResponse, PlainTextResponse
from pydantic import BaseModel
 
import base64

from extract import extract_page
from pdf import extract_pdf, page_texts
from extract import make_passages, split_sentences
import fulltext
from video import extract_video
from metadata import enrich, lookup
from store import add_page, clear, expired, forget, keep, move, rename_project, replace, search, sources, stored_text
from reading import ReadingSettings
from verify import verify
from claims import needs_source
from feedback import FeedbackModel
import paths
import library
import bib
import statements
from meetings import Meetings
from ai_log import AILog
from notes import Notes
import todoist
import code_folder as code_check
import api_key
from claim_log import ClaimLog
from highlights import Highlights
from keywords import tokens
from urllib.parse import quote_plus
 
# Minimum similarity score before a passage is sent to Claude at all.
# Set this from the scores load_demo.py prints for your real demo sources.
MIN_SCORE = 0.5
HIGHLIGHT_SCORE = 0.4  # passages the person highlighted count with a little less similarity
CLOSEST_SCORE = 0.3  # loosely related reading worth suggesting for an unsupported claim

feedback = FeedbackModel(paths.data("feedback.json"))
claim_log = ClaimLog(paths.data("claims.json"))
highlights = Highlights(paths.data("highlights.json"))
reading = ReadingSettings(paths.data("reading.json"))


def forget_expired_reading():
    # Temporary reading (not saved for later, not cited) is forgotten after keep_minutes.
    while True:
        for url in expired(time.time() - reading.keep_minutes * 60):
            claim_log.forget(url)
            notes.forget_source(url)
            forget(url)
        time.sleep(60)


threading.Thread(target=forget_expired_reading, daemon=True).start()


class WritingSession:

    """
    Whether someone is writing right now. The Word helper pings while you type in Word;
    in automatic mode the browser extension captures reading while this is active.
    """

    ACTIVE_FOR = 5 * 60  # seconds after the last ping

    HELPER_FOR = 2 * 60  # the Word helper sends a heartbeat every 30 seconds while it runs

    def __init__(self):

        self.last_ping = 0.0
        self.last_helper = 0.0

    def ping(self):

        self.last_ping = time.time()

    def active(self):

        return time.time() - self.last_ping < self.ACTIVE_FOR

    def helper_running(self):

        return time.time() - self.last_helper < self.HELPER_FOR


writing = WritingSession()


class FocusMode:

    """
    Research mode switched on from outside the browser, e.g. by a macOS Focus through a
    Shortcuts automation. While it is on, the extension captures reading.
    """

    def __init__(self):

        self.on = False


focus = FocusMode()
 
app = FastAPI()

# Only Referee's own apps may call this server: the browser extension (the Mac app and the
# Word helper run on this computer and send no Origin).
# Any other website a person visits is refused, so it can't spend their API
# credit, wipe their reading or see what they've captured.
REFEREE_ORIGINS = r"^chrome-extension://[a-p]{32}$"
app.add_middleware(CORSMiddleware, allow_origin_regex=REFEREE_ORIGINS,
                   allow_methods=["*"], allow_headers=["*"])


@app.middleware("http")
async def referee_only(request: Request, call_next):
    # Browsers only let a page send the X-Referee header to another site if that site allows
    # it, which this one doesn't for ordinary websites. Requests without an Origin come from
    # programs on this computer (curl, scripts); http://localhost:8000 is the /docs page.
    origin = request.headers.get("origin")
    trusted = (
        request.method == "OPTIONS"
        or request.headers.get("x-referee") == "1"
        or origin is None
        or origin == "http://localhost:8000"
    )
    if not trusted:
        return JSONResponse({"error": "Only Referee's own apps can use this server."}, status_code=403)
    return await call_next(request)

 
 
class CaptureRequest(BaseModel):
    url: str
    html: str
    project: str = ""  # reading is kept per project; empty means any
 
 
class CheckRequest(BaseModel):
    sentence: str
    project: str = ""   # only check against this project's reading
    document: str = ""  # which piece of writing it's from, for the reports
 
 
class StatementRequest(BaseModel):
    statement: str     # LaTeX, maths included
    kind: str = "theorem"
    keys: list = []    # the citation keys it cites
    label: str = ""    # its optional title, e.g. "Bobrowski and Skraba, Conjecture 1"


class CurrentRequest(BaseModel):
    document: str = ""
    text: str = ""         # the whole document (Word): claims not in it are dropped
    removed: list = []     # sentences rewritten or deleted (Overleaf)


class CodeRequest(BaseModel):
    text: str          # the LaTeX being written


class CapturePdfRequest(BaseModel):
    url: str
    project: str = ""
    title: str = ""
    data: str  # the PDF file, base64-encoded


class CaptureVideoRequest(BaseModel):
    url: str
    project: str = ""


class ApiKeyRequest(BaseModel):
    key: str


class FocusRequest(BaseModel):
    on: bool


class KeepRequest(BaseModel):
    url: str
    project: str = ""


class SettingsRequest(BaseModel):
    project: str | None = None
    projects: list[str] | None = None
    keep_minutes: int | None = None
    links: dict[str, list[str]] | None = None


class RenameRequest(BaseModel):
    old: str
    new: str = ""  # empty: delete the project (its sources are kept, with no project)


class MoveRequest(BaseModel):
    url: str
    project: str = ""


class CaptureUrlRequest(BaseModel):
    url: str


class FeedbackRequest(BaseModel):
    event: str            # "opened_source" | "edited_after" | "dismissed" | "ignored"
    sentence: str = ""
    url: str = ""
    label: str = ""
    confidence: float = 0
    score: float = 0
 
 
@app.get("/")
def health():
    return {"status": "Referee server running"}
 
 
def stamp(metadata, project):
    metadata["captured_at"] = date.today().isoformat()  # APA access date
    metadata["captured_ts"] = time.time()                # for expiring temporary reading
    metadata["project"] = project or reading.project or None
    metadata["kept"] = False                             # temporary until saved or cited


def with_abstract(metadata, texts, pages=None):
    # The abstract from the DOI lookup goes first, unless the text already has it: abstracts carry
    # a paper's main claims, which are what writing most often cites.
    abstract = metadata.pop("abstract", None)
    if not abstract or abstract[:80].lower() in " ".join(" ".join(texts[:8]).split()).lower():
        return texts, pages
    extra = make_passages(split_sentences(abstract))
    return extra + texts, ([1] * len(extra) + pages) if pages else None


@app.post("/capture")
def capture(req: CaptureRequest):
    try:
        text, metadata, passages = extract_page(req.html, url=req.url)
    except ValueError as e:
        return {"ok": False, "reason": str(e)}
    enrich(metadata, req.html)  # exact details for academic pages, from their DOI
    if len(text.split()) < fulltext.MIN_WORDS and (metadata.get("doi") or fulltext.arxiv_id(req.url)):
        # An abstract page (arXiv, a journal's landing page): read the whole paper instead.
        better = fulltext.find(req.url, text, metadata.get("title"), metadata.get("doi"))
        if better and make_passages(split_sentences(better[0])):
            passages, metadata["text_from"] = make_passages(split_sentences(better[0])), better[1]
    passages, _ = with_abstract(metadata, passages)
    stamp(metadata, req.project)
    added = add_page(metadata, passages)
    if added == 0:
        return {"ok": True, "passages": 0, "already_captured": True}
    return {"ok": True, "passages": added}
 
 
@app.post("/capture-pdf")
def capture_pdf(req: CapturePdfRequest):
    data = base64.b64decode(req.data)
    try:
        metadata, passages = extract_pdf(data, url=req.url)
    except ValueError as e:
        return {"ok": False, "reason": str(e)}
    if req.title and not metadata.get("title"):
        metadata["title"] = req.title
    enrich(metadata, " ".join(text for text, _ in passages[:5]))
    stamp(metadata, req.project)
    texts, pages = [text for text, _ in passages], [page for _, page in passages]
    # PDF text scrambles maths: use the paper's LaTeX or HTML version when there is one.
    better = fulltext.passages(req.url, page_texts(data), metadata.get("title"), metadata.get("doi"))
    if better:
        texts, pages, metadata["text_from"] = better
    texts, pages = with_abstract(metadata, texts, pages)
    added = add_page(metadata, texts, pages=pages)
    if added == 0:
        return {"ok": True, "passages": 0, "already_captured": True}
    return {"ok": True, "passages": added}


@app.post("/capture-video")
def capture_video(req: CaptureVideoRequest):
    try:
        metadata, passages = extract_video(req.url)
    except ValueError as e:
        return {"ok": False, "reason": str(e)}
    stamp(metadata, req.project)
    added = add_page(metadata, [text for text, _ in passages], times=[time for _, time in passages])
    if added == 0:
        return {"ok": True, "passages": 0, "already_captured": True}
    return {"ok": True, "passages": added}


def log_unsupported(sentence, unsupported, project, document):
    # Claims that need a source are logged too, for the pre-submission report and research trail.
    if unsupported["needs_source"]:
        claim_log.record(sentence, {"label": "needs_source", "closest": unsupported["closest"]}, project, document)
    return unsupported


def scholar_search(sentence):
    """A Google Scholar search for the sentence's key terms: a place to look, not text to use."""
    terms = [t for t in tokens(sentence) if len(t) > 3 and not t.isdigit()][:8]
    return "https://scholar.google.com/scholar?q=" + quote_plus(" ".join(terms)) if terms else None


def closest_sources(results, limit=3):
    seen, closest = set(), []
    for r in results:
        url = r["source"].get("url")
        if url in seen or r["score"] < CLOSEST_SCORE:
            continue
        seen.add(url)
        closest.append({"title": r["source"].get("title"), "url": url, "page": r.get("page"), "time": r.get("time")})
    return closest[:limit]


@app.post("/check")
def check(req: CheckRequest):
    sentence = req.sentence.strip()
    if len(sentence.split()) < 5:          # too short to carry a real claim
        return {"match": False}
 
    project = req.project or reading.project or None
    results = search(sentence, k=5, projects=reading.allowed(project))  # 3 missed the best passage in testing
    # Passages the person highlighted while reading go first, and count with a slightly lower
    # similarity: what they marked as important is most likely what they're citing.
    for r in results:
        r["highlighted"] = highlights.overlaps(r["source"].get("url"), r["text"])
    results.sort(key=lambda r: not r["highlighted"])

    # No supporting reading: say whether the sentence reads like a claim that needs one, and
    # which sources already read come closest, as places to look. Nothing is written for them.
    unsupported = {"match": False, "needs_source": needs_source(sentence), "closest": closest_sources(results),
                   "search": scholar_search(sentence)}
    candidates = [r for r in results if r["score"] >= (HIGHLIGHT_SCORE if r["highlighted"] else MIN_SCORE)]
    if not candidates:
        return log_unsupported(sentence, unsupported, project, req.document)

    verdict = verify(sentence, candidates)
    if verdict is None:
        return log_unsupported(sentence, unsupported, project, req.document)
    if not feedback.should_show(verdict):  # this person keeps rejecting markers like this
        return {"match": False}
    claim_log.record(sentence, verdict, project, req.document)  # for the library and reports
    if verdict.get("label") == "supports" and verdict.get("source", {}).get("url"):
        # Supported from a page with no reading note, in a project that uses notes: a nudge.
        verdict["noted"] = notes.noted(verdict["source"]["url"], verdict.get("page"), project)
    if verdict.get("label") == "supports" and verdict.get("source", {}).get("url"):
        keep(verdict["source"]["url"])  # cited sources are kept automatically
    # verdict includes "label": "supports" or "contradicts" - Word handles both
    return {"match": True, **verdict}
 
 
@app.post("/statement")
def check_statement(req: StatementRequest):
    # A theorem or definition taken from a paper, compared with the paper itself.
    result = statements.check(req.statement, req.kind, req.keys, req.label)
    if result.get("found") and result.get("source", {}).get("url"):
        # Cited from a page with no note: worth a nudge to check it's been read.
        result["noted"] = notes.noted(result["source"]["url"], result.get("page"), reading.project or "")
    return result


meetings = Meetings(paths.data("meetings.json"))


notes = Notes(paths.data("notes.json"))


@app.get("/notes")
def list_notes(project: str = "all"):
    return notes.all(library_project(project))


@app.post("/notes")
def save_note(note: dict):
    return notes.save(note)


@app.delete("/notes")
def delete_note(id: str):
    return {"ok": notes.delete(id)}


todoist_sync = todoist.Sync(meetings)
todoist_sync.start()


@app.get("/todoist")
def todoist_status():
    return todoist_sync.status()


@app.post("/todoist")
def todoist_connect(body: dict):
    # Checks and saves a Todoist token, then syncs your action points straight away.
    result = todoist.connect(body.get("token", ""))
    if result["ok"]:
        todoist_sync.soon()
    return result


@app.delete("/todoist")
def todoist_disconnect():
    todoist.disconnect()
    return {"ok": True}


@app.post("/todoist/sync")
def todoist_sync_now():
    todoist_sync.soon()
    return {"ok": True}


@app.get("/meetings")
def list_meetings(project: str = "all"):
    return meetings.all(library_project(project))


@app.post("/meetings")
def save_meeting(meeting: dict):
    saved = meetings.save(meeting)
    todoist_sync.soon()  # new, changed or ticked-off action points reach Todoist straight away
    return saved


@app.delete("/meetings")
def delete_meeting(id: str):
    return {"ok": meetings.delete(id)}


@app.get("/meetings/workspace")
def meeting_workspace(project: str):
    return {"folder": meetings.workspaces.get(project, "")}


@app.post("/meetings/workspace")
def set_meeting_workspace(body: dict):
    # Links a project to its shared workspace: its notes/ files are then kept up to date there.
    return meetings.set_workspace(body.get("project", ""), body.get("folder", ""))


@app.get("/meetings/export", response_class=PlainTextResponse)
def export_meetings(project: str = "all", format: str = "markdown"):
    # A project's meeting log to share: Markdown for Teams or a document, LaTeX for Overleaf.
    return meetings.export(library_project(project), format)


ai_log = AILog(paths.data("ai-log.json"))


def referee_checks(project):
    # How many claims Referee checked in this project, for the declaration.
    return sum(1 for c in claim_log.claims() if project is None or (c.get("project") or "") == project)


@app.get("/ai-log")
def list_ai_use(project: str = "all"):
    return ai_log.all(library_project(project))


@app.post("/ai-log")
def save_ai_use(entry: dict):
    return ai_log.save(entry)


@app.delete("/ai-log")
def delete_ai_use(id: str):
    return {"ok": ai_log.delete(id)}


@app.get("/ai-log/declaration")
def ai_declaration(project: str = "all"):
    chosen = "*" if project == "all" else library_project(project)  # all projects: the default wording
    own = chosen == "*" or chosen in ai_log.templates
    return {"text": ai_log.declaration(chosen, referee_checks(None if chosen == "*" else chosen)),
            **ai_log.template(chosen), "own": own}


@app.post("/ai-log/template")
def set_ai_template(body: dict):
    # A project's declaration wording: a preset ("standard", "paragraph") or custom text with
    # {tools}, {system}, {purposes} and {checks} filled in from the log.
    project = body.get("project", "all")
    return ai_log.set_template("*" if project == "all" else library_project(project), body.get("preset", "custom"),
                               body.get("used", ""), body.get("unused", ""))


@app.get("/ai-log/export", response_class=PlainTextResponse)
def export_ai_use(project: str = "all", format: str = "markdown"):
    chosen = library_project(project)
    return ai_log.export(chosen, format, referee_checks(chosen))


@app.post("/claims/current")
def current_claims(req: CurrentRequest):
    # Keeps reports to what's written now: drafts and deleted sentences leave the claim log.
    dropped = claim_log.forget_sentences(req.removed)
    if req.text and req.document:
        dropped += claim_log.keep_present(req.document, req.text)
    return {"ok": True, "dropped": dropped}


@app.post("/code")
def check_code(req: CodeRequest):
    # The writing against the code folder chosen in settings: uncited libraries, stale figures.
    return code_check.check(req.text)


@app.post("/feedback")
def record_feedback(req: FeedbackRequest):
    return {"ok": feedback.record(req.model_dump())}


@app.get("/feedback")
def feedback_summary():
    return feedback.summary()


@app.post("/feedback/reset")
def reset_feedback():
    feedback.reset()
    return {"ok": True}


@app.post("/writing")
def writing_ping():
    writing.ping()
    return {"ok": True}


@app.get("/writing")
def writing_status():
    return {"active": writing.active(), "focus": focus.on, "helper": writing.helper_running(),
            "api_key": api_key.status()["has_key"]}


class WordRequest(BaseModel):
    request: str = ""
    result: str = ""


class WordRequests:

    """
    A request from Referee's menu for the Word helper (which is the only part that edits Word),
    and the helper's reply once it's done.
    """

    def __init__(self):

        self.request = ""
        self.result = ""


word_requests = WordRequests()


@app.post("/word/request")
def set_word_request(req: WordRequest):
    word_requests.request = req.request
    if req.result or req.request:
        word_requests.result = req.result
    return {"ok": True}


@app.get("/word/request")
def get_word_request():
    return {"request": word_requests.request, "result": word_requests.result}


@app.post("/helper")
def helper_heartbeat():
    # The background Word helper is running (the app shows a warning when it isn't).
    writing.last_helper = time.time()
    return {"ok": True}


@app.get("/api-key")
def api_key_status():
    return api_key.status()


@app.post("/api-key")
def api_key_save(req: ApiKeyRequest):
    return api_key.save(req.key)


@app.delete("/api-key")
def api_key_remove():
    return api_key.remove()


@app.post("/focus")
def set_focus(req: FocusRequest):
    focus.on = req.on
    return {"ok": True, "focus": focus.on}


@app.get("/sources")
def list_sources():
    found = sources()
    cite_keys = bib.keys(found)
    return [{**s, "cite_key": cite_keys.get(s.get("url"))} for s in found]


@app.delete("/sources")
def forget_source(url: str):
    claim_log.forget(url)
    notes.forget_source(url)
    highlights.forget(url)
    return {"ok": True, "removed": forget(url)}


@app.post("/sources/forget-temporary")
def forget_temporary():
    # Everything not saved for later or cited, now rather than when it expires.
    urls = expired(time.time() + 1)
    for url in urls:
        claim_log.forget(url)
        notes.forget_source(url)
        forget(url)
    return {"ok": True, "forgotten": len(urls)}


@app.post("/sources/keep")
def keep_source(req: KeepRequest):
    # "Save for later": kept permanently, in the given or current project.
    return {"ok": keep(req.url, req.project or reading.project or None)}


@app.post("/sources/move")
def move_source(req: MoveRequest):
    return {"ok": move(req.url, req.project or None)}


@app.post("/projects/rename")
def rename_project_route(req: RenameRequest):
    new = req.new.strip()
    rename_project(req.old, new or None)
    claim_log.rename_project(req.old, new or None)
    meetings.rename_project(req.old, new or None)
    notes.rename_project(req.old, new or None)
    ai_log.rename_project(req.old, new or None)
    return reading.rename(req.old, new)


@app.get("/settings")
def get_settings():
    # Plus the Overleaf panel's settings, chosen in Referee's Settings (~/.referee/config.json).
    try:
        config = json.loads((Path.home() / ".referee" / "config.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        config = {}
    return {**reading.as_dict(), "overleaf_auto_cite": bool(config.get("overleaf_auto_cite", False))}


@app.post("/settings")
def set_settings(req: SettingsRequest):
    return reading.update(req.model_dump(exclude_none=True))


def library_project(project: Optional[str]):
    # "all" (or nothing): every source; "none": sources with no project; otherwise that project.
    return None if project in (None, "", "all") else "" if project == "none" else project


class AuditRequest(BaseModel):
    document: str
    issues: list[dict]


class Audits:

    """
    Findings from the Word helper for each document (its reference check, or its warnings),
    shown in the library.
    """

    def __init__(self, path):

        self.path = path
        try:
            self.documents = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            self.documents = {}

    def save(self, document, issues):

        if issues:
            self.documents[document] = {"issues": issues, "at": time.time()}
        else:
            self.documents.pop(document, None)
        self.path.write_text(json.dumps(self.documents), encoding="utf-8")


audits = Audits(paths.data("audits.json"))


@app.post("/audit")
def save_audit(req: AuditRequest):
    audits.save(req.document, req.issues)
    return {"ok": True}


@app.get("/audit")
def list_audits():
    return audits.documents


warnings_found = Audits(paths.data("warnings.json"))


@app.post("/warnings")
def save_warnings(req: AuditRequest):
    # The Word helper's warnings for each document (contradictions, misquotes and so on).
    warnings_found.save(req.document, req.issues)
    return {"ok": True}


@app.get("/warnings")
def list_warnings():
    return warnings_found.documents


@app.get("/references")
def list_references(project: str = "all", style: str = "apa"):
    return library.references(sources(), claim_log.claims(), library_project(project), style)


class ImportRequest(BaseModel):
    text: str  # a BibTeX or RIS file


@app.get("/export", response_class=PlainTextResponse)
def export_sources(format: str = "bibtex", project: str = "all"):
    # Saved sources in the chosen project, as a BibTeX or RIS file (Zotero reads both).
    chosen = library_project(project)
    kept = [s for s in sources() if s.get("kept") is not False and library.in_project(s.get("project"), chosen)]
    return bib.ris(kept) if format == "ris" else bib.bibtex(kept, bib.keys(sources()))


@app.post("/import")
def import_sources(req: ImportRequest):
    # Each entry is fetched through its link, DOI or arXiv ID and saved like Add Source.
    added, failed = 0, []
    for entry in bib.entries(req.text):
        if not entry.get("link"):
            failed.append(f"{entry['title']} (no link, DOI or arXiv ID)")
            continue
        result = add_url(CaptureUrlRequest(url=entry["link"]))
        if result.get("ok"):
            added += 1
        else:
            failed.append(f"{entry['title']} ({result.get('reason') or 'couldn’t be read'})")
    return {"ok": True, "added": added, "failed": failed}


@app.get("/presubmission", response_class=HTMLResponse)
def before_you_submit(project: str = "all"):
    return library.presubmission(sources(), claim_log.claims(), library_project(project))


@app.get("/trail", response_class=HTMLResponse)
def research_trail(project: str = "all"):
    return library.trail(sources(), claim_log.claims(), highlights.notes, library_project(project))


@app.get("/report", response_class=HTMLResponse)
def proof_of_work(project: str = "all", style: str = "apa"):
    return library.report(sources(), claim_log.claims(), library_project(project), style)


class HighlightRequest(BaseModel):
    url: str
    text: str


@app.post("/highlights")
def add_highlight(req: HighlightRequest):
    return {"ok": highlights.add(req.url, req.text)}


@app.get("/highlights")
def list_highlights(url: str = ""):
    return highlights.for_url(url) if url else highlights.notes


@app.get("/claims")
def list_claims(project: str = ""):
    return claim_log.claims(project or None)


@app.post("/clear")
def clear_store():
    clear()
    claim_log.clear()
    highlights.clear()
    return {"ok": True}
 
 
class AddPdfRequest(BaseModel):
    name: str
    data: str  # the PDF file, base64-encoded


# --- Adding sources by hand (the Mac app's Add Source): saved straight into the current
# project, so Referee works without the browser extension. ---
@app.post("/sources/add-url")
def add_url(req: CaptureUrlRequest):
    url = req.url.strip()
    if not url.startswith(("http://", "https://")):
        url = "https://" + url
    if ("youtube.com/" in url or "youtu.be/" in url):
        result = capture_video(CaptureVideoRequest(url=url))
    else:
        # Look at what comes back, not the link: many PDF links (arXiv, journals) don't end in .pdf.
        try:
            response = requests.get(url, timeout=30, headers={"User-Agent": "Mozilla/5.0 (Macintosh) Referee"})
        except requests.RequestException:
            return {"ok": False, "reason": "Couldn't open that link."}
        if not response.ok:
            return {"ok": False, "reason": f"The site answered {response.status_code}. Some sites block programs; save it from the browser instead."}
        if "pdf" in response.headers.get("content-type", "").lower() or response.content[:5] == b"%PDF-":
            result = capture_pdf(CapturePdfRequest(url=url, data=base64.b64encode(response.content).decode()))
        else:
            result = capture(CaptureRequest(url=url, html=response.text))
    if result.get("ok"):
        keep(url, reading.project or None)
    return result


@app.post("/sources/reread")
def reread(req: CaptureUrlRequest):
    # Reads a saved paper again, with the maths kept, replacing its old text. Its project, saved
    # state, highlights and checked claims stay as they were.
    source = next((s for s in sources() if s.get("url") == req.url), None)
    if source is None:
        return {"ok": False, "reason": "That source isn't saved."}
    texts, pages, where = None, None, None
    if req.url.startswith("http"):
        try:
            response = requests.get(req.url, timeout=30, headers=fulltext.HEADERS)
            content = response.content if response.ok else b""
            kind = response.headers.get("content-type", "").lower()
        except requests.RequestException:
            content, kind = b"", ""
        if content[:5] == b"%PDF-" or "pdf" in kind:
            better = fulltext.passages(req.url, page_texts(content), source.get("title"), source.get("doi"))
            if better:
                texts, pages, where = better
            else:
                found = extract_pdf(content, url=req.url)[1]
                texts, pages, where = [t for t, _ in found], [p for _, p in found], "PDF"
        else:
            better = fulltext.find(req.url, "", source.get("title"), source.get("doi"))
            if better:
                texts, where = make_passages(split_sentences(better[0])), better[1]
            elif content:
                try:
                    texts, where = extract_page(content.decode("utf-8", errors="ignore"), url=req.url)[2], "web page"
                except ValueError:
                    pass
    if not texts and source.get("doi"):
        # The site blocks programs: keep the saved text, adding the abstract if it's missing.
        texts, pages, where = stored_text(req.url), None, source.get("text_from") or "earlier copy"
    if not texts:
        return {"ok": False, "reason": "Couldn't read it again. Save it from the browser instead."}
    details = lookup(source["doi"]) if source.get("doi") else {}
    texts, pages = with_abstract(details, texts, pages)
    count = replace(req.url, texts, pages, {"text_from": where})
    return {"ok": True, "passages": count, "text_from": where}


@app.post("/sources/add-pdf")
def add_pdf(req: AddPdfRequest):
    url = f"file://{req.name}"
    result = capture_pdf(CapturePdfRequest(url=url, title=Path(req.name).stem, data=req.data))
    if result.get("ok"):
        keep(url, reading.project or None)
    return result


# --- Debug only: capture by URL so you can test from /docs without the extension ---
@app.post("/debug/capture-url")
def capture_url(req: CaptureUrlRequest):
    html = trafilatura.fetch_url(req.url)
    if html is None:
        return {"ok": False, "reason": "Could not fetch that URL."}
    return capture(CaptureRequest(url=req.url, html=html))