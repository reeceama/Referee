// Runs on every page. While research mode is on, it waits until the page has actually
// been read (open and visible for READ_MS, or text highlighted), then sends it to the
// backend, which keeps it only if it has real article text.

const READ_MS = 20000;      // time a page must be open and visible before it counts as read
const MIN_SELECTION = 20;   // highlighting this many characters also counts as reading

// Anything a person could type into, plus code and embedded pages, is removed before
// the page leaves the tab: only readable content is sent.
const PRIVATE = "input, textarea, select, button, script, noscript, style, iframe, object, embed, template, [contenteditable]";

function readableHtml() {
  const copy = document.documentElement.cloneNode(true);
  copy.querySelectorAll(PRIVATE).forEach((element) => element.remove());
  return copy.outerHTML;
}

// Research mode on, or (automatic mode only) the Word helper reports someone writing.
async function capturing() {
  const { research, mode } = await chrome.storage.local.get(["research", "mode"]);
  if (research) return true;
  if ((mode ?? "auto") !== "auto") return false; // automatic is the default
  return Boolean(await chrome.runtime.sendMessage({ type: "writing" }));
}

// A sign-in form someone can see (a login, banking or account page). Many article pages keep a hidden
// sign-in form in their header (Wiley's has three password boxes); those pages are still read.
function signInShown() {
  return [...document.querySelectorAll('input[type="password"]')].some(
    (box) => box.getClientRects().length > 0 && getComputedStyle(box).visibility !== "hidden"
  );
}

// "Save for later" from the popup: hand over the page now, whether or not capture is on.
chrome.runtime.onMessage.addListener((message, sender, reply) => {
  if (message.type !== "capture-now") return;
  if (isSkipped(location.href) || signInShown()) {
    reply({ error: "Referee never saves this kind of page." });
    return;
  }
  reply({ url: location.href, title: document.title, html: readableHtml() });
});

if (!isSkipped(location.href)) {
  let sent = false;
  let visibleMs = 0;
  let last = Date.now();
  let nextTry = 0; // when research mode is off, re-check every 10s rather than every tick

  async function capture() {
    if (sent || Date.now() < nextTry) return;
    nextTry = Date.now() + 10000;
    if (signInShown()) return; // login, banking and account pages
    if (!(await capturing())) return;
    sent = true;
    clearInterval(timer);
    chrome.runtime.sendMessage(
      { type: "capture", body: { url: location.href, title: document.title, html: readableHtml() } },
      (result) => console.log("[Referee] capture:", result)
    );
  }

  // Count only time the tab is actually visible. Checked once a second; the storage
  // lookup in capturing() happens only when the page qualifies, not every tick.
  function tick() {
    const now = Date.now();
    if (document.visibilityState === "visible") visibleMs += now - last;
    last = now;
    if (visibleMs >= READ_MS) capture().catch(() => {});
  }
  let timer = setInterval(tick, 1000);

  // If this page is forgotten (or all reading is cleared) while the tab is still open, start
  // over, so reading it again captures it again.
  chrome.storage.onChanged.addListener((changes, area) => {
    if (area !== "local" || !changes.captures || !sent) return;
    const still = (changes.captures.newValue || []).some((c) => c.url === location.href);
    if (still) return;
    sent = false;
    visibleMs = 0;
    nextTry = 0;
    timer = setInterval(tick, 1000);
  });

  // Highlighting counts as reading, and what you highlight is kept as a note on the source,
  // only while capture is on (research mode, a Focus, or writing), like the page itself.
  document.addEventListener("mouseup", async () => {
    const selected = String(window.getSelection()).trim();
    if (selected.length < MIN_SELECTION) return;
    capture().catch(() => {});
    if (signInShown() || !(await capturing().catch(() => false))) return;
    chrome.runtime.sendMessage({ type: "highlight", body: { url: location.href, text: selected.slice(0, 1000) } }).catch(() => {});
  });
}
