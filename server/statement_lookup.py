"""Finds a numbered statement (Theorem 4.50, Definition 4.17, Cor 4.41) in a saved source, for the
preview shown when hovering over a reference in a note: its wording as the source prints it, and
its page. No AI: the source's own text, from where its label appears to where the next numbered
item or proof begins.

PDFs saved from this computer are read page by page, so the page is exact; other sources are
searched in their saved passages, with the page those carry.
"""

import re
from functools import lru_cache
from pathlib import Path
from typing import Dict, List, Optional
from urllib.parse import unquote, urlparse

from pdf import page_texts

KINDS = {
    "def": "Definition", "defn": "Definition", "definition": "Definition", "definitions": "Definition",
    "thm": "Theorem", "theorem": "Theorem", "theorems": "Theorem",
    "lem": "Lemma", "lemma": "Lemma", "prop": "Proposition", "proposition": "Proposition",
    "cor": "Corollary", "corollary": "Corollary", "ex": "Example", "example": "Example",
    "rem": "Remark", "remark": "Remark", "eq": "Equation", "equation": "Equation",
    "fig": "Figure", "figure": "Figure",
}
# A bare equation number, as maths writing refers to them: "(4.1)", "by (4.7)".
EQUATION = re.compile(r"(?<![\w\]])\((\d+\.\d+)\)")
BY_PAGE = re.compile(r"\b(" + "|".join(sorted(KINDS, key=len, reverse=True)) + r")\.?\s*\(\s*p(?:age|p)?\.?\s*(\d+)\s*\)", re.I)
REFERENCE = re.compile(r"\b(" + "|".join(sorted(KINDS, key=len, reverse=True)) + r")\.?\s+(\d+(?:\.\d+)+)(?:\s*\(([a-z]|[ivx]+)\))?", re.I)
NEXT_ITEM = re.compile(r"\n?\s*(?:Definition|Theorem|Lemma|Proposition|Corollary|Example|Remark|Proof|Exercise)s?\b"
                       r"(?:\s+\d+(?:\.\d+)+)?[.:]", re.I)
MAX = 900


def references(text: str) -> List[Dict]:

    """
    The numbered statements a line points to: [{"kind": "Theorem", "number": "4.50"}], in order.
    """

    found, seen = [], set()
    # A part after the number ("Theorem 4.50(b)") is kept, so the preview shows that part.
    matches = [(m.start(), KINDS[m.group(1).lower()], m.group(2), (m.group(3) or "").lower()) for m in REFERENCE.finditer(text)]
    matches += [(m.start(), "Equation", m.group(1), "") for m in EQUATION.finditer(text)]
    # No number, only a page ("Theorem (p. 55)"): the statement of that kind on that page.
    matches += [(m.start(), KINDS[m.group(1).lower()], "", f"p{m.group(2)}") for m in BY_PAGE.finditer(text)]
    for _, kind, number, part in sorted(matches):
        item = (kind, number, part)
        if item not in seen:
            seen.add(item)
            if part.startswith("p") and not number:
                found.append({"kind": kind, "number": "", "part": "", "page": int(part[1:])})
            else:
                found.append({"kind": kind, "number": number, "part": part})
    return found


@lru_cache(maxsize=16)
def _pdf_pages(path: str, modified: float) -> tuple:

    try:
        return tuple(page_texts(Path(path).read_bytes()))
    except OSError:
        return ()


def _ligatures(text: str) -> str:

    return text.replace("ﬁ", "fi").replace("ﬂ", "fl").replace("ﬀ", "ff").replace("ﬃ", "ffi")


def find(kind: str, number: str, url: str, passages: List[Dict], part: str = "") -> Optional[Dict]:

    """
    {"kind", "number", "text", "page"} for the statement in this source, or None.
    """

    if kind == "Equation":
        return _equation(number, url, passages)
    if not number:
        return None   # found by page instead: number_on_page
    label = re.compile(rf"{kind}\s+{re.escape(number)}(?![\d])\s*(\([^)]{{0,60}}\))?\s*[.:]", re.I)
    pages: List[str] = []
    if url.startswith("file://"):
        path = unquote(urlparse(url).path)
        if Path(path).is_file():
            pages = [_ligatures(t) for t in _pdf_pages(path, Path(path).stat().st_mtime)]
    for i, page in enumerate(pages):
        m = label.search(page)
        if m:
            # The whole statement, every part, whichever part was named: (a) and (b) show the same.
            following = page[m.start():] + "\n" + (pages[i + 1] if i + 1 < len(pages) else "")
            return {"kind": kind, "number": number, "text": _statement(following, m.end() - m.start()), "page": i + 1,
                    "raw": _raw(following, m.end() - m.start())}
    for p in passages:  # web pages and anything not on disk: the saved passages
        text = _ligatures(p.get("text") or "")
        m = label.search(text)
        if m:
            return {"kind": kind, "number": number, "text": _statement(text[m.start():], m.end() - m.start()),
                    "page": p.get("page")}
    return None


def _equation(number: str, url: str, passages: List[Dict]) -> Optional[Dict]:

    """
    An equation, found by the number printed beside it, "(4.1)": the lines just before it, where the
    equation itself is (its page picture shows it as printed; PDF text keeps little of a display).
    """

    tag = re.compile(rf"\({re.escape(number)}\)")
    pages: List[str] = []
    if url.startswith("file://"):
        path = unquote(urlparse(url).path)
        if Path(path).is_file():
            pages = [_ligatures(t) for t in _pdf_pages(path, Path(path).stat().st_mtime)]
    for i, page in enumerate(pages):
        for m in tag.finditer(page):
            # The printed tag sits at the end of its equation's line; skip references to it in text,
            # which have words straight after them on the same line.
            after = page[m.end():m.end() + 40].split("\n")[0].strip()
            if after and after[0].isalpha():
                continue
            start = page.rfind("\n", 0, max(0, m.start() - 160))
            raw = page[start + 1 if start >= 0 else 0:m.end()].strip()
            return {"kind": "Equation", "number": number, "page": i + 1, "raw": raw,
                    "text": f"**Equation ({number})** " + as_maths(re.sub(r"\s*\n\s*", " ", raw.replace(f"({number})", "")).strip())}
    return None


def _raw(text: str, head: int) -> str:

    """
    The statement as the PDF's text has it, label included, for finding it on the page.
    """

    stop = NEXT_ITEM.search(text[head:])
    return (text[:head + stop.start()] if stop else text[:head + MAX]).strip()


def _statement(text: str, head: int) -> str:

    """
    From the label to the next numbered item or proof, tidied, at most a short paragraph or two.
    """

    rest = text[head:]
    stop = NEXT_ITEM.search(rest)
    body = rest[:stop.start()] if stop else rest
    body = re.sub(r"-\n(?=[a-z])", "", body)            # words split across lines
    body = re.sub(r"\s*\n\s*", " ", body).strip()
    if len(body) > MAX:
        body = body[:MAX].rsplit(" ", 1)[0] + " …"
    return f"**{text[:head].strip()}** {as_maths(body)}".strip()


def as_maths(text: str) -> str:

    """
    A PDF's flattened maths, tidied into Markdown with $LaTeX$, for the preview: "v1,..., vn" ->
    "$v_1, \\dots, v_n$", "c1v1 +··· +cnvn" -> "$c_1v_1 + \\cdots + c_nv_n$", "spaceV ." -> "space V.".
    Only patterns that are clearly maths are touched; anything else is left as the PDF has it.
    """

    # Set-builder notation: {α1v1 +··· +αnvn|α1,...,α n∈ R} -> $\{… \mid … \in \mathbb{R}\}$,
    # with the parts inside tidied by the rules below first.
    def set_builder(m):
        inner = lambda t: as_maths(t).replace("$", "").strip()
        field = lambda t: re.sub(r"(?:∈|\\in)\s*([RCQZN])\b", lambda f: "\\in \\mathbb{" + f.group(1) + "}", t)
        inner_raw = inner
        inner = lambda t: inner_raw(t).replace("∈", "\\in ")
        return "$\\{" + inner(m.group(1)) + " \\mid " + field(inner(m.group(2))) + "\\}$"
    text = re.sub(r"\{([^{}|$]+)\|([^{}|$]+)\}", set_builder, text)
    # Other ways PDFs write the dots: "· · ·" and "a1,.,am".
    text = re.sub(r"·\s·\s·", "···", text)
    text = re.sub(r",\s*\.\s*,", ",...,", text)
    # Sums with their first terms written out: x1a1 + x2a2 + ··· + xmam
    text = re.sub(r"(?<![\w$])([a-z])1([a-z])1\s*\+\s*\1\s?2\2\s?2\s*\+\s*(?:···|⋯|\.\.\.)\s*\+\s*\1([nmk])\2\3(?![\w])",
                  r"$\1_1\2_1 + \1_2\2_2 + \\cdots + \1_\3\2_\3$", text)
    # Words the PDF ran into a following single-letter variable: "spaceV", "forV", "spansV".
    text = re.sub(r"\b([a-z]{2,})([A-Z])(?=[\s.,;:)}]|$)", r"\1 \2", text)
    # Lists like v1,..., vn (and c1,...,c n, where the PDF split the subscript).
    text = re.sub(r"(?<![\w$])([a-zA-Zα-ω])\s?1\s*,\s*(?:\.\.\.|…)\s*,?\s*\1\s?([nmk])(?![\w])",
                  r"$\1_1, \\dots, \1_\2$", text)
    # Sums written out: c1v1 +··· +cnvn
    text = re.sub(r"(?<![\w$])([a-zα-ω])1([a-z])1\s*\+\s*(?:···|⋯|\.\.\.|\\cdots)\s*\+\s*\1n\2n(?![\w])",
                  r"$\1_1\2_1 + \\cdots + \1_n\2_n$", text)
    # Products and terms like α1v1, c1v1, a1, v2 outside those patterns.
    text = re.sub(r"(?<![\w$\\])([a-zα-ω])(\d)(?:([a-z])(\d))?(?![\w])",
                  lambda m: "$" + m.group(1) + "_" + m.group(2) + (m.group(3) + "_" + m.group(4) if m.group(3) else "") + "$", text)
    text = text.replace("···", "⋯")
    text = re.sub(r"(?<=[a-z])\{", " {", text)                          # "If{" -> "If {", before the sets below
    # Sets, membership and Span around those: {$…$} -> $\{…\}$, $…$∈V -> $… \in V$,
    # Span($…$) =V -> $\mathrm{Span}(…) = V$.
    text = re.sub(r"\{\s*\$([^$]+)\$\s*\}", r"$\\{\1\\}$", text)
    text = re.sub(r"\b(Span|span)\s*\(\s*\$([^$]+)\$\s*\)", r"$\\mathrm{Span}(\2)$", text)
    text = re.sub(r"(?<![\w$\\])R\s?([nmk2-9])(?![\w])", r"$\\mathbb{R}^\1$", text)   # Rn -> ℝ^n
    text = re.sub(r"\$([^$]+)\$\s*∈\s*\$([^$]+)\$", r"$\1 \\in \2$", text)
    text = re.sub(r"\$([^$]+)\$\s*∈\s*([A-Z])\b", r"$\1 \\in \2$", text)
    text = re.sub(r"\$([^$]+)\$\s*=\s*([A-Z0-9])(?![\w])", r"$\1 = \2$", text)
    text = re.sub(r"\$([^$]+)\$\s*=\s*\$([^$]+)\$", r"$\1 = \2$", text)
    # A capital letter standing alone is a space or matrix: V -> $V$ (not "A" or "I" as words).
    text = re.sub(r"(?<![\w$\\{])([B-HJ-Z])(?![\w$}])", r"$\1$", text)
    text = re.sub(r"\b(Span|span|dim|rank|ker)\s+\(", r"\1(", text)   # "Span (v)" -> "Span(v)"
    # Spaces the PDF put before punctuation, and doubled spaces.
    text = re.sub(r"\s+([.,;:)}])", r"\1", text)
    text = re.sub(r"([({])\s+", r"\1", text)
    return re.sub(r"\s{2,}", " ", text)


SUB = str.maketrans("0123456789aeijklmnoprstuvx+-=()", "₀₁₂₃₄₅₆₇₈₉ₐₑᵢⱼₖₗₘₙₒₚᵣₛₜᵤᵥₓ₊₋₌₍₎")
SUP = str.maketrans("0123456789nmk+-", "⁰¹²³⁴⁵⁶⁷⁸⁹ⁿᵐᵏ⁺⁻")


def as_unicode(text: str) -> str:

    """
    The same tidying as as_maths, but written with Unicode instead of LaTeX, for places that can't
    typeset maths (Raycast): "v1,..., vn" -> "v₁, …, vₙ", "Rn" -> "ℝⁿ". Bracket pieces a PDF
    draws from private symbol fonts (big matrix brackets) are dropped.
    """

    text = re.sub(r"[\ue000-\uf8ff]", "", text)
    text = re.sub(r"(?<![\w$])R\s?([nmk2-9])(?![\w])", lambda m: "ℝ" + m.group(1).translate(SUP), text)
    # A column written out down a matrix: "c1 ... cn" -> "c₁ … cₙ".
    text = re.sub(r"(?<![\w$])([a-z])1\s*(?:\.\.\.|…)\s*\1([nmk])(?![\w])",
                  lambda m: m.group(1) + "₁ … " + m.group(1) + m.group(2).translate(SUB), text)
    text = as_maths(text)

    def plain(m):
        t = m.group(1)
        for latex, char in (("\\dots", "…"), ("\\cdots", "⋯"), ("\\in", "∈"), ("\\mid", "|"), ("\\{", "{"),
                            ("\\}", "}"), ("\\mathrm{Span}", "Span"), ("\\alpha", "α")):
            t = t.replace(latex, char)
        t = re.sub(r"\\(?:mathrm|text|operatorname)\s*\{([^{}]*)\}", r"\1", t)
        for latex, char in (("\\Delta", "Δ"), ("\\delta", "δ"), ("\\beta", "β"), ("\\gamma", "γ"), ("\\lambda", "λ"),
                            ("\\sigma", "σ"), ("\\epsilon", "ε"), ("\\leq", "≤"), ("\\geq", "≥"), ("\\to", "→"), ("\\times", "×")):
            t = t.replace(latex, char)
        t = re.sub(r"\\mathbb\s*\{([A-Z])\}", lambda f: {"R": "ℝ", "C": "ℂ", "Q": "ℚ", "Z": "ℤ", "N": "ℕ"}.get(f.group(1), f.group(1)), t)
        t = re.sub(r"_\{([^}]+)\}|_([0-9]+|[a-z])", lambda s: (s.group(1) or s.group(2)).translate(SUB), t)
        return t

    text = re.sub(r"\$([^$]+)\$", plain, text)
    return re.sub(r"\s{2,}", " ", text).strip()


def from_web(text: str) -> str:

    """
    A web page's passage tidied for showing: maths the page wrote for MathJax (\\( … \\), \\[ … \\])
    as $…$, \\textrm as \\mathrm, and numbered references ("[3,4]", "[5–8]") taken out.
    """

    text = re.sub(r"\\\[(.+?)\\\]", lambda m: "$$" + m.group(1).strip() + "$$", text, flags=re.S)
    text = re.sub(r"\\\((.+?)\\\)", lambda m: "$" + m.group(1).strip() + "$", text, flags=re.S)
    text = re.sub(r"\\text(?:rm|normal)\s*\{", r"\\mathrm{", text)
    text = re.sub(r"\s?\[\d+(?:\s*[,–-]\s*\d+)*\]", "", text)
    # Inside the maths: thin spaces and doubled braces publishers add, which typesetting doesn't need.
    def simpler(m):
        t = m.group(0).replace("\\,", "")
        # {{\mathrm{death}}} and the like: the wrapping braces around a single \mathrm{…}.
        for _ in range(3):
            t = re.sub(r"\{\s*(\\mathrm\s*\{[^{}]*\})\s*\}", r"\1", t)
        return re.sub(r"\\mathrm\s+\{", r"\\mathrm{", t)
    text = re.sub(r"\$[^$]+\$", simpler, text)
    return re.sub(r"\s{2,}", " ", text).strip()


def number_on_page(kind: str, url: str, page: int) -> Optional[str]:

    """
    For a statement named only by its page ("Theorem (p. 55)"): the number of the first statement of that
    kind labelled on that page ("4.3"), or None.
    """

    if not url.startswith("file://"):
        return None
    path = unquote(urlparse(url).path)
    if not Path(path).is_file():
        return None
    pages = _pdf_pages(path, Path(path).stat().st_mtime)
    if not 0 < page <= len(pages):
        return None
    m = re.search(rf"{kind}\s+(\d+(?:\.\d+)+)\s*(?:\([^)]{{0,60}}\))?\s*[.:]", _ligatures(pages[page - 1]), re.I)
    return m.group(1) if m else None


def page_of(quote: str, url: str) -> Optional[int]:

    """The page of a PDF on this computer that holds a quote (matched by its letters and digits), or None."""

    if not url.startswith("file://"):
        return None
    path = unquote(urlparse(url).path)
    if not Path(path).is_file():
        return None
    squash = lambda t: re.sub(r"[^0-9a-z]", "", _ligatures(t).lower())
    wanted = squash(quote)
    if len(wanted) < 15:
        return None
    # Short pieces from its start, middle and end: an equation number or display maths on the page
    # between them doesn't stop it being found. The page holding the most pieces wins.
    size = min(25, len(wanted))
    pieces = {wanted[:size], wanted[len(wanted) // 2 - size // 2:][:size], wanted[-size:]}
    best, most = None, 0
    for i, page in enumerate(_pdf_pages(path, Path(path).stat().st_mtime)):
        text = squash(page)
        hits = sum(piece in text for piece in pieces)
        if hits > most:
            best, most = i + 1, hits
    return best
