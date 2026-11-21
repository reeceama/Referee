"""Accurate details for academic sources, from their DOI.

When a page or PDF is captured, its DOI is found (in the page's citation tags, its text, or an
arXiv link) and looked up at doi.org, which answers for Crossref and DataCite alike: exact
authors, year, journal, volume and pages replace whatever the page itself said. Crossref is
then asked whether the paper has been retracted (its data includes Retraction Watch).
Lookups have short timeouts and failures are ignored: a source is never held up or lost.
"""

import html
import re
from typing import Dict, Optional

import requests

import privacy

DOI = re.compile(r"\b(10\.\d{4,9}/[^\s\"'<>]+[^\s\"'<>.,;)\]])", re.IGNORECASE)
META_DOI = re.compile(r'<meta[^>]+name=["\'](?:citation_doi|dc\.identifier|prism\.doi)["\'][^>]+content=["\'](?:doi:)?([^"\']+)["\']', re.IGNORECASE)
ARXIV = re.compile(r"arxiv\.org/(?:abs|pdf)/(\d{4}\.\d{4,5})", re.IGNORECASE)
TIMEOUT = 6


def find_doi(url: str, text: str = "", pdf: bool = False) -> Optional[str]:

    """
    The source's own DOI: an arXiv link's, one in the link itself (doi.org/...), a citation tag in the page,
    or, for a PDF, the first DOI on its first page, where a paper prints its own. A DOI anywhere else in a
    page is a citation of something else (a README citing a paper), so it isn't used: the page would take
    that paper's title and authors.
    """

    arxiv = ARXIV.search(url or "")
    if arxiv:
        return f"10.48550/arXiv.{arxiv.group(1)}"
    in_link = DOI.search(requests.utils.unquote(url or ""))
    if in_link:
        return in_link.group(1).strip()
    tagged = META_DOI.search(text or "")
    if tagged:
        return tagged.group(1).strip()
    if pdf:
        found = DOI.search((text or "")[:3000])
        if found:
            return found.group(1).strip()
    return None


def lookup(doi: str) -> Dict:

    """
    Citation details for a DOI, in Referee's metadata fields; empty if doi.org doesn't know it.
    """
    if not privacy.allowed("paper_details"):
        return {}  # switched off in Settings: nothing is sent

    try:
        response = requests.get(f"https://doi.org/{doi}", timeout=TIMEOUT,
                                headers={"Accept": "application/vnd.citationstyles.csl+json"})
        data = response.json() if response.ok else {}
    except (requests.RequestException, ValueError):
        return {}
    people = [f"{a.get('given', '')} {a.get('family', '')}".strip() for a in data.get("author", []) if a.get("family")]
    parts = ((data.get("issued") or {}).get("date-parts") or [[]])[0]
    found = {
        # Without the markup some publishers put in titles ("<scp>CIELAB</scp>", "<i>k</i>").
        "title": html.unescape(re.sub(r"\s+", " ", re.sub(r"<[^>]+>", "", data.get("title") or "")).strip()) or None,
        "author": "; ".join(people) or None,
        "date": "-".join(f"{p:02d}" if i else str(p) for i, p in enumerate(parts)) or None,
        "site": html.unescape(data.get("container-title") or data.get("publisher") or "") or None,
        "volume": data.get("volume"),
        "issue": data.get("issue"),
        "pages": data.get("page") or data.get("article-number"),  # online-only journals number articles
        "doi": doi,
        # The abstract (JATS XML): pages often leave it out of their main text, where it's missed.
        "abstract": re.sub(r"\s+", " ", re.sub(r"<jats:title>.*?</jats:title>|<[^>]+>", " ", data.get("abstract") or "")).strip() or None,
    }
    return {k: v for k, v in found.items() if v}


def retracted(doi: str) -> bool:

    """
    Whether Crossref records a retraction of this paper.
    """
    if not privacy.allowed("paper_details"):
        return False  # switched off in Settings: nothing is sent

    if doi.lower().startswith("10.48550/"):  # arXiv: not in Crossref
        return False
    try:
        response = requests.get(f"https://api.crossref.org/works/{doi}", timeout=TIMEOUT)
        updates = response.json().get("message", {}).get("updated-by", []) if response.ok else []
    except (requests.RequestException, ValueError):
        return False
    return any(u.get("type") == "retraction" for u in updates)


def enrich(metadata: Dict, text: str = "", pdf: bool = False) -> Dict:

    """
    Fills in the metadata from the source's DOI, if it has one. Returns the same dictionary.
    """

    doi = find_doi(metadata.get("url") or "", text, pdf)
    if not doi:
        return metadata
    details = lookup(doi)
    if details:
        metadata.update(details)
        metadata["retracted"] = retracted(doi)
    return metadata
