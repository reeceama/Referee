"""A running record of AI use, and the disclosure drafted from it.

Universities, publishers, funders and clients increasingly ask for AI use to be disclosed: which
tools, used for what, and how the output was checked. Keeping the record as you go is far easier
than reconstructing it. Each entry has a date, what it was used for, the tool and version, the key
prompt, what came back and how it was checked.

The disclosure is drafted from the entries with fixed rules, not written by AI, and says only
what the log shows: grouped by tool, so many uses of one tool make one sentence, not one each.
It's then the person's to edit: their edited text is kept until they ask for a fresh draft.
Formats: a short statement, a line per tool, a table, or wording someone else has given them
with {tools}, {system}, {purposes} and {checks} filled in: one version for when AI was used,
and one for when it wasn't.
"""

import json
import platform
import re
import time
import uuid
from datetime import date
from pathlib import Path
from typing import Dict, List, Optional

from meetings import _tex, _when


# Declaration templates. Placeholders are filled from the log: {tools}, {system}, {purposes}, {checks}.
# No institution's wording is built in: each person enters theirs once, as their default for every
# project ("*"), or for one project.
PRESETS = {
    "paragraph": {  # in the style of a paper's AI acknowledgement
        # Facts from the log only: no boilerplate about responsibility.
        "used": "Generative AI ({tools}) was used for {purposes}. Its output was checked by {checks}.",
        "unused": "No generative AI tools were used in this work.",
    },
}
DEFAULT = "*"  # the template for projects without their own

class AILog:

    def __init__(self, path: Path):

        self.path = path
        self.templates_path = path.with_name(path.stem + "-templates.json")
        try:
            self.items: List[Dict] = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            self.items = []
        try:
            self.templates: Dict[str, Dict] = json.loads(self.templates_path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            self.templates = {}

    def template(self, project: Optional[str]) -> Dict:

        """
        A project's declaration template: {"preset", "used", "unused"}. Its own if set, else the
        person's default, else empty (to be filled in with their institution's wording).
        """

        return (self.templates.get(project or "") or self.templates.get(DEFAULT)
                or {"preset": "custom", "used": "", "unused": ""})

    def set_template(self, project: Optional[str], preset: str, used: str = "", unused: str = "") -> Dict:

        """
        Sets a project's template, or the default with project "*": a preset as it is, or custom
        wording. Choosing "default" removes a project's own template, so it uses the default again.
        """

        key = project or ""
        if preset == "default" and key != DEFAULT:
            self.templates.pop(key, None)
        elif preset in PRESETS and not used and not unused:
            self.templates[key] = {"preset": preset, **PRESETS[preset]}
        else:
            self.templates[key] = {"preset": "custom", "used": used, "unused": unused}
        self._save_templates()
        return self.template(project)

    def _save_templates(self) -> None:

        # The wording, format and edited disclosures, kept with the templates (not the log).
        self.templates_path.write_text(json.dumps(self.templates, indent=1), encoding="utf-8")

    def _save(self) -> None:

        self.path.write_text(json.dumps(self.items, indent=1), encoding="utf-8")

    def all(self, project: Optional[str] = None) -> List[Dict]:

        found = [e for e in self.items if project is None or (e.get("project") or "") == project]
        # Newest day first; within a day, the person's own order if they've set one, else newest first.
        return sorted(found, key=lambda e: (e.get("date") or "", e.get("order") or e.get("created") or 0), reverse=True)

    def save(self, entry: Dict) -> Dict:

        clean = {
            "id": entry.get("id") or uuid.uuid4().hex,
            "project": entry.get("project") or "",
            "date": entry.get("date") or date.today().isoformat(),
            "tool": (entry.get("tool") or "").strip(),
            "version": (entry.get("version") or "").strip(),
            "purpose": (entry.get("purpose") or "").strip(),
            "prompt": entry.get("prompt") or "",
            "response": entry.get("response") or "",
            "checked": (entry.get("checked") or "").strip(),
            "created": entry.get("created") or time.time(),
        }
        if entry.get("order") is not None:
            clean["order"] = entry["order"]
        self.items = [e for e in self.items if e["id"] != clean["id"]] + [clean]
        self._save()
        return clean

    def delete(self, entry_id: str) -> bool:

        before = len(self.items)
        self.items = [e for e in self.items if e["id"] != entry_id]
        self._save()
        return len(self.items) < before

    def rename_project(self, old: str, new: Optional[str]) -> None:

        for entry in self.items:
            if entry.get("project") == old:
                entry["project"] = new or ""
        self._save()
        if old in self.templates:
            moved = self.templates.pop(old)
            if new:
                self.templates[new] = moved
            self.templates_path.write_text(json.dumps(self.templates, indent=1), encoding="utf-8")

    def disclosure(self, project: str, extra: Optional[List[Dict]] = None, format: Optional[str] = None) -> Dict:

        """
        The project's disclosure in a format (the last one shown, unless given): the person's
        edited text for that format if they've edited it, otherwise a fresh draft from the log.
        Each format keeps its own edits, so switching between them loses nothing.
        """

        wording = self.templates.get(project) or {}
        saved = wording.get("disclosure") or {}
        format = format if format in FORMATS else saved.get("format") if saved.get("format") in FORMATS else "statement"
        mine = (saved.get("texts") or {}).get(format) or {}
        entries = list(reversed(self.all(project))) + (extra or [])
        given = wording.get("used", "") if wording.get("preset") == "given" else ""
        unused = wording.get("unused", "") if wording.get("preset") == "given" else ""
        fresh = draft(entries, format, given, unused)
        # An opening paragraph for this project (its own-work statement, say) goes above any format
        # but the given wording, which has its own.
        opening = (wording.get("opening") or "").strip()
        if opening and format != "given":
            fresh = f"{opening}\n\n{fresh}"
        return {"format": format, "text": mine["text"] if mine.get("edited") else fresh, "draft": fresh,
                "edited": bool(mine.get("edited")), "given": given, "unused": unused, "opening": wording.get("opening", ""),
                "groups": _by_tool(entries),
                "entries": len([e for e in entries if (e.get("tool") or "").strip()])}

    def save_disclosure(self, project: str, text: Optional[str] = None, format: Optional[str] = None,
                        given: Optional[str] = None, redraft: bool = False, unused: Optional[str] = None,
                        opening: Optional[str] = None) -> None:

        """
        Remembers the format shown; keeps edits for that format; a redraft clears them.
        """

        wording = self.templates.setdefault(project, {})
        saved = wording.setdefault("disclosure", {})
        texts = saved.setdefault("texts", {})
        if format in FORMATS:
            saved["format"] = format
        current = saved.get("format") if saved.get("format") in FORMATS else "statement"
        if given is not None or unused is not None:
            if given is not None:
                wording["used"] = given
            if unused is not None:
                wording["unused"] = unused
            wording["preset"] = "given"
            texts.pop("given", None)
        if opening is not None:
            wording["opening"] = opening.strip()   # in fresh drafts; edited versions keep their text
        if redraft:
            texts.pop(current, None)
        if text is not None:
            texts[current] = {"text": text, "edited": True}
        self._save_templates()

    def fields(self, project: Optional[str], referee_claims: int = 0) -> Optional[Dict[str, str]]:

        """
        What the templates are filled with, from the log; None when no AI use is logged. Referee
        counts as generative AI use when it has checked claims, since it uses Claude to do so.
        """

        entries = [e for e in reversed(self.all(project)) if e["tool"]]
        tools = list(dict.fromkeys(f"{e['tool']} {e['version']}".strip() for e in entries))
        purposes = list(dict.fromkeys(_clause(e["purpose"]) for e in entries if e["purpose"]))
        checks = list(dict.fromkeys(_clause(e["checked"]) for e in entries if e["checked"]))
        if referee_claims:
            tools.append("Referee (a citation checker I developed, using Anthropic Claude)")
            purposes.append("checking that the sources I cite support the claims I make")
            checks.append("reviewing every issue it flagged and correcting the text myself")
        if not tools:
            return None
        system = platform.mac_ver()[0]
        return {"tools": "; ".join(tools), "system": f"macOS {system}" if system else platform.system(),
                "purposes": _join(purposes, "; ") if purposes else "[fill in]",
                "checks": _join(checks, "; ") if checks else "[fill in]"}

    def declaration(self, project: Optional[str], referee_claims: int = 0) -> str:

        """
        The project's declaration, from its template and the log.
        """

        template = self.template(project)
        fields = self.fields(project, referee_claims)
        if not template["used"].strip() and not template["unused"].strip():
            return ""  # no wording yet: the app asks for the institution's
        if fields is None:
            return template["unused"]
        return re.sub(r"\{(tools|system|purposes|checks)\}", lambda m: fields[m.group(1)], template["used"])

    def export(self, project: Optional[str], format: str = "markdown", referee_claims: int = 0) -> str:

        entries = list(reversed(self.all(project)))
        name = project if project else "All projects" if project is None else "No project"
        declared = self.disclosure(project or "")["text"]
        if format == "latex":
            # Paragraphs, with the form's lines kept apart by line breaks (never on an empty line).
            form = "\n\n".join(" \\\\\n".join(_tex(line) for line in block.split("\n")) for block in declared.split("\n\n"))
            out = [r"\section*{AI use disclosure}", form, "", r"\subsection*{Record of use: " + _tex(name) + "}"]
            for e in entries:
                out.append(r"\paragraph{" + _tex(f"{_when(e['date'])}, {(e['tool'] + ' ' + e['version']).strip() or 'AI tool'}") + "}")
                for label, key in (("Used for", "purpose"), ("Prompt", "prompt"), ("Output", "response"), ("Checked by", "checked")):
                    if e[key].strip():
                        out.append(r"\textit{" + label + r":} " + _tex(e[key].strip()).replace("\n", "\n\n") + "\n")
            return "\n".join(out).rstrip() + "\n"
        lines = ["# AI use disclosure", "", declared, "", f"## Record of use: {name}", ""]
        for e in entries:
            lines += [f"### {_when(e['date'])}, {(e['tool'] + ' ' + e['version']).strip() or 'AI tool'}", ""]
            for label, key in (("Used for", "purpose"), ("Prompt", "prompt"), ("Output", "response"), ("Checked by", "checked")):
                if e[key].strip():
                    lines += [f"**{label}:** {e[key].strip()}", ""]
        return "\n".join(lines).rstrip() + "\n"


def _clause(text: str) -> str:

    """
    A logged phrase made to fit mid-sentence: "Checked each step by hand." -> "checked each step by hand".
    """

    text = text.strip().rstrip(".")
    first = text.split(" ", 1)[0]
    # Only an ordinarily capitalised word is lowered: "Checked" -> "checked", but not "LaTeX", "R" or "GUDHI".
    ordinary = len(first) > 1 and first[0].isupper() and first[1:].islower()
    return text[:1].lower() + text[1:] if ordinary else text


def _join(items: List[str], separator: str = ", ") -> str:

    """
    "a", "a and b", "a, b and c"; with separator "; ", "a; b; and c" (for phrases containing "and").
    """

    if len(items) == 1:
        return items[0]
    return separator.join(items[:-1]) + (" and " if separator == ", " else "; and ") + items[-1]


FORMATS = ("statement", "by-tool", "table", "given")


def _by_tool(entries: List[Dict]) -> List[Dict]:

    """
    The entries grouped by tool and version, in the order first used: name, purposes, checks.
    """

    groups: Dict[str, Dict] = {}
    for e in entries:
        if not (e.get("tool") or "").strip():
            continue
        name = e["tool"].strip() + (f", {e['version'].strip()}" if (e.get("version") or "").strip() else "")
        g = groups.setdefault(name, {"name": name, "purposes": [], "checks": []})
        for key, field in (("purposes", "purpose"), ("checks", "checked")):
            phrase = _clause(e.get(field) or "")
            if phrase and phrase not in g[key]:
                g[key].append(phrase)
    return list(groups.values())


def _tools(entries: List[Dict]) -> str:

    """
    Each tool once, with each version once: "Claude (Opus 5.5, Sonnet 5.5 and Haiku 5.5) and Referee (Claude)".
    """

    tools: Dict[str, List[str]] = {}
    for e in entries:
        tool = (e.get("tool") or "").strip()
        if not tool:
            continue
        versions = tools.setdefault(tool, [])
        maker = None
        for version in re.split(r",\s*|\s+and\s+", (e.get("version") or "").strip()):
            # "Claude Haiku 5.5" from Referee joins Claude's versions, so no model is named twice.
            maker = next((t for t in tools if t != tool and version.startswith(t + " ")), None) or maker
            if maker and version.startswith(maker + " "):
                version = version[len(maker) + 1:]
            into = tools[maker] if maker else versions
            if not maker and tool in tools and version.startswith(tool + " "):
                version = version[len(tool) + 1:]
            if version and version not in into:
                into.append(version)
    return _and([f"{tool} ({_and(versions)})" if versions else tool for tool, versions in tools.items()])


def _and(items: List[str]) -> str:

    return items[0] if len(items) == 1 else ", ".join(items[:-1]) + " and " + items[-1]


def draft(entries: List[Dict], format: str, given: str = "", unused: str = "") -> str:

    """
    A disclosure from the log, saying only what the entries say.
    """

    groups = _by_tool(entries)
    if not groups:
        # The wording given for no AI use, if there is one, in that format; otherwise a plain line.
        return unused.strip() if format == "given" and unused.strip() else "No generative AI tools were used."
    if format == "by-tool":
        lines = []
        for g in groups:
            parts = [f"used for {_and(g['purposes'])}" if g["purposes"] else "",
                     f"checked: {'; '.join(g['checks'])}" if g["checks"] else ""]
            lines.append(f"- **{g['name']}**: " + "; ".join(p for p in parts if p) + ".")
        return "\n".join(lines)
    if format == "table":
        rows = ["| Tool | Used for | How it was checked |", "|---|---|---|"]
        cap = lambda t: t[:1].upper() + t[1:]   # each cell starts a sentence of its own
        rows += [f"| {g['name']} | {cap(_and(g['purposes'])) if g['purposes'] else ''} | {cap('; '.join(g['checks']))} |"
                 for g in groups]
        return "\n".join(rows)
    if format == "given" and given.strip():
        system = platform.mac_ver()[0]
        fields = {"tools": _tools(entries),
                  "system": f"macOS {system}" if system else platform.system(),
                  "purposes": _and([p for g in groups for p in g["purposes"]]) or "[fill in]",
                  "checks": _and([c for g in groups for c in g["checks"]]) or "[fill in]"}
        return re.sub(r"\{(tools|system|purposes|checks)\}", lambda m: fields[m.group(1)], given)
    sentences = []
    for g in groups:
        used = f"I used {g['name']}" + (f" for {_and(g['purposes'])}." if g["purposes"] else ".")
        checked = f" {_checked(g['checks'])}" if g["checks"] else ""
        sentences.append(used + checked)
    return " ".join(sentences)


def _checked(checks: List[str]) -> str:

    """
    How a tool's output was checked, phrased to fit how the checks were written: "comparing it
    with the brief" -> "I checked it by comparing…"; "compared it with the brief" -> "To check
    it, I compared…"; anything else -> "Checked: …".
    """

    first = checks[0].split(" ", 1)[0].lower()
    joined = "; ".join(checks)
    if first.endswith("ing"):
        return f"I checked it by {joined}."
    if first.endswith("ed") or first in ("ran", "re-ran", "read", "made", "wrote", "found", "went", "did", "got", "took"):
        return f"To check it, I {joined}."
    return f"Checked: {joined}."
