"""Pictures of passages as their PDF prints them, for PDFs saved on this computer: maths, matrices
and layout that text pulled out of a PDF loses. Made by the referee-pagecrop helper built into
Referee for Mac (Apple's PDFKit), and kept in page-images/ so each is made once.
"""

import hashlib
import os
import shutil
import subprocess
import tempfile
from pathlib import Path
from typing import Optional
from urllib.parse import unquote, urlparse

import paths

FOLDER = paths.data("page-images")


def helper() -> Optional[str]:

    for candidate in (os.environ.get("REFEREE_PAGECROP"),
                      "/Applications/Referee.app/Contents/MacOS/referee-pagecrop",
                      str(Path.home() / "Applications/Referee.app/Contents/MacOS/referee-pagecrop"),
                      shutil.which("referee-pagecrop")):
        if candidate and Path(candidate).is_file():
            return candidate
    return None


def image(url: str, page: Optional[int], text: str) -> Optional[str]:

    """
    The path of a picture of this passage on its page, or None (not a PDF on this computer, the
    helper missing, or the passage not found on the page).
    """

    if not url.startswith("file://") or not page or not text:
        return None
    pdf = Path(unquote(urlparse(url).path))
    tool = helper()
    if tool is None or not pdf.is_file() or pdf.suffix.lower() != ".pdf":
        return None
    key = hashlib.sha1(f"v5|{pdf}|{pdf.stat().st_mtime}|{page}|{text}".encode()).hexdigest()[:20]
    out = FOLDER / f"{key}.png"
    if out.is_file():
        return str(out)
    FOLDER.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False, encoding="utf-8") as f:
        f.write(text)
    try:
        subprocess.run([tool, str(pdf), str(page), f.name, str(out)], timeout=15, capture_output=True)
    except (OSError, subprocess.SubprocessError):
        return None
    finally:
        os.unlink(f.name)
    return str(out) if out.is_file() else None
