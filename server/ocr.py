"""Reading scanned pages and screenshots with Apple's Vision, on this Mac, through the small
referee-ocr helper built into Referee for Mac. Pages with text of their own keep it; only pages
without (scans) are read from their image. Text read from an image is marked: it's good for
searching and claim checks, but maths comes out as plain characters, so it isn't treated as the
paper's exact wording (theorem comparison and statement previews don't rely on it).
"""

import json
import os
import shutil
import subprocess
import tempfile
from pathlib import Path
from typing import List, Optional, Tuple

IMAGES = (".png", ".jpg", ".jpeg", ".heic", ".tiff", ".tif", ".gif", ".bmp", ".webp")


def helper() -> Optional[str]:

    for candidate in (os.environ.get("REFEREE_OCR"),
                      "/Applications/Referee.app/Contents/MacOS/referee-ocr",
                      str(Path.home() / "Applications/Referee.app/Contents/MacOS/referee-ocr"),
                      shutil.which("referee-ocr")):
        if candidate and Path(candidate).is_file():
            return candidate
    return None


def read(data: bytes, suffix: str) -> Optional[Tuple[List[str], List[int]]]:

    """
    Each page's text and which pages were read from images, or None if the helper isn't here
    (Windows, or Referee run from the code without it).
    """

    tool = helper()
    if tool is None:
        return None
    with tempfile.NamedTemporaryFile(suffix=suffix) as file:
        file.write(data)
        file.flush()
        try:
            done = subprocess.run([tool, file.name], capture_output=True, text=True, timeout=600)
        except (OSError, subprocess.TimeoutExpired):
            return None
    if done.returncode != 0:
        return None
    try:
        found = json.loads(done.stdout)
    except ValueError:
        return None
    return found.get("pages", []), found.get("scanned", [])
