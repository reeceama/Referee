"""The maths-faithful text of a paper saved as a PDF.

PDF text scrambles mathematics: subscripts drift, fractions split and symbols vanish or turn into
look-alikes, so a theorem read from a PDF can't be compared reliably. When a paper has a better
version online, its text is used instead:

    1. arXiv's LaTeX source (the authors' own TeX: exact),
    2. arXiv's HTML version (MathML with the TeX kept),
    3. the publisher's page, found through the DOI (MathJax or MathML).

Each passage is then matched to the PDF page with the most words in common, so citations keep
their page numbers. If nothing better is found, the PDF's own text is used as before.
"""

import gzip
import io
import re
import tarfile
from typing import Dict, List, Optional, Tuple

import requests

import privacy

from extract import extract_page, make_passages, split_sentences
from metadata import find_doi

TIMEOUT = 20
HEADERS = {"User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"}
ARXIV_ID = re.compile(r"(?:arxiv\.org/(?:abs|pdf|html)/|arXiv:)\s*(\d{4}\.\d{4,5}|[a-z\-]+(?:\.[A-Z]{2})?/\d{7})(?:v\d+)?", re.IGNORECASE)
WORD = re.compile(r"[a-z]{4,}")
MIN_WORDS = 1500  # less than this isn't the full paper (an abstract page, a paywall)


def arxiv_id(url: str, text: str = "") -> Optional[str]:

    for haystack in (url or "", (text or "")[:5000]):
        found = ARXIV_ID.search(haystack)
        if found:
            return found.group(1)
    return None


def arxiv_by_title(title: str) -> Optional[str]:

    """
    The arXiv version of a published paper, found by its exact title (most maths papers have one).
    """
    if not privacy.allowed("paper_details"):
        return None  # switched off in Settings: nothing is sent

    squash = lambda t: re.sub(r"[^a-z0-9]", "", (t or "").lower())
    if len(squash(title)) < 15:
        return None
    words = " AND ".join(f"ti:{w}" for w in re.findall(r"[A-Za-z]{3,}", title)[:12])
    try:
        response = requests.get("https://export.arxiv.org/api/query", params={"search_query": words, "max_results": 5},
                                headers=HEADERS, timeout=TIMEOUT)
    except requests.RequestException:
        return None
    for entry in re.findall(r"<entry>(.*?)</entry>", response.text, re.DOTALL):
        found_title = re.search(r"<title>(.*?)</title>", entry, re.DOTALL)
        found_id = re.search(r"<id>https?://arxiv\.org/abs/([^<]+?)(?:v\d+)?</id>", entry)
        if found_title and found_id and squash(found_title.group(1)) == squash(title):
            return found_id.group(1)
    return None


# --- LaTeX source -> running text with the maths kept as TeX ---

MATH = re.compile(r"\$\$.*?\$\$|\\\[.*?\\\]|\\\(.*?\\\)|(?<!\\)\$.*?(?<!\\)\$|"
                  r"\\begin\{(equation|align|gather|multline|eqnarray|displaymath)\*?\}.*?\\end\{\1\*?\}", re.DOTALL)
DROPPED = r"figure|table|tikzpicture|algorithm|lstlisting|verbatim|thebibliography|comment"


def _main_file(files: Dict[str, str]) -> Optional[str]:

    candidates = [name for name, text in files.items() if name.endswith(".tex") and "\\documentclass" in text]
    return max(candidates, key=lambda n: ("\\begin{document}" in files[n], len(files[n])), default=None)


def _inline(text: str, files: Dict[str, str], depth: int = 0) -> str:

    """
    Replaces \\input{x} and \\include{x} with the files' contents.
    """

    if depth > 5:
        return text

    def read(match):
        name = match.group(1).strip()
        for candidate in (name, f"{name}.tex"):
            for path, content in files.items():
                if path == candidate or path.endswith("/" + candidate):
                    return _inline(content, files, depth + 1)
        return ""

    return re.sub(r"\\(?:input|include|subfile)\{([^}]+)\}", read, text)


def latex_to_text(tex: str) -> str:

    """
    Running text from a paper's LaTeX: sections and theorem headings on their own lines, maths kept
    as $...$ and $$...$$, citations, labels, figures and the bibliography removed.
    """

    titles = {m.group(1): m.group(2) for m in re.finditer(r"\\newtheorem\*?\{(\w+)\}(?:\[\w+\])?\{([^}]+)\}", tex)}
    titles.update({k: k.capitalize() for k in ("theorem", "lemma", "proposition", "corollary", "conjecture", "definition", "remark", "example")
                   if k not in titles})
    text = re.sub(r"(?<!\\)%.*", "", tex)
    start = text.find("\\begin{document}")
    text = text[start + 16:] if start >= 0 else text
    text = re.split(r"\\begin\{thebibliography\}|\\bibliography\{|\\printbibliography|\\end\{document\}", text)[0]
    text = re.sub(rf"\\begin\{{({DROPPED})\*?\}}.*?\\end\{{\1\*?\}}", " ", text, flags=re.DOTALL)

    # Keep maths exactly: set it aside while the prose is cleaned.
    kept: List[str] = []

    def keep(match):
        maths = match.group(0)
        if match.group(1):  # a displayed environment: as $$...$$ on its own line
            body = re.sub(r"^\\begin\{[^}]*\}|\\end\{[^}]*\}$", "", maths).strip()
            maths = f"\n$$ {re.sub(r'\\\\label\\{[^}]*\\}', '', body)} $$\n"
        elif maths.startswith(("\\[", "$$")):
            maths = f"\n$$ {maths[2:-2].strip()} $$\n"
        kept.append(" ".join(maths.split(" ")))
        return f"\u0000{len(kept) - 1}\u0000"

    text = MATH.sub(keep, text)
    for name, title in titles.items():
        text = re.sub(rf"\\begin\{{{name}\*?\}}(?:\[([^\]]*)\])?",
                      lambda m, t=title: f"\n\n{t}" + (f" ({m.group(1)})" if m.group(1) else "") + ": ", text)
        text = re.sub(rf"\\end\{{{name}\*?\}}", "\n\n", text)
    text = re.sub(r"\\begin\{proof\}(?:\[[^\]]*\])?", "\n\nProof: ", text)
    text = re.sub(r"\\(?:part|chapter|(?:sub)*section|paragraph)\*?(?:\[[^\]]*\])?\{([^}]*)\}", r"\n\n\1\n\n", text)
    text = re.sub(r"\\item\b(?:\[[^\]]*\])?", "\n", text)
    text = re.sub(r"\s*\\(?:cite\w*|citep|citet)\*?(?:\[[^\]]*\]){0,2}\{[^}]*\}", "", text)
    text = re.sub(r"\\(?:label|bibliographystyle|vspace|hspace)\*?\{[^}]*\}", "", text)
    text = re.sub(r"\\(?:eq|c|C|auto)?ref\{[^}]*\}", "(ref)", text)
    for _ in range(3):
        text = re.sub(r"\\(?:emph|textbf|textit|texttt|textsc|underline|text|mbox|footnote)\{([^{}]*)\}", r"\1", text)
    text = re.sub(r"\\(?:begin|end)\{[^}]*\}(?:\[[^\]]*\])?", "\n\n", text)
    text = re.sub(r"\\[a-zA-Z]+\*?", " ", text).replace("~", " ").replace("``", "\"").replace("''", "\"")
    text = re.sub(r"[{}]", "", text)
    text = re.sub(r"\u0000(\d+)\u0000", lambda m: kept[int(m.group(1))], text)
    text = re.sub(r"[ \t]+", " ", text)
    return re.sub(r"\n\s*\n\s*", "\n\n", text).strip()


def _arxiv_source(identifier: str) -> Optional[str]:
    if not privacy.allowed("paper_details"):
        return None  # switched off in Settings: nothing is sent

    try:
        response = requests.get(f"https://arxiv.org/e-print/{identifier}", headers=HEADERS, timeout=TIMEOUT)
    except requests.RequestException:
        return None
    if not response.ok:
        return None
    data = response.content
    files: Dict[str, str] = {}
    try:
        with tarfile.open(fileobj=io.BytesIO(data)) as archive:
            for member in archive.getmembers():
                if member.isfile() and member.name.endswith((".tex", ".ltx")) and member.size < 5_000_000:
                    files[member.name] = archive.extractfile(member).read().decode("utf-8", errors="ignore")
    except tarfile.TarError:
        try:  # a single gzipped .tex file
            files["main.tex"] = gzip.decompress(data).decode("utf-8", errors="ignore")
        except OSError:
            return None
    main = _main_file(files)
    return latex_to_text(_inline(files[main], files)) if main else None


def _html(url: str) -> Optional[str]:
    if not privacy.allowed("paper_details"):
        return None  # switched off in Settings: nothing is sent

    try:
        response = requests.get(url, headers=HEADERS, timeout=TIMEOUT)
        if not response.ok or "html" not in response.headers.get("content-type", ""):
            return None
        return extract_page(response.text, response.url)[0]
    except (requests.RequestException, ValueError):
        return None


def find(url: str, pdf_text: str, title: Optional[str] = None, doi: Optional[str] = None) -> Optional[Tuple[str, str]]:

    """
    (text, where it came from) for the paper's best online version, or None.
    """

    identifier = arxiv_id(url, pdf_text) or (arxiv_by_title(title) if title else None)
    attempts = []
    if identifier:
        attempts += [(lambda: _arxiv_source(identifier), "arXiv LaTeX source"),
                     (lambda: _html(f"https://arxiv.org/html/{identifier}"), "arXiv HTML")]
    doi = doi or find_doi(url, pdf_text[:20000])
    if doi and not doi.lower().startswith("10.48550/"):
        attempts.append((lambda: _html(f"https://doi.org/{doi}"), "publisher's page"))
    for attempt, where in attempts:
        text = attempt()
        if text and len(text.split()) >= MIN_WORDS:
            return text, where
    return None


def page_for(passages: List[str], pages: List[str]) -> List[int]:

    """
    For each passage, the PDF page (from 1) sharing most of its words. Ties go to the page after
    the previous passage's, since a paper reads in order.
    """

    page_words = [set(WORD.findall(p.lower())) for p in pages]
    found, previous = [], 1
    for passage in passages:
        words = set(WORD.findall(passage.lower()))
        scores = [len(words & w) for w in page_words]
        best = max(scores, default=0)
        if best == 0:
            found.append(previous)
            continue
        candidates = [i + 1 for i, s in enumerate(scores) if s == best]
        previous = min(candidates, key=lambda p: (p < previous, abs(p - previous)))
        found.append(previous)
    return found


def passages(url: str, pdf_pages: List[str], title: Optional[str] = None, doi: Optional[str] = None) -> Optional[Tuple[List[str], List[int], str]]:

    """
    (passages, their PDF pages, where the text came from), or None to keep the PDF's own text.
    """

    better = find(url, "\n".join(pdf_pages[:2]), title, doi)
    if better is None:
        return None
    text, where = better
    found = make_passages(split_sentences(text))
    if not found:
        return None
    return found, page_for(found, pdf_pages), where
