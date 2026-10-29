<p align="center"><img src="assets/icon.png" alt="Referee" width="128"></p>

<h1 align="center">Referee</h1>

<p align="center">
  <b>Checks your writing against what you've read.</b><br>
  Every claim matched to the source and page that back it, in Word, Google Docs, Overleaf, Notion, Obsidian, R Markdown and Quarto, with the AI running on your Mac if you choose.
</p>

<p align="center">
  <a href="https://github.com/reeceama/Referee/releases/latest/download/Referee-mac.zip"><b>Download for Mac</b></a>
  &nbsp;·&nbsp;
  <a href="CHANGELOG.md">Changelog</a>
  &nbsp;·&nbsp;
  <a href="https://github.com/reeceama/Referee/releases">All releases</a>
</p>

<p align="center">
  <a href="https://github.com/reeceama/Referee/releases/latest"><img alt="Newest release" src="https://img.shields.io/github/v/release/reeceama/Referee?label=newest&color=2f6fd6"></a>
  <img alt="macOS 14 or later" src="https://img.shields.io/badge/macOS-14%20or%20later-4a4f57">
  <img alt="Apple silicon" src="https://img.shields.io/badge/Apple%20silicon-M1%20or%20later-4a4f57">
  <img alt="Windows: run from the code" src="https://img.shields.io/badge/Windows-from%20the%20code-4a4f57">
</p>

Referee is for anyone who writes from sources: reports, proposals, articles, dissertations, policy papers and the rest. It checks your writing against the sources you have read: you add the articles, papers, PDFs and YouTube videos you'll cite, or a browser extension collects what you read while researching, and as you write in Word, Google Docs, Overleaf, Notion, Obsidian, R Markdown or Quarto, each finished sentence is checked against that reading. Supported claims are shown with the exact quote that backs them and the citation to add, and Referee warns you when a source says the opposite, when a quotation doesn't match its source, or when wording has been copied without quotation marks.

For mathematical writing it also compares the theorems and definitions you restate with the papers you cite, checks your notation, and checks your code and results. And it keeps the records a project needs: notes from meetings, with action points sent to your to-do app, reading notes linked to the page, and a log of AI use from which a disclosure is filled in, for the universities, publishers, funders and clients that now ask for one.

It never writes for you. It only checks, credits, warns and keeps records.

The first version was built in one day for the Invisible AI hackathon on 10 October 2026, where the brief was AI that works inside what you're already doing rather than something you have to prompt; it's kept as the [Hackathon Submission](https://github.com/reeceama/Referee/releases/tag/hackathon-submission) release. This version grew out of real projects (a maths dissertation in LaTeX, mini-projects and group work) into a tool for any project written from sources.

## Download

**[Download Referee for Mac](https://github.com/reeceama/Referee/releases/latest/download/Referee-mac.zip)** (Apple silicon, macOS 14 or later). Everything it needs is inside the app.

1. Open the zip and drag **Referee** into Applications.
2. Open it. The first time, macOS says it can't check the developer, because the app isn't notarised by Apple: go to **System Settings → Privacy & Security** and click **Open Anyway**. You only do this once.
3. Choose what checks your claims, in Settings → Checks:
   - **Claude (recommended):** paste your [Anthropic API key](https://console.anthropic.com) in **Integrations** (Manage…). It's kept in your Keychain. Comparing theorems with papers needs Claude.
   - **Ollama, on your Mac (free), on Macs with 32 GB of memory or more:** install [Ollama](https://ollama.com), then run `ollama pull qwen3:14b`. Nothing leaves your Mac. With Claude chosen, Referee also uses it when you're offline.
4. Add the sources you'll cite with **Add Source…** in the menu bar, or install the browser extension from Settings to collect what you read automatically. The extension works in Chromium browsers (Chrome, Brave, Edge and Arc) and also adds Referee's panel to Overleaf. Referee works with Safari too, with fewer features: Safari can't run the extension, so there's no capture while reading (add sources by hand), no highlights and no Overleaf panel, and pages behind a university login can't be fetched. For the best experience, use a Chromium browser.

Referee checks your writing as you type in Word or Overleaf, and updates itself when a new release comes out. There's no Windows app yet; Windows users can run it from the code (see [Running it](#6-running-it)).

See the [changelog](CHANGELOG.md) for what's new in each release.

## Team members

- Reece Mings-Alleyne ([GitHub](https://github.com/reeceama) / [LinkedIn](https://www.linkedin.com/in/reece-mings-alleyne/))
- Mohammed Seddik ([GitHub](https://github.com/sedmoh) / [LinkedIn](https://www.linkedin.com/in/mohammed-seddik-b17bab366/))

## Contents

1. [What it does](#1-what-it-does)
2. [How it works](#2-how-it-works)
3. [Data and models](#3-data-and-models)
4. [Validation](#4-validation)
5. [Repository layout](#5-repository-layout)
6. [Running it](#6-running-it)
7. [API](#7-api)
8. [License](#8-license)

## 1. What it does

**While you research.** Pages are captured only once you've actually read them: a page counts after it has been open and visible for 20 seconds, or as soon as you highlight text on it. Pages you bounce off aren't kept. PDFs are captured with their page numbers, and YouTube videos through their transcripts, with timestamps. By default the extension captures only while you're writing in Word (and for five minutes after), or while research mode is on: switched on from the menu bar, the popup or a keyboard shortcut you set in Referee's settings, or by a macOS Focus once two Shortcuts automations are set up (see [Running it](#6-running-it)). Sources can also be added by hand with **Add Source** in the menu bar: a link to a page, PDF or YouTube video, or a PDF on your Mac.

Captured reading is temporary: it can be cited straight away, and is forgotten after 15 minutes (or an hour, or a day) unless you keep it. **Save for later** in the extension's popup keeps the page you're on, whether or not it was captured; sources added by hand are kept straight away, and any source your writing cites is kept automatically. Kept sources belong to the current project, chosen or created from the menu bar, the library or the popup. Projects are kept apart: writing is only checked against its own project's sources, plus any other projects you link it to in the library, where sources can also be moved between projects. The extension never runs in private (Incognito) windows. The library lists your reading, saved or temporary, and lets you save, rename, move or forget any source. Renaming changes only the name you see; **citation details** (title, authors, year, publisher) set how a source appears in references, for sources that lack them, such as lecture notes. A source's `\cite` key never changes once made, so citations already written keep working.

Text you highlight while reading is kept as a note on its source, and the passages you highlighted are tried first when checking your claims. Academic sources with a DOI (journal articles, arXiv papers) get their exact authors, year, journal, volume, issue, pages and abstract from doi.org, and a warning if Crossref records a retraction. Papers keep their mathematics: pages keep equations as TeX (from MathJax or MathML), and for a PDF, Referee reads the paper's arXiv LaTeX source, arXiv HTML or publisher's page when one exists (finding a journal paper's arXiv version by its title), matching each passage back to its PDF page so citations keep page numbers. **Re-read** in the library brings sources saved earlier up to date, keeping their project, highlights and checked claims.

Banking, payment, login and account pages, email, social media, search results and writing tools are never captured, nor is any page with a password box. Before a page leaves the browser tab, every form field, text box and script is removed, so nothing anyone typed is sent.

**While you write.** Each sentence is checked when it is finished, whether or not research mode is on. Research mode controls what is captured; anything already captured can be checked against at any time.

| Marker | Meaning |
|---|---|
| Supported | A source you read backs this claim, shown with the exact supporting quote. |
| Contradicted | A source you read says the opposite, or a much weaker version, of the claim. |
| Misquote | Text in quotation marks doesn't match the source word for word. |
| Too close | Wording copied from a source without quotation marks. |
| Needs a source | Reads like a factual claim, but nothing you read supports it. The closest sources you've read are suggested as places to look. |

Referee also warns when a figure in the sentence isn't in the source, shows exactly which words of a misquote differ, note when another source you read points the other way, when a claim only holds by combining two sources, and when a supporting source is more than ten years old. The library summarises how many claims your reading backs, and flags leaning heavily on one source.

In Word, the background Word helper (macOS and Windows) checks as you type with no add-in or panel: supported claims are marked, warnings become comments (and are listed in the library), and each supported sentence gets a comment suggesting its citation. Type it in and Referee adds the source to a reference list it keeps at the end; or switch on **Add citations automatically** in Settings to have citations typed in for you. Sentences are marked with coloured underlines (green supported, amber check the wording, red contradicted), or highlights, or nothing, as chosen in settings; **Remove Marks** in Settings clears Referee's marks, leaving your own. The library, a window in Referee for Mac (and a page in the extension), lists everything you've read, manages projects, and gives the reference list for what you've cited in APA 7, Harvard, MLA 9, Chicago, IEEE, AMS or Vancouver, with page numbers for PDFs and timestamps for videos. It imports and exports BibTeX and RIS files, for Zotero, Mendeley, EndNote or LaTeX: imported entries are fetched by their link, DOI or arXiv ID and read, so Referee can check against them. The **Research trail** opens from it: a day-by-day timeline of what you read, saved, highlighted and claimed, with each claim and the source that backs it. Claims that need a source come with the closest reading you have and a Google Scholar search for their key terms: places to look, never text to use.

If a sentence makes no claim and nothing you read relates to it, Referee stays silent rather than guessing.

**In Overleaf.** The extension adds a small panel to Overleaf projects. It reads the LaTeX you're editing (leaving out maths, proofs, figures and commands), checks each finished sentence like the Word helper, and lists what it finds; clicking an item jumps to its line. Supported sentences come with a `\cite{}` key that matches Referee's BibTeX export, and an **Insert** button that adds it to the end of the sentence (or switch on automatic citations in Settings, which skips the sentence you're editing). For a sentence that already cites something, it says whether the cited paper is the one your reading says backs it. Overleaf's text is only ever changed by an insert, as an ordinary edit you can undo. The library's **Export .bib** gives the `refs.bib` file to upload to Overleaf, and each source has a button to copy its `\cite{}`.

**Mathematics.** Theorems, lemmas, conjectures and definitions that cite a paper (for example `\begin{theorem}[{\cite[Theorem 2]{key}}]`) are compared with the paper's own statement, and real differences are listed: a missing or extra condition, a different conclusion, a changed constant or quantifier. Differences in notation or wording don't count, and nothing is ever suggested as a fix. Notation checks run instantly, without AI: `\ref`s to labels that don't exist, labels used twice, symbols used before they're introduced or introduced twice, results cited vaguely ("a theorem from lectures") without a citation, steps asserted with "clearly" or "obviously", and an "if and only if" whose proof never shows the converse.

**Code.** Choose your project's code folder in Settings. Referee then lists the libraries your Python, R or C/C++ code uses that ask to be cited but that your writing doesn't cite (GUDHI, Ripser, scikit-learn, NumPy, R itself, ggplot2, lme4, the tidyverse, Eigen, GSL, CGAL and others), each with its BibTeX entry; and figures in your writing that are close to, but not the same as, a value in your results (CSV, JSON or notebook outputs), which usually means the code was re-run after you wrote them.

**Notes.** Reading notes by project, each optionally linked to a saved source and a page or range of pages: "Def 4.35, basis" on pages 57–61 of your lecture notes. Clicking a note opens the source at that page, in your browser; if it's already open in a tab, the browser extension switches to that tab at the page instead of opening another. Referee also uses them: in projects where you keep notes, a claim or theorem supported by a page you haven't noted gets a short hint, in Word and Overleaf. It's information, not a warning: you don't have to note everything you cite.

**Referee links.** Notes and meetings have **Copy Link**, giving a `referee://` link to paste into a planner, Notion, a to-do list or anywhere else; clicking it opens Referee right there (a note opens its source at the page). `referee://source?url=…&page=…` opens any saved source at a page. Todoist tasks made from meeting action points link back to their meeting.

**Meetings.** Notes from supervisor and group meetings, by project: date, attendees, notes, decisions and action points (what, who, by when, done). Action points not yet done are carried into the next meeting. A project's log exports as Markdown or LaTeX, and as the `decision-notes` and `who-did-what` files group projects ask for; link a project to its shared workspace (a GitHub repository or shared folder) and Referee keeps `notes/decision-notes.md` and `notes/who-did-what.md` up to date in it. Connect Todoist in Settings → Integrations and your own action points (where "who" is your name, "me" or everyone) become tasks in a Todoist project of the same name, with their due dates; ticking one off in either app ticks it off in both.

**AI use.** A running record of each use of an AI tool: the tool and version, what you used it for, the key prompt, what it gave you and how you checked it. Your declaration is filled in from it with each project's own wording: paste the declaration your module asks for, with `{tools}`, `{system}`, `{purposes}` and `{checks}` where your answers go, or use a paragraph in the style of a paper's acknowledgement. No institution's wording is built in, and every project starts empty. The declaration is assembled from your entries with a fixed template, not written by AI, and Referee includes itself as a tool once it has checked claims, since it uses Claude.

**Learning from behaviour (not yet active in Word).** The server can learn which kinds of marker a person finds useful from what they do with them, such as dismissing a marker or opening its source, and stop showing the ones they keep rejecting. The Word helper doesn't report those actions yet, so in everyday use every marker the verifier accepts is shown.

## 2. How it works

```
Browser extension, Add Source ──capture──▶ Backend (your laptop) ◀──check── Word, Overleaf
                                │
                                ├─ extract.py    article text → overlapping passages, maths kept as TeX
                                ├─ pdf.py        PDF text, with page numbers
                                ├─ fulltext.py   a PDF's arXiv source, arXiv HTML or publisher page
                                ├─ video.py      YouTube transcripts, with timestamps
                                ├─ embeddings.py passages → vectors (runs locally)
                                ├─ store.py      saved to disk; meaning and keyword search
                                ├─ claims.py     does an unsupported sentence need a source?
                                ├─ verify.py     Claude: supports / contradicts / neutral,
                                │                plus quote and copying checks
                                ├─ statements.py Claude: a restated theorem against the cited paper
                                ├─ code_folder.py uncited libraries, figures that don't match results
                                └─ feedback.py   learns which markers each person finds useful
```

**Capture.** The extension sends each article page to a local backend (or Add Source fetches a page, PDF or video by its link), which extracts the article text with trafilatura, strips references and citation clutter, and splits it into short overlapping passages.

**Search.** Passages are embedded with a small sentence-embedding model that runs on your own machine. A finished sentence is embedded the same way and compared by cosine similarity, and a BM25 keyword search runs alongside it, since meaning-based search can blur exact names and figures. The two rankings are combined by reciprocal rank fusion, and the top five passages are taken forward, provided they clear a minimum similarity. If none do, nothing is sent anywhere.

**Verify.** Claude decides whether any of those passages supports or contradicts the specific claim, or neither. Being on the same topic is not support, and the strength of a claim counts, so "strongly linked" is contradicted by a source that finds only a weak link. The reply is constrained to a fixed schema with structured outputs. The quote it returns must be at least four words and appear in the passage (ignoring differences in spacing, capitals and curly quotes), otherwise nothing is shown. Calls time out after 10 seconds, and failures are logged. Verdicts are cached, so re-checking the same sentence against the same passages costs nothing.

**Wording checks.** Quotations are compared with the source, treating `...` and `[insertions]` as gaps. Unquoted text is checked for copied wording by the share of its 3-word runs found in the passage, ignoring runs that recur across four or more sentences of the reading, since those are stock phrasing rather than copying from one source.

**Learning.** Behaviour events become labelled examples, with explicit actions weighted fully and implicit ones weighted less. A logistic regression on verifier confidence, search similarity and marker type is refitted after every event. Until there are enough events to cover both outcomes, every marker the verifier accepts is shown, so the evaluated threshold acts as the prior.

**Theorems.** A theorem or definition that cites a paper is searched for only in that paper's saved passages, and Claude compares the two statements, listing only mathematical differences. Displayed equations and theorem headings are kept together with their statements when papers are read, so a statement split across lines by a web page or LaTeX isn't lost.

**Privacy.** Only the sentence or statement being checked and its closest passages are sent to Claude. The reading, your code, meetings and AI use log stay on your machine.

## 3. Data and models

| Source | Use |
|---|---|
| SciFact | 1,409 scientific claims with labelled evidence from 5,183 abstracts, used to evaluate the verifier |
| trafilatura | Article text extraction from captured pages |
| all-MiniLM-L6-v2 (ONNX) | Local sentence embeddings for search, run with ONNX Runtime |
| [SwiftMath](https://github.com/mgriebling/SwiftMath) (MIT) | Typesetting the LaTeX in notes, meetings and reports, in Latin Modern |
| Qwen 2.5 7B or Qwen 3 14B, through Ollama | Claim verification on your own computer (free, offered on Macs with 32 GB of memory or more) |
| Claude Haiku 5.5 | Claim verification and theorem comparison, through the Anthropic API (most accurate) |
| doi.org, Crossref, arXiv | Paper details, abstracts, retractions, LaTeX sources and HTML versions |
| Wikipedia, NHS and BBC pages | Captured during development and used for the wording calibration |

SciFact is not committed to this repository. The evaluation script expects it in `~/scifact/data`.

### Raycast

The `raycast` folder is a Raycast extension: Search Referee and Quick Capture (opening Referee's own windows), Check Selected Text, New Note, Save Link, Log AI Use, Switch Project, and Library, Evidence, Notes, Meetings and AI Use to browse each section, talking to Referee on your Mac (which must be open). To add it to your Raycast: `cd raycast && npm install && npm run dev` (Node.js 20 or later).

## 4. Validation

Every figure in this section is reproduced by `eval_scifact.py` and `eval_wording.py` in `server/`.

### Claim verification

100 claim and evidence pairs were drawn from the SciFact development set: 40 supporting, 30 contradicting, 15 claims paired with an abstract they cite but that doesn't address them, and 15 claims paired with sentences from their own evidence abstract that aren't the evidence. The last group is the hard case: same topic, same paper, but no support.

The verifier was run on every pair with its threshold switched off, then scored at each confidence level. A marker counts as shown when the verdict is supported or contradicted at or above the threshold.

| Threshold | Precision | 95% CI | Recall | Markers shown |
|---|---|---|---|---|
| 0.60 | 0.93 | 0.83–0.97 | 0.76 | 57 |
| **0.70 (chosen)** | **0.96** | **0.87–0.99** | **0.70** | 51 |
| 0.80 | 0.98 | 0.88–1.00 | 0.63 | 45 |
| 0.85 | 1.00 | 0.89–1.00 | 0.46 | 32 |

Intervals are Wilson score intervals. To choose the threshold, a logistic regression of whether a marker was correct on the verifier's confidence was fitted by maximum likelihood, pooling this run with the previous one (117 markers). Treating a wrong marker as three times as costly as a missed one, a marker should be shown when it is at least 75% likely to be right, which the fit puts at a confidence of 0.68 (bootstrap 90% range 0.61–0.73). 0.7 is the nearest round value.

| True label ↓ / verdict → | contradicts | neutral | supports |
|---|---|---|---|
| contradicts | 24 | 6 | 0 |
| neutral | 3 | 27 | 0 |
| supports | 3 | 8 | 29 |

Verdicts before any threshold. Most errors are missed support rather than false support, which is the safer way for a citation tool to be wrong.

Earlier runs with previous versions of the prompt gave precisions of 0.91 and 0.95 at a threshold of 0.6. They sit inside each other's intervals, which is consistent with run-to-run variation in the model's answers rather than real differences between the prompts.

#### Local models

The same 100 pairs, the same prompt and the same 0.7 threshold, with models run on a MacBook Air (M1, 16 GB) instead of Claude (`REFEREE_AI_PROVIDER=ollama REFEREE_OLLAMA_MODEL=… python eval_scifact.py run`):

| Model | Precision | 95% CI | Recall | Hard negatives wrongly marked | Time per check |
|---|---|---|---|---|---|
| Claude Haiku 5.5 (API) | 0.96 | 0.87–0.99 | 0.70 | 2 of 15 | not timed |
| Qwen 3 14B (Ollama, thinking off) | 0.91 | 0.81–0.96 | 0.74 | 3 of 15 | about 12 s |
| **Qwen 2.5 7B** (Ollama) | **0.90** | **0.79–0.96** | **0.66** | **1 of 15** | about 5 s |
| Apple's on-device model | 0.64 | 0.52–0.75 | 0.59 | 11 of 15 | about 7 s |
| DeBERTa-v3-large, entailment only | 0.49 (raw accuracy) | – | – | 9 of 15 | about 1 s |

Claude is recommended. On Macs with 32 GB of memory or more, Qwen 2.5 7B is the free option: about nine in ten claims it marks as backed really are, at about 5 seconds a check and half the memory of Qwen 3 14B (about 4.6 GB while checking, against 9.3 GB). Qwen 3 14B finds a little more, for Macs with memory to spare. It still misses about a third of contradictions (calling them neutral), so a check that flags nothing isn't proof that nothing's wrong.

Local models are slow to write, so for them each passage's sentences are numbered and the model answers with a number ("2.3") instead of copying out a quote; Referee then takes the quote from the passage, so it's always exact. For Qwen 3 14B this cut a check from about 17 to 12 seconds and raised recall from 0.63 to 0.74, with precision unchanged (0.90 to 0.91). The Apple and DeBERTa rows were measured before this change. Qwen 3 with thinking switched on took about three minutes a check on this computer. Apple's on-device model and the DeBERTa entailment model (trained on everyday sentences, not research) were too often wrong to offer. Comparing theorems with papers isn't offered with local models.

### Copying detection

21 sentences were written against five passages from the captured Wikipedia article on the Mediterranean diet: copies, light edits, paraphrases and sentences in the writer's own words. The check should flag the first two and not the last two. A grid over run length, stock-phrase threshold and cut-off finds the setting with the widest gap between them.

| Setting | Margin |
|---|---|
| Word-run overlap only | 0.06 |
| Ignoring stock phrases | 0.32 |

Ignoring stock phrasing widened the margin more than five times. The chosen setting is 3-word runs, stock phrases appearing in 4 or more sentences of the reading, and a cut-off of 0.30.

## 5. Repository layout

```
├── referee.py                  starts and watches the background parts (macOS and Windows)
├── tests/smoke_test.py         checks the background parts work, run by GitHub on Windows and macOS
├── server/                     backend, runs locally
│   ├── main.py                 API routes
│   ├── paths.py                where your data is kept (Application Support, or %LOCALAPPDATA%)
│   ├── api_key.py              your Anthropic API key, in Keychain or Credential Manager
│   ├── extract.py              article text and passages
│   ├── pdf.py                  PDF text and page numbers
│   ├── fulltext.py             a PDF's maths-faithful text: arXiv source, arXiv HTML or publisher page
│   ├── video.py                YouTube transcripts and timestamps
│   ├── embeddings.py           local sentence embeddings
│   ├── keywords.py             BM25 keyword search
│   ├── store.py                passage storage and search
│   ├── claims.py               does a sentence need a source?
│   ├── verify.py               claim verification, quote, figure and copying checks
│   ├── statements.py           theorems and definitions compared with the papers they cite
│   ├── code_folder.py          the code folder: uncited libraries, figures that don't match results
│   ├── notes.py                reading notes, linked to a source's page
│   ├── meetings.py             meeting notes and action points, and their exports
│   ├── todoist.py              your action points as Todoist tasks, both ways
│   ├── ai_log.py               the AI use log and declarations
│   ├── feedback.py             learns which markers each person finds useful
│   ├── claim_log.py            claims each source has backed, for the library
│   ├── reading.py              projects, and how long unsaved reading is kept
│   ├── citations.py            citation styles, for the Word helper and the library
│   ├── library.py              reference lists and the research trail
│   ├── highlights.py           text highlighted while reading, kept as notes
│   ├── metadata.py             details from a source's DOI, and retraction checks
│   ├── bib.py                  BibTeX and RIS import and export
│   ├── eval_scifact.py         verifier evaluation on SciFact
│   ├── eval_wording.py         copying detection calibration
│   ├── load_demo.py            preloads demo sources
│   ├── .env.example            copy to .env and add your API key
│   └── requirements.txt
│
├── extension/                  Chrome extension
│   ├── manifest.json
│   ├── background.js           talks to the backend, runs research mode
│   ├── content.js              captures article pages once they've been read
│   ├── skip.js                 pages that are never captured
│   ├── popup/                  research mode, projects, captured reading
│   ├── library/                captured reading, references, reports, BibTeX import and export
│   ├── overleaf/               the Overleaf panel: reads the LaTeX, checks it, inserts citations
│   ├── dev/editor/             developer test page for checks (not user facing)
│   └── icons/
│
├── macapp/                     Referee for Mac: menu bar app, library, meetings, AI use, settings and updates
│   ├── Sources/                the app, in Swift
│   ├── build.sh                builds it from this folder into /Applications
│   ├── package.sh              builds the downloadable app, with its own Python
│   └── make_icon.py            draws the app and extension icons
├── word-helper/                background Word helper (AppleScript on macOS, COM on Windows)
├── scripts/install-windows.bat starts Referee at login on Windows
├── assets/                     README icon and link preview image
├── .github/workflows/test.yml  runs the tests on Windows and macOS after every push
│
├── README.md
├── CHANGELOG.md                what changed in each release
├── LICENSE
└── .gitignore
```

## 6. Running it

```bash
python3 -m venv .venv
source .venv/bin/activate          # Windows: .venv\Scripts\activate
pip install -r server/requirements.txt
```

Add your Anthropic API key in Referee's settings (the Mac app, or the extension's library on any system). It's checked with Anthropic, then kept in your computer's password store (Keychain or Credential Manager). Alternatively, copy `server/.env.example` to `server/.env` and put the key there. Never commit that file.

```
ANTHROPIC_API_KEY=sk-ant-...
```

```bash
# start everything: the server and the Word helper. The first run downloads the embedding
# model (about 90 MB).
python referee.py

# or just the server
cd server
uvicorn main:app --port 8000

# verifier and wording tests
python verify.py

# evaluation: needs pandas and matplotlib, and SciFact in ~/scifact/data
python eval_scifact.py build
python eval_scifact.py run
python eval_scifact.py analyse
python eval_wording.py
```

On a Mac, `sh macapp/build.sh` builds **Referee.app** from this folder and installs it in `/Applications`; `sh macapp/package.sh 2026-10-12` builds the downloadable version instead, named for its release, with its own Python, code and libraries inside, as `macapp/dist.noindex/Referee-mac.zip` and its checksum (Apple silicon); publish both as a GitHub release of the same name, and downloaded copies update themselves. The app lives in the menu bar (a whistle: outlined when idle, filled while capturing) and runs the server and the Word helper while it's open. Its menu has research mode, the current project, how long unsaved reading is kept, Add Source, the library, Notes, Meetings, AI Use and settings (the research mode shortcut, Word and Overleaf settings, the code folder, opening at login, whether to show in the menu bar, and Integrations: the Anthropic API key and Todoist). With the menu bar icon hidden, open Referee from Applications or Spotlight to get to settings, the library, meetings and AI use. On Windows, `scripts\install-windows.bat` starts the server and Word helper at login. `tests/smoke_test.py` checks the background parts work, without Word or an API key; GitHub runs it on Windows and macOS after every push. See `word-helper/README.md`.

To switch research mode on with a macOS Focus, create two automations in the Shortcuts app: when the Focus turns on, run the shell script `curl -s -X POST localhost:8000/focus -H 'Content-Type: application/json' -d '{"on":true}'`, and when it turns off, the same with `false`.

To load the extension, open `chrome://extensions`, turn on **Developer mode**, choose **Load unpacked** and select the `extension` folder. (In Brave or Edge, use `brave://extensions` or `edge://extensions`.) Start writing in Word or Overleaf and read some sources; anything you read while writing is captured. Open the library from the popup to see your reading and references. API docs are at http://localhost:8000/docs while the backend is running.

## 7. API

| Endpoint | Body | Returns |
|---|---|---|
| `POST /capture` | `{url, html, project}` | `{ok, passages}` |
| `POST /capture-pdf` | `{url, data, title, project}` (PDF as base64) | `{ok, passages}` |
| `POST /capture-video` | `{url, project}` | `{ok, passages}` |
| `POST /check` | `{sentence, project, document}` | `{match: false, needs_source, closest}` or `{match: true, label, quote, source, passage, page, time, confidence, score, misquote, too_close, changes, wrong_numbers, mixed, together_with}` |
| `GET /sources`, `DELETE /sources?url=` | | lists captured sources, or forgets one |
| `GET /claims?project=` | | claims the reading has backed or contradicted, oldest first |
| `POST /focus` | `{on}` | switches research mode on or off (macOS Focus) |
| `POST /sources/keep` | `{url, project}` | keeps a source (save for later) |
| `POST /sources/move` | `{url, project}` | moves a source to another project |
| `GET /settings`, `POST /settings` | `{project, projects, keep_minutes, links}` | current project, project list, how long unsaved reading is kept |
| `POST /helper` | | heartbeat from the Word helper, so the app can show whether it's running |
| `GET /word/request`, `POST /word/request` | `{request, result}` | a request for the Word helper (such as removing highlights) and its reply |
| `POST /feedback` | `{event, sentence, url, label, confidence, score}` | `{ok}` |
| `GET /feedback` | | what the model has learned so far |
| `POST /feedback/reset` | | clears learned behaviour |
| `POST /writing`, `GET /writing` | | marks or reports an active writing session (automatic mode) |
| `POST /clear` | | forgets all captured reading |
| `POST /highlights`, `GET /highlights?url=` | `{url, text}` | keeps text highlighted while reading; lists a source's highlights |
| `GET /presubmission?project=` | | the Before You Submit report, as a web page |
| `GET /trail?project=` | | the Research Trail, as a web page |
| `GET /export?format=bibtex\|ris&project=` | | saved sources as a BibTeX or RIS file |
| `POST /import` | `{text}` (a BibTeX or RIS file) | fetches and saves each entry; returns how many were added and which failed |
| `POST /sources/add-url` | `{url}` | adds a page, PDF or YouTube video by its link, kept in the current project |
| `POST /sources/add-pdf` | `{name, data}` (PDF as base64) | adds a PDF from this computer, kept in the current project |
| `POST /sources/forget-temporary` | | forgets reading that hasn't been saved or cited |
| `POST /projects/rename` | `{old, new}` | renames a project, or deletes it when `new` is empty (its sources stay) |
| `GET /references?project=&style=` | | the reference list for what's been cited |
| `GET /report?project=&style=` | | the proof-of-work report, as a web page |
| `GET /api-key`, `POST /api-key`, `DELETE /api-key` | `{key}` | whether a key is saved; checks and saves one; removes it |
| `POST /statement` | `{statement, kind, keys, label}` | a theorem or definition compared with the cited paper: `{found, quote, page, source, differences}` |
| `POST /code` | `{text}` (the LaTeX) | against the code folder: `{folder, software, numbers}` |
| `POST /claims/current` | `{document, text}` or `{removed}` | drops claims whose sentences were reworded or deleted |
| `POST /sources/rename` | `{url, name}` | the name shown for a source (empty: its title); references are unchanged |
| `POST /sources/details` | `{url, title, author, date, site}` | a source's citation details, keeping its `\cite` key |
| `GET /open?url=&page=` | | opens a saved source at a page; the extension reuses a tab that already has it open |
| `GET /source-file?url=` | | a PDF saved from this computer, so notes can open it at a page (opened directly only) |
| `POST /sources/reread` | `{url}` | reads a saved source again, with its maths and abstract |
| `GET /meetings?project=`, `POST /meetings`, `DELETE /meetings?id=` | a meeting | lists, saves or deletes meetings |
| `GET /meetings/export?project=&format=` | | `markdown`, `latex`, `decision-notes` or `who-did-what` |
| `GET /meetings/workspace?project=`, `POST /meetings/workspace` | `{project, folder}` | the shared workspace where a project's notes files are kept up to date |
| `GET /notes?project=`, `POST /notes`, `DELETE /notes?id=` | a note: `{project, text, url, page, to}` | lists, saves or deletes reading notes |
| `GET /todoist`, `POST /todoist`, `DELETE /todoist` | `{token}` | Todoist connection: status; checks and saves a token; disconnects |
| `POST /todoist/sync` | | syncs action points with Todoist now (otherwise every three minutes, and after each meeting change) |
| `GET /ai-log?project=`, `POST /ai-log`, `DELETE /ai-log?id=` | an entry | lists, saves or deletes AI use entries |
| `GET /ai-log/declaration?project=` | | the project's declaration, and its template |
| `POST /ai-log/template` | `{project, preset, used, unused}` | sets a project's declaration wording: `paragraph`, or `custom` with its text |
| `GET /ai-log/export?project=&format=markdown\|latex` | | the declaration and the full record |

`label` is `supports`, `contradicts` or `misquote`. Feedback events are `opened_source`, `edited_after`, `dismissed` and `ignored`.

## 8. License

Code released under the [Apache License 2.0](LICENSE). See [NOTICE](NOTICE) for credits.
