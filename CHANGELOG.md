# Changelog

What changed in each release of Referee, newest first. Releases are numbered (`v1.0.0`), and downloaded copies of Referee for Mac update themselves to the latest one.

## 1.0.1 (1 November 2026, `v1.0.1`)

- Disclosures list tools, purposes and checks with commas rather than semicolons, in every format.
- The **Claude connector** can read and edit the disclosure (including wording you've been given) and your reflection, when you ask.
- **Reflection** in AI Use: the two questions a reflection on your work answers (how you structured your arguments, where the main difficulty was), each answered in your own words, with your AI use record and meetings beside them for reference. **Check My Reflection** asks about anything missing, never rewriting it, and **Export** gives the declaration and reflection together, to copy as LaTeX or plain text (for Word or Markdown), or as a separate LaTeX page.
- **Add to Notes** from search now opens Notes and asks for your summary in your own words, with the passage shown as its page prints it. Notes no longer start with an empty "-" line. With "Claude writes lines for notes" switched on, Claude's line is added as before.
- A quote added from search now always shows its page picture, even where the PDF's text doesn't match the passage exactly (maths often doesn't).
- The README covers the whole app: choosing Claude, ChatGPT or a model on your Mac, what each sends, Sonnet for theorems, and the current API.

## 1.0.0 (29 October 2026, `v1.0.0`)

The first full release, compared with the hackathon submission below. Referee is now a Mac app for anyone who writes from sources, not only academic work.

### The app
- **Referee for Mac**: one main window with a sidebar for the Library, Evidence report, Notes, Meetings, AI use and Settings, and a menu bar icon (optionally a Dock icon too). It runs everything it needs itself and updates itself.
- **Setup** on first launch: a Claude key (recommended), or ChatGPT, or a model on your Mac if it has 32 GB of memory or more; then where you write and your first project.
- **Fits half a screen**: every page works at half a laptop screen's width.
- **Due dates**: a project's due date in the sidebar, with the next task due before it from Meetings.
- **Projects**: what you read is saved to the current project, and your writing is checked against it.

### Checking your writing
- **Claude** checks each claim with your own key (Haiku for claims, Sonnet for theorems and definitions); **ChatGPT** is an option too. On Macs with 32 GB of memory or more, a model run with Ollama can check instead, free, with nothing leaving your Mac, and takes over when you're offline.
- **Where you write**: Word (with no add-in, marking sentences and suggesting citations), a **Google Docs add-on** that marks sentences, inserts citations in your style and removes its marks as in Word (paired with your Mac by a code), and panels in **Overleaf**, **Notion** and Google Docs through the browser extension. **Obsidian**, **R Markdown** and **Quarto** files are checked in a folder you choose.
- **Evidence report**: each document's checked claims in the order they appear, with the source, page and statement number that back them ("Def. 4.42 · p. 59"), how sure the check was, and what needs a source or contradicts one. Claims on the same statement count once. A claim credited to a different source from the rest of the document is checked again against the usual one.
- **Mathematics**: theorems and definitions that cite a paper are compared with the paper's statement; notation checks for undefined `\ref`s, duplicate labels, symbols used early or introduced twice, vague citations, asserted steps and one-way "if and only if" proofs.
- **Code checks**: uncited Python, R and C/C++ libraries, and figures that don't match your latest results.
- Citations are suggested rather than inserted, unless automatic citing is switched on. Reports show only what's written now: reworded or deleted sentences drop out.

### Sources and reading
- **Add Source** for links, PDFs and YouTube videos, as well as capture while reading through the browser extension.
- Papers keep their maths: pages keep equations as TeX, PDFs use the arXiv source, arXiv HTML or publisher's page, and abstracts are always saved. **Re-read** updates sources saved earlier.
- Exact details from a paper's DOI, and **retraction warnings**.
- **References** in seven styles, including Chicago and Vancouver, with journal volume, issue, pages and DOI; BibTeX and RIS import and export; `\cite` keys in the Library.
- Rename sources without changing how they're cited, and set **citation details** for sources that lack them, such as lecture notes.
- **Zotero**: papers added to a Zotero collection join a project, with their PDFs.
- Temporary reading that expires unless saved or cited, highlights kept as notes, and the **Research trail**: what you read, when, and the claims it backs.
- **Recently Deleted** for sources, notes, meetings and AI use, kept for 30 days.

### Keeping records
- **Hover over a theorem or definition** named in a note ("Theorem 4.50(a)") to see its statement as the source prints it, with its page.
- **Scanned PDFs, screenshots and photos of pages** are read with Apple's Vision on your Mac. Text read from a scan is marked, and isn't used for comparing theorems, since its maths isn't exact.
- **Notes** filtered by source, topic (sorted by Claude) and your own folders, any number at once, sorted newest first, by page or A to Z; the filters are kept for each project. **Add to Notes** from search leaves the summary line for you to write, with the passage quoted under it, and **Check My Summary** asks questions about your note rather than rewriting it.
- Each note has a title, a body written freely in Markdown (paragraphs, lists, headings, tables, and LaTeX maths typeset as in a paper), shown formatted, the sources it's about (opening at their pages), and photos or files of your own attached. A claim backed by a page you haven't noted gets a short hint.
- **Meetings**: notes, decisions and action points by project, started from an event in your calendar if you like, with exports. Link a group's shared folder to read and edit its Markdown files in Referee, saved exactly as you write them; a teammate's change made meanwhile is never overwritten. Action points go to **Things 3**, **Apple Reminders**, **Todoist** or **Notion**, ticked off in both.
- **AI use**: a log of AI use, each entry titled by what it was used for, in date order (newest or oldest first, and dragged into order within a day), and a short **disclosure** drafted from it (facts only: which tool, what for, how checked), as a statement, a line per tool, a table, or wording you've been given with {tools}, {system}, {purposes} and {checks} filled in from the log. It's editable, and your edits are kept.
- **Claude connector**: search your reading, check a claim, and add or edit notes, meetings, tasks, sources and AI use from a Claude chat. Deleting always asks first.
- **Obsidian**: reading and meeting notes written into your vault as Markdown.
- **Raycast**: search Referee, quick capture, new notes, links, AI use and switching project from Raycast (the `raycast` folder; Referee must be open).
- **Undo** after deleting a note, meeting or AI use entry: put back exactly as it was.
- **Overleaf panel**: statements typeset with KaTeX, rechecked when the page opens, and notation you mark as fine ignored.
- **Save a copy with your highlights**: a saved PDF with what you highlighted while reading written in, for Preview or any PDF app.
- Referee reopens where you left off: the section, meeting, AI use entry and Evidence report document.
- **Search** (⌘K in Referee, or a shortcut of your choice from anywhere): commands, your notes, sources, highlights and meetings, and the passages in your reading that match by meaning, each opening at its page. It finds what your sources say; it never writes an answer.
- **Quick capture** (a shortcut of your choice, from anywhere): save a note, a link or an AI use entry into the current project without opening Referee.
- **Referee links**: `referee://` links to notes, meetings and sources, for a planner or to-do list.
- Right-click meetings, AI use entries and notes to rename or delete them.

### Privacy and safety
- **What leaves this device**: everything Referee can send off your Mac, what, where and when, with switches, including for Claude writing note lines and sorting notes into topics (both can be turned off).
- Keys and tokens in your Keychain, never in a file.
- **Backups**: back up and restore everything in one file, and weekly backups.
- **Report a problem**, in Settings → Help.

## 10 October 2026 (`hackathon-submission`)

The version built in one day for the Invisible AI hackathon: a browser extension and local server that check your writing against what you've read, with claim verification by Claude (evaluated on SciFact), misquote and copying checks, and learning from behaviour.
