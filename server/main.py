import json
import re
import uuid
import threading
import time
from datetime import date
from pathlib import Path
from typing import List, Optional

import requests
import trafilatura
from fastapi import FastAPI, Query, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, HTMLResponse, JSONResponse, PlainTextResponse
from pydantic import BaseModel
 
import base64

from extract import extract_page
from pdf import extract_pdf, page_texts
from extract import make_passages, split_sentences
import fulltext
from video import extract_video
from metadata import enrich, lookup
from store import add_page, clear, expired, forget, keep, move, passages_of, put_back, rename_project, replace, search, sources, stored_text, update_source
from reading import ReadingSettings
from verify import verify
from claims import needs_source
from feedback import FeedbackModel
import paths
import library
import bib
import citations
import statements
from meetings import Meetings
from ai_log import AILog
from notes import Notes
import todoist
import tasks
import notion
import obsidian
import zotero
import privacy
from maths_html import with_maths
import backups
import phone_sync
import statement_lookup
import ocr
import undo
import history
import note_import
import page_crop
import trail_archive
import pairing
import code_folder as code_check
import writing_folder
import local_models
import cloud_models
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
REFEREE_ORIGINS = r"^(chrome-extension://[a-p]{32}|https://[a-z0-9-]+-script\.googleusercontent\.com)$"
# The Google Docs add-on's panel runs on Google's script pages. Any Apps Script page could ask
# from there, so those requests need the pairing code shown in Referee's Settings as well.
GOOGLE_SCRIPT = re.compile(r"^https://[a-z0-9-]+-script\.googleusercontent\.com$")
app.add_middleware(CORSMiddleware, allow_origin_regex=REFEREE_ORIGINS,
                   allow_methods=["*"], allow_headers=["*"])


@app.middleware("http")
async def referee_only(request: Request, call_next):
    # Browsers only let a page send the X-Referee header to another site if that site allows
    # it, which this one doesn't for ordinary websites. Requests without an Origin come from
    # programs on this computer (curl, scripts); http://localhost:8000 is the /docs page.
    origin = request.headers.get("origin")
    if origin and GOOGLE_SCRIPT.match(origin) and request.method != "OPTIONS":
        if not pairing.matches(request.headers.get("x-referee-pairing", "")):
            # With CORS headers, so the add-on can tell a wrong code from Referee not running.
            return JSONResponse({"error": "Pair the Google Docs add-on in Referee's Settings."}, status_code=403,
                                headers={"Access-Control-Allow-Origin": origin, "Vary": "Origin"})
        return await call_next(request)
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


ORDER_FILE = paths.data("document-order.json")   # document -> its sentences, in the order written


@app.post("/claims/order")
def claims_order(body: dict):
    # The panels (Overleaf, Google Docs) and the Word helper send a document's sentences in order each time
    # they read it, so Evidence lists its claims in the order they appear. No AI: only remembered.
    document, order = str(body.get("document", "")), [str(x) for x in body.get("sentences") or []][:5000]
    if not document:
        return {"ok": False}
    try:
        saved = json.loads(ORDER_FILE.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        saved = {}
    if saved.get(document) != order:
        saved[document] = order
        ORDER_FILE.write_text(json.dumps(saved), encoding="utf-8")
    return {"ok": True}


@app.get("/claims/order")
def claims_order_get(document: str):
    try:
        return json.loads(ORDER_FILE.read_text(encoding="utf-8")).get(document, [])
    except (OSError, ValueError):
        return []


def usual_source(document: str, sentence: str) -> Optional[str]:
    # The source backing most of this document's other claims, when one does (at least two of them).
    if not document:
        return None
    counts = {}
    for c in claim_log.claims():
        if c.get("document") == document and c.get("sentence") != sentence and c.get("label") == "supports":
            url = (c.get("source") or {}).get("url")
            if url:
                counts[url] = counts.get(url, 0) + 1
    best = max(counts.items(), key=lambda kv: kv[1], default=(None, 0))
    return best[0] if best[1] >= 2 else None


@app.post("/check")
def check(req: CheckRequest):
    sentence = req.sentence.strip()
    if len(sentence.split()) < 5:          # too short to carry a real claim
        return {"match": False}
    if not_claims.has(sentence):           # marked "Ignore" by the person
        return {"match": False}
 
    project = req.project or reading.project or None
    results = search(sentence, k=5, projects=reading.allowed(project))  # 3 missed the best passage in testing
    # With maths in the sentence, also search its words alone: the notation ($v_1,\dots,v_n$) pulled in
    # passages that share the letters, and a definition written with other letters (a_1, ..., a_n)
    # was missed. The best of those join the candidates.
    words = re.sub(r"\$[^$]*\$|\\\(.*?\\\)", " ", sentence)
    if words != sentence and len(words.split()) >= 4:
        seen = {(r["source"].get("url"), r["text"]) for r in results}
        extra = [r for r in search(words, k=3, projects=reading.allowed(project))
                 if (r["source"].get("url"), r["text"]) not in seen]
        results += extra[:2]
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
    # Backed by a different source from the one the rest of this document relies on (a second set of
    # notes defining the same thing): if the document's own source backs it too, that one is used, so
    # one document cites its definitions from one place.
    usual = usual_source(req.document, sentence)
    if verdict and verdict.get("label") == "supports" and usual and verdict.get("source", {}).get("url") != usual:
        own = [r for r in search(sentence, k=5, urls={usual}) if r["score"] >= MIN_SCORE]
        if words != sentence and len(words.split()) >= 4:
            own += [r for r in search(words, k=3, urls={usual}) if r["score"] >= MIN_SCORE and r not in own][:2]
        again = verify(sentence, own) if own else None
        if again and again.get("label") == "supports":
            verdict = again
    if verdict is None:
        return log_unsupported(sentence, unsupported, project, req.document)
    if not feedback.should_show(verdict):  # this person keeps rejecting markers like this
        return {"match": False}
    claim_log.record(sentence, verdict, project, req.document)  # for the library and reports
    if verdict.get("label") == "supports" and verdict.get("source", {}).get("url"):
        # Supported from a page with no reading note, in a project that uses notes: a nudge.
        verdict["noted"] = notes.noted(verdict["source"]["url"], verdict.get("page"), project)
    if verdict.get("label") == "supports" and verdict.get("source", {}).get("url"):
        verdict["cite"] = in_text_citation(verdict["source"], verdict.get("page"))
        # "Definition 4.42": lets the panel count neighbouring sentences on one statement as one claim.
        verdict["statement"] = statement_for(verdict["source"]["url"], verdict.get("quote") or "", verdict.get("page")) or ""
        keep(verdict["source"]["url"])  # cited sources are kept automatically
    # verdict includes "label": "supports" or "contradicts" - Word handles both
    return {"match": True, **verdict}
 
 
def in_text_citation(source: dict, page=None) -> str:
    # The in-text citation in the chosen style, for editors where Referee can't type it in
    # (Google Docs): numbered styles need the reference list's numbering, so those get the name.
    try:
        style = json.loads((Path.home() / ".referee" / "config.json").read_text(encoding="utf-8")).get("style", "apa")
    except (OSError, ValueError):
        style = "apa"
    source = next((s for s in sources() if s.get("url") == source.get("url")), source)
    if style in citations.NUMBERED:
        return citations.clean_title(source)
    return citations.in_text(style, source, page=page)


# Obsidian vaults and R Markdown or Quarto files in the writing folder chosen in Settings.
writing_files = writing_folder.Watcher(
    paths.data("writing_folder.json"),
    check=lambda sentence, document: check(CheckRequest(sentence=sentence, document=document)),
    forget=lambda removed: claim_log.forget_sentences(removed),
)


@app.on_event("startup")
def watch_writing_folder():
    writing_files.start()  # once everything above and below has loaded


@app.get("/ai-provider")
def get_ai_provider():
    # Which model checks claims, which local ones this computer has, and which keys are saved.
    return {**local_models.status(), "cloud": cloud_models.status()}


@app.post("/ai-key/{provider}")
def set_ai_key(provider: str, body: dict):
    # An OpenAI key: checked with the provider, then kept in the password store.
    if provider not in cloud_models.PROVIDERS:
        return {"ok": False, "reason": "Unknown provider."}
    return cloud_models.connect(provider, body.get("key", ""))


@app.delete("/ai-key/{provider}")
def delete_ai_key(provider: str):
    if provider in cloud_models.PROVIDERS:
        cloud_models.disconnect(provider)
    return {"ok": True}


@app.get("/writing-folder")
def get_writing_folder():
    return writing_files.summary()


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


def source_title(url: str) -> str:
    # The name shown for a saved source: the one the person gave it, or its title.
    saved = next((s for s in sources() if s.get("url") == url), {})
    return saved.get("name") or saved.get("title") or url


# Notes and meetings written into an Obsidian vault, when a folder is chosen in Settings.
obsidian_export = obsidian.Export(notes, meetings, source_title)


@app.on_event("startup")
def export_to_obsidian():
    obsidian_export.start()


@app.get("/source-file")
def source_file(url: str, request: Request):
    # A saved PDF from this computer, so a note can open it at its page: macOS drops "#page="
    # when it opens a file:// link, but keeps it for http://localhost. Only PDFs in the library.
    # Only as a whole page in a tab (whoever opened it: a note, the extension's reload), never
    # embedded in another site's frame or fetched by a script, which could expose it.
    if request.headers.get("sec-fetch-dest", "document") != "document":
        return JSONResponse({"error": "Open this link directly."}, status_code=403)
    saved = next((s for s in sources() if s.get("url") == url), None)
    path = Path(url[len("file://"):]) if url.startswith("file://") else None
    if not saved or not path or path.suffix.lower() != ".pdf" or not path.is_file():
        return JSONResponse({"error": "That isn't a PDF saved in Referee."}, status_code=404)
    return FileResponse(path, media_type="application/pdf", headers={"Content-Disposition": "inline"})


def page_link(url: str, page: Optional[int]) -> str:

    # Where a saved source opens at a page: a PDF from this computer through /source-file (macOS
    # drops "#page=" from file:// links), anything else as it is.
    target = f"http://localhost:8000/source-file?url={quote_plus(url)}" if url.startswith("file://") else url
    return f"{target}#page={page}" if page else target


@app.get("/open", response_class=HTMLResponse)
def open_source(url: str, page: Optional[int] = None):
    # A note's link to a source page. The browser extension sees it first: if the source is already
    # open in a tab, it switches to that tab at the page and closes this one. Without the extension,
    # this page opens the source at the page itself. Only sources saved in Referee.
    if not any(s.get("url") == url for s in sources()):
        return HTMLResponse("That source isn't saved in Referee.", status_code=404)
    target = json.dumps(page_link(url, page))
    return HTMLResponse(f"""<!doctype html><meta charset=utf-8><title>Opening…</title>
<body style="font:14px -apple-system,sans-serif;color:#888;background:#1c1c1e">Opening…
<script>setTimeout(() => location.replace({target}), 400)</script>""")


@app.get("/notes")
def list_notes(project: str = "all"):
    return notes.all(library_project(project))


@app.post("/notes")
def save_note(note: dict):
    versions.replaced("note", next((n for n in notes.items if n["id"] == note.get("id")), None), note)
    return notes.save(note)


class PassageNote(BaseModel):
    label: str      # what the passage states, as numbered in the source: "Definition 5.1", "Theorem 4.53"; "" if none
    summary: str    # one short line saying what it states, maths in $LaTeX$


PASSAGE_NOTE = (
    "You turn a passage from someone's reading into one line for their study notes, in their style. "
    "label: the numbered statement the passage gives, exactly as numbered (\"Definition 5.1\", \"Theorem 4.53(b)\"), "
    "or \"\" if it states none. summary: what it says, in a short plain phrase, lower case, maths in $...$ LaTeX, "
    "no full stop. Examples of their lines: \"in a finite dimensional space, any linearly independent set can be "
    "completed to a basis\"; \"the span of $v_1, \\dots, v_n$, the set of all their linear combinations\"; "
    "\"if $\\dim V = n$, any $n$ linearly independent vectors span $V$\". Summarise only what the passage states."
)


def own_line(statement: Optional[str]) -> str:
    # The start of the person's own line: "- **Definition 5.1**: ", for them to finish.
    return f"- **{statement}**: " if statement else "- "


NOTE_FEEDBACK = (
    "Someone has written a short note summarising a passage from their reading, as part of learning it. "
    "Compare their note with the passage. Say, briefly, whether it's accurate, and point out anything wrong, "
    "missing that matters (a hypothesis, a condition such as 'not all zero', a quantifier), or too vague. Ask "
    "about gaps rather than filling them in: never write the correct version for them or rewrite their note. "
    "If it's accurate and complete, say so in one line. At most four short sentences, plain text, maths in $...$."
)


@app.post("/notes/check")
def check_note(body: dict):
    # Notes → right-click → Check My Summary: Claude compares the person's own lines with the passage quoted
    # in the note (or, if none, the statement it names on its page) and says what's wrong or missing.
    # It never writes the summary for them.
    from verify import anthropic_client, MODEL
    note = next((n for n in notes.items if n["id"] == body.get("id")), None)
    if not note:
        return {"feedback": "That note wasn't found."}
    lines = (note.get("body") or "").splitlines()
    mine = "\n".join(l for l in lines if not l.lstrip().startswith(">")).strip()
    passage = "\n".join(l.lstrip()[1:].strip() for l in lines if l.lstrip().startswith(">")).strip()
    if not passage:
        attachment = (note.get("attachments") or [{}])[0]
        found = []   # every statement the note names, each once ("Theorem 4.50(a)" and "(b)" are one)
        for ref in statement_lookup.references(mine)[:6]:
            url = attachment.get("url") or ""
            number = ref["number"] or (statement_lookup.number_on_page(ref["kind"], url, ref["page"]) if ref.get("page") else None)
            hit = statement_lookup.find(ref["kind"], number, url, [], ref.get("part", "")) if number and url else None
            if hit and hit.get("text") not in found:
                found.append(hit["text"])
        passage = "\n\n".join(found)
    if not mine.strip("- *:") or not passage:
        return {"feedback": "Write your summary first, and quote or name the statement it's about (\"**Definition 4.17**\")."}
    client = anthropic_client.get()
    if not client:
        return {"feedback": "Checking needs Claude: add your key in Settings → Keys, and be online."}
    reply = client.messages.create(model=MODEL, max_tokens=2000, system=NOTE_FEEDBACK,
                                   messages=[{"role": "user", "content": f"Passage:\n{passage}\n\nTheir note:\n{mine}"}])
    return {"feedback": "".join(b.text for b in reply.content if b.type == "text").strip()}


@app.post("/notes/from-passage")
def note_from_passage(body: dict):
    # Right-click → Add to Notes on a search result: titled by the search, with a line like the person's
    # other notes ("**Definition 5.1**: ..."), linked to the passage's page. Without Claude (no key, or
    # offline), the passage is quoted instead.
    # By default the person writes the line themselves (writing it is part of learning it): the note
    # starts with the statement's number in bold and the passage quoted below for reference. Claude
    # writes the line only with Settings → Privacy → "Claude writes lines for notes from search" on.
    from verify import anthropic_client, MODEL
    from claim_log import statement_of
    text, query = str(body.get("text", "")), str(body.get("query", "")).strip()
    line = None
    client = anthropic_client.get() if privacy.allowed("note_lines") else None
    if client and text:
        try:
            reply = client.messages.parse(model=MODEL, max_tokens=300, system=PASSAGE_NOTE,
                                          messages=[{"role": "user", "content": text}], output_format=PassageNote)
            found = reply.parsed_output
            if found and found.summary.strip():
                line = f"- **{found.label.strip()}**: {found.summary.strip()}" if found.label.strip() else f"- {found.summary.strip()}"
        except Exception as e:
            print(f"[notes] couldn't summarise the passage: {e}")
    title = (query[:1].upper() + query[1:]) if query else str(body.get("source", "")) + (f", p. {body['page']}" if body.get("page") else "")
    url = str(body.get("url", ""))
    note = {"id": uuid.uuid4().hex, "project": body.get("project") or reading.project or "", "title": title,
            # Without Claude's line, only the passage: Referee then asks the person for their own summary.
            "body": (line + "\n\n" if line else "") + "\n".join("> " + l for l in text.splitlines()),
            "files": [], "created": time.time(),
            "attachments": [{"url": url, "page": body.get("page"), "to": None}] if url else []}
    return notes.save(note)


class NoteTopic(BaseModel):
    id: str
    topic: str


class NoteTopics(BaseModel):
    topics: List[NoteTopic]


NOTE_TOPICS = (
    "Group someone's study notes by topic. Give each note one topic name of one to three words, capitalised like "
    "a heading (\"Span and bases\", \"Linear programs\"). Topics should be broad, like a chapter or section of a "
    "course, so each covers several related notes: about one topic for every five to eight notes, and never a "
    "separate topic for each note. A topic with one note is only right when that note fits nothing else. Each note "
    "says which source it's from. Notes from different sources may share a topic when they're about the same idea, "
    "but a shared word isn't enough (a convex combination in linear programming is not about span; a basic feasible "
    "solution is not about bases of vector spaces). When existing topics are listed, put a note in one only if it's "
    "about the same subject, reusing the name exactly; otherwise make a new topic. Return every note's id with its topic."
)
TOPICS_VERSION = 3   # raised when the instructions change, so notes are sorted again under the new ones
TOPICS_FILE = paths.data("note-topics.json")   # note id -> {"topic", "of": the note as sorted}


def _saved_topics() -> dict:
    try:
        return json.loads(TOPICS_FILE.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}


@app.get("/notes/topics")
def note_topics(project: str = "all"):
    # Notes → Filter → Topics: Claude sorts notes into topics once; the result is saved. Later, only notes
    # that are new or changed are sent, to be fitted into the existing topics (or a new one if none fits).
    from verify import anthropic_client, MODEL
    scope = library_project(project)
    mine = [n for n in notes.items if scope is None or (n.get("project") or "") == scope]
    saved = _saved_topics()
    fingerprint = lambda n: f"{TOPICS_VERSION}\n{n.get('title', '')}\n{n.get('body', '')[:300]}"
    unsorted = [n for n in mine if saved.get(n["id"], {}).get("of") != fingerprint(n)]
    client = anthropic_client.get() if privacy.allowed("note_topics") else None  # off: only saved topics
    if unsorted and client:
        # Existing topics with the sources of their notes, so a new note isn't put with another course's.
        names = {x.get("url"): x.get("name") or x.get("title") for x in sources()}
        kept = {}
        for n in mine:
            if n["id"] in saved and n not in unsorted:
                kept.setdefault(saved[n["id"]]["topic"], set()).add(names.get((n.get("attachments") or [{}])[0].get("url"), "no source"))
        existing = [f"{t} (notes from {', '.join(sorted(srcs))})" for t, srcs in sorted(kept.items())]
        names = {x.get("url"): x.get("name") or x.get("title") for x in sources()}
        source_of = lambda n: names.get((n.get("attachments") or [{}])[0].get("url"), "no source")
        listing = "\n".join(f"{n['id']} (from {source_of(n)}): {n.get('title', '')}: {n.get('body', '')[:300]}" for n in unsorted)
        prompt = (f"Existing topics: {', '.join(existing)}\n\nNotes to sort:\n{listing}" if existing else listing)
        try:
            reply = client.messages.parse(model=MODEL, max_tokens=4000, system=NOTE_TOPICS,
                                          messages=[{"role": "user", "content": prompt}], output_format=NoteTopics)
            by_id = {n["id"]: n for n in unsorted}
            for t in (reply.parsed_output.topics if reply.parsed_output else []):
                if t.id in by_id and t.topic.strip():
                    saved[t.id] = {"topic": t.topic.strip(), "of": fingerprint(by_id[t.id])}
            ids = {n["id"] for n in notes.items}
            saved = {k: v for k, v in saved.items() if k in ids}    # deleted notes' topics go
            TOPICS_FILE.write_text(json.dumps(saved), encoding="utf-8")
        except Exception as e:
            print(f"[notes] couldn't sort notes into topics: {e}")
    return {n["id"]: saved[n["id"]]["topic"] for n in mine if n["id"] in saved}


@app.delete("/notes")
def delete_note(id: str):
    recently_deleted.deleted("note", next((n for n in notes.items if n["id"] == id), None))
    return {"ok": notes.delete(id)}


# Notes brought in from a Markdown folder (such as an Obsidian vault) or Apple Notes.
importer = note_import.Importer(notes, paths.data("note-files"))


@app.post("/notes/import")
def import_notes(body: dict):
    project = body.get("project") or ""
    if body.get("folder"):
        return importer.markdown_folder(body["folder"], project)
    return importer.apple_notes(body.get("notes") or [], project)


# Action points in the chosen to-do app: Things, Reminders, Todoist or Notion.
todoist_sync = tasks.Sync(meetings)
todoist_sync.start()


@app.get("/tasks")
def tasks_status():
    return todoist_sync.status()


@app.post("/tasks")
def tasks_choose(body: dict):
    # Which app gets action points: one of tasks.APPS, or none.
    app_name = body.get("app")
    config_path = Path.home() / ".referee" / "config.json"
    config = json.loads(config_path.read_text(encoding="utf-8")) if config_path.exists() else {}
    config["tasks_app"] = app_name if app_name in tasks.APPS else "none"
    config_path.write_text(json.dumps(config, indent=2), encoding="utf-8")
    todoist_sync.soon()
    return todoist_sync.status()


@app.post("/notion")
def notion_connect(body: dict):
    result = notion.connect(body.get("token", ""), body.get("database", ""))
    if result["ok"]:
        todoist_sync.soon()
    return result


@app.delete("/notion")
def notion_disconnect():
    notion.disconnect()
    return {"ok": True}


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


# Each project's due date: typed in, or followed from a Todoist task (so moving it there moves it here).
project_due_path = paths.data("project-due.json")


def _project_dues() -> dict:
    try:
        return json.loads(project_due_path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}


_due_cache: dict = {}


@app.get("/projects/due")
def project_dues():
    # {project: {"date", "task", "title", "submitted"}}, with Todoist-linked dates refreshed at most every 10 minutes.
    dues = _project_dues()
    for name, due in dues.items():
        task = due.get("task")
        if task:
            cached = _due_cache.get(task)
            if not cached or time.time() - cached[1] > 600:
                fresh = todoist.due_of(task)
                _due_cache[task] = (fresh or due.get("date"), time.time())
            due["date"] = _due_cache[task][0]
    return dues


@app.post("/projects/due")
def set_project_due(body: dict):
    # {"project", "date"} or {"project", "task", "title", "date"}; no date and no task clears it.
    dues = _project_dues()
    name = body.get("project") or ""
    if not body.get("date") and not body.get("task"):
        dues.pop(name, None)
    else:
        dues[name] = {"date": body.get("date"), "task": body.get("task"), "title": body.get("title"),
                      "submitted": (dues.get(name) or {}).get("submitted"),
                      "deadlines": (dues.get(name) or {}).get("deadlines") or []}
    project_due_path.write_text(json.dumps(dues, indent=1), encoding="utf-8")
    return {"ok": True}


@app.post("/projects/submitted")
def set_project_submitted(body: dict):
    # {"project", "submitted"}: ticked off as submitted (today), so its due date stops warning; or not.
    dues = _project_dues()
    name = body.get("project") or ""
    due = dues.setdefault(name, {})
    due["submitted"] = date.today().isoformat() if body.get("submitted") else None
    project_due_path.write_text(json.dumps(dues, indent=1), encoding="utf-8")
    return {"ok": True}


@app.post("/projects/deadline")
def set_project_deadline(body: dict):
    # A named deadline besides the project's due date ("Draft to supervisor"): {"project", "id"?, "name",
    # "date", "submitted"?} adds or changes one; {"project", "id", "delete": true} removes it.
    dues = _project_dues()
    due = dues.setdefault(body.get("project") or "", {})
    deadlines = [d for d in due.get("deadlines") or [] if d.get("id") != body.get("id")]
    if not body.get("delete"):
        old = next((d for d in due.get("deadlines") or [] if d.get("id") == body.get("id")), {})
        submitted = body.get("submitted", bool(old.get("submitted")))
        deadlines.append({"id": body.get("id") or uuid.uuid4().hex, "name": (body.get("name") or old.get("name") or "").strip(),
                          "date": body.get("date") or old.get("date"),
                          "submitted": (old.get("submitted") or date.today().isoformat()) if submitted else None})
    due["deadlines"] = sorted(deadlines, key=lambda d: d.get("date") or "")
    project_due_path.write_text(json.dumps(dues, indent=1), encoding="utf-8")
    return {"ok": True}


@app.get("/todoist/dated")
def todoist_dated():
    return todoist.dated()


@app.get("/meetings")
def list_meetings(project: str = "all"):
    return meetings.all(library_project(project))


@app.post("/meetings")
def save_meeting(meeting: dict):
    versions.replaced("meeting", next((m for m in meetings.items if m["id"] == meeting.get("id")), None), meeting)
    saved = meetings.save(meeting)
    todoist_sync.soon()  # new, changed or ticked-off action points reach the to-do app straight away
    return saved


@app.delete("/meetings")
def delete_meeting(id: str):
    recently_deleted.deleted("meeting", next((m for m in meetings.items if m["id"] == id), None))
    return {"ok": meetings.delete(id)}


@app.get("/meetings/workspace")
def meeting_workspace(project: str):
    return {"folder": meetings.workspaces.get(project, "")}


@app.post("/meetings/workspace")
def set_meeting_workspace(body: dict):
    # Links a project to its group's shared folder, whose Markdown files then open in Referee.
    return meetings.set_workspace(body.get("project", ""), body.get("folder", ""))


@app.get("/meetings/files")
def shared_files(project: str):
    return meetings.shared_files(project)


@app.get("/meetings/file")
def read_shared_file(project: str, path: str):
    return meetings.read_shared(project, path)


@app.post("/meetings/file")
def write_shared_file(body: dict):
    # Saved exactly as written; refused if a teammate changed it since it was opened.
    return meetings.write_shared(body.get("project", ""), body.get("path", ""), body.get("text", ""),
                                 float(body.get("modified") or 0))


@app.get("/meetings/my-actions", response_class=PlainTextResponse)
def my_action_points(project: str):
    return meetings.my_actions(project)


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
    versions.replaced("ai-use", next((e for e in ai_log.items if e["id"] == entry.get("id")), None), entry)
    return ai_log.save(entry)


@app.delete("/ai-log")
def delete_ai_use(id: str):
    recently_deleted.deleted("ai-use", next((e for e in ai_log.items if e["id"] == id), None))
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


def referee_use(project: Optional[str]) -> list:
    # Referee's own claim checks are AI use too: listed once, with the model that made them.
    if not referee_checks(project):
        return []
    # Not when the person has logged Referee's checks themselves, so they aren't listed twice.
    if any("referee" in f"{e.get('tool', '')} {e.get('purpose', '')}".lower() for e in ai_log.all(project)):
        return []
    chosen = local_models.settings()
    model = {"ollama": chosen["ollama_model"], "openai": "OpenAI " + cloud_models.model("openai")}.get(chosen["provider"], "Claude Haiku 5.5 and Sonnet 5.5")
    return [{"tool": "Referee", "version": model, "purpose": "checking that my sources support my claims",
             "checked": "reviewed each issue it raised against the source"}]


@app.get("/ai-log/disclosure")
def ai_disclosure(project: str, format: str = ""):
    return ai_log.disclosure(project, referee_use(project), format or None)


@app.post("/ai-log/disclosure")
def save_ai_disclosure(body: dict):
    # Edited text is kept; a new format, new given wording or "redraft" starts again from the log.
    project = body.get("project", "")
    ai_log.save_disclosure(project, body.get("text"), body.get("format"), body.get("given"), bool(body.get("redraft")),
                           body.get("unused"), body.get("opening"))
    return ai_log.disclosure(project, referee_use(project))


@app.get("/ai-log/export", response_class=PlainTextResponse)
def export_ai_use(project: str = "all", format: str = "markdown"):
    chosen = library_project(project)
    return ai_log.export(chosen, format, referee_checks(chosen))


class NotClaims:

    """
    Sentences the person marked "Ignore": never checked again, in any document.
    """

    def __init__(self, path: Path):
        self.path = path
        try:
            self.items = set(json.loads(path.read_text(encoding="utf-8")))
        except (OSError, ValueError):
            self.items = set()

    @staticmethod
    def _key(sentence: str) -> str:
        return " ".join(sentence.lower().split())

    def has(self, sentence: str) -> bool:
        return self._key(sentence) in self.items

    def add(self, sentence: str) -> None:
        self.items.add(self._key(sentence))
        self.path.write_text(json.dumps(sorted(self.items)), encoding="utf-8")


not_claims = NotClaims(paths.data("not-claims.json"))


@app.post("/claims/ignore")
def ignore_claim(body: dict):
    # "Ignore": leaves Evidence and the trail, and isn't checked again.
    sentence = (body.get("sentence") or "").strip()
    if not sentence:
        return {"ok": False}
    not_claims.add(sentence)
    claim_log.forget_sentences([s_ for s_ in claim_log.entries if not_claims.has(s_)])
    return {"ok": True}


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
    # Kept in Recently Deleted for 30 days: its passages, the checks it backed and its highlights.
    kept = passages_of(url)
    if kept:
        source = kept[0]["source"]
        recently_deleted.deleted("source", {
            "title": source.get("name") or source.get("title") or url, "project": source.get("project"),
            "url": url, "passages": kept,
            "claims": {s_: e for s_, e in claim_log.entries.items() if (e.get("source") or {}).get("url") == url},
            "highlights": highlights.for_url(url)})
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


@app.post("/projects/archive")
def archive_project(body: dict):
    # Out of the menus, or back: its sources, notes, meetings, AI use and checks stay as they are.
    return reading.archive(str(body.get("project", "")), bool(body.get("archived", True)))


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
def list_references(project: str = "all", style: str = "apa", document: str = ""):
    # One document's references (the one chosen in Referee's sidebar), or every document's.
    claims = claim_log.claims()
    if document:
        claims = [c for c in claims if (c.get("document") or "Unnamed document") == document]
    return library.references(sources(), claims, library_project(project), style)


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
    return with_maths(library.presubmission(sources(), claim_log.claims(), library_project(project)))


@app.get("/trail", response_class=HTMLResponse)
def research_trail(project: str = "all", archived: float = 0, style: str = "apa"):
    # The current trail (since the last archive), or an archived one, chosen by when it ended.
    scope = library_project(project)
    if scope is None:
        return with_maths(library.trail(sources(), claim_log.claims(), highlights.notes, scope, style=style))
    if archived:
        entry = next((a for a in trails.archived(scope) if abs(a["to"] - archived) < 0.001), None)
        if entry:
            return with_maths(library.trail(sources(), claim_log.claims(), highlights.notes, scope, entry["from"], entry["to"],
                                            ", archived: " + trail_archive.period(entry["from"] or entry["to"], entry["to"]), style))
    return with_maths(library.trail(sources(), claim_log.claims(), highlights.notes, scope, trails.current_start(scope), style=style))


trails = trail_archive.TrailArchive(paths.data("trail_archive.json"))


@app.get("/trail/archive")
def trail_summary(project: str):
    # For the archive dialog: what the current trail holds, and when writing was last checked.
    start = trails.current_start(project)
    read = [s_ for s_ in sources() if (s_.get("project") or "") == project and (s_.get("captured_ts") or 0) >= start]
    checks = [c for c in claim_log.claims(project) if (c.get("at") or 0) >= start]
    first = min([s_["captured_ts"] for s_ in read] + [c["at"] for c in checks], default=None)
    return {"from": first, "sources": len(read), "checks": len(checks),
            "last_check": max((c["at"] for c in checks), default=None),
            "archived": [{**a, "period": trail_archive.period(a["from"] or a["to"], a["to"])} for a in trails.archived(project)][::-1]}


@app.post("/trail/archive")
def archive_trail(body: dict):
    project = body.get("project") or ""
    return trails.archive(project, trail_summary(project)["from"] or trails.current_start(project))


@app.post("/trail/restore")
def restore_trail(body: dict):
    return {"ok": trails.restore(body.get("project") or "", float(body.get("to", 0)))}


@app.get("/report", response_class=HTMLResponse)
def proof_of_work(project: str = "all", style: str = "apa"):
    # Proof of work is now part of the research trail.
    return research_trail(project, 0, style)


class HighlightRequest(BaseModel):
    url: str
    text: str


@app.post("/highlights")
def add_highlight(req: HighlightRequest):
    return {"ok": highlights.add(req.url, req.text)}


@app.get("/highlights")
def list_highlights(url: str = ""):
    return highlights.for_url(url) if url else highlights.notes


def statement_for(url: str, quote: str, page: Optional[int] = None) -> Optional[str]:
    # "Definition 4.17" and the like: the last one before the quote. For a PDF on this Mac, from the page's
    # own text (with the page before it), which keeps the numbers that search passages often lose;
    # otherwise from the stored passages.
    from claim_log import statement_of
    squash = lambda t: " ".join(t.split())
    if url.startswith("file://") and url.lower().endswith(".pdf") and page:
        import os
        import urllib.parse
        import statement_lookup
        path = urllib.parse.unquote(url[len("file://"):])
        try:
            pages = statement_lookup._pdf_pages(path, os.path.getmtime(path))
        except OSError:
            pages = ()
        if 0 < page <= len(pages):
            text = squash(statement_lookup._ligatures(" ".join(pages[max(0, page - 2):page])))
            found = statement_of(text, squash(quote)[:30])
            if found:
                return found
    from store import _passages
    mine = [p["text"] for p in _passages if p["source"].get("url") == url]
    at = next((i for i, text in enumerate(mine) if quote[:40] in text), None)
    if at is None:
        return None
    for i in range(at, max(at - 3, -1), -1):
        found = statement_of(mine[i], quote if i == at else "")
        if found:
            return found
    return None


@app.get("/claims")
def list_claims(project: str = ""):
    found = claim_log.claims(project or None)
    # The numbered statement behind each check ("Definition 4.17"), worked out once and kept.
    missing = [c for c in found if not c.get("statement_v4") and c.get("quote") and (c.get("source") or {}).get("url")]
    for c in missing:
        c["statement"] = statement_for(c["source"]["url"], c["quote"], c.get("page")) or ""
        c["statement_v4"] = True
        if c["sentence"] in claim_log.entries:
            claim_log.entries[c["sentence"]].update(statement=c["statement"], statement_v4=True)
    if missing:
        claim_log.save()
    return found


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


def fixed_key(url: str) -> dict:

    # The source's current \cite key, kept from now on, so citations already written still work.
    key = bib.keys(sources()).get(url)
    return {"cite_key": key, "cite_key_fixed": True} if key else {}


@app.post("/sources/rename")
def rename_source(body: dict):
    # The name you see in the library and notes ("MTH5112 notes"). References keep the source's
    # citation details: for those, use /sources/details. An empty name goes back to the title.
    url, name = body.get("url", ""), (body.get("name") or body.get("title") or "").strip()
    if not update_source(url, {"name": name or None}):
        return {"ok": False, "reason": "That source isn't saved."}
    return {"ok": True, "name": name}


@app.post("/sources/details")
def source_details(body: dict):
    # Citation details for sources that lack them (lecture notes, reports): title, authors
    # ("Surname, First; ..."), date (year or YYYY-MM-DD) and publisher or institution.
    url = body.get("url", "")
    fields = {k: (body.get(k) or "").strip() or None for k in ("title", "author", "date", "site") if k in body}
    if "title" in fields and not fields["title"]:
        return {"ok": False, "reason": "A title can't be empty."}
    if not update_source(url, {**fixed_key(url), **fields}):
        return {"ok": False, "reason": "That source isn't saved."}
    return {"ok": True}


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
    if Path(req.name).suffix.lower() in ocr.IMAGES:
        return add_image(req.name, base64.b64decode(req.data))
    result = capture_pdf(CapturePdfRequest(url=url, title=Path(req.name).stem, data=req.data))
    if result.get("ok"):
        keep(url, reading.project or None)
    return result


def zotero_pdf(path: str, title: str, project: Optional[str]) -> dict:
    # A PDF from Zotero's storage, read where it is, into the chosen project.
    url = f"file://{path}"
    data = base64.b64encode(Path(path).read_bytes()).decode()
    result = capture_pdf(CapturePdfRequest(url=url, title=title, data=data))
    if result.get("ok"):
        keep(url, project)
    return result


def zotero_link(link: str, project: Optional[str]) -> dict:
    # An item with no PDF in Zotero: its DOI or link, fetched like Add Source.
    result = add_url(CaptureUrlRequest(url=link))
    if result.get("ok"):
        keep(result.get("url") or link, project)
    return result


def zotero_details(url: str, found: dict) -> None:
    # Zotero's citation details win over what Referee guessed from the page.
    update_source(url, {**fixed_key(url), **{k: v for k, v in found.items() if k in ("title", "author", "date", "site", "doi")}})


import reading_folders
linked_folders = reading_folders.ReadingFolders(paths.data("reading-folders.json"), zotero_pdf)


@app.on_event("startup")
def watch_reading_folders():
    linked_folders.start()


@app.get("/reading-folders")
def list_reading_folders():
    return linked_folders.status()


@app.post("/reading-folders")
def link_reading_folder(body: dict):
    return linked_folders.link(body.get("path") or "", body.get("project") or "")


@app.delete("/reading-folders")
def unlink_reading_folder(path: str):
    linked_folders.unlink(path)
    return {"ok": True}


zotero_sync = zotero.Sync(zotero_pdf, zotero_link, zotero_details, paths.data("zotero.json"))


@app.on_event("startup")
def sync_zotero():
    zotero_sync.start()


@app.get("/zotero")
def zotero_status():
    return zotero_sync.status()


@app.post("/zotero")
def zotero_choose(body: dict):
    # The collection to follow and the project it feeds; an empty collection stops it.
    config_path = Path.home() / ".referee" / "config.json"
    config = json.loads(config_path.read_text(encoding="utf-8")) if config_path.exists() else {}
    config["zotero_collection"] = body.get("collection") or None
    config["zotero_project"] = body.get("project") or None
    config_path.write_text(json.dumps(config, indent=2), encoding="utf-8")
    zotero_sync.soon()
    return zotero_sync.status()


@app.get("/privacy")
def privacy_settings():
    # The switches on "What leaves this device", and what's in use, for Settings.
    return {**privacy.settings(), "provider": local_models.provider(),
            "tasks_app": tasks.chosen_app(), "notion": notion.status()["connected"],
            "zotero": bool(zotero._config().get("zotero_collection")), "phone": phone_sync.enabled()}


@app.post("/privacy")
def privacy_switch(body: dict):
    return privacy.set_switch(body.get("name", ""), bool(body.get("on")))


weekly_backups = backups.Weekly()


@app.on_event("startup")
def back_up_weekly():
    weekly_backups.start()


@app.get("/backups")
def backup_settings():
    return backups.automatic()


@app.post("/backups")
def backup_now(body: dict):
    # A backup into the chosen folder; with "automatic", also makes that folder the weekly one.
    folder = body.get("folder", "")
    if not folder or not Path(folder).is_dir():
        return {"ok": False, "reason": "Choose a folder for the backup."}
    if "automatic" in body:
        config_path = Path.home() / ".referee" / "config.json"
        config = json.loads(config_path.read_text(encoding="utf-8")) if config_path.exists() else {}
        config["backup_folder"] = folder if body["automatic"] else None
        config_path.write_text(json.dumps(config, indent=2), encoding="utf-8")
        if not body["automatic"]:
            return {"ok": True}
    return {"ok": True, "path": str(backups.make(Path(folder)))}


@app.post("/backups/restore")
def backup_restore(body: dict):
    # Replaces everything with the backup, after backing up what's there now. The app restarts
    # the server afterwards, so it loads the restored data.
    return backups.restore(Path(body.get("path", "")))


def phone_snapshot() -> dict:
    # What the iPhone shows: everything but passages, search vectors and files.
    keys = bib.keys(sources())
    library = [{k: s.get(k) for k in ("url", "name", "title", "author", "date", "site", "project", "kept", "type", "doi")}
               | {"cite_key": keys.get(s.get("url"))} for s in sources()]
    return {
        "library.json": library,
        "notes.json": notes.all(),
        "meetings.json": meetings.all(),
        "ai-use.json": ai_log.all(),
        "evidence.json": claim_log.claims(None),
        "projects.json": {"current": reading.project, "projects": reading.projects},
    }


def phone_change(change: dict) -> str:
    # One change made on the iPhone, from the iCloud Inbox.
    kind = change["type"]
    if kind == "note":
        notes.save(change["note"])
    elif kind == "delete-note":
        notes.delete(change["id"])
    elif kind == "meeting":
        meetings.save(change["meeting"])
        todoist_sync.soon()
    elif kind == "delete-meeting":
        meetings.delete(change["id"])
    elif kind == "action":
        meeting = next(m for m in meetings.items if m["id"] == change["meeting"])
        for action in meeting.get("actions", []):
            if action.get("id") == change["action"]:
                action["done"] = bool(change["done"])
        meetings._save({meeting.get("project") or ""})
        todoist_sync.soon()
    elif kind == "ai-use":
        ai_log.save(change["entry"])
    elif kind == "delete-ai-use":
        ai_log.delete(change["id"])
    elif kind == "source":
        # A link saved on the phone: fetched here, into the project it was saved to.
        result = add_url(CaptureUrlRequest(url=change["url"]))
        if result.get("ok") and change.get("project") is not None:
            move(result.get("url") or change["url"], change.get("project") or None)
    elif kind == "rename-source":
        update_source(change["url"], {"name": (change.get("name") or "").strip() or None})
    elif kind == "project":
        reading.update({"project": change["project"]})
    else:
        raise ValueError(f"unknown change {kind}")
    return kind


phone = phone_sync.Sync(phone_snapshot, phone_change)


@app.on_event("startup")
def sync_phone():
    phone.start()


@app.get("/pairing")
def pairing_code():
    # The code that pairs the Google Docs add-on with this Mac; "new" makes a fresh one.
    return {"code": pairing.code()}


@app.post("/pairing")
def pairing_new():
    return {"code": pairing.renew()}


@app.get("/phone")
def phone_status():
    return phone.status()


@app.post("/phone")
def phone_switch(body: dict):
    # Sync with iPhone through iCloud Drive: on or off.
    config_path = Path.home() / ".referee" / "config.json"
    config = json.loads(config_path.read_text(encoding="utf-8")) if config_path.exists() else {}
    config["phone_sync"] = bool(body.get("on"))
    config_path.write_text(json.dumps(config, indent=2), encoding="utf-8")
    phone.soon()
    return phone.status()


@app.get("/find")
def find(q: str, project: str = "", every: bool = Query(False, alias="all")):
    # The ⌘K box: notes, sources, meetings and AI use whose words match, and the passages in your
    # reading that best match by meaning. Nothing is written: only what your sources say.
    words = [w for w in q.lower().split() if w]
    # "*" searches every project; nothing given, the current one.
    scope = None if project == "*" else (project or reading.project or None)
    if not words:
        # Nothing typed yet: the latest notes and sources in the project, to pick up where you were.
        recent = [n for n in notes.all() if (n.get("text") or "").strip()
                  and (scope is None or (n.get("project") or "") == scope)][-4:][::-1]
        saved = sorted((s_ for s_ in sources() if scope is None or (s_.get("project") or "") == scope),
                       key=lambda s_: s_.get("kept_at") or s_.get("captured_ts") or 0, reverse=True)[:4]
        return {"items": [{"kind": "note", "id": n["id"], "title": n["text"],
                           "detail": " · ".join(x for x in (source_title(n["url"]) if n.get("url") else "",
                                                             f"p. {n['page']}" if n.get("page") else "") if x),
                           "url": n.get("url"), "page": n.get("page")} for n in recent]
                         + [{"kind": "source", "id": s_["url"], "title": s_.get("name") or s_.get("title") or s_["url"],
                             "detail": " · ".join(x for x in (s_.get("site"), (s_.get("date") or "")[:4]) if x),
                             "url": s_["url"]} for s_ in saved],
                "passages": [], "recent": True}

    def matches(*fields) -> bool:
        text = " ".join(f or "" for f in fields).lower()
        return all(w in text for w in words)

    def in_scope(item_project) -> bool:
        return scope is None or (item_project or "") == scope

    items = []
    for n in notes.all():
        if in_scope(n.get("project")) and matches(n.get("title"), n.get("body"),
                                                   source_title(n["url"]) if n.get("url") else ""):
            items.append({"kind": "note", "id": n["id"], "title": n["text"],
                          "detail": " · ".join(x for x in (source_title(n["url"]) if n.get("url") else "",
                                                            f"p. {n['page']}" if n.get("page") else "") if x),
                          "url": n.get("url"), "page": n.get("page")})
    for s_ in sources():
        if in_scope(s_.get("project")) and matches(s_.get("name"), s_.get("title"), s_.get("author"), s_.get("site")):
            items.append({"kind": "source", "id": s_["url"], "title": s_.get("name") or s_.get("title") or s_["url"],
                          "detail": " · ".join(x for x in (s_.get("site"), (s_.get("date") or "")[:4]) if x), "url": s_["url"]})
    for m in meetings.all():
        if in_scope(m.get("project")) and matches(m.get("title"), m.get("notes"), m.get("decisions"), m.get("attendees"),
                                                   " ".join(a.get("text", "") for a in m.get("actions", []))):
            items.append({"kind": "meeting", "id": m["id"], "title": m.get("title") or "Meeting", "detail": m.get("date")})
    # Text highlighted while reading, by its words, opening its source.
    for url, marked in highlights.notes.items():
        saved = next((s_ for s_ in sources() if s_.get("url") == url), None)
        if saved is None or not in_scope(saved.get("project")):
            continue
        for h in marked:
            if matches(h.get("text")):
                items.append({"kind": "highlight", "id": f"{url}#{h.get('text', '')[:40]}", "title": h["text"],
                              "detail": "Highlight · " + source_title(url), "url": url})
    for e in ai_log.all():
        if in_scope(e.get("project")) and matches(e.get("tool"), e.get("purpose"), e.get("prompt"), e.get("checked")):
            items.append({"kind": "ai-use", "id": e["id"], "title": e.get("tool") or "AI use", "detail": e.get("date")})

    passages = []
    if len(q.strip()) >= 3:
        seen = set()
        found = sorted(search(q, k=200 if every else 12, projects=reading.allowed(scope) if scope else None),
                       key=lambda r: -r.get("score", 0))
        # Only passages near the closest one: a specific search keeps fewer, a broad one more.
        best = found[0].get("score", 0) if found else 0
        for r in found:
            if r.get("score", 0) < best - 0.15:
                break
            # One passage per page; web pages have no pages, so their passages are told apart by text.
            key = (r["source"].get("url"), r.get("page") if r.get("page") is not None else r["text"][:80])
            # Only passages that really match: unrelated reading scored under 0.3, real matches 0.6+.
            if key in seen or r.get("score", 0) < 0.4:
                continue
            seen.add(key)
            passages.append({"text": r["text"], "url": r["source"].get("url"), "page": r.get("page"),
                             "display": statement_lookup.as_unicode(statement_lookup.from_web(r["text"])),   # Unicode maths, for Raycast
                             # Typeset maths, for Referee: $…$ from a web page's own LaTeX, or tidied from a PDF's text.
                             "maths": statement_lookup.as_maths(statement_lookup.from_web(r["text"])),
                             "project": r["source"].get("project") or "",
                             "image": page_crop.image(r["source"].get("url") or "", r.get("page"), r["text"]),
                             "title": source_title(r["source"].get("url"))})
    return {"items": items[:12], "passages": passages if every else passages[:8]}


@app.post("/statements/preview")
def statement_preview(body: dict):
    # The statements a line of a note points to ("Theorem 4.50(a)"), as the note's sources print
    # them, with their pages: for the preview shown on hover. No AI, only the sources' own text.
    urls = [u for u in body.get("urls") or [] if u]
    found = []
    text = body.get("text", "")
    if text.startswith(">"):
        # A quote from a source: found on its page and shown as printed there.
        quote = text.lstrip("> ").strip()
        for url in urls:
            # Found in the PDF's text, or else by the saved passage it was quoted from (which knows its
            # page), so a quote added from search always finds its page.
            page = statement_lookup.page_of(quote, url) or passage_page(quote, url)
            if page:
                picture = page_crop.image(url, page, quote)
                found.append({"kind": "Quote", "number": "", "text": quote, "page": page, "url": url,
                              "source": source_title(url), "scanned": False, "image": picture})
                break
        return found
    for ref in statement_lookup.references(text)[:4]:
        for url in urls:
            passages = [{"text": t, "page": p} for t, p in stored_passages(url)]
            number = ref["number"] or (statement_lookup.number_on_page(ref["kind"], url, ref["page"]) if ref.get("page") else None)
            hit = statement_lookup.find(ref["kind"], number, url, passages, ref.get("part", "")) if number else None
            if hit:
                saved = next((s_ for s_ in sources() if s_.get("url") == url), {})
                scanned = hit.get("page") in (saved.get("scanned_pages") or [])
                # A picture of it on the page, as printed, for PDFs on this computer.
                picture = page_crop.image(url, hit.get("page"), hit.pop("raw", "")) if not scanned else None
                found.append({**hit, "url": url, "source": source_title(url), "scanned": scanned, "image": picture})
                break
    return found


def passage_page(quote: str, url: str):
    # The page of the saved passage a quote was taken from, matched on its opening words.
    squash = lambda t: re.sub(r"\W+", "", t).lower()
    start = squash(quote)[:80]
    if len(start) < 20:
        return None
    return next((page for text, page in stored_passages(url) if page and start in squash(text)), None)


def stored_passages(url: str) -> list:
    # A saved source's passages with their pages, for finding statements in web sources.
    from store import _passages
    return [(p["text"], p.get("page")) for p in _passages if p["source"].get("url") == url]


def add_image(path: str, data: bytes) -> dict:
    # A screenshot or photo of a page, read with Apple's Vision on this Mac and saved as a source.
    found = ocr.read(data, Path(path).suffix)
    if not found or not found[0] or not found[0][0].strip():
        return {"ok": False, "reason": "Couldn't read any text in that image."}
    text = found[0][0]
    sentences = [s_.strip() for s_ in split_sentences(text.replace("\n", " ")) if len(s_.split()) >= 4]
    if not sentences:
        return {"ok": False, "reason": "Couldn't read enough text in that image."}
    url = f"file://{path}"
    metadata = {"title": Path(path).stem, "url": url, "type": "image", "scanned_pages": [1],
                "author": None, "date": None, "site": None}
    added = add_page(metadata, make_passages(sentences))
    if added:
        keep(url, reading.project or None)
    return {"ok": True, "passages": added}


# Deleted notes, meetings and AI use entries can be put back (⌘Z), exactly as they were.
recently_deleted = undo.Undo(paths.data("recently-deleted.json"), {
    "note": lambda item: notes.save(item),
    "meeting": lambda item: meetings.save(item),
    "ai-use": lambda item: ai_log.save(item),
    "document": lambda item: (claim_log.entries.update(item["entries"]), claim_log.save()),
    "source": lambda item: restore_source(item),
})


def restore_source(item: dict) -> None:
    put_back(item.get("passages", []))
    claim_log.entries.update(item.get("claims", {}))
    claim_log.save()
    if item.get("highlights"):
        highlights.notes[item["url"]] = item["highlights"]
        highlights.save()


@app.delete("/claims/document")
def remove_document(document: str, project: str = ""):
    # A piece of writing deleted where it was written (Referee isn't told): its checks leave
    # Evidence and the current research trail. Checks in an archived trail stay there. Undoable.
    # The document's checks in whichever project they belong to (not only the current one), each kept
    # if it's in a trail already archived for its project.
    gone = {s_: e for s_, e in claim_log.entries.items()
            if (e.get("document") or "Unnamed document") == document
            and (e.get("at") or 0) >= trails.current_start(e.get("project") or "")}
    if gone:
        recently_deleted.deleted("document", {"id": document, "title": document, "entries": gone})
        claim_log.forget_sentences(list(gone))
    return {"ok": True, "removed": len(gone)}


@app.get("/undo")
def undo_available():
    last = recently_deleted.last()
    return {"kind": last["kind"], "title": undo_title(last)} if last else {}


@app.get("/recently-deleted")
def recently_deleted_list(kind: str, project: str = "all"):
    scope = library_project(project)
    return [{"at": e["at"], "title": undo_title(e), "date": e["item"].get("date"), "project": e["item"].get("project")}
            for e in recently_deleted.of(kind, scope)]


@app.post("/recently-deleted/restore")
def recently_deleted_restore(body: dict):
    return {"ok": bool(recently_deleted.put_back(float(body.get("at", 0))))}


@app.post("/recently-deleted/forget")
def recently_deleted_forget(body: dict):
    recently_deleted.forget(float(body.get("at", 0)))
    return {"ok": True}


@app.post("/undo")
def undo_delete():
    entry = recently_deleted.undo()
    return {"ok": bool(entry), "kind": entry["kind"] if entry else None, "title": undo_title(entry) if entry else ""}


def undo_title(entry: dict) -> str:
    item = entry["item"]
    return item.get("title") or item.get("purpose") or item.get("tool") or "Untitled"


# Earlier versions of notes, meetings and AI use entries.
versions = history.History(paths.data("history.json"))


@app.get("/history")
def item_history(id: str):
    return versions.versions(id)


@app.post("/history/restore")
def restore_version(body: dict):
    # Saves the chosen earlier version as the current one (keeping the current one as a version).
    chosen = next((v for v in versions.versions(body.get("id", "")) if abs(v["at"] - float(body.get("at", 0))) < 0.001), None)
    if chosen is None:
        return {"ok": False, "reason": "That version isn't there any more."}
    {"note": save_note, "meeting": save_meeting_any, "ai-use": save_ai_use}[chosen["kind"]](dict(chosen["item"]))
    return {"ok": True}


def save_meeting_any(item: dict):
    versions.replaced("meeting", next((m for m in meetings.items if m["id"] == item.get("id")), None), item)
    return meetings.save(item)


# --- Debug only: capture by URL so you can test from /docs without the extension ---
@app.post("/debug/capture-url")
def capture_url(req: CaptureUrlRequest):
    html = trafilatura.fetch_url(req.url)
    if html is None:
        return {"ok": False, "reason": "Could not fetch that URL."}
    return capture(CaptureRequest(url=req.url, html=html))

# The reflection on your work, for the page with the declaration: two prompts, answered by the person.
REFLECTION_FEEDBACK = (
    "Someone has drafted a short reflection on their own written project, answering two prompts: how they "
    "structured their arguments, and where they found the main difficulty. It goes with their work. Ask about anything missing or vague: a part of the work it "
    "doesn't cover, a difficulty named without saying what made it hard, a claim about the process their AI "
    "use record doesn't bear out. Ask questions only: never write sentences for them, suggest wording or "
    "rewrite theirs. If it answers both prompts clearly, say so in one line. At most four short sentences, plain text."
)


@app.get("/ai-log/reflection")
def get_reflection(project: str):
    saved = (ai_log.templates.get(project) or {}).get("reflection") or {}
    return {"structure": saved.get("structure", ""), "difficulty": saved.get("difficulty", "")}


@app.post("/ai-log/reflection")
def save_reflection(body: dict):
    project = body.get("project", "")
    ai_log.templates.setdefault(project, {})["reflection"] = {
        "structure": body.get("structure", ""), "difficulty": body.get("difficulty", "")}
    ai_log._save_templates()
    return {"ok": True}


@app.post("/ai-log/reflection/check")
def check_reflection(body: dict):
    # Questions about the person's draft, against the two prompts and their own AI use record. Never a rewrite.
    from verify import anthropic_client, MODEL
    project = body.get("project", "")
    saved = get_reflection(project)
    if not (saved["structure"].strip() or saved["difficulty"].strip()):
        return {"feedback": "Write something first."}
    client = anthropic_client.get()
    if not client:
        return {"feedback": "Checking needs Claude: add your key in Settings → Integrations, and be online."}
    record = "\n".join(f"- {e['date']}: {e['purpose']} ({e['tool']})" for e in reversed(ai_log.all(project)))
    reply = client.messages.create(model=MODEL, max_tokens=1000, system=REFLECTION_FEEDBACK, messages=[{"role": "user", "content":
        f"How they structured their arguments:\n{saved['structure']}\n\nWhere they found the main difficulty:\n"
        f"{saved['difficulty']}\n\nTheir AI use record:\n{record or '(none)'}"}])
    return {"feedback": "".join(b.text for b in reply.content if b.type == "text").strip()}


@app.get("/ai-log/reflection/export", response_class=PlainTextResponse)
def export_reflection(project: str, page: bool = False, format: str = "latex"):
    # The declaration as currently shown, then the reflection: in LaTeX, to paste in or as a page of its
    # own, or as plain text with Markdown headings, for Word or a Markdown file.
    from meetings import _tex
    declared = ai_log.disclosure(project, referee_use(project))["text"]
    saved = get_reflection(project)
    if format == "text":
        parts = ["## Declaration of Authenticity and AI use", declared.strip(), "## Reflection on my work"]
        parts += [t.strip() for t in (saved["structure"], saved["difficulty"]) if t.strip()]
        return "\n\n".join(parts) + "\n"
    block = lambda text: "\n\n".join(" \\\\\n".join(_tex(l) for l in part.split("\n")) for part in text.strip().split("\n\n"))
    out = ([r"\newpage"] if page else []) + [r"\section*{Declaration of Authenticity and AI use}", block(declared), "",
           r"\section*{Reflection on my work}"]
    out += [block(t) + "\n" for t in (saved["structure"], saved["difficulty"]) if t.strip()]
    return "\n".join(out).rstrip() + "\n"
