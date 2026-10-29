"""Checks Referee's background parts work on this computer, without Word or an API key.

Runs on a copy of the server folder, so it never touches real reading. GitHub runs it on
Windows and macOS after every push (.github/workflows/test.yml); run it locally with
    python tests/smoke_test.py
"""

import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import urllib.request
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
PAGE = """<html><head><title>Waggle dance</title></head><body><article><h1>Waggle dance</h1>
<p>Honey bees communicate the direction of food to their nestmates with a waggle dance. The angle
of the waggle run relative to vertical shows the direction of the food relative to the sun, and the
duration of the waggle run shows the distance to the food source.</p>
<p>Researchers have decoded these dances to map where colonies forage across a landscape.</p>
</article></body></html>"""


def check(label, condition):

    print(("ok   " if condition else "FAIL ") + label, flush=True)
    if not condition:
        raise SystemExit(1)


def server_parts():

    """
    Capture, search, saving, projects (with a non-ASCII name) and the feedback model, in-process.
    """

    work = Path(tempfile.mkdtemp())
    shutil.copytree(REPO / "server", work / "server", ignore=shutil.ignore_patterns(
        "store.json", "store.npy", "claims.json", "reading.json", "feedback.json", ".env", "eval_*", "__pycache__"))
    os.environ["REFEREE_DATA"] = str(work / "data")  # never touch real reading
    os.chdir(work / "server")
    sys.path.insert(0, str(work / "server"))
    from fastapi.testclient import TestClient
    import main
    import store
    client = TestClient(main.app)
    headers = {"X-Referee": "1"}

    result = client.post("/capture", json={"url": "https://referee.test/bees", "html": PAGE}, headers=headers).json()
    check("captures a page", result.get("ok") and result.get("passages", 0) > 0)
    found = store.search("Honey bees dance to tell other bees where food is.", k=1)
    check("finds the matching passage", found and found[0]["score"] > 0.5)
    sources = client.get("/sources", headers=headers).json()
    check("new reading is temporary", sources[0]["kept"] is False)
    client.post("/sources/keep", json={"url": "https://referee.test/bees"}, headers=headers)
    check("Save for later keeps it", client.get("/sources", headers=headers).json()[0]["kept"] is True)
    name = "Café dissertation ✓"
    client.post("/settings", json={"project": name}, headers=headers)
    check("project names survive a restart", json.loads((work / "data" / "reading.json").read_text(encoding="utf-8"))["project"] == name)
    check("other websites are refused", client.get("/sources", headers={"Origin": "https://example.com"}).status_code == 403)
    references = client.get("/references?project=all&style=apa", headers=headers).json()
    check("reference list builds", isinstance(references.get("entries"), list) and references.get("heading") == "References")
    report = client.get("/report?project=all", headers=headers).text
    check("research trail builds", "Research trail" in report and "Waggle dance" in report)
    client.post("/warnings", json={"document": "Essay.docx", "issues": [{"entry": "A claim.", "note": "Your source says otherwise."}]}, headers=headers)
    check("Word warnings reach the library", client.get("/warnings", headers=headers).json()["Essay.docx"]["issues"][0]["note"] == "Your source says otherwise.")
    client.post("/highlights", json={"url": "https://referee.test/bees", "text": "The angle of the waggle run relative to vertical shows the direction"}, headers=headers)
    check("highlights are kept as notes", len(client.get("/highlights?url=https://referee.test/bees", headers=headers).json()) == 1)
    unrelated = client.post("/check", json={"sentence": "Most of the 2019 survey respondents reported higher energy prices.", "document": "Essay.docx"}, headers=headers).json()
    claims_now = client.get("/claims", headers=headers).json()
    check("claims needing a source are logged", unrelated.get("needs_source") and any(c["label"] == "needs_source" and c["document"] == "Essay.docx" for c in claims_now))
    check("needs-a-source comes with a search link", (unrelated.get("search") or "").startswith("https://scholar.google.com/"))
    check("Before You Submit builds", "Needs a source" in client.get("/presubmission", headers=headers).text)
    check("Research Trail builds", "Highlighted" in client.get("/trail", headers=headers).text)
    check("BibTeX export", "@misc{" in client.get("/export?format=bibtex", headers=headers).text)
    import bib
    check("BibTeX and RIS import read links", bib.entries("@article{a,\n  title = {T},\n  doi = {10.1/x},\n}")[0]["link"] == "https://doi.org/10.1/x"
          and bib.entries("TY  - JOUR\nTI  - T\nUR  - https://x.test/p\nER  - ")[0]["link"] == "https://x.test/p")
    rejected = client.post("/api-key", json={"key": "sk-ant-not-a-real-key"}, headers=headers).json()
    check("a wrong API key is rejected, not saved", rejected.get("ok") is False)

    from feedback import LogisticModel
    model = LogisticModel().fit([[0.9, 0.8, 0], [0.6, 0.5, 1], [0.95, 0.7, 0], [0.65, 0.55, 1]], [1, 0, 1, 0], [1, 1, 1, 1])
    check("feedback model learns", model.probability([0.9, 0.8, 0]) > 0.5 > model.probability([0.6, 0.5, 1]))

    sys.path.insert(0, str(REPO / "word-helper"))
    import citations
    check("citations format", citations.in_text("apa", {"author": "Jane Smith", "date": "2023"}) == "(Smith, 2023)")
    os.chdir(REPO)


def word_helper():

    """
    The Word helper's driver for this system loads, and says Word isn't open (there's no Word here).
    """

    sys.path.insert(0, str(REPO / "word-helper"))
    import helper
    driver = helper.driver()
    check(f"Word helper driver loads ({type(driver).__name__})", driver is not None)
    if os.environ.get("CI"):
        check("reports that Word isn't open", driver.available() is False)


def port_open(port):

    with socket.socket() as s:
        return s.connect_ex(("127.0.0.1", port)) == 0


def launcher():

    """
    referee.py starts the server, and stopping it stops everything it started.
    """

    if port_open(8000):
        print("skip launcher test: something is already using port 8000 (Referee is probably running)")
        return
    process = subprocess.Popen([sys.executable, str(REPO / "referee.py")], cwd=REPO)
    try:
        for _ in range(120):
            time.sleep(1)
            try:
                body = urllib.request.urlopen("http://127.0.0.1:8000/", timeout=2).read()
                break
            except OSError:
                continue
        else:
            body = b""
        check("launcher starts the server", b"Referee server running" in body)
    finally:
        process.terminate()
        process.wait(timeout=30)
    for _ in range(30):
        if not port_open(8000):
            break
        time.sleep(1)
    check("stopping the launcher stops the server", not port_open(8000))


if __name__ == "__main__":
    server_parts()
    word_helper()
    launcher()
    print("All checks passed.")
