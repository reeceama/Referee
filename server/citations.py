"""Citation formatting for the Word helper, matching extension/library/cite.js.

Five styles from the metadata the server stores ({title, author, date, site, url,
captured_at, type}):
    author-date: APA 7, Harvard (Cite Them Right) and MLA 9, listed alphabetically.
    numbered:    IEEE (computing) and AMS (mathematics), listed in order of first citation.
In-text citations carry the page (PDFs) or timestamp (videos) when known.
"""

import re
from datetime import date
from typing import Dict, List, Optional
from urllib.parse import urlparse

MONTHS = ["January", "February", "March", "April", "May", "June", "July", "August",
          "September", "October", "November", "December"]
SHORT_MONTHS = ["Jan.", "Feb.", "Mar.", "Apr.", "May", "Jun.", "Jul.", "Aug.", "Sep.", "Oct.", "Nov.", "Dec."]
HEADINGS = {"apa": "References", "harvard": "Reference list", "mla": "Works Cited", "chicago": "References",
            "ieee": "References", "ams": "References", "vancouver": "References"}
NUMBERED = {"ieee", "ams", "vancouver"}


def _squash(text: Optional[str]) -> str:

    return re.sub(r"[^a-z0-9]", "", (text or "").lower())


def clean_title(source: Dict) -> str:

    """
    Drop a " - Wikipedia" or " | BBC News" ending when it just names the site.
    """

    title = (source.get("title") or source.get("url") or "Untitled").strip()
    match = re.match(r"^(.+?)\s+[-|–—]\s+([^-|–—]+)$", title)
    if not match:
        return title
    tail = match.group(2).strip().lower()
    host = urlparse(source.get("url") or "").hostname or ""
    site_name = source.get("site")
    names_site = len(tail.split()) <= 4 and (
        _squash(tail) in _squash(site_name) or _squash(tail) in _squash(host)
        or _squash(site_name) in _squash(tail))
    return match.group(1).strip() if names_site else title


def _end_stop(text: str) -> str:

    return text if re.search(r"[.!?]$", text) else f"{text}."


def _site(source: Dict) -> str:

    site = re.sub(r",?\s*(Inc|Ltd|LLC|plc)\.?$", "", source.get("site") or "", flags=re.IGNORECASE)
    return site.rstrip(".").strip()


def _split_authors(author: Optional[str]) -> List[str]:

    """
    Page metadata often has junk in the author field (Wikipedia's is a list of catalogue
    names), so anything long or catalogue-like is treated as no author.
    """

    if not author or re.search(r"databases|authority control", author, re.IGNORECASE):
        return []
    if ";" not in author and len(author.split()) > 8:  # a semicolon-separated list (from a DOI) is genuine
        return []
    return [a.strip() for a in re.split(r";|\band\b|&", author) if a.strip()]


def _parse_name(name: str) -> Dict:

    if "," in name:
        last, first = [part.strip() for part in name.split(",", 1)]
        return {"last": last, "firsts": first.split()}
    parts = name.split()
    return {"last": parts[-1], "firsts": parts[:-1]}


def _initials(firsts: List[str], separator: str) -> str:

    pieces = [p for f in firsts for p in f.split("-") if p]
    return separator.join(p[0].upper() + "." for p in pieces)


def _parse_date(value: Optional[str]) -> Optional[Dict]:

    match = re.match(r"^(\d{4})(?:-(\d{2}))?(?:-(\d{2}))?", value or "")
    if not match:
        return None
    return {"year": match.group(1), "month": int(match.group(2)) if match.group(2) else None,
            "day": int(match.group(3)) if match.group(3) else None}


def _accessed(source: Dict) -> Dict:

    return _parse_date(source.get("captured_at") or date.today().isoformat())


def _list_authors(names: List[str], separator: str, conjunction: str) -> str:

    people = []
    for n in map(_parse_name, names):
        people.append(f"{n['last']}, {_initials(n['firsts'], separator)}" if n["firsts"] else n["last"])
    if len(people) == 1:
        return people[0]
    return ", ".join(people[:-1]) + conjunction + people[-1]


def _initials_first(names: List[str]) -> str:

    people = [f"{_initials(n['firsts'], ' ')} {n['last']}" if n["firsts"] else n["last"] for n in map(_parse_name, names)]
    if len(people) <= 2:
        return " and ".join(people)
    return ", ".join(people[:-1]) + ", and " + people[-1]


def _surnames(source: Dict) -> Optional[str]:

    names = [_parse_name(n)["last"] for n in _split_authors(source.get("author"))]
    if len(names) == 1:
        return names[0]
    if len(names) == 2:
        return f"{names[0]} & {names[1]}"
    if len(names) > 2:
        return f"{names[0]} et al."
    return None


def _short_title(source: Dict) -> str:

    title = clean_title(source)
    short = " ".join(title.split()[:4])
    return f"{short}…" if len(short) < len(title) else short


def timestamp(seconds: float) -> str:

    """
    Seconds -> "5:26" or "1:02:05", as a video timestamp.
    """

    seconds = int(seconds)
    h, m, s = seconds // 3600, (seconds % 3600) // 60, seconds % 60
    return f"{h}:{m:02d}:{s:02d}" if h else f"{m}:{s:02d}"


def _locator(page=None, time=None) -> str:

    if page:
        return f", p. {page}"
    return f", {timestamp(time)}" if time is not None else ""


def _is_video(source: Dict) -> bool:

    return source.get("type") == "video"


def in_text(style: str, source: Dict, number: Optional[int] = None, page=None, time=None) -> str:

    """
    The in-text citation for a source in the given style.
    """

    where = _locator(page, time)
    d = _parse_date(source.get("date"))
    if style in NUMBERED:
        return f"[{number}{where}]"
    if style == "harvard":
        who = (_surnames(source) or _site(source) or _short_title(source)).replace(" & ", " and ")
        return f"({who}, {d['year'] if d else 'no date'}{where})"
    if style == "chicago":
        # Chicago author-date: (Smith 2023, 45), (Smith and Jones 2023), (Smith et al. 2023)
        names = [_parse_name(n)["last"] for n in _split_authors(source.get("author"))]
        who = f"{names[0]} et al." if len(names) > 3 else " and ".join(names) if len(names) < 3 else f"{names[0]}, {names[1]}, and {names[2]}"
        if not names:
            who = f"“{_short_title(source)}”"
        at = f", {page}" if page else f", {timestamp(time)}" if time is not None else ""
        return f"({who} {d['year'] if d else 'n.d.'}{at})"
    if style == "mla":
        names = [_parse_name(n)["last"] for n in _split_authors(source.get("author"))]
        who = f"{names[0]} et al." if len(names) > 2 else " and ".join(names) if names else f"“{_short_title(source)}”"
        at = f" {page}" if page else f", {timestamp(time)}" if time is not None else ""
        return f"({who}{at})"
    # APA 7
    surnames = _surnames(source)
    year = d["year"] if d else "n.d."
    if surnames:
        return f"({surnames}, {year}{where})"
    return f"(“{_short_title(source)},” {year}{where})"


def is_article(source: Dict) -> bool:

    """
    A journal article: its DOI lookup gave a volume or pages.
    """

    return bool(source.get("volume") or source.get("pages"))


def _pages(source: Dict, single: str = "p. ", several: str = "pp. ") -> str:

    pages = (source.get("pages") or "").replace("-", "–")
    return f"{several if '–' in pages else single}{pages}" if pages else ""


def _doi_link(source: Dict) -> str:

    return f"https://doi.org/{source['doi']}" if source.get("doi") else source.get("url") or ""


def article(style: str, source: Dict, number: Optional[int] = None) -> str:

    """
    The reference list entry for a journal article, with its journal, volume, issue, pages and DOI.
    """

    names = _split_authors(source.get("author"))
    title = clean_title(source).rstrip(".")
    d = _parse_date(source.get("date"))
    year = d["year"] if d else "n.d."
    journal, volume, issue = source.get("site") or "", source.get("volume") or "", source.get("issue") or ""
    pages = (source.get("pages") or "").replace("-", "–")
    link, doi = _doi_link(source), source.get("doi")
    vol_issue = f"{volume}({issue})" if issue else volume

    if style == "harvard":
        who = _list_authors(names, "", " and ") if names else journal
        parts = ", ".join(v for v in [journal, vol_issue, _pages(source)] if v)
        return f"{who} ({year}) ‘{title}’, {parts}. Available at: {link}."

    if style == "mla":
        people = [_parse_name(n) for n in names]
        full = lambda n: f"{n['last']}, {' '.join(n['firsts'])}" if n["firsts"] else n["last"]
        who = (f"{_end_stop(full(people[0]))} " if len(people) == 1 else
               f"{full(people[0])}, and {' '.join(people[1]['firsts'])} {people[1]['last']}. " if len(people) == 2 else
               f"{full(people[0])}, et al. " if people else "")
        parts = ", ".join(v for v in [journal, volume and f"vol. {volume}", issue and f"no. {issue}", year, _pages(source, "p. ", "pp. "), link] if v)
        return f"{who}“{title}.” {parts}."

    if style == "ieee":
        who = f"{_initials_first(names)}, " if names else ""
        when = f"{SHORT_MONTHS[d['month'] - 1]} {year}" if d and d["month"] else year
        parts = ", ".join(v for v in [journal, volume and f"vol. {volume}", issue and f"no. {issue}", _pages(source, "Art. no. "), when] if v)
        return f"[{number}] {who}“{title},” {parts}" + (f", doi: {doi}." if doi else ".")

    if style == "chicago":
        people = [_parse_name(n) for n in names]
        full = [f"{p['last']}, {' '.join(p['firsts'])}" if i == 0 and p["firsts"] else f"{' '.join(p['firsts'])} {p['last']}".strip()
                for i, p in enumerate(people)]
        who = full[0] if len(full) == 1 else f"{full[0]}, and {full[1]}" if len(full) == 2 else ", ".join(full[:-1]) + ", and " + full[-1] if full else journal
        where = f"{journal} {volume}" + (f" ({issue})" if issue else "") + (f": {pages}" if pages else "")
        return f"{_end_stop(who)} {year}. “{title}.” {where.strip()}. {link}."

    if style == "vancouver":
        people = [_parse_name(n) for n in names]
        who = ", ".join(f"{p['last']} {''.join(f[0] for f in p['firsts'])}".strip() for p in people[:6]) + (", et al" if len(people) > 6 else "")
        where = f"{year};{vol_issue}" + (f":{pages}" if pages else "")
        return f"{number}. {who + '. ' if who else ''}{title}. {_end_stop(journal)} {where}." + (f" doi:{doi}" if doi else "")

    if style == "ams":
        who = f"{_initials_first(names)}, " if names else ""
        parts = ", ".join(v for v in [f"{journal} {volume} ({year})".strip(), issue and f"no. {issue}", pages] if v)
        return f"[{number}] {who}{title}, {parts}" + (f", DOI {doi}." if doi else ".")

    # APA 7: Surname, I., & Surname, I. (Year). Title. Journal, Volume(Issue), Pages. https://doi.org/...
    who = _list_authors(names, " ", ", & ") if names else journal
    parts = ", ".join(v for v in [journal, vol_issue, pages] if v)
    return f"{who} ({year}). {title}. {parts}. {link}".strip()


def local_document(style: str, source: Dict, number: Optional[int] = None) -> str:

    """
    A document saved on this computer (lecture notes, a PDF someone sent): cited as a document, by its
    author, title, publisher and year. A file:// path means nothing to a reader, so no link or access
    date. The details come from the source, or from Citation Details in the Library.
    """

    names = _split_authors(source.get("author"))
    title = clean_title(source)
    d = _parse_date(source.get("date"))
    year = d["year"] if d else None
    publisher = source.get("site") or ""
    if style == "harvard":
        # With no author, the title leads: Title (Year) Publisher.
        who = _list_authors(names, "", " and ") if names else ""
        lead = f"{who} ({year or 'no date'}) {_end_stop(title)}" if who else f"{title} ({year or 'no date'})"
        return f"{_end_stop(lead)} {_end_stop(publisher) if publisher else ''}".strip()
    if style == "mla":
        people = [_parse_name(n) for n in names]
        who = f"{people[0]['last']}, {' '.join(people[0]['firsts'])}. " if len(people) == 1 and people[0]["firsts"] else ""
        tail = ", ".join(v for v in [publisher, year] if v)
        return f"{who}{_end_stop(title)} {_end_stop(tail) if tail else ''}".strip()
    if style == "ieee":
        who = f"{_initials_first(names)}, " if names else ""
        rest = ", ".join(v for v in [publisher, year] if v)
        return f"[{number}] {who}“{title},” {_end_stop(rest)}" if rest else f"[{number}] {who}“{_end_stop(title)}”"
    if style == "chicago":
        who = _end_stop(names[0]) + " " if names else ""
        return f"{who}{year + '. ' if year else ''}{_end_stop(title)} {_end_stop(publisher) if publisher else ''}".strip()
    if style == "vancouver":
        people = [_parse_name(n) for n in names]
        who = ", ".join(f"{p['last']} {''.join(f[0] for f in p['firsts'])}".strip() for p in people[:6])
        where = "; ".join(v for v in [publisher, year] if v)
        return f"{number}. {who + '. ' if who else ''}{title.rstrip('.')}. {where + '.' if where else ''}".strip()
    if style == "ams":
        who = f"{_initials_first(names)}, " if names else ""
        return f"[{number}] {who}{_end_stop(', '.join(v for v in [title, publisher, year] if v))}"
    # APA 7: Author. (Year). Title. Publisher.
    # With no author, the title takes the author's place: Title. (Year). Publisher.
    who = _list_authors(names, " ", ", & ") if names else ""
    when = f"({year})." if year else "(n.d.)."
    lead = [_end_stop(who), when, _end_stop(title)] if who else [_end_stop(title), when]
    return " ".join(lead + ([_end_stop(publisher)] if publisher else []))


def reference(style: str, source: Dict, number: Optional[int] = None) -> str:

    """
    The reference list entry for a source in the given style.
    """

    if is_article(source):
        return article(style, source, number)
    if (source.get("url") or "").startswith("file://"):
        return local_document(style, source, number)

    names = _split_authors(source.get("author"))
    title = clean_title(source)
    d = _parse_date(source.get("date"))
    a = _accessed(source)
    url = source.get("url") or ""
    site = _site(source)

    if style == "harvard":
        who = _list_authors(names, "", " and ") if names else site or title
        video = " [Video]" if _is_video(source) else ""
        return (f"{who} ({d['year'] if d else 'no date'}) {_end_stop(title + video)} "
                f"Available at: {url} (Accessed: {a['day']} {MONTHS[a['month'] - 1]} {a['year']}).")

    if style == "mla":
        people = [_parse_name(n) for n in names]
        full = lambda n: f"{n['last']}, {' '.join(n['firsts'])}" if n["firsts"] else n["last"]
        who = ""
        if len(people) == 1:
            who = f"{_end_stop(full(people[0]))} "
        elif len(people) == 2:
            who = f"{full(people[0])}, and {' '.join(people[1]['firsts'])} {people[1]['last']}. "
        elif len(people) > 2:
            who = f"{full(people[0])}, et al. "
        when = lambda x: " ".join(str(v) for v in [x["day"], SHORT_MONTHS[x["month"] - 1] if x["month"] else None, x["year"]] if v)
        container = ", ".join(v for v in [site, when(d) if d else None, url] if v)
        return f"{who}“{_end_stop(title)}” {container}. Accessed {when(a)}."

    if style == "ieee":
        who = f"{_initials_first(names)}, " if names else ""
        rest = ", ".join(v for v in [site, d["year"] if d else None] if v)
        body = _end_stop(f"“{title},” {rest}") if rest else f"“{_end_stop(title)}”"
        kind = "Online Video" if _is_video(source) else "Online"
        return (f"[{number}] {who}{body} [{kind}]. Available: {url} "
                f"(Accessed: {SHORT_MONTHS[a['month'] - 1]} {a['day']}, {a['year']}).")

    if style == "chicago":
        # Smith, Jane, and Tom Jones. 2023. “Title.” Site, Month Day, Year. URL.
        people = [_parse_name(n) for n in names]
        full = [f"{p['last']}, {' '.join(p['firsts'])}" if i == 0 and p["firsts"] else f"{' '.join(p['firsts'])} {p['last']}".strip()
                for i, p in enumerate(people)]
        who = full[0] if len(full) == 1 else f"{full[0]}, and {full[1]}" if len(full) == 2 else ", ".join(full[:-1]) + ", and " + full[-1] if full else site or title
        when = f"{MONTHS[d['month'] - 1]} {d['day']}, {d['year']}" if d and d["month"] and d["day"] else None
        video = " YouTube video." if _is_video(source) else ""
        tail = f"{site}, {when}." if site and when else f"{site}." if site else ""
        accessed = "" if d else f" Accessed {MONTHS[a['month'] - 1]} {a['day']}, {a['year']}."
        return f"{_end_stop(who)} {d['year'] + '.' if d else 'n.d.'} “{_end_stop(title)}”{video} {tail}{accessed} {url}.".replace("  ", " ")

    if style == "vancouver":
        # 1. Smith J, Jones T. Title [Internet]. Site; 2023 [cited 2026 Oct 11]. Available from: URL
        people = [_parse_name(n) for n in names]
        who = ", ".join(f"{p['last']} {''.join(f[0] for f in p['firsts'])}".strip() for p in people[:6]) + (", et al" if len(people) > 6 else "")
        kind = "Video" if _is_video(source) else "Internet"
        cited = f"{a['year']} {SHORT_MONTHS[a['month'] - 1].rstrip('.')} {a['day']}"
        where = "; ".join(v for v in [site, d["year"] if d else None] if v)
        return f"{number}. {who + '. ' if who else ''}{title.rstrip('.')} [{kind}]. {where + ' ' if where else ''}[cited {cited}]. Available from: {url}"

    if style == "ams":
        who = f"{_initials_first(names)}, " if names else ""
        parts = ", ".join(v for v in [title + (" (video)" if _is_video(source) else ""), site, d["year"] if d else None] if v)
        return f"[{number}] {who}{_end_stop(parts)} Available at {url} (accessed {a['day']} {MONTHS[a['month'] - 1]} {a['year']})."

    # APA 7: Author. (Year, Month Day). Title. Site. URL
    date_part = "(n.d.)"
    if d:
        date_part = f"({d['year']}"
        if d["month"]:
            date_part += f", {MONTHS[d['month'] - 1]}" + (f" {d['day']}" if d["day"] else "")
        date_part += ")"
    where = f" {_end_stop(site)}" if site else ""
    link = f" {url}" if url else ""
    if _is_video(source):
        who = _list_authors(names, " ", ", & ") if names else site
        return f"{who}. {date_part}. {title} [Video]. YouTube.{link}"
    if names:
        return f"{_list_authors(names, ' ', ', & ')} {date_part}. {_end_stop(title)}{where}{link}"
    return f"{_end_stop(title)} {date_part}.{where}{link}"


def sort_key(source: Dict) -> str:

    """
    Alphabetical position in an author-date reference list.
    """

    names = _split_authors(source.get("author"))
    return (_parse_name(names[0])["last"] if names else _site(source) or clean_title(source)).lower()
