// Background service worker: talks to the backend, runs research mode and keeps a log of
// captured pages for the popup. Pages and the library send messages here rather than calling
// localhost themselves, which Chrome would block from ordinary web pages.

importScripts("skip.js");

const SERVER = "http://localhost:8000";
const HEADERS = { "Content-Type": "application/json", "X-Referee": "1" };
const ROUTES = ["check", "feedback", "statement", "code", "claims/current", "claims/ignore", "claims/order"];
const MAX_LOG = 50;

// Notes open sources through http://localhost:8000/open?url=…&page=…. If that source is already
// open in a tab, it isn't opened twice: at a page, the new tab replaces the old; otherwise the old is shown.
// Tabs are matched by the source they show, however its address was written.
function sourceOf(address) {
  try {
    const link = new URL(address);
    if (link.origin === SERVER && link.pathname === "/source-file") {
      const inner = link.searchParams.get("url");
      return inner && !inner.startsWith(SERVER) ? sourceOf(inner) : null;  // spaces and %20 count as the same
    }
    link.hash = "";
    return link.href;
  } catch {
    return null;
  }
}

chrome.tabs.onUpdated.addListener(async (tabId, change) => {
  if (!change.url || !change.url.startsWith(`${SERVER}/open?`)) return;
  const opening = new URL(change.url);
  const source = opening.searchParams.get("url");
  const page = opening.searchParams.get("page");
  if (!source) return;
  const tabs = await chrome.tabs.query({});
  const already = tabs.find((t) => t.id !== tabId && t.url && sourceOf(t.url) === sourceOf(source));
  if (!already) return; // not open yet: the /open page opens it at the page itself
  if (page) {
    // The PDF viewer keeps its scroll position on a reload and ignores "#page=", so going to a page
    // in the open tab doesn't work. Instead the new tab opens the PDF at the page, and the old one
    // closes: still one tab for the source, now at the page.
    chrome.tabs.remove(already.id);
    return;
  }
  await chrome.tabs.update(already.id, { active: true });
  await chrome.windows.update(already.windowId, { focused: true });
  chrome.tabs.remove(tabId);
});

chrome.runtime.onMessage.addListener((message, sender, reply) => {
  if (ROUTES.includes(message.type)) {
    post(message.type, message.body).then(reply).catch((error) => reply({ error: String(error) }));
    return true; // reply asynchronously
  }
  if (message.type === "highlight") {
    post("highlights", message.body).then(reply).catch(() => reply({ ok: false }));
    return true;
  }
  if (message.type === "capture") {
    capture(message.body).then(reply);
    return true;
  }
  if (message.type === "forget") {
    forgetOne(message.url).then(reply);
    return true;
  }
  if (message.type === "clear") {
    forgetEverything().then(reply);
    return true;
  }
  if (message.type === "server") {
    fetch(`${SERVER}/`, { headers: HEADERS, cache: "no-store" })
      .then((response) => reply(response.ok))
      .catch(() => reply(false));
    return true;
  }
  if (message.type === "writing-ping") {
    fetch(`${SERVER}/writing`, { method: "POST", headers: HEADERS })
      .then(() => reply({ ok: true }))
      .catch(() => reply({ ok: false }));
    return true;
  }
  if (message.type === "writing") {
    fetch(`${SERVER}/writing`, { headers: HEADERS })
      .then((response) => response.json())
      .then((result) => reply(Boolean(result.active)))
      .catch(() => reply(false));
    return true;
  }
  if (message.type === "sync-research") {
    checkFocus().then(() => reply({ ok: true }));
    return true;
  }
  if (message.type === "sync") {
    syncCaptures().then(() => reply({ ok: true }));
    return true;
  }
  if (message.type === "save-later") {
    saveForLater(message.tab).then(reply);
    return true;
  }
  if (message.type === "post") {  // the popup changes settings
    post(message.path, message.body || {}).then(reply).catch((error) => reply({ error: String(error) }));
    return true;
  }
  if (message.type === "delete") {  // the library removes the saved API key
    fetch(`${SERVER}/${message.path}`, { method: "DELETE", headers: HEADERS })
      .then((response) => response.json())
      .then(reply)
      .catch((error) => reply({ error: String(error) }));
    return true;
  }
  if (message.type === "get") {  // the library reads /sources and /claims
    fetch(`${SERVER}/${message.path}`, { headers: HEADERS, cache: "no-store" })
      .then((response) => response.json())
      .then(reply)
      .catch((error) => reply({ error: String(error) }));
    return true;
  }
  if (message.type === "page") {  // the library opens a report or exports a file: text, not JSON
    fetch(`${SERVER}/${message.path}`, { headers: HEADERS, cache: "no-store" })
      .then((response) => response.text())
      .then(reply)
      .catch(() => reply(null));
    return true;
  }
  if (message.type === "gdoc") {  // Google Docs: the open document's text, from its plain-text export
    // Only ever the document in the tab that asked, read with the person's own Google sign-in.
    const id = (sender.tab?.url || "").match(/^https:\/\/docs\.google\.com\/document\/d\/([\w-]+)/)?.[1];
    if (!id) { reply(null); return; }
    fetch(`https://docs.google.com/document/d/${id}/export?format=txt`, { credentials: "include", cache: "no-store" })
      .then((response) => (response.ok ? response.text() : null))
      .then(reply)
      .catch(() => reply(null));
    return true;
  }
  if (message.type === "setResearch") {
    setResearch(message.on, message.minutes).then(() => reply({ ok: true }));
    return true;
  }
});

async function post(route, body) {
  const response = await fetch(`${SERVER}/${route}`, { method: "POST", headers: HEADERS, body: JSON.stringify(body) });
  return response.json();
}

// Sends a page to the backend and records what happened, for the popup's saved pages list.
async function capture({ url, title, html }) {
  let entry = { url, title: title || url, at: Date.now() };
  try {
    const result = await post("capture", { url, html });
    if (result.ok && result.already_captured) entry.status = "already";
    else if (result.ok) entry = { ...entry, status: "saved", passages: result.passages };
    else entry = { ...entry, status: "skipped", reason: result.reason };
  } catch {
    entry = { ...entry, status: "offline", reason: "the Referee server isn't running" };
  }
  console.log("[Referee] capture:", entry);
  await logCapture(entry);
  return entry;
}

async function logCapture(entry) {
  const { captures = [] } = await chrome.storage.local.get("captures");
  const previous = captures.find((c) => c.url === entry.url);
  // A repeat visit shouldn't overwrite the original "saved" record.
  const keep = entry.status === "already" && previous ? previous : entry;
  const rest = captures.filter((c) => c.url !== entry.url);
  await chrome.storage.local.set({ captures: [keep, ...rest].slice(0, MAX_LOG) });
}

// --- PDFs ---
// Chrome's PDF viewer doesn't run extension scripts, so PDF tabs are watched from here.
// A PDF counts as read once its tab has been showing for READ_MS, as for web pages.

const READ_MS = 20000;
const MAX_PDF_BYTES = 25 * 1024 * 1024;
const PDF_URL = /\.pdf($|[?#])/i;
const pdfTimers = new Map(); // tab id -> timer
const pdfsSent = new Set();  // URLs already sent this session

// Research mode on, a macOS Focus has switched it on through the server, or (automatic
// mode only) Word reports someone writing.
async function capturing() {
  const { research, mode } = await chrome.storage.local.get(["research", "mode"]);
  if (research) return true;
  try {
    const result = await fetch(`${SERVER}/writing`, { headers: HEADERS }).then((r) => r.json());
    return Boolean(result.focus) || ((mode ?? "auto") === "auto" && Boolean(result.active));
  } catch {
    return false;
  }
}

// YouTube videos are captured from their transcript; the page itself stays on the skip list.
const YOUTUBE_VIDEO = /^https:\/\/(www\.|m\.)?youtube\.com\/(watch\?|shorts\/)|^https:\/\/youtu\.be\//;

function watchPdf(tab) {
  const isPdf = tab.url && PDF_URL.test(tab.url) && !isSkipped(tab.url);
  const isVideo = tab.url && YOUTUBE_VIDEO.test(tab.url);
  if ((!isPdf && !isVideo) || pdfsSent.has(tab.url)) return;
  clearTimeout(pdfTimers.get(tab.id));
  pdfTimers.set(tab.id, setTimeout(async () => {
    pdfTimers.delete(tab.id);
    const current = await chrome.tabs.get(tab.id).catch(() => null);
    // Only if the same PDF or video is still the tab being looked at.
    if (!current?.active || current.url !== tab.url) return;
    if (isPdf) capturePdf(current.url, current.title);
    else captureVideo(current.url, current.title);
  }, READ_MS));
}

chrome.tabs.onUpdated.addListener((tabId, change, tab) => {
  // YouTube changes video without reloading the page, so a new URL counts too.
  if (change.status === "complete" || change.url) watchPdf(tab);
});

async function captureVideo(url, title, force = false) {
  if (!force && !(await capturing())) return;
  pdfsSent.add(url);
  let entry = { url, title: (title || url).replace(/ - YouTube$/, ""), at: Date.now() };
  try {
    const result = await post("capture-video", { url });
    if (result.ok && result.already_captured) entry.status = "already";
    else if (result.ok) entry = { ...entry, status: "saved", passages: result.passages };
    else entry = { ...entry, status: "skipped", reason: result.reason };
  } catch {
    entry = { ...entry, status: "offline", reason: "the Referee server isn't running" };
  }
  console.log("[Referee] video capture:", entry);
  await logCapture(entry);
  return entry;
}
chrome.tabs.onActivated.addListener(({ tabId }) => {
  chrome.tabs.get(tabId).then(watchPdf).catch(() => {});
});
chrome.tabs.onRemoved.addListener((tabId) => {
  clearTimeout(pdfTimers.get(tabId));
  pdfTimers.delete(tabId);
});

function toBase64(buffer) {
  const bytes = new Uint8Array(buffer);
  let binary = "";
  for (let i = 0; i < bytes.length; i += 0x8000) binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(binary);
}

// Downloads the PDF the person is reading (with their own login, so journal papers they
// can open are included) and sends it to the backend.
async function capturePdf(url, title, force = false) {
  if (!force && !(await capturing())) return;
  pdfsSent.add(url);
  let entry = { url, title: title || url, at: Date.now() };
  try {
    const response = await fetch(url, { credentials: "include" });
    const type = response.headers.get("content-type") || "";
    if (!url.startsWith("file:") && !type.includes("pdf")) throw new Error("not a PDF");
    const data = await response.arrayBuffer();
    if (data.byteLength > MAX_PDF_BYTES) throw new Error("PDF is larger than 25 MB");
    const result = await post("capture-pdf", { url, title: title || "", data: toBase64(data) });
    if (result.ok && result.already_captured) entry.status = "already";
    else if (result.ok) entry = { ...entry, status: "saved", passages: result.passages };
    else entry = { ...entry, status: "skipped", reason: result.reason };
  } catch (error) {
    const offline = String(error).includes("Failed to fetch") && url.startsWith("file:");
    entry = { ...entry, status: "skipped", reason: offline ? "allow access to file URLs in Chrome's extension settings" : String(error.message || error) };
  }
  console.log("[Referee] PDF capture:", entry);
  await logCapture(entry);
  return entry;
}

// Forget one page or PDF, on the server and in the saved pages list.
async function forgetOne(url) {
  try {
    await fetch(`${SERVER}/sources?url=${encodeURIComponent(url)}`, { method: "DELETE", headers: HEADERS });
  } catch {
    // Server down: the list still drops it; the server copy goes next time it's forgotten.
  }
  const { captures = [] } = await chrome.storage.local.get("captures");
  await chrome.storage.local.set({ captures: captures.filter((c) => c.url !== url) });
  pdfsSent.delete(url);
  return { ok: true };
}

// Reading older than the chosen number of days is forgotten automatically (checked daily).


// Forget everything captured, on the server and in the saved pages list.
// "Save for later": keep the page in the current project permanently, capturing it first if
// it wasn't captured (e.g. outside a Focus or writing session).
async function saveForLater(tab) {
  if (!tab?.url || isSkipped(tab.url)) return { ok: false, reason: "Referee never saves this kind of page." };
  try {
    const stored = await fetch(`${SERVER}/sources`, { headers: HEADERS }).then((r) => r.json());
    if (!stored.some((s) => s.url === tab.url)) {
      let entry;
      if (YOUTUBE_VIDEO.test(tab.url)) entry = await captureVideo(tab.url, tab.title, true);
      else if (PDF_URL.test(tab.url)) entry = await capturePdf(tab.url, tab.title, true);
      else {
        const page = await chrome.tabs.sendMessage(tab.id, { type: "capture-now" }).catch(() => null);
        if (!page) return { ok: false, reason: "Reload the page and try again." };
        if (page.error) return { ok: false, reason: page.error };
        entry = await capture(page);
      }
      if (entry.status !== "saved" && entry.status !== "already") return { ok: false, reason: entry.reason || "Couldn't read this page." };
    }
    return await post("sources/keep", { url: tab.url });
  } catch {
    return { ok: false, reason: "The Referee server isn't running." };
  }
}

async function forgetEverything() {
  try {
    await post("clear", {});
  } catch {
    // Server down: still clear the list so the popup matches what the person expects.
  }
  await chrome.storage.local.set({ captures: [] });
  return { ok: true };
}

// Research mode: on/off, with an optional timer that switches it off automatically.
// Research mode is one switch, kept by the server, so the popup, Referee's menu bar, its keyboard
// shortcut and macOS Focus modes all turn the same thing on and off.
async function setResearch(on, minutes) {
  const until = on && minutes ? Date.now() + minutes * 60 * 1000 : null;
  try {
    await post("focus", { on });
  } catch { /* server not running: the popup still reflects the choice */ }
  await chrome.storage.local.set({ research: on, focus: on, until });
  await chrome.alarms.clear("research-off");
  if (until) chrome.alarms.create("research-off", { when: until });
}

chrome.alarms.onAlarm.addListener((alarm) => {
  if (alarm.name === "research-off") setResearch(false);
  if (alarm.name === "focus-check") {
    checkFocus();
    syncCaptures();
  }
});

// A macOS Focus can switch research mode on through the server; check every minute so the
// badge shows it.
async function checkFocus() {
  let focus;
  try {
    focus = Boolean((await fetch(`${SERVER}/writing`, { headers: HEADERS }).then((r) => r.json())).focus);
  } catch {
    return;  // server not running: leave things as they are
  }
  const { focus: before, research } = await chrome.storage.local.get(["focus", "research"]);
  if (focus !== Boolean(before) || focus !== Boolean(research)) {
    // Follow the server: switched off by the shortcut or menu bar means off here too.
    await chrome.storage.local.set({ focus, research: focus, ...(focus ? {} : { until: null }) });
    if (!focus) await chrome.alarms.clear("research-off");
  }
}

chrome.alarms.create("focus-check", { periodInMinutes: 1 });

// Temporary reading expires on the server. Drop expired or forgotten pages from the capture
// log too, so an open tab showing one of them can capture it again.
async function syncCaptures() {
  let stored;
  try {
    stored = await fetch(`${SERVER}/sources`, { headers: HEADERS }).then((r) => r.json());
  } catch {
    return;  // server not running: leave the log alone
  }
  if (!Array.isArray(stored)) return;
  const urls = new Set(stored.map((s) => s.url));
  const { captures = [] } = await chrome.storage.local.get("captures");
  const kept = captures.filter((c) => urls.has(c.url) || (c.status !== "saved" && c.status !== "already"));
  if (kept.length !== captures.length) await chrome.storage.local.set({ captures: kept });
}

// While research mode is on (by hand or by a Focus), the badge shows how many pages have been saved.
async function updateBadge() {
  const { research: manual, focus, captures = [] } = await chrome.storage.local.get(["research", "focus", "captures"]);
  const research = manual || focus;
  const saved = captures.filter((c) => c.status === "saved").length;
  await chrome.action.setBadgeBackgroundColor({ color: "#111111" });
  await chrome.action.setBadgeText({ text: research ? String(saved || "ON") : "" });
}

chrome.storage.onChanged.addListener((changes, area) => {
  if (area === "local" && (changes.research || changes.focus || changes.captures)) updateBadge();
});
chrome.runtime.onStartup.addListener(updateBadge);
chrome.runtime.onInstalled.addListener(updateBadge);
