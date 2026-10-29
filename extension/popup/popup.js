const research = document.getElementById("research");
const duration = document.getElementById("duration");
const mode = document.getElementById("mode");
const statusLine = document.getElementById("status");
const savedList = document.getElementById("saved-list");
const savedTitle = document.getElementById("saved-title");
const savedEmpty = document.getElementById("saved-empty");
const server = document.getElementById("server");
const projectSelect = document.getElementById("project");
const keepSelect = document.getElementById("keep");
const saveButton = document.getElementById("save-later");
const saveResult = document.getElementById("save-result");
const NEW_PROJECT = "__new__";
let settings = { project: "", projects: [], keep_minutes: 15 };
const searchBox = document.getElementById("search");

// A rough guide to what kind of source a page is, from its address.
const SOURCE_TYPES = [
  ["Academic", /\.(ac\.uk|edu)(\/|$)|doi\.org|arxiv\.org|jstor|springer|sciencedirect|wiley|nature\.com|ncbi\.nlm|pubmed|researchgate|semanticscholar|tandfonline|sagepub|\.pdf($|[?#])/i],
  ["Government", /\.gov(\.[a-z]{2})?(\/|$)|\.gov\.uk|nhs\.uk|who\.int|europa\.eu|\.mod\.uk|ons\.gov/i],
  ["News", /bbc\.|theguardian|nytimes|reuters|apnews|ft\.com|economist|independent\.co|telegraph|washingtonpost|cnn\.com|sky\.com|aljazeera/i],
  ["Encyclopedia", /wikipedia\.org|britannica\.com/i],
  ["Blog or forum", /medium\.com|substack|wordpress|blogspot|reddit|quora|stackexchange|stackoverflow|tumblr/i],
];
function sourceType(url) {
  const found = SOURCE_TYPES.find(([, pattern]) => pattern.test(url || ""));
  return found ? found[0] : "Website";
}


// Tick and cross drawn with the same stroke, so they match whatever the system font is.
const ICONS = {
  keep: '<svg viewBox="0 0 16 16" width="14" height="14" aria-hidden="true"><path d="M3 8.5l3.2 3.2L13 4.8" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/></svg>',
  forget: '<svg viewBox="0 0 16 16" width="14" height="14" aria-hidden="true"><path d="M4 4l8 8M12 4l-8 8" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"/></svg>',
};

// Everything Referee holds, most recent first, filtered by the search box. Saved sources stay
// until forgotten; temporary ones show how long they have left.
async function showSaved() {
  const [stored, claims] = await Promise.all([
    chrome.runtime.sendMessage({ type: "get", path: "sources" }).catch(() => null),
    chrome.runtime.sendMessage({ type: "get", path: "claims" }).catch(() => []),
  ]);
  // Only the project chosen above: its saved and temporary reading. With no project, everything.
  const project = projectSelect.value && projectSelect.value !== NEW_PROJECT ? projectSelect.value : settings.project;
  const sources = (Array.isArray(stored) ? stored : []).filter((c) => !project || (c.project || "") === project);
  // How many claims each source backs, shown as "Cited 3×" as in the library.
  const cited = new Map();
  for (const claim of Array.isArray(claims) ? claims : []) {
    if (claim.label === "supports" && claim.source?.url) cited.set(claim.source.url, (cited.get(claim.source.url) || 0) + 1);
  }
  const query = searchBox.value.trim().toLowerCase();
  const shown = sources
    .filter((c) => !query || `${c.name || ""} ${c.title} ${c.url}`.toLowerCase().includes(query))
    .sort((a, b) => (b.captured_ts || 0) - (a.captured_ts || 0))
    // Saved first, then temporary, under their own headings, as in the library.
    .sort((a, b) => (a.kept === false) - (b.kept === false))
    .slice(0, 30);

  const heading = (text) => {
    const item = document.createElement("li");
    item.className = "group";
    item.textContent = text;
    return item;
  };
  const rows = shown.map((c) => {
    const item = document.createElement("li");
    const title = document.createElement("span");
    title.className = c.kept === false ? "t temp" : "t";
    title.textContent = c.name || c.title || c.url;
    title.title = c.url;
    const tags = document.createElement("div");
    tags.className = "tags";
    const addTag = (text, extra = "") => {
      const tag = document.createElement("span");
      tag.className = `tag ${extra}`;
      tag.textContent = text;
      tags.append(tag);
    };
    if (c.kept === false) {
      const left = Math.max(1, Math.round(((c.captured_ts || 0) + settings.keep_minutes * 60 - Date.now() / 1000) / 60));
      addTag(`${left} min left`, "temp");
    }
    addTag(c.type === "pdf" ? "PDF" : c.type === "video" ? "Video" : sourceType(c.url));
    if (c.project && !project) addTag(c.project);  // every project shown: say which
    if (cited.get(c.url)) addTag(`Cited ${cited.get(c.url)}×`, "cited");
    const forget = document.createElement("button");
    forget.className = "forget-one";
    forget.title = "Forget this page";
    forget.innerHTML = ICONS.forget;
    forget.setAttribute("aria-label", "Forget this page");
    forget.addEventListener("click", async (event) => {
      event.stopPropagation();
      // Saved pages take two clicks (the first turns the cross red); temporary pages take one.
      if (c.kept !== false && forget.dataset.armed !== "yes") {
        forget.dataset.armed = "yes";
        forget.title = "Click again to forget";
        setTimeout(() => { forget.dataset.armed = ""; forget.title = "Forget this page"; }, 3000);
        return;
      }
      forget.disabled = true;
      item.style.opacity = "0.4";
      try {
        await chrome.runtime.sendMessage({ type: "forget", url: c.url });
      } finally {
        showSaved();
      }
    });
    const actions = document.createElement("div");
    actions.className = "actions";
    if (c.kept === false) {
      const keep = document.createElement("button");
      keep.className = "keep-one";
      keep.title = `Save for later${settings.project ? ` in ${settings.project}` : ""}`;
      keep.innerHTML = ICONS.keep;
      keep.setAttribute("aria-label", keep.title);
      keep.addEventListener("click", async (event) => {
        event.stopPropagation();
        keep.disabled = true;
        await chrome.runtime.sendMessage({ type: "post", path: "sources/keep", body: { url: c.url } });
        showSaved();
      });
      actions.append(keep);
    }
    actions.append(forget);
    item.append(title, tags, actions);
    return item;
  });
  const firstTemporary = shown.findIndex((c) => c.kept === false);
  if (firstTemporary >= 0) rows.splice(firstTemporary, 0, heading("Temporary · forgotten unless saved"));
  if (firstTemporary !== 0 && shown.length) rows.unshift(heading("Saved"));
  savedList.replaceChildren(...rows);
  const kept = sources.filter((c) => c.kept !== false).length;
  savedTitle.textContent = sources.length ? `Your reading · ${kept} saved` : "Your reading";
  savedEmpty.textContent = project ? `Nothing in ${project} yet.` : "Nothing saved yet.";
  savedEmpty.hidden = sources.length > 0;
  showSaveButton(sources);
}

searchBox.addEventListener("input", showSaved);

// Projects live on the server, so Word and the Mac app use the same current project.
async function showProject() {
  const fetched = await chrome.runtime.sendMessage({ type: "get", path: "settings" }).catch(() => null);
  if (fetched && !fetched.error) settings = fetched;
  projectSelect.replaceChildren(
    new Option("No project", ""),
    ...settings.projects.map((name) => new Option(name, name)),
    new Option("New project…", NEW_PROJECT));
  projectSelect.value = settings.project;
  keepSelect.value = String(settings.keep_minutes);
}

async function saveSettings(changes) {
  const saved = await chrome.runtime.sendMessage({ type: "post", path: "settings", body: changes });
  if (saved && !saved.error) settings = saved;
  showProject();
  showSaved();
}

// Chrome doesn't show prompt() in extension popups, so new projects are named in the popup.
const newProject = document.getElementById("new-project");
const newProjectName = document.getElementById("new-project-name");

projectSelect.addEventListener("change", () => {
  newProject.hidden = projectSelect.value !== NEW_PROJECT;
  if (projectSelect.value !== NEW_PROJECT) return saveSettings({ project: projectSelect.value });
  newProjectName.value = "";
  newProjectName.focus();
});

async function createProject() {
  const name = newProjectName.value.trim();
  if (!name) return newProjectName.focus();
  newProject.hidden = true;
  await saveSettings({ project: name });  // the new project becomes the current one
}

document.getElementById("new-project-create").addEventListener("click", createProject);
newProjectName.addEventListener("keydown", (event) => {
  if (event.key === "Enter") createProject();
  if (event.key === "Escape") {
    newProject.hidden = true;
    showProject();
  }
});

keepSelect.addEventListener("change", () => saveSettings({ keep_minutes: Number(keepSelect.value) }));

// "Save for later": keep the page you're on in the current project, whether or not it was captured.
async function currentTab() {
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  return tab;
}

async function showSaveButton(sources) {
  const tab = await currentTab();
  const stored = sources.find((c) => c.url === tab?.url);
  const saved = stored && stored.kept !== false;
  saveButton.disabled = Boolean(saved);
  saveButton.textContent = saved ? "Saved for later ✓" : "Save this page for later";
}

saveButton.addEventListener("click", async () => {
  saveButton.disabled = true;
  saveButton.textContent = "Saving…";
  const result = await chrome.runtime.sendMessage({ type: "save-later", tab: await currentTab() });
  saveResult.textContent = result?.ok
    ? `Saved${settings.project ? ` to ${settings.project}` : ""}.`
    : result?.reason || "Couldn't save this page.";
  showSaved();
});

async function showServer() {
  const online = await chrome.runtime.sendMessage({ type: "server" });
  server.dataset.state = online ? "online" : "offline";
  server.textContent = online ? "Server running" : "Server not running";
}

async function showStatus() {
  // Research mode may have been switched from Referee's menu bar or shortcut: catch up first.
  await chrome.runtime.sendMessage({ type: "sync-research" }).catch(() => {});
  const state = await chrome.storage.local.get(["research", "until", "duration", "mode"]);
  research.checked = Boolean(state.research);
  duration.value = state.duration ?? "60";
  mode.value = state.mode ?? "auto";
  const writing = !state.research && (state.mode ?? "auto") === "auto" &&
    (await chrome.runtime.sendMessage({ type: "writing" }));
  if (writing) {
    statusLine.textContent = "You're writing: capturing articles you read.";
    statusLine.className = "";
  } else if (!state.research) {
    statusLine.textContent = "Not reading anything.";
    statusLine.className = "off";
  } else if (state.until) {
    const minutes = Math.max(1, Math.round((state.until - Date.now()) / 60000));
    statusLine.textContent = `Capturing articles you read · off in ${minutes} min`;
    statusLine.className = "";
  } else {
    statusLine.textContent = "Capturing articles you read.";
    statusLine.className = "";
  }
}

research.addEventListener("change", async () => {
  await chrome.runtime.sendMessage({ type: "setResearch", on: research.checked, minutes: Number(duration.value) });
  showStatus();
});

duration.addEventListener("change", async () => {
  await chrome.storage.local.set({ duration: duration.value });
  if (research.checked) {
    await chrome.runtime.sendMessage({ type: "setResearch", on: true, minutes: Number(duration.value) });
  }
  showStatus();
});

const modeHint = document.getElementById("mode-hint");
function showModeHint() {
  modeHint.hidden = mode.value !== "auto";
}
mode.addEventListener("change", () => {
  chrome.storage.local.set({ mode: mode.value });
  showModeHint();
});

document.getElementById("open-library").addEventListener("click", () => {
  chrome.tabs.create({ url: chrome.runtime.getURL("library/library.html") });
  window.close();
});

// Clears reading that hasn't been saved or cited. Saved reading can only be forgotten one
// source at a time here, or all at once from the library.
const forgetTemporary = document.getElementById("forget");
forgetTemporary.addEventListener("click", async () => {
  // Two clicks: the first asks, a second within 3 seconds forgets.
  if (forgetTemporary.dataset.armed !== "yes") {
    forgetTemporary.dataset.armed = "yes";
    forgetTemporary.textContent = "Click again to forget temporary pages";
    setTimeout(() => {
      forgetTemporary.dataset.armed = "";
      forgetTemporary.textContent = "Forget temporary pages";
    }, 3000);
    return;
  }
  forgetTemporary.dataset.armed = "";
  forgetTemporary.textContent = "Forget temporary pages";
  await chrome.runtime.sendMessage({ type: "post", path: "sources/forget-temporary" });
  await chrome.runtime.sendMessage({ type: "sync" });
  showSaved();
});

chrome.storage.onChanged.addListener((changes, area) => {
  if (area === "local" && changes.captures) showSaved();
});
setInterval(showSaved, 30000);  // keep "min left" current while the popup is open

showStatus().then(showModeHint);
showProject().then(showSaved);
showServer();


// The project as a title at the top, as in the app's sidebar.
{
  const select = document.getElementById("project");
  const title = document.getElementById("project-title");
  const show = () => { title.textContent = select.selectedOptions[0]?.textContent || ""; };
  select.addEventListener("change", show);
  new MutationObserver(show).observe(select, { childList: true, subtree: true, attributes: true });
  show();
  // Its value is set in code once the projects load, which fires no event: look again shortly.
  [300, 1000, 2500].forEach((ms) => setTimeout(show, ms));
}
