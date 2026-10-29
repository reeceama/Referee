"""Typeset maths in Referee's report pages (proof of work, before you submit, research trail): the
$...$ in claims and quotes, drawn by KaTeX (MIT licence), the copy in the browser extension. Everything
is put inside the page, fonts included, so a report saved or exported still shows its maths.
"""

import base64
from functools import lru_cache
from pathlib import Path
from typing import Optional

# The extension's copy, beside the server in the code folder or the app.
CANDIDATES = [Path(__file__).resolve().parent.parent / "extension" / "vendor" / "katex",
              Path(__file__).resolve().parent / "katex"]

# Finds $...$, $$...$$, \(...\) and \[...\] in the page's text and typesets each; anything KaTeX
# can't read is left as written.
RENDER = r"""
(() => {
  const MATHS = /\$\$([\s\S]+?)\$\$|\$([^$]+?)\$|\\\(([\s\S]+?)\\\)|\\\[([\s\S]+?)\\\]/g;
  const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, {
    acceptNode: (n) => n.parentElement.closest("script, style, textarea, code") ? NodeFilter.FILTER_REJECT
      : /\$|\\\(|\\\[/.test(n.nodeValue) ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_REJECT });
  const nodes = [];
  while (walker.nextNode()) nodes.push(walker.currentNode);
  for (const node of nodes) {
    const text = node.nodeValue, parts = document.createDocumentFragment();
    let last = 0;
    for (const m of text.matchAll(MATHS)) {
      if (m.index > last) parts.append(text.slice(last, m.index));
      const span = document.createElement("span");
      try { span.innerHTML = katex.renderToString(m[1] ?? m[2] ?? m[3] ?? m[4], { throwOnError: true, displayMode: m[1] !== undefined || m[4] !== undefined }); }
      catch { span.textContent = m[0]; }
      parts.append(span);
      last = m.index + m[0].length;
    }
    if (last < text.length) parts.append(text.slice(last));
    node.replaceWith(parts);
  }
})();
"""


@lru_cache(maxsize=1)
def _assets() -> Optional[str]:

    folder = next((c for c in CANDIDATES if (c / "katex.min.js").is_file()), None)
    if not folder:
        return None
    css = (folder / "katex.min.css").read_text(encoding="utf-8")
    for font in (folder / "fonts").glob("*.woff2"):
        data = base64.b64encode(font.read_bytes()).decode()
        css = css.replace(f"url(fonts/{font.name})", f"url(data:font/woff2;base64,{data})")
    script = (folder / "katex.min.js").read_text(encoding="utf-8")
    return f"<style>{css}</style><script>{script}</script><script>{RENDER}</script>"


def with_maths(page: str) -> str:

    """The report page with its maths typeset (unchanged if KaTeX can't be found)."""

    assets = _assets()
    if not assets or "$" not in page and "\\(" not in page:
        return page
    return page.replace("</body>", assets + "</body>", 1) if "</body>" in page else page + assets
