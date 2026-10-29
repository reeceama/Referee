// Referee in Google Docs and Notion: checks each sentence of the open document against your
// reading, as the Word helper does in Word, and lists what it finds in a small panel. The
// document is never edited: supported sentences come with their citation, in your style, to copy.
//
// Google Docs draws its text on a canvas, so its page can't be read directly: the document's
// plain-text export is read instead (through the background, with your own Google sign-in).
// Notion's text is on the page, so it's read from there. Either way, only while the tab is open
// and in view, every few seconds, and checked when it changes.

(() => {
  const EVERY = 8000;              // ms between looks at the document
  const notion = /(^|\.)notion\.(so|site)$/.test(location.hostname);
  const id = notion ? location.pathname.split("-").pop() || "page" : location.pathname.split("/")[3] || "doc";
  const memory = `${notion ? "notion" : "gdocs"}:${id}`;

  // The document's text: Notion's page body, one block per line, or Google Docs' export.
  async function read() {
    if (!notion) return ask({ type: "gdoc" });
    const page = document.querySelector(".notion-page-content");
    if (!page) return null;
    return [...page.querySelectorAll("[data-block-id]")]
      .filter((block) => !block.querySelector("[data-block-id]"))      // innermost blocks only
      .filter((block) => !block.closest(".notion-code-block, .notion-equation-block"))
      .map((block) => block.innerText.trim()).filter(Boolean).join("\n");
  }
  let results = {};                // sentence -> result
  let namesByUrl = {};
  let latest = "";
  let running = false;

  const alive = () => Boolean(globalThis.chrome?.runtime?.id);
  const ask = (message) => new Promise((resolve) => {
    if (!alive()) { resolve(null); return; }
    try { chrome.runtime.sendMessage(message, (reply) => resolve(chrome.runtime.lastError ? null : reply)); }
    catch { resolve(null); }
  });

  const ABBREVIATIONS = ["e.g.", "i.e.", "et al.", "cf.", "Fig.", "Eq.", "vs.", "approx.", "resp.", "p.", "pp.", "No.", "Dr.", "Prof."];

  // The document's sentences: headings, list markers and very short lines left out.
  function sentences(text) {
    const found = [];
    for (const paragraph of text.replace(/\r/g, "").split(/\n+/)) {
      let flat = paragraph.replace(/^\s*([*•◦▪-]|\d+[.)])\s+/, "").replace(/\s+/g, " ").trim();
      if (flat.split(" ").length < 5 || !/[.!?]["”)]?$/.test(flat)) continue;  // headings don't end in a full stop
      for (const short of ABBREVIATIONS) flat = flat.split(short).join(short.replace(/\./g, "․"));
      flat = flat.replace(/(\d)\.(\d)/g, "$1․$2");
      for (const part of flat.split(/(?<=[.!?]["”)]?)\s+(?=[A-Z"“(])/)) {
        const sentence = part.replace(/․/g, ".").trim();
        if (sentence.split(" ").length >= 5) found.push(sentence);
      }
    }
    return found;
  }

  const name = () => notion
    ? `${document.title.replace(/^\(\d+\+?\)\s*/, "").replace(/\s*\|\s*Notion$/, "")} (Notion)`
    : `${document.title.replace(/ - Google Docs$/, "")} (Google Docs)`;
  const title = (source) => (namesByUrl[source?.url] || source?.title || source?.url || "a source").replace(/\s+[-|–—]\s+[^-|–—]+$/, "");

  async function look() {
    if (running || document.hidden || !alive()) return;
    const text = await read();
    if (!text || text === latest) return;
    const previous = latest;
    latest = text;
    running = true;
    render();
    const sources = await ask({ type: "get", path: "sources" });
    if (Array.isArray(sources)) namesByUrl = Object.fromEntries(sources.filter((s) => s.name).map((s) => [s.url, s.name]));
    const found = sentences(text);
    ask({ type: "claims/order", body: { document: name(), sentences: found } });   // for Evidence's order
    for (const sentence of found.filter((s) => !results[s])) {
      const result = await ask({ type: "check", body: { sentence, document: name() } });
      if (!result || result.error) break;   // server not running: try again later
      results[sentence] = result;
      render(found);
    }
    // Reworded or deleted sentences leave the panel and the reports.
    const present = new Set(found);
    const removed = Object.keys(results).filter((s) => !present.has(s));
    if (removed.length && previous) await ask({ type: "claims/current", body: { removed } });
    for (const sentence of removed) delete results[sentence];
    if (alive()) chrome.storage.local.set({ [memory]: results }).catch(() => {});
    running = false;
    render(found);
  }

  // What a checked sentence needs telling: [kind, message, citation to copy, search link].
  function findings(result) {
    const out = [];
    if (!result.match) {
      if (result.needs_source) {
        const closest = (result.closest || []).map(title).join("; ");
        out.push(["warn", `Reads like a claim that needs a citation, but nothing you've read supports it.${closest ? ` Closest: ${closest}.` : ""}`, null, result.search]);
      }
      return out;
    }
    const source = result.source || {};
    if (source.retracted) out.push(["bad", `${title(source)} has been retracted.`]);
    if (result.label === "contradicts") out.push(["bad", `Your source says otherwise: “${result.quote}” (${title(source)})`]);
    if (result.label === "supports") {
      out.push(["good", `Supported by ${title(source)}${result.page ? `, p. ${result.page}` : ""}.`, result.cite]);
      if (result.noted === false) out.push(["quote", `Not in your notes${result.page ? `: page ${result.page} of ${title(source)}` : ""}.`]);
    }
    if (result.misquote) out.push(["warn", `This quotation doesn't match the source. It says: “${result.quote}”`]);
    if (result.too_close) out.push(["warn", "Very close to the source's wording. Consider quoting or rephrasing."]);
    for (const figure of result.wrong_numbers || []) out.push(["warn", `“${figure}” doesn't appear in the source.`]);
    if (result.together_with) out.push(["warn", `Combines two sources: also cite ${title(result.together_with.source)}.`]);
    if (result.mixed) out.push(["warn", `Mixed evidence: ${title(result.mixed)} points the other way.`]);
    return out;
  }

  // The panel, in a shadow root so Google's styles and Referee's can't affect each other.
  const host = document.createElement("div");
  const shadow = host.attachShadow({ mode: "closed" });
  shadow.innerHTML = `<style>
    .box { color-scheme: light dark; position: fixed; right: 16px; bottom: 16px; z-index: 2147483647; width: 340px; max-height: 50vh; display: flex; flex-direction: column;
      font: 13px -apple-system, system-ui, sans-serif; color: #1d1d1f; background: #fff; border-radius: 10px; box-shadow: 0 4px 20px rgba(0,0,0,.2); }
    header { display: flex; justify-content: space-between; align-items: center; padding: 8px 12px; font-weight: 600; cursor: pointer; }
    .list { overflow-y: auto; padding: 0 12px 10px; }
    .closed .list { display: none; }
    .item { padding: 8px 0; border-top: 1px solid #eee; }
    .sentence { color: #6e6e73; font-size: 12px; margin-bottom: 4px; }
    .note { padding-left: 8px; border-left: 3px solid; margin-top: 4px; }
    .quote { border-color: #8e8e93; color: #6e6e73; font-size: 12px; }
    .good { border-color: #34c759; } .warn { border-color: #ff9f0a; } .bad { border-color: #ff3b30; }
    button, a { font: inherit; font-size: 12px; margin-left: 4px; }
    code { font-size: 12px; background: #f2f2f7; padding: 1px 4px; border-radius: 4px; }
    @media (prefers-color-scheme: dark) { .box { background: #2c2c2e; color: #f5f5f7; } .item { border-color: #3a3a3c; } code { background: #3a3a3c; } a { color: #64d2ff; } }
  </style><div class="box closed"><header><span>Referee</span><span class="count"></span></header><div class="list"></div></div>`;
  document.documentElement.append(host);
  const box = shadow.querySelector(".box");
  shadow.querySelector("header").addEventListener("click", () => box.classList.toggle("closed"));

  function render(found) {
    const order = found || Object.keys(results);
    const claims = order.filter((s) => results[s]).map((s) => [s, findings(results[s])]).filter(([, f]) => f.length);
    const problems = claims.filter(([, f]) => f.some(([kind]) => kind === "warn" || kind === "bad")).length;
    shadow.querySelector(".count").textContent = running ? "checking…" : claims.length ? `${problems} to look at, ${claims.length - problems} fine` : "nothing yet";
    shadow.querySelector(".list").replaceChildren(...claims.map(item));
  }

  function item([sentence, notes]) {
    const item = document.createElement("div");
    item.className = "item";
    const quoted = document.createElement("div");
    quoted.className = "sentence";
    quoted.textContent = sentence.length > 120 ? `${sentence.slice(0, 117)}…` : sentence;
    // Ignore: not a claim (part of a question, a hypothesis): dropped here and in Evidence, and not checked again.
    const ignore = document.createElement("button");
    ignore.textContent = "Ignore";
    ignore.title = "Stop checking this sentence";
    ignore.style.cssText = "margin-left:6px;font-size:11px;opacity:0.7";
    ignore.addEventListener("click", async () => {
      await chrome.runtime.sendMessage({ type: "claims/ignore", body: { sentence } });
      delete results[sentence];
      chrome.storage.local.set({ [memory]: results }).catch(() => {});
      render();
    });
    quoted.append(ignore);
    item.append(quoted);
    for (const [kind, message, cite, search] of notes) {
      const note = document.createElement("div");
      note.className = `note ${kind}`;
      note.textContent = message;
      if (cite) {
        const code = document.createElement("code");
        code.textContent = cite;
        const copy = document.createElement("button");
        copy.textContent = "Copy";
        copy.addEventListener("click", () => navigator.clipboard.writeText(cite).then(() => { copy.textContent = "Copied"; }));
        note.append(" ", code, copy);
      }
      if (search) {
        const link = document.createElement("a");
        link.href = search; link.target = "_blank"; link.textContent = "Search Scholar";
        note.append(link);
      }
      item.append(note);
    }
    return item;
  }

  // Earlier results for this document, so reopening it doesn't pay for checks again.
  chrome.storage.local.get(memory, (saved) => {
    results = saved[memory] || {};
    render();
    look();
    setInterval(look, EVERY);
  });
})();
