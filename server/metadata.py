"""Accurate details for academic sources, from their DOI.

When a page or PDF is captured, its DOI is found (in the page's citation tags, its text, or an
arXiv link) and looked up at doi.org, which answers for Crossref and DataCite alike: exact
authors, year, journal, volume and pages replace whatever the page itself said. Crossref is
then asked whether the paper has been retracted (its data includes Retraction Watch).
Lookups have short timeouts and failures are ignored: a source is never held up or lost.
"""

import re
from typing import Dict, Optional

import requests

import privacy

DOI = re.compile(r"\b(10\.\d{4,9}/[^\s\"'<>]+[^\s\"'<>.,;)\]])", re.IGNORECASE)
META_DOI = re.compile(r'<meta[^>]+name=["\'](?:citation_doi|dc\.identifier|prism\.doi)["\'][^>]+content=["\'](?:doi:)?([^"\']+)["\']', re.IGNORECASE)
ARXIV = re.compile(r"arxiv\.org/(?:abs|pdf)/(\d{4}\.\d{4,5})", re.IGNORECASE)
TIMEOUT = 6


def find_doi(url: str, text: str = "") -> Optional[str]:

    """
    The DOI for a source: an arXiv link's DOI, a citation tag in the page, or the first DOI in its text.
    """

    arxiv = ARXIV.search(url or "")
    if arxiv:
        return f"10.48550/arXiv.{arxiv.group(1)}"
    for pattern in (META_DOI, DOI):
        found = pattern.search(text or "")
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
        "title": data.get("title") or None,
        "author": "; ".join(people) or None,
        "date": "-".join(f"{p:02d}" if i else str(p) for i, p in enumerate(parts)) or None,
        "site": data.get("container-title") or data.get("publisher") or None,
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


def enrich(metadata: Dict, text: str = "") -> Dict:

    """
    Fills in the metadata from the source's DOI, if it has one. Returns the same dictionary.
    """

    doi = find_doi(metadata.get("url") or "", text)
    if not doi:
        return metadata
    details = lookup(doi)
    if details:
        metadata.update(details)
        metadata["retracted"] = retracted(doi)
    return metadata
