"""Referee as a connector for Claude chats (MCP, over stdio): search your reading, check a claim,
add notes and links, and log AI use, all through the Referee server already running on this Mac
(localhost:8000). Nothing here goes online itself; the chat sends Claude whatever these tools return.

Add it to the Claude app's claude_desktop_config.json under "mcpServers" (see the README).
"""

import json
import urllib.error
import urllib.parse
import urllib.request
from datetime import date
from typing import Any, Optional

from mcp.server.mcpserver import MCPServer

SERVER = "http://localhost:8000"

referee = MCPServer(
    name="Referee",
    instructions=(
        "Referee keeps the person's reading (sources, passages, highlights), notes, meetings and AI use log, "
        "per project. Search before answering questions about their reading, and quote what it returns "
        "with source and page rather than paraphrasing from memory. Only add or change entries when asked."
    ),
)


def _call(path: str, body: Optional[dict] = None, timeout: float = 60, method: Optional[str] = None) -> Any:
    request = urllib.request.Request(f"{SERVER}/{path}", method=method or ("GET" if body is None else "POST"),
                                     headers={"X-Referee": "1", "Content-Type": "application/json"},
                                     data=None if body is None else json.dumps(body).encode())
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return json.loads(response.read() or b"null")
    except urllib.error.URLError:
        raise RuntimeError("Referee isn't running on this Mac. Open Referee, then try again.")


def _project() -> str:
    return (_call("settings") or {}).get("project") or ""


@referee.tool()
def search(query: str, all_projects: bool = False) -> str:
    """Search the person's notes, sources, highlights, meetings and AI use by words, and the passages
    in their reading that match by meaning. Current project only unless all_projects is true."""
    found = _call(f"find?all=true&q={urllib.parse.quote(query)}" + ("&project=*" if all_projects else ""), timeout=120)
    lines = []
    for item in found.get("items", []):
        lines.append(f"- {item.get('kind')}: {item.get('title')}" + (f" ({item['detail']})" if item.get("detail") else ""))
    for p in found.get("passages", []):
        where = p.get("title", "") + (f", p. {p['page']}" if p.get("page") else "")
        lines.append(f"\n> {p.get('maths') or p.get('text')}\n— {where}" + (f" [{p['project']}]" if p.get("project") else ""))
    return "\n".join(lines) or "Nothing in Referee matches that."


@referee.tool()
def check_claim(sentence: str) -> str:
    """Check whether the person's saved reading backs a sentence, as Referee does in Word: the verdict,
    the passage, the source and page, and a citation."""
    v = _call("check", {"sentence": sentence, "document": "Claude chat"}, timeout=120)
    if not v.get("match"):
        return "Nothing in the reading backs this." + (" It reads like a claim that needs a source." if v.get("needs_source") else "")
    source = (v.get("source") or {}).get("title") or (v.get("source") or {}).get("url")
    return (f"{v.get('label')}: \"{v.get('quote') or v.get('passage')}\" — {source}"
            + (f", p. {v['page']}" if v.get("page") else "") + (f"\nCitation: {v['cite']}" if v.get("cite") else ""))


@referee.tool()
def projects() -> str:
    """The person's projects, and which is current."""
    s = _call("settings")
    return json.dumps({"current": s.get("project"), "projects": s.get("projects", [])})


@referee.tool()
def switch_project(name: str) -> str:
    """Make another project current (what's read is saved to it, and writing is checked against it)."""
    _call("settings", {"project": name})
    return f"Now in {name}."


def _source(name: str) -> Optional[dict]:
    """A saved source by its name, title or link: exact first, then the closest partial match."""
    if not name:
        return None
    wanted = name.strip().lower()
    sources = _call("sources") or []
    label = lambda s: [(s.get(k) or "").lower() for k in ("name", "title", "url")]
    return (next((s for s in sources if wanted in label(s)), None)
            or next((s for s in sources if any(wanted in v for v in label(s) if v)), None))


def _attachment(source: str, page: Optional[int], to: Optional[int]) -> list:
    found = _source(source)
    if source and not found:
        raise ValueError(f"No saved source matches “{source}”. Use search or the library's source names.")
    return [{"url": found["url"], "page": page, "to": to}] if found else []


@referee.tool()
def add_note(title: str, body: str = "", source: str = "", page: Optional[int] = None, to: Optional[int] = None) -> str:
    """Add a note to the current project: a title, a Markdown body with $LaTeX$ maths, and optionally the
    saved source it's about (by its name, e.g. "Linear Algebra Lecture Notes") and page (or pages, page
    to to), shown as the note's source link and used for hover previews of "Definition 4.17" lines."""
    project = _project()
    try:
        attachments = _attachment(source, page, to)
    except ValueError as error:
        return str(error)
    _call("notes", {"title": title, "body": body, "project": project, "attachments": attachments})
    where = f", linked to {source} p. {page}" if attachments and page else f", linked to {source}" if attachments else ""
    return f"Note “{title}” added to {project or 'no project'}{where}."


@referee.tool()
def edit_note(title: str, new_title: str = "", body: Optional[str] = None, source: str = "",
              page: Optional[int] = None, to: Optional[int] = None) -> str:
    """Change a note in the current project, found by its title: rename it, replace its body, or link it
    to a saved source and page (replacing its link). Only the parts given change."""
    notes = _call(f"notes?project={urllib.parse.quote(_project())}") or []
    note = next((n for n in notes if (n.get("title") or "").strip().lower() == title.strip().lower()), None)
    if not note:
        return f"No note titled “{title}” in this project."
    if new_title:
        note["title"] = new_title
    if body is not None:
        note["body"] = body
    if source:
        try:
            note["attachments"] = _attachment(source, page, to)
        except ValueError as error:
            return str(error)
    _call("notes", note)
    return f"Note “{note['title']}” updated."


@referee.tool()
def delete_note(title: str, confirm: bool = False) -> str:
    """Delete a note in the current project, found by its exact title. Only when the person asks for that
    note to be deleted. It goes to Recently Deleted in Referee's Notes for 30 days, where it can be restored."""
    if not confirm:
        return (f"Not deleted yet. Ask the person to confirm deleting the note “{title}”, and only after they "
                "say yes in this chat, call this again with confirm set to true.")
    notes = _call(f"notes?project={urllib.parse.quote(_project())}") or []
    matches = [n for n in notes if (n.get("title") or "").strip().lower() == title.strip().lower()]
    if not matches:
        return f"No note titled “{title}” in this project."
    if len(matches) > 1:
        return f"{len(matches)} notes are titled “{title}”; rename one with edit_note first, so the right one is deleted."
    _call(f"notes?id={urllib.parse.quote(matches[0]['id'])}", method="DELETE")
    return f"Note “{matches[0]['title']}” deleted. It's in Recently Deleted (Notes → trash icon) for 30 days."


@referee.tool()
def list_sources() -> str:
    """The saved sources' names, for linking notes to them."""
    sources = _call("sources") or []
    return "\n".join(f"- {s.get('name') or s.get('title')} ({s.get('project') or 'no project'})"
                      for s in sources if s.get("kept") is not False) or "No saved sources."


@referee.tool()
def list_notes() -> str:
    """The current project's notes, in full, with their linked source and pages."""
    notes = _call(f"notes?project={urllib.parse.quote(_project())}")
    names = {s.get("url"): s.get("name") or s.get("title") for s in _call("sources") or []}
    def link(n):
        a = (n.get("attachments") or [{}])[0]
        if not a.get("url"):
            return ""
        pages = f" p. {a['page']}" + (f"–{a['to']}" if a.get("to") else "") if a.get("page") else ""
        return f"\n(source: {names.get(a['url'], a['url'])}{pages})"
    return "\n\n".join(f"## {n.get('title') or 'Untitled'}\n{n.get('body', '')}{link(n)}" for n in notes) or "No notes yet."


@referee.tool()
def save_link(url: str) -> str:
    """Save a web page as a source in the current project."""
    result = _call("sources/add-url", {"url": url}, timeout=120)
    return "Saved." if result.get("ok") else result.get("reason", "Couldn't save that link.")


@referee.tool()
def log_ai_use(purpose: str, tool: str, version: str = "", asked: str = "", response: str = "", checked: str = "") -> str:
    """Log a use of an AI tool in the current project, for its disclosure: what it was used for, the
    tool and version, what was asked, what it gave, and how the person checked it."""
    project = _project()
    _call("ai-log", {"purpose": purpose, "tool": tool, "version": version, "prompt": asked, "response": response,
                     "checked": checked, "project": project, "date": date.today().isoformat()})
    return f"Logged in {project or 'no project'}: {purpose}."


@referee.tool()
def list_ai_use() -> str:
    """The current project's AI use log."""
    entries = _call(f"ai-log?project={urllib.parse.quote(_project())}")
    return "\n".join(f"- {e.get('date')}: {e.get('purpose')} ({e.get('tool')} {e.get('version') or ''})".rstrip()
                     for e in entries) or "No AI use logged."


# Meetings and their tasks (tasks reach Todoist or the person's to-do app as in Referee).

def _meetings() -> list:
    return _call(f"meetings?project={urllib.parse.quote(_project())}") or []


def _meeting(title: str) -> Optional[dict]:
    found = [m for m in _meetings() if (m.get("title") or "").strip().lower() == title.strip().lower()]
    return found[0] if len(found) == 1 else None


@referee.tool()
def list_meetings() -> str:
    """The current project's meetings: date, title, and each task with its deadline and whether it's done."""
    out = []
    for m in _meetings():
        tasks = "".join(f"\n  - [{'x' if a.get('done') else ' '}] {a.get('text')}" + (f" (by {a['due']})" if a.get("due") else "")
                        for a in m.get("actions") or [])
        out.append(f"- {m.get('date') or ''} {m.get('title') or 'Untitled meeting'}{tasks}")
    return "\n".join(out) or "No meetings yet."


@referee.tool()
def read_meeting(title: str) -> str:
    """One meeting in full, found by its exact title: attendees, notes, decisions and tasks."""
    m = _meeting(title)
    if not m:
        return f"No single meeting titled “{title}” in this project."
    tasks = "\n".join(f"- [{'x' if a.get('done') else ' '}] {a.get('text')}" + (f" (by {a['due']})" if a.get("due") else "")
                      + (f": {a['notes']}" if a.get("notes") else "") for a in m.get("actions") or [])
    return (f"# {m.get('title')}\nDate: {m.get('date') or ''}\nAttendees: {m.get('attendees') or ''}\n\n"
            f"## Notes\n{m.get('notes') or ''}\n\n## Decisions\n{m.get('decisions') or ''}\n\n## Tasks\n{tasks or 'None'}")


@referee.tool()
def add_meeting(title: str, date: str = "", attendees: str = "", notes: str = "", decisions: str = "") -> str:
    """Add a meeting to the current project. date as YYYY-MM-DD (today if left out). Notes and decisions in Markdown."""
    import uuid
    _call("meetings", {"id": str(uuid.uuid4()).upper(), "project": _project(), "title": title,
                       "date": date or __import__("datetime").date.today().isoformat(), "attendees": attendees,
                       "notes": notes, "decisions": decisions, "actions": [], "files": []})
    return f"Meeting “{title}” added."


@referee.tool()
def edit_meeting(title: str, new_title: str = "", date: str = "", attendees: Optional[str] = None,
                 notes: Optional[str] = None, decisions: Optional[str] = None) -> str:
    """Change a meeting found by its exact title. Only the parts given change; notes and decisions replace the old."""
    m = _meeting(title)
    if not m:
        return f"No single meeting titled “{title}” in this project."
    for key, value in (("title", new_title), ("date", date)):
        if value:
            m[key] = value
    for key, value in (("attendees", attendees), ("notes", notes), ("decisions", decisions)):
        if value is not None:
            m[key] = value
    _call("meetings", m)
    return f"Meeting “{m['title']}” updated."


@referee.tool()
def add_task(meeting: str, task: str, deadline: str = "", notes: str = "") -> str:
    """Add a task to a meeting (found by its exact title). deadline as YYYY-MM-DD or DD/MM/YYYY. It's sent to
    the person's to-do app (such as Todoist) as Referee does."""
    import uuid
    m = _meeting(meeting)
    if not m:
        return f"No single meeting titled “{meeting}” in this project."
    m.setdefault("actions", []).append({"id": str(uuid.uuid4()).upper(), "text": task, "who": "", "due": deadline,
                                        "done": False, "notes": notes})
    _call("meetings", m)
    return f"Task “{task}” added to “{m['title']}”."


@referee.tool()
def update_task(meeting: str, task: str, done: Optional[bool] = None, new_text: str = "",
                deadline: Optional[str] = None, notes: Optional[str] = None) -> str:
    """Tick off, reopen or change a task, found by its meeting's title and the task's text."""
    m = _meeting(meeting)
    if not m:
        return f"No single meeting titled “{meeting}” in this project."
    a = next((a for a in m.get("actions") or [] if (a.get("text") or "").strip().lower() == task.strip().lower()), None)
    if not a:
        return f"No task “{task}” in “{m['title']}”."
    if done is not None:
        a["done"] = done
    if new_text:
        a["text"] = new_text
    if deadline is not None:
        a["due"] = deadline
    if notes is not None:
        a["notes"] = notes
    _call("meetings", m)
    return f"Task “{a['text']}” updated."


@referee.tool()
def delete_meeting(title: str, confirm: bool = False) -> str:
    """Delete a meeting found by its exact title. Only when the person asks. It stays in Recently Deleted for 30 days."""
    if not confirm:
        return (f"Not deleted yet. Ask the person to confirm deleting the meeting “{title}”, and only after they "
                "say yes in this chat, call this again with confirm set to true.")
    m = _meeting(title)
    if not m:
        return f"No single meeting titled “{title}” in this project."
    _call(f"meetings?id={urllib.parse.quote(m['id'])}", method="DELETE")
    return f"Meeting “{m['title']}” deleted. It's in Recently Deleted (Meetings) for 30 days."


# AI use: change or remove an entry.

def _ai_entry(purpose: str) -> Optional[dict]:
    entries = _call(f"ai-log?project={urllib.parse.quote(_project())}") or []
    found = [e for e in entries if (e.get("purpose") or "").strip().lower() == purpose.strip().lower()]
    return found[0] if len(found) == 1 else None


@referee.tool()
def edit_ai_use(purpose: str, new_purpose: str = "", tool: str = "", version: str = "", asked: Optional[str] = None,
                response: Optional[str] = None, checked: Optional[str] = None) -> str:
    """Change an AI use entry, found by its exact purpose. Only the parts given change."""
    e = _ai_entry(purpose)
    if not e:
        return f"No single AI use entry “{purpose}” in this project."
    for key, value in (("purpose", new_purpose), ("tool", tool), ("version", version)):
        if value:
            e[key] = value
    for key, value in (("prompt", asked), ("response", response), ("checked", checked)):
        if value is not None:
            e[key] = value
    _call("ai-log", e)
    return f"AI use entry “{e['purpose']}” updated."


@referee.tool()
def delete_ai_use(purpose: str, confirm: bool = False) -> str:
    """Delete an AI use entry found by its exact purpose. Only when the person asks. It stays in Recently Deleted for 30 days."""
    if not confirm:
        return (f"Not deleted yet. Ask the person to confirm deleting the AI use entry “{purpose}”, and only after they "
                "say yes in this chat, call this again with confirm set to true.")
    e = _ai_entry(purpose)
    if not e:
        return f"No single AI use entry “{purpose}” in this project."
    _call(f"ai-log?id={urllib.parse.quote(e['id'])}", method="DELETE")
    return f"AI use entry “{e['purpose']}” deleted. It's in Recently Deleted (AI Use) for 30 days."


# Library: a saved source's name, citation details, project, or forgetting it.

@referee.tool()
def edit_source(source: str, new_name: str = "", author: Optional[str] = None, year: Optional[str] = None,
                publisher: Optional[str] = None, title: Optional[str] = None, project: Optional[str] = None) -> str:
    """Change a saved source (found by its name): the name shown in Referee, the citation details used in
    references (author as "Surname, First; Surname, First", year, publisher, title), or move it to another
    project ("" for no project)."""
    found = _source(source)
    if not found:
        return f"No saved source matches “{source}”."
    url, done = found["url"], []
    if new_name:
        _call("sources/rename", {"url": url, "name": new_name})
        done.append("renamed")
    details = {k: v for k, v in (("author", author), ("date", year), ("site", publisher), ("title", title)) if v is not None}
    if details:
        _call("sources/details", {"url": url, **details})
        done.append("citation details updated")
    if project is not None:
        _call("sources/move", {"url": url, "project": project})
        done.append(f"moved to {project or 'no project'}")
    return f"{found.get('name') or found.get('title')}: " + (", ".join(done) or "nothing to change") + "."


@referee.tool()
def forget_source(source: str, confirm: bool = False) -> str:
    """Forget a saved source (found by its name), with its passages. Only when the person asks. It stays in
    Recently Deleted in the Library for 30 days, with its highlights and the checks it backed."""
    if not confirm:
        return (f"Not deleted yet. Ask the person to confirm deleting the source “{source}”, and only after they "
                "say yes in this chat, call this again with confirm set to true.")
    found = _source(source)
    if not found:
        return f"No saved source matches “{source}”."
    _call(f"sources?url={urllib.parse.quote(found['url'], safe='')}", method="DELETE")
    return f"Forgot “{found.get('name') or found.get('title')}”. It's in Recently Deleted (Library) for 30 days."


# Evidence, due dates and references: reading what Referee has worked out.

@referee.tool()
def evidence(document: str = "") -> str:
    """The checked claims in the current project's writing, by document, in the order written: each claim's
    result (backed, contradicted, needs a source, too close to the source's wording), its source, the
    numbered statement and page. With document, only that one (part of its name is enough)."""
    claims = _call(f"claims?project={urllib.parse.quote(_project())}") or []
    names = {s.get("url"): s.get("name") or s.get("title") for s in _call("sources") or []}
    by_document = {}
    for c in claims:
        name = c.get("document") or "Unnamed document"
        if document and document.lower() not in name.lower():
            continue
        by_document.setdefault(name, []).append(c)
    labels = {"supports": "backed", "contradicts": "contradicted", "needs_source": "needs a source", "misquote": "quote doesn't match"}
    out = []
    for name, items in by_document.items():
        order = _call(f"claims/order?document={urllib.parse.quote(name)}") or []
        place = {s: i for i, s in enumerate(order)}
        items.sort(key=lambda c: (place.get(c["sentence"], len(place)), c.get("at") or 0))
        out.append(f"## {name}")
        for c in items:
            result = labels.get(c.get("label"), c.get("label")) + (", too close to the source's wording" if c.get("too_close") else "")
            where = ", ".join(v for v in (names.get((c.get("source") or {}).get("url")), c.get("statement"),
                                          f"p. {c['page']}" if c.get("page") else None) if v)
            out.append(f"- {c['sentence']}\n  {result}" + (f" ({where})" if where else ""))
    return "\n".join(out) or "No checked writing yet."


@referee.tool()
def due_dates() -> str:
    """When each project is due."""
    dues = _call("projects/due") or {}
    return "\n".join(f"- {name or 'No project'}: {d.get('date') or 'no date'}" for name, d in dues.items()) or "No due dates set."


@referee.tool()
def set_due_date(date: str, project: str = "") -> str:
    """Set when a project is due (the current one if left out), as YYYY-MM-DD. An empty date clears it."""
    name = project or _project()
    _call("projects/due", {"project": name, "date": date})
    return f"{name or 'No project'}: due {date}." if date else f"{name or 'No project'}: due date cleared."


@referee.tool()
def references(style: str = "ams", document: str = "") -> str:
    """The reference list for the sources the current project's writing cites, in a style: apa, harvard,
    mla, chicago, ieee, ams or vancouver. With document, only that document's (its full name, from evidence)."""
    query = f"references?project={urllib.parse.quote(_project())}&style={urllib.parse.quote(style)}"
    if document:
        query += f"&document={urllib.parse.quote(document)}"
    found = _call(query) or {}
    entries = found.get("entries") or []
    return (f"{found.get('heading', 'References')}\n" + "\n".join(entries)) if entries else "No cited sources yet."


if __name__ == "__main__":
    referee.run()
