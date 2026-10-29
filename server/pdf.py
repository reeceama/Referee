"""Passages from PDFs, such as academic papers, with the page each passage starts on.

PDF text comes out line by line, with words hyphenated across line breaks and the
reference list at the end, so it needs more cleaning than a web page.
"""

import io
import re
from typing import Dict, List, Optional, Tuple

from pypdf import PdfReader

from extract import MIN_SENTENCE_WORDS, SENTENCE_SPLIT

PASSAGE_SIZE = 3  # sentences per passage, overlapping by one (as for web pages)
REFERENCES = re.compile(r"^\s*(references|bibliography|works cited|literature cited)\s*$", re.IGNORECASE | re.MULTILINE)
CITATION_MARKERS = re.compile(r"\s*\[\d+(?:[,–-]\s*\d+)*\]")  # [3], [3, 7], [3-5]


def clean_page(text: str) -> str:

    """
    Join a page's lines into running text.
    """

    text = re.sub(r"(\w)-\n(\w)", r"\1\2", text)  # re-join words hyphenated over a line break
    text = CITATION_MARKERS.sub("", text)
    return re.sub(r"\s+", " ", text).strip()


def pdf_date(raw: Optional[str]) -> Optional[str]:

    """
    PDF dates look like D:20230514120000; return 2023-05-14.
    """

    match = re.match(r"D?:?(\d{4})(\d{2})?(\d{2})?", raw or "")
    if not match:
        return None
    return "-".join(part for part in match.groups() if part)


BOILERPLATE = re.compile(r"permission|copyright|licen[cs]e|©|arxiv|preprint|proceedings|conference|journal|"
                         r"vol\.|doi|https?:|www\.|@|accepted|submitted|published", re.IGNORECASE)


def first_page_title(text: str) -> Optional[str]:

    """
    The title from the first page's lines: the first short line that isn't publishing or legal
    boilerplate and doesn't end like a sentence.
    """

    for line in (text or "").splitlines()[:25]:
        line = line.strip()
        if 2 <= len(line.split()) <= 20 and not line.endswith((".", ",", ";", ":")) and not BOILERPLATE.search(line):
            return line
    return None


def page_texts(data: bytes) -> List[str]:

    """
    Each page's raw text, for matching better text back to pages.
    """

    try:
        return [page.extract_text() or "" for page in PdfReader(io.BytesIO(data)).pages]
    except Exception:
        return []


def extract_pdf(data: bytes, url: Optional[str] = None) -> Tuple[Dict, List[Tuple[str, int]]]:

    """
    Return metadata and a list of (passage, page number) from a PDF.
    """

    try:
        reader = PdfReader(io.BytesIO(data))
    except Exception as error:
        raise ValueError(f"Not a readable PDF: {error}")

    info = reader.metadata or {}
    metadata = {
        "title": (info.get("/Title") or "").strip() or None,
        "author": (info.get("/Author") or "").strip() or None,
        "date": pdf_date(info.get("/CreationDate")),
        "site": None,
        "url": url,
        "type": "pdf",
    }

    # Each page's text; scanned pages (little or no text of their own) are read from their image
    # on this Mac with Apple's Vision, and the source is marked as partly read from images.
    texts = [page.extract_text() or "" for page in reader.pages]
    if texts and sum(len(t.strip()) < 40 for t in texts) > len(texts) / 3:
        import ocr
        found = ocr.read(data, ".pdf")
        if found and any(t.strip() for t in found[0]):
            texts, metadata["scanned_pages"] = found[0], found[1]

    # Sentences tagged with their page, stopping at the reference list.
    sentences: List[Tuple[str, int]] = []
    for number, raw in enumerate(texts, start=1):
        heading = REFERENCES.search(raw)
        if heading and number > 1:
            raw = raw[: heading.start()]
        for sentence in SENTENCE_SPLIT.split(clean_page(raw)):
            if len(sentence.split()) >= MIN_SENTENCE_WORDS:
                sentences.append((sentence.strip(), number))
        if heading and number > 1:
            break

    if not sentences:
        raise ValueError("No readable text in this PDF, and it couldn't be read as a scan here.")
    if not metadata["title"]:
        first_page = texts[0] if texts else ""
        metadata["title"] = first_page_title(first_page) or sentences[0][0][:120]

    passages = []
    step = PASSAGE_SIZE - 1
    for start in range(0, len(sentences), step):
        group = sentences[start : start + PASSAGE_SIZE]
        passages.append((" ".join(text for text, _ in group), group[0][1]))
        if start + PASSAGE_SIZE >= len(sentences):
            break
    return metadata, passages
