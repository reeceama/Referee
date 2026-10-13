# Changelog

What changed in each release of Referee, newest first. Releases are named by date (`2026-10-12`, with `.2` and so on for later builds that day) and downloaded copies of Referee for Mac update themselves to the latest one.

## Unreleased

### Added
- **Notes**: reading notes by project, each linked to a saved source and page. Opening a note shows the source at that page, in your browser.
- In projects that keep notes, a claim or theorem supported by a page you haven't noted gets a nudge, in Word and Overleaf.
- **Referee links**: Copy Link on notes and meetings gives a `referee://` link for a planner or to-do list; clicking it opens Referee right there. Todoist tasks link back to their meeting.

### Changed
- The Integrations card in Settings has a general description.

## 12 October 2026 (`2026-10-12.2`)

### Added
- **Todoist**: your meeting action points become Todoist tasks in a project of the same name, with due dates; ticking one off in either app ticks it off in both.
- **Integrations** window for the AI key and Todoist, opened from Settings.

### Changed
- Declarations start empty for every project: no institution's wording is built in. Paste the wording each module asks for in AI Use, or use a paragraph.
- Meeting and Todoist fields have plain placeholders.

## 11 October 2026 (`2026-10-11.7`)

The first release of Referee for Mac, a menu bar app with everything it needs inside.

### Added
- **Referee for Mac**: menu bar app that runs the server and the Word helper, with Add Source, a Library window, Settings, automatic updates and a research mode shortcut.
- **Word helper** for Mac and Windows: checks as you type with no add-in. Sentences are marked with underlines, highlights or nothing; Remove Marks in Word.
- **Overleaf**: a panel that checks your LaTeX, suggests `\cite` keys with an Insert button, and jumps to lines.
- **Mathematics**: theorems and definitions that cite a paper are compared with the paper's statement; notation checks for undefined `\ref`s, duplicate labels, symbols used early or introduced twice, vague citations, asserted steps and one-way "if and only if" proofs.
- **Code checks**: uncited Python, R and C/C++ libraries, and figures that don't match your results.
- **Meetings**: notes, decisions and action points by project, with exports and `decision-notes`/`who-did-what` files kept up to date in a linked workspace.
- **AI Use**: a log of AI use and a declaration filled in from it.
- Papers keep their maths: pages keep equations as TeX, PDFs use the arXiv source, arXiv HTML or publisher's page, and abstracts are always saved. **Re-read** updates sources saved earlier.
- Journal references with volume, issue, pages and DOI in all seven styles; Chicago and Vancouver; BibTeX and RIS import and export; `\cite` keys in the Library.
- Exact details for academic sources from their DOI, and retraction warnings.
- Highlights kept as notes, Before You Submit and Research Trail reports, temporary reading that expires unless saved or cited, and projects.
- Your Anthropic API key in the Keychain; cheaper checks through prompt caching.

### Changed
- Citations are suggested rather than inserted, unless automatic citing is switched on (Word and Overleaf).
- Reports show what's written now: reworded or deleted sentences drop out.
- Settings and the Library open even with the menu bar icon hidden.

### Fixed
- Word freezing after a reference list was added.
- Add Source and the API key check wrongly saying the server wasn't running.
- Build copies of the app appearing in Launchpad and Spotlight.

## 10 October 2026 (`hackathon-submission`)

The version built in one day for the Invisible AI hackathon: a browser extension and local server that check your writing against what you've read, with claim verification by Claude (evaluated on SciFact), misquote and copying checks, and learning from behaviour.
