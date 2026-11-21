# Changelog

What changed in each release of Referee, newest first. Releases are numbered (`v1.0.0`), and downloaded copies of Referee for Mac update themselves to the latest one.

## 1.1.4 (21 November 2026, `v1.1.4`)

- **Tasks carry more detail for your to-do app.** A task's Details set its deadline and when you plan to do it (Todoist's date, Things' When), which can repeat, apart from each other, as Todoist does; and its duration, priority (P1 red, P2 orange, P3 blue, or none), labels, section, the flag, and reminders (minutes before, or arriving at or leaving a place, picked with the Mac's map search). Each app takes what it has: Todoist all of it (reminders at a place need Todoist Pro), Things the date and tags, Reminders priority, the flag and a remind-me time, and Notion priority and labels when the database has those columns. What an app can't hold is written into the task's notes. The same Details are in the Calendar's new task, under More.
- **"By when" is called Deadline**, everywhere a task has one, and tasks from the Calendar have a deadline and duration too.
- **Drag and drop into the Library**: drop PDFs, pictures of pages, links or YouTube videos to add them to the project the Library is showing (or the current one, showing all reading).
- **The Library opens on the current project**, not on all reading. Choosing another, or all reading, stays chosen.
- **The project title has two menus**: a click lists the projects to switch between, with New project and the archived ones; a right-click has the current project's options (due date, also cite from, rename, archive, delete) and Sort projects. Their names are in sentence case.
- **Saved pages no longer take a cited paper's details.** A page with no DOI of its own (a GitHub repository whose README cites a paper, say) took the first DOI in its text and with it that paper's title, authors and journal. Only the source's own DOI counts now: in its citation tags, in its link, or on a PDF's first page.
- A source's citation details can now clear a wrong DOI and make its citation key again.

## 1.1.3 (17 November 2026, `v1.1.3`)

- **Settings has a sidebar**, like System Settings, with a page for each part: General, Checks, Reading, Writing, Integrations, and Privacy and help. The keyboard shortcuts are together under General. Under Writing, each writing app (Word, Google Docs, Overleaf, Obsidian, and R Markdown and Quarto) has a page of its own, so its settings are no longer behind a "Writing in" menu.
- **Integrations is part of Settings** rather than a window of its own: Zotero is under Reading, GitHub under Writing, and tasks, Obsidian and the Meetings calendar under Integrations. They're laid out like the rest of Settings.
- **Add API Key**, in the menu bar, opens Settings at Checks, where the keys are.
- **VAR in Raycast**: a VAR command opens Referee at VAR.
- **Search is easier to read**: results are grouped by kind (notes, sources, meetings, AI use, passages), with the words you typed marked in each. The bar names the project it's searching, and when searching every project, each result shows the project it's in. AI use entries are named by what they were for, not by the tool. A word a letter or two off, or written without its underscore ("model c" for model_c), still finds a match when nothing matches exactly. The panel is darker, so a bright window behind it no longer shows through.
- **Linking a GitHub repository no longer adds it to VAR.** In Settings, a repository is linked to a project; to practise on it, add it from VAR's + menu, under From GitHub. A study set taken out of VAR stays out, rather than coming back when the repository next updates.
- **Linked GitHub repositories update every hour**, rather than once a day.
- **The browser extension saves journal pages with a hidden sign-in form**, such as Wiley's. It took any page with a password box for a login page and wouldn't save it; now only a sign-in form you can see stops it.
- Titles and journal names looked up from a DOI no longer show the publisher's markup ("<scp>CIELAB</scp>", "&amp;").
- **GitHub repositories keep updating after a force-push.** When a commit was amended and pushed again, Referee's copy stopped updating; it's now made to match GitHub.

## 1.1.2 (15 November 2026, `v1.1.2`)

- **GitHub in Settings lists only the repositories VAR reads**, so it stays short however many you have. **Add a repository** searches the rest, recently updated first. Each shows when it was last updated, and they update by themselves once a day.
- **The browser extension looks like the Mac app**: serif project titles, small capital section labels, and outlined controls in the popup and the Library page, with fewer greys and brighter secondary text, so it's easier to read, in dark mode most of all. The Overleaf and Google Docs panels are easier to read in dark mode too, and project menus show the whole project name.
- **The browser extension shows what Referee knows**: the Library page has **Library** and **Evidence**, as the Mac app does, with each document's claims, what backs each one (source, statement and page) and what needs a look, and **Move to project** for a document. The popup leads with the project's next due date, the page you're on (whether it's in your reading, and how many of your claims it backs), and the latest claims that need a look; its settings fold under **Settings**.
- The popup's project menu says "New project", without "…".

## 1.1.1 (14 November 2026, `v1.1.1`)

- **Sign in instead of a key**: with no key saved, Referee uses a sign-in from Anthropic's `ant` command-line tool, which renews itself. Settings shows which is in use.
- When Claude rejects your key (expired or revoked), Referee says so, wherever it happens, instead of "Try again".
- **VAR reads more than LaTeX**: on either side, add a document Referee has read in Overleaf, Google Docs or Word straight from ＋, or choose or drop in Word, PDF, R Markdown, Quarto, Markdown, code or a whole project folder (the write-up first). Before, anything but LaTeX was ignored without a word; now VAR says what it couldn't read, and asks OneDrive, iCloud Drive or Google Drive to download a file kept online only.
- The mock interview and mock Q&A use their own words throughout ("End interview", "Couldn't start the mock interview"), instead of "viva".
- **Documents keep their project**: a document's first check goes to the project its title names ("PLA - Semester 1 (Individual Project)" to PLA Individual Project), or else the selected project, and later checks stay there whichever project is selected. **Move to project** in the Evidence report's ⋯ menu moves a document and all its checks.
- **Sort projects** by name or by date created, from the project menu. Every list of projects follows it, and menus keep their order when they open upwards.
- **A tidier project menu**: the current project's actions fold under **Project options**, the list scrolls after eight projects, and a search field appears once there are more than eight.
- "Needs a source" no longer flags pieces of links or LaTeX left when a sentence is split at a link, numbers inside links, or instructions for using software (a template's sample text).
- The code on GitHub no longer includes a stray link to a Python environment.

## 1.1.0 (9 November 2026, `v1.1.0`)

- **VAR**: practise explaining your own write-up before a viva. Choose a write-up (from Overleaf or a `.tex` file) and VAR asks about its statements and arguments, checks your answers against the write-up and your reading, and asks a follow-up where an answer is unclear. Answers can be typed, drawn or spoken, and drafts are kept until checked. **Try again** lets you answer a question afresh.
- **Mock viva**: a spoken run-through, opening with the reflection question in full, then four short questions answerable in two or three sentences. It can be paused and resumed.
- **GitHub integration**: in Settings → Integrations, choose repositories for VAR to read through the GitHub CLI on your Mac (Referee never handles a token). On the academic side it reads the write-up (LaTeX, R Markdown or Quarto) and the code.
- On Windows, Referee still runs from the code.

## 1.0.3 (6 November 2026, `v1.0.3`)

- **Todoist in the calendar**: with Todoist as your to-do app, its tasks in projects named after your Referee projects show on their days. Click one to edit it in place (name, notes, date and time, repeat, priority, project and labels), right-click to mark it done, and ＋ → **Task** makes a new one in any Todoist project, or a new project. Changes go to Todoist at once. Reminders are left to your calendar app, so none are sent twice. Action points already sent to Todoist show once.
- **Times on due dates and deadlines**: a project's due date or a named deadline can have a time, shown in the calendar and the countdown ("Due today at 17:00").
- **Right-click a project's due date** in the calendar to mark it submitted or delete it. Clearing a due date no longer removes the project's other deadlines.
- **Archived projects** are left out of the Library, Notes, Checks and AI use across all projects, and kept as they were until unarchived. Their tasks and deadlines stay in the calendar.
- **Project menu**: the current project's tick sits in a column on the left, with every item level beside it, and archived projects are folded under **Archived**.
- **Integrations** opens inside Settings, with a way back, instead of in its own window.

## 1.0.2 (1 November 2026, `v1.0.2`)

- **Mark as Submitted**: click a project's due date under its name to tick it off. Its warning stops, and the calendar keeps the date with a green tick.
- **Deadlines**: named deadlines besides a project's due date ("Draft to supervisor"), added from the calendar. The soonest one not yet submitted shows under the project's name.
- **Tasks without a meeting**: each project has a list of tasks that came from no meeting, at the top of Meetings. They go to your to-do app like action points.
- **Calendar**: ＋ on a day adds a meeting, a deadline or a task. Each day shows its year, and **Today** and a date picker jump to any date. Right-click a task to mark it done or delete it, or a deadline to mark it submitted or delete it.
- Menu items and buttons no longer end in "…", and text boxes no longer show examples.
- The README opens with a picture of Referee.

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
