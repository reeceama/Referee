// Library: everything Referee has captured, the references for what your writing cites (in
// Word), and the proof-of-work report. Checking happens where you write; this
// page is for looking back over your reading.

const STYLE_KEY = "referee-style";

const projectSelect = document.getElementById("project");
const searchBox = document.getElementById("search");
const styleSelect = document.getElementById("citation-style");
const serverStatus = document.getElementById("server");

let sources = [];   // from the server: metadata and passage count per source
let claims = [];    // from the server: verdicts, oldest first
let captures = [];  // from the extension: when each source was read

const get = (path) => chrome.runtime.sendMessage({ type: "get", path });

function escapeHtml(text) {
  return String(text ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
}

function when(ms) {
  return new Date(ms).toLocaleString("en-GB", { day: "numeric", month: "short", year: "numeric", hour: "2-digit", minute: "2-digit" });
}

function toast(message) {
  const box = document.getElementById("toast");
  box.textContent = message;
  box.classList.add("show");
  setTimeout(() => box.classList.remove("show"), 1600);
}

function style() {
  return Cite.STYLES[styleSelect.value] || Cite.STYLES.apa;
}

let settings = { project: "", projects: [], links: {} };
const NO_PROJECT = "__none__";

// Projects are kept apart: a project shows only its own sources ("All reading" shows everything).
function inProject(project) {
  if (!projectSelect.value) return true;
  if (projectSelect.value === NO_PROJECT) return !project;
  return project === projectSelect.value;
}

// The projects this one may also cite from, chosen with the checkboxes under the controls.
function renderLinks() {
  const box = document.getElementById("links");
  const project = projectSelect.value;
  const others = settings.projects.filter((p) => p !== project);
  if (!project || project === NO_PROJECT || !others.length) {
    box.hidden = true;
    return;
  }
  const linked = new Set(settings.links?.[project] || []);
  box.hidden = false;
  box.innerHTML = `<h2>Also cite from</h2><p class="hint">Projects whose sources ${escapeHtml(project)} may cite as well as its own.</p>` + others.map((p) =>
    `<label><span>${escapeHtml(p)}</span><input type="checkbox" value="${escapeHtml(p)}" ${linked.has(p) ? "checked" : ""}/></label>`).join("");
  box.querySelectorAll("input").forEach((input) => input.addEventListener("change", async () => {
    const chosen = [...box.querySelectorAll("input:checked")].map((i) => i.value);
    const saved = await chrome.runtime.sendMessage({ type: "post", path: "settings", body: { links: { ...settings.links, [project]: chosen } } });
    if (saved && !saved.error) settings = saved;
    toast("Saved");
  }));
}

function supported() {
  return claims.filter((c) => c.label === "supports" && c.source?.url && inProject(c.project));
}

// Cited sources with full metadata, numbered in order of first citation.
function citedSources() {
  const byUrl = new Map(sources.map((s) => [s.url, s]));
  const cited = new Map();
  for (const claim of supported()) {
    if (!cited.has(claim.source.url)) cited.set(claim.source.url, byUrl.get(claim.source.url) || claim.source);
  }
  return [...cited.values()];
}

function renderReferences() {
  const cited = citedSources();
  const numbers = new Map(cited.map((s, i) => [s.url, i + 1]));
  const ordered = style().numbered ? cited : [...cited].sort((a, b) => Cite.sortKey(a).localeCompare(Cite.sortKey(b)));
  const entries = ordered.map((s) => style().reference(s, { number: numbers.get(s.url) }));
  const list = document.getElementById("ref-list");
  list.className = "plain"; // references carry their own [n] where the style is numbered
  list.replaceChildren(...entries.map((text) => Object.assign(document.createElement("li"), { textContent: text })));
  document.getElementById("refs-empty").hidden = entries.length > 0;
  document.getElementById("copy-refs").onclick = async () => {
    await navigator.clipboard.writeText(entries.join("\n"));
    toast(`${entries.length} reference${entries.length === 1 ? "" : "s"} copied`);
  };
}

function renderSources() {
  const query = searchBox.value.trim().toLowerCase();
  const citedCount = new Map();
  for (const claim of supported()) citedCount.set(claim.source.url, (citedCount.get(claim.source.url) || 0) + 1);
  const readAt = new Map(captures.map((c) => [c.url, c.at]));

  const shown = sources
    .filter((s) => inProject(s.project))
    .filter((s) => !query || [s.name, s.title, s.site, s.author, s.url].some((v) => String(v || "").toLowerCase().includes(query)))
    .sort((a, b) => (readAt.get(b.url) || 0) - (readAt.get(a.url) || 0));

  const saved = shown.filter((s) => s.kept !== false);
  const cited = saved.filter((s) => citedCount.get(s.url)).length;
  document.getElementById("count").textContent = `${saved.length} source${saved.length === 1 ? "" : "s"} · ${cited} cited`;
  const row = (s) => {
    const item = document.createElement("li");
    const n = citedCount.get(s.url) || 0;
    const type = s.type === "pdf" ? "PDF" : s.type === "video" ? "Video" : "Web page";
    const read = readAt.get(s.url) ? when(readAt.get(s.url)) : s.captured_at || "";
    item.innerHTML = `
      <div class="what">
        <a class="title" href="${escapeHtml(s.url)}" target="_blank" rel="noopener">${escapeHtml(s.name || Cite.cleanTitle(s))}</a>
        <div class="meta">${escapeHtml([s.site, read].filter(Boolean).join(" · "))}</div>
        <div class="tags">
          ${s.retracted ? `<span class="tag retracted">Retracted</span>` : ""}
          <span class="tag">${type}</span>
          ${n ? `<span class="tag cited">Cited ${n}×</span>` : ""}
        </div>
      </div>
      <div class="row-actions">
      <select class="move" aria-label="Project for this source">
        <option value="">No project</option>
        ${settings.projects.map((p) => `<option value="${escapeHtml(p)}" ${s.project === p ? "selected" : ""}>${escapeHtml(p)}</option>`).join("")}
      </select>
      ${s.kept === false ? `<button class="keep">Save</button>` : ""}
      <button class="forget" title="Forget this source" aria-label="Forget this source">×</button>
      </div>`;
    item.querySelector(".move").addEventListener("change", async (event) => {
      await chrome.runtime.sendMessage({ type: "post", path: "sources/move", body: { url: s.url, project: event.target.value } });
      toast(event.target.value ? `Moved to ${event.target.value}` : "Removed from its project");
      load();
    });
    item.querySelector(".keep")?.addEventListener("click", async () => {
      await chrome.runtime.sendMessage({ type: "post", path: "sources/keep", body: { url: s.url, project: s.project || "" } });
      toast("Saved");
      load();
    });
    item.querySelector(".forget").onclick = async (event) => {
      // Saved sources take two clicks (the first turns the cross red); temporary ones take one.
      const button = event.currentTarget;
      if (s.kept !== false && button.dataset.armed !== "yes") {
        button.dataset.armed = "yes";
        button.title = "Click again to forget";
        setTimeout(() => { button.dataset.armed = ""; button.title = "Forget this source"; }, 3000);
        return;
      }
      await chrome.runtime.sendMessage({ type: "forget", url: s.url });
      toast("Forgotten");
      load();
    };
    return item;
  };
  const temporary = shown.filter((s) => s.kept === false);
  document.getElementById("sources").replaceChildren(...saved.map(row));
  document.getElementById("temp-sources").replaceChildren(...temporary.map(row));
  document.getElementById("saved-heading").hidden = !saved.length;
  document.getElementById("temp-heading").hidden = !temporary.length;
  if (!shown.length) document.getElementById("sources").innerHTML = `<li class="hint">${sources.length ? "Nothing matches." : "Nothing captured yet. Read with research mode on, or while writing in Word."}</li>`;
}

// Evidence summary for the writing in this project: what the reading backs and contradicts,
// and whether it leans on one source.
const RELIANCE_SHARE = 0.5;
const RELIANCE_MIN_CLAIMS = 4;

function renderSummary() {
  const mine = claims.filter((c) => inProject(c.project));
  const backed = mine.filter((c) => c.label === "supports");
  const against = mine.filter((c) => c.label === "contradicts").length;
  const unsupported = mine.filter((c) => c.label === "needs_source").length;
  const box = document.getElementById("summary");
  if (!mine.length) {
    box.textContent = "";
    return;
  }
  const perSource = new Map();
  for (const c of backed) perSource.set(c.source.url, (perSource.get(c.source.url) || 0) + 1);
  const [topUrl, top] = [...perSource].sort((a, b) => b[1] - a[1])[0] || [];
  const topSource = backed.find((c) => c.source.url === topUrl)?.source;
  box.innerHTML = `<strong>${backed.length} claim${backed.length === 1 ? "" : "s"} backed by your reading</strong>` +
    (against ? ` · ${against} contradicted by a source` : "") +
    (unsupported ? ` · ${unsupported} need${unsupported === 1 ? "s" : ""} a source` : "") +
    "";   // no "rest on one source" warning: leaning on one set of lecture notes is normal
}

// Create, rename, delete. Renaming and deleting are done in place: prompt() and confirm()
// aren't relied on, so this works the same in every browser.
function renderProjects() {
  const list = document.getElementById("projects");
  const counts = new Map();
  for (const s of sources) if (s.project) counts.set(s.project, (counts.get(s.project) || 0) + 1);
  list.replaceChildren(...settings.projects.map((name) => {
    const item = document.createElement("li");
    const n = counts.get(name) || 0;
    item.innerHTML = `<span class="name">${escapeHtml(name)}</span>
      ${settings.project === name ? `<span class="current">Current</span>` : `<button class="use">Make current</button>`}
      <span class="hint">${n} source${n === 1 ? "" : "s"}</span>
      <button class="rename">Rename</button><button class="delete">Delete</button>`;
    item.querySelector(".use")?.addEventListener("click", () => saveSettings({ project: name }));
    item.querySelector(".rename").addEventListener("click", () => {
      item.innerHTML = `<input class="rename-to" value="${escapeHtml(name)}" maxlength="60" /><button class="ok">Rename</button><button class="cancel">Cancel</button>`;
      const input = item.querySelector(".rename-to");
      input.focus();
      const done = async () => {
        const to = input.value.trim();
        if (to && to !== name) await renameProject(name, to);
        else renderProjects();
      };
      item.querySelector(".ok").onclick = done;
      item.querySelector(".cancel").onclick = renderProjects;
      input.onkeydown = (event) => { if (event.key === "Enter") done(); if (event.key === "Escape") renderProjects(); };
    });
    const remove = item.querySelector(".delete");
    remove.addEventListener("click", async () => {
      if (remove.dataset.armed !== "yes") {
        remove.dataset.armed = "yes";
        remove.textContent = "Click again: sources stay, with no project";
        setTimeout(() => { remove.dataset.armed = ""; remove.textContent = "Delete"; }, 4000);
        return;
      }
      await renameProject(name, "");
    });
    return item;
  }));
  if (!settings.projects.length) list.innerHTML = `<li class="hint">No projects yet.</li>`;
}

async function saveSettings(changes) {
  const saved = await chrome.runtime.sendMessage({ type: "post", path: "settings", body: changes });
  if (saved && !saved.error) settings = saved;
  load();
}

async function renameProject(old, name) {
  await chrome.runtime.sendMessage({ type: "post", path: "projects/rename", body: { old, new: name } });
  toast(name ? `Renamed to ${name}` : "Project deleted");
  if (projectSelect.value === old) projectSelect.value = name;
  load();
}

async function createProject() {
  const input = document.getElementById("new-project-name");
  const name = input.value.trim();
  if (!name) return input.focus();
  input.value = "";
  await saveSettings({ project: name });
  toast(`Created ${name}: it's now the current project`);
}
document.getElementById("new-project-create").onclick = createProject;
document.getElementById("new-project-name").onkeydown = (event) => { if (event.key === "Enter") createProject(); };

function render() {
  renderProjects();
  renderLinks();
  renderSummary();
  renderReferences();
  renderSources();
}

function proofOfWork() {
  // Everything the server holds, timed by the extension's capture log where it has one (the
  // log keeps only recent captures), otherwise by the capture date the server recorded.
  const loggedAt = new Map(captures.map((c) => [c.url, c.at]));
  const read = sources.filter((s) => inProject(s.project))
    .map((s) => ({ url: s.url, title: Cite.cleanTitle(s), at: loggedAt.get(s.url) || Date.parse(s.captured_at || "") || 0 }))
    .sort((a, b) => a.at - b.at);
  const readAt = new Map(read.map((c) => [c.url, c.at]));
  const cited = citedSources();
  const numbers = new Map(cited.map((s, i) => [s.url, i + 1]));
  const byUrl = new Map(sources.map((s) => [s.url, s]));
  const items = supported();
  const name = projectSelect.value === NO_PROJECT ? "No project" : projectSelect.value || "All reading";

  const readingRows = read.map((c) => `<tr><td>${c.at ? escapeHtml(when(c.at)) : "—"}</td><td>${escapeHtml(c.title || c.url)}<br>
    <span class="url">${escapeHtml(c.url)}</span></td></tr>`).join("");
  const claimRows = items.map((c) => {
    const source = byUrl.get(c.source.url) || c.source;
    const cite = style().inText(source, { number: numbers.get(c.source.url), page: c.page, time: c.time });
    const at = readAt.get(c.source.url);
    return `<tr><td>${escapeHtml(c.sentence)}</td><td>${escapeHtml(cite)}<br><q>${escapeHtml(c.quote || "")}</q></td>
      <td>${at ? escapeHtml(when(at)) : "—"}</td><td>${escapeHtml(when(c.at * 1000))}</td></tr>`;
  }).join("");

  const html = `<!doctype html><html lang="en-GB"><head><meta charset="utf-8">
<title>Proof of work: ${escapeHtml(name)}</title>
<style>
  :root { --text: #1f2328; --muted: #6b7280; --line: #e5e7eb; --page: #ffffff; }
  @media (prefers-color-scheme: dark) { :root { --text: #e6e6e6; --muted: #9aa0a6; --line: #30363d; --page: #0d1117; } }
  @media print { :root { --text: #1f2328; --muted: #6b7280; --line: #e5e7eb; --page: #ffffff; } }  /* paper stays light */
  body { font: 14px/1.5 Georgia, serif; color: var(--text); background: var(--page); max-width: 920px; margin: 32px auto; padding: 0 20px; }
  h1 { font-size: 22px; margin-bottom: 4px; } h2 { font-size: 16px; margin-top: 28px; }
  .meta, .url, .note { color: var(--muted); font-size: 12px; }
  table { width: 100%; border-collapse: collapse; margin-top: 8px; }
  th, td { text-align: left; vertical-align: top; padding: 6px 8px; border-bottom: 1px solid var(--line); }
  th { font-size: 12px; text-transform: uppercase; letter-spacing: 0.04em; color: var(--muted); }
</style></head><body>
<h1>Proof of work: ${escapeHtml(name)}</h1>
<div class="meta">Generated by Referee on ${escapeHtml(when(Date.now()))} · ${read.length} source${read.length === 1 ? "" : "s"} read · ${items.length} supported claim${items.length === 1 ? "" : "s"}</div>
<h2>Reading log</h2>
${read.length ? `<table><tr><th>Read</th><th>Source</th></tr>${readingRows}</table>` : "<p>No reading has been recorded.</p>"}
<h2>Claims and their evidence</h2>
${items.length ? `<table><tr><th>Claim</th><th>Source and supporting passage</th><th>Source read</th><th>Claim checked</th></tr>${claimRows}</table>` : "<p>No supported claims yet.</p>"}
<p class="note">Reading times were recorded by the Referee browser extension when each source was captured, and claims
when Referee checked them as they were written. Both are kept on this computer. This report shows the research behind
the writing; it is not tamper-proof.</p>
<p class="note">To keep a copy, print this page (Cmd+P or Ctrl+P) and choose "Save as PDF".</p>
</body></html>`;
  openReport(html);
}

async function load() {
  const [fetchedSources, fetchedClaims, stored] = await Promise.all([
    get("sources"), get("claims"), chrome.storage.local.get("captures"),
  ]);
  const online = Array.isArray(fetchedSources);
  serverStatus.dataset.state = online ? "online" : "offline";
  serverStatus.textContent = online ? "" : "Server not running";
  sources = online ? fetchedSources : [];
  claims = Array.isArray(fetchedClaims) ? fetchedClaims : [];
  captures = stored.captures || [];

  const fetched = await get("settings").catch(() => null);
  if (fetched && !fetched.error) settings = fetched;
  const projects = [...new Set([...(settings.projects || []), ...sources.map((s) => s.project).filter(Boolean)])].sort();
  settings.projects = projects;
  const current = projectSelect.value;
  projectSelect.replaceChildren(new Option("All reading", ""), ...projects.map((p) => new Option(p, p)), new Option("No project", NO_PROJECT));
  projectSelect.value = projects.includes(current) || current === NO_PROJECT ? current
    : (current === "" && settings.project && !projectSelect.dataset.touched ? settings.project : "");
  render();
}

try { styleSelect.value = localStorage.getItem(STYLE_KEY) || "apa"; } catch { /* storage blocked */ }
styleSelect.onchange = () => {
  try { localStorage.setItem(STYLE_KEY, styleSelect.value); } catch { /* storage blocked */ }
  render();
};
projectSelect.onchange = () => {
  projectSelect.dataset.touched = "yes";  // opened on the current project; now the person's choice
  render();
};
searchBox.oninput = renderSources;

// Reports open in the font and size chosen beside the buttons (remembered), as in the Mac app.
const REPORT_FONTS = {
  "Times New Roman": "'Times New Roman', Times, serif",
  "Arial": "Arial, Helvetica, sans-serif",
  "Calibri": "Calibri, Carlito, 'Helvetica Neue', sans-serif",
  "Georgia": "Georgia, serif",
  "Garamond": "'EB Garamond', Garamond, 'Adobe Garamond Pro', serif",
  "Cambria": "Cambria, Caladea, Georgia, serif",
  "Computer Modern": "'CMU Serif', 'Latin Modern Roman', 'Computer Modern', serif",
};
const fontSelect = document.getElementById("report-font");
const sizeSelect = document.getElementById("report-size");
for (const name of Object.keys(REPORT_FONTS)) fontSelect.add(new Option(name, name));
for (const size of [10, 11, 12, 14]) sizeSelect.add(new Option(`${size} pt`, size));
chrome.storage.local.get(["reportFont", "reportSize"]).then(({ reportFont, reportSize }) => {
  fontSelect.value = REPORT_FONTS[reportFont] ? reportFont : "Times New Roman";
  sizeSelect.value = reportSize || 12;
});
fontSelect.onchange = sizeSelect.onchange = () =>
  chrome.storage.local.set({ reportFont: fontSelect.value, reportSize: Number(sizeSelect.value) });

function openReport(html) {
  const css = `<style>body, body * { font-family: ${REPORT_FONTS[fontSelect.value] || REPORT_FONTS["Times New Roman"]} !important; }
body { font-size: ${sizeSelect.value || 12}pt !important; }</style>`;
  const styled = html.includes("</head>") ? html.replace("</head>", css + "</head>") : css + html;
  window.open(URL.createObjectURL(new Blob([styled], { type: "text/html" })), "_blank");
}

// The other reports and Zotero files come from Referee's server, as in the Mac app's Library.
function serverProject() {
  if (!projectSelect.value) return "all";
  return projectSelect.value === NO_PROJECT ? "none" : projectSelect.value;
}

async function serverPage(path) {
  const text = await chrome.runtime.sendMessage({ type: "page", path });
  if (text == null) alert("Referee isn't running. Open Referee and try again.");
  return text;
}

async function openServerReport(page) {
  const html = await serverPage(`${page}?project=${encodeURIComponent(serverProject())}`);
  if (html != null) openReport(html);
}

document.getElementById("reports").onchange = (event) => {
  const page = event.target.value;
  event.target.value = "";
  if (page === "proof") proofOfWork(); else if (page) openServerReport(page);
};

document.getElementById("export").onclick = async () => {
  const bib = await serverPage(`export?format=bibtex&project=${encodeURIComponent(serverProject())}`);
  if (bib == null) return;
  const link = document.createElement("a");
  link.href = URL.createObjectURL(new Blob([bib], { type: "application/x-bibtex" }));
  link.download = "refs.bib";
  link.click();
};

const importFile = document.getElementById("import-file");
document.getElementById("import").onclick = () => importFile.click();
importFile.onchange = async () => {
  const file = importFile.files[0];
  importFile.value = "";
  if (!file) return;
  const button = document.getElementById("import");
  button.disabled = true;
  button.textContent = "Importing…";
  const result = await chrome.runtime.sendMessage({ type: "post", path: "import", body: { text: await file.text() } });
  button.disabled = false;
  button.textContent = "Import .bib or .ris";
  if (!result || result.error) { alert("Referee isn't running. Open Referee and try again."); return; }
  const failed = result.failed?.length ? `\n\nCouldn't add:\n${result.failed.join("\n")}` : "";
  alert(`Added ${result.added} source${result.added === 1 ? "" : "s"}.${failed}`);
  load();
};

// Forgetting everything is kept off the popup and needs a typed confirmation.
const forgetEverything = document.getElementById("forget-everything");
forgetEverything.onclick = async () => {
  const typed = forgetEverything.parentElement.querySelector("input");
  if (!typed) {
    const input = Object.assign(document.createElement("input"), { placeholder: "Type forget to confirm" });
    input.style.marginRight = "8px";
    forgetEverything.before(input);
    forgetEverything.textContent = "Forget everything";
    input.focus();
    return;
  }
  if (typed.value.trim().toLowerCase() !== "forget") return typed.focus();
  await chrome.runtime.sendMessage({ type: "clear" });
  typed.remove();
  forgetEverything.textContent = "Forget all reading, saved and temporary";
  toast("All reading forgotten");
  load();
};
chrome.storage.onChanged.addListener((changes, area) => { if (area === "local" && changes.captures) load(); });
load();


// The sidebar's title follows the project chosen.
{
  const title = document.getElementById("project-title");
  const show = () => { title.textContent = projectSelect.selectedOptions[0]?.textContent || "All reading"; };
  projectSelect.addEventListener("change", show);
  new MutationObserver(show).observe(projectSelect, { childList: true });
  show();
  // Its value is set in code once the projects load, which fires no event: look again shortly.
  [300, 1000, 2500].forEach((ms) => setTimeout(show, ms));
}


// One page at a time, like Referee for Mac: the sidebar and the Reading/References switch choose it.
{
  const titles = { reading: "Library", references: "Library", "projects-section": "Projects" };
  const showPage = (page) => {
    if (!titles[page]) page = "reading";
    document.querySelectorAll("section.page").forEach((s) => { s.hidden = s.id !== page; });
    document.querySelectorAll("[data-page]").forEach((el) => el.classList.toggle("selected", el.dataset.page === page));
    document.getElementById("page-title").textContent = titles[page];
    const library = page === "reading" || page === "references";
    document.querySelector(".controls").hidden = !library;
    document.getElementById("summary").hidden = !library;
    document.querySelector(".header-actions").hidden = !library;
  };
  document.querySelectorAll("[data-page]").forEach((el) => el.addEventListener("click", (event) => {
    event.preventDefault();
    history.replaceState(null, "", "#" + el.dataset.page);
    showPage(el.dataset.page);
  }));
  showPage(location.hash.slice(1));
}
