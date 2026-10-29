// Referee in Overleaf: checks each finished sentence of the open file against your reading, as the
// Word helper does in Word, and lists what it finds in a small panel. Overleaf's text is never
// edited; supporting sources come with a \cite{} to copy instead.
//
// For a sentence that already cites something, it says whether the cited paper is the one your
// reading says backs it up. Theorems and definitions that cite a paper are compared with the
// paper's own statement, and notation problems are listed (checked here, without AI). With a code
// folder chosen in Referee's settings, uncited libraries and figures that don't match the latest
// results are listed too.

(() => {
  const PAUSE = 3000;            // ms after the last change before checking
  const project = location.pathname.split("/")[2] || "overleaf";
  const memory = `overleaf:${project}`;
  let results = {};              // sentence -> {keys, result}
  let compared = {};             // statement -> {keys, result}
  let ignoredNotation = [];      // notation warnings marked Ignore, without their line numbers
  let code = null;               // the code folder check: uncited libraries, stale figures
  let lines = {};                // sentence or statement -> line, for jumping to it
  let keysByUrl = {};
  let namesByUrl = {};   // names the person gave sources, shown instead of their titles
  let timer = null;
  let running = false;
  let latest = "";

  // After the extension is reloaded, this copy of the script is left behind in open tabs and can no
  // longer reach Referee. It stops quietly; refreshing the tab loads the new copy.
  const alive = () => Boolean(globalThis.chrome?.runtime?.id);

  const ask = (message) => new Promise((resolve) => {
    if (!alive()) { resolve(null); return; }
    try { chrome.runtime.sendMessage(message, (reply) => resolve(chrome.runtime.lastError ? null : reply)); }
    catch { resolve(null); } // the extension was reloaded: this page's script is stale
  });


  window.addEventListener("message", (event) => {
    if (event.source !== window || event.data?.referee !== "overleaf" || !alive()) return;
    latest = event.data.text;
    clearTimeout(timer);
    timer = setTimeout(checkAll, PAUSE);
  });

  let library = "";
  let autoCite = false;          // insert supported citations without asking (off unless switched on)
  const tried = new Set();       // sentences auto-cite has already handled
  let insertedAny = false;

  // Asks page.js to insert a citation, and waits for how it went ("ok", "editing", ...).
  let nextId = 0;
  function insertCite(sentence, key, auto) {
    const id = ++nextId;
    return new Promise((resolve) => {
      const listen = (event) => {
        if (event.source !== window || event.data?.referee !== "overleaf-inserted" || event.data.id !== id) return;
        window.removeEventListener("message", listen);
        if (event.data.outcome === "ok") insertedAny = true;
        resolve(event.data.outcome);
      };
      window.addEventListener("message", listen);
      window.postMessage({ referee: "overleaf-insert", id, line: lines[sentence], sentence, key, auto }, location.origin);
      setTimeout(() => { window.removeEventListener("message", listen); resolve("no answer"); }, 3000);
    });
  }

  // Auto-cite: supported sentences without a citation get one, except the sentence being edited.
  async function autoInsert() {
    if (!autoCite) return;
    for (const [sentence, { keys, result }] of Object.entries(results)) {
      const key = keysByUrl[result.source?.url];
      if (tried.has(sentence) || !result.match || result.label !== "supports" || keys.length || !key) continue;
      const outcome = await insertCite(sentence, key, true);
      if (outcome !== "editing") tried.add(sentence);  // the sentence being edited is tried again later
    }
  }              // the saved sources last time, to notice new or re-read ones

  async function loadKeys() {
    const settings = await ask({ type: "get", path: "settings" });  // Auto-cite is set in Referee's Settings
    autoCite = Boolean(settings?.overleaf_auto_cite);
    const sources = await ask({ type: "get", path: "sources" });
    if (!Array.isArray(sources)) return;
    keysByUrl = Object.fromEntries(sources.map((s) => [s.url, s.cite_key]));
    namesByUrl = Object.fromEntries(sources.filter((s) => s.name).map((s) => [s.url, s.name]));
    // The library changed: sentences with no support yet, and comparisons, are worth another look.
    const now = sources.map((s) => `${s.url}:${s.passages}:${s.text_from || ""}`).sort().join("|");
    if (library && now !== library) {
      for (const [sentence, { result }] of Object.entries(results)) if (!result.match) delete results[sentence];
      compared = {};
    }
    library = now;
  }

  let previous = "";              // the text last checked, to tell an edit from opening another file

  function sameFile(before, after) {
    const lines = (text) => new Set(text.split("\n").map((l) => l.trim()).filter((l) => l.length > 3));
    const a = lines(before), b = lines(after);
    return a.size > 0 && [...a].filter((l) => b.has(l)).length >= a.size / 2;
  }

  // A reference file (refs.bib) open in the editor: its entries aren't writing to check.
  const isBib = (text) => !/\\begin\{document\}|\\section|\\documentclass/.test(text) && /^\s*@\w+\s*\{/m.test(text);

  async function checkAll() {
    if (running) { timer = setTimeout(checkAll, PAUSE); return; }
    if (isBib(latest)) return;
    running = true;
    code = await ask({ type: "code", body: { text: latest } });  // no AI: quick, so run every time
    const found = Latex.sentences(latest);
    const stated_ = Latex.statements(latest);
    lines = Object.fromEntries(stated_.map((s) => [s.statement, s.line]));
    for (const { sentence } of found) lines[sentence] ??= lineOf(sentence);
    await loadKeys();
    // The sentences in the order written, so Evidence lists them that way.
    ask({ type: "claims/order", body: { document: `${document.title.replace(/ - Overleaf.*$/, "")} (Overleaf)`, sentences: found.map((f) => f.sentence) } });
    const fresh = found.filter(({ sentence }) => !results[sentence]);
    const unchecked = stated_.filter((s) => !compared[s.statement] || compared[s.statement].keys.join() !== s.keys.join());
    for (const { kind, label, statement, keys } of unchecked) {
      const result = await ask({ type: "statement", body: { statement, kind, keys, label } });
      if (!result || result.error) break;
      compared[statement] = { keys, kind, label, result };
      render(found);
    }
    const stated = new Set(stated_.map((s) => s.statement));
    for (const statement of Object.keys(compared)) if (!stated.has(statement)) delete compared[statement];
    for (const { sentence, keys } of fresh) {
      const result = await ask({ type: "check", body: { sentence, document: `${document.title.replace(/ - Overleaf.*$/, "")} (Overleaf)` } });
      if (!result || result.error) break;  // server not running: try again after the next change
      results[sentence] = { keys, result };
      render(found);
    }
    // Forget sentences that are no longer in the file, so the panel matches what's written.
    const present = new Set(found.map((f) => f.sentence));
    const removed = Object.keys(results).filter((sentence) => !present.has(sentence));
    // Mostly the same lines as last time: this file was edited, so the missing sentences were
    // reworded or deleted, and leave the reports. Mostly different: another file was opened.
    if (removed.length && sameFile(previous, latest)) await ask({ type: "claims/current", body: { removed } });
    previous = latest;
    for (const sentence of removed) delete results[sentence];
    for (const { sentence, keys } of found) if (results[sentence]) results[sentence].keys = keys;
    if (alive()) chrome.storage.local.set({ [memory]: { results, compared, library, ignoredNotation } }).catch(() => {});
    running = false;
    render(found);
    await autoInsert();
  }

  // The line a sentence starts on, found from its first few words (the parsed text loses positions).
  function lineOf(sentence) {
    const start = sentence.split(/\s+/).slice(0, 4).join(" ");
    const at = latest.replace(/\s+/g, " ").indexOf(start);
    if (at < 0) return null;
    let seen = 0;
    for (const [i, line] of latest.split("\n").entries()) {
      seen += line.replace(/\s+/g, " ").length + 1;
      if (seen > at) return i + 1;
    }
    return null;
  }

  const KINDS = { missing_condition: "Missing condition", extra_condition: "Extra condition", different_conclusion: "Different conclusion", other: "Difference" };

  // What a compared theorem or definition needs telling: [kind, message, key].
  function comparison({ keys, kind, label, result }) {
    const name = label || kind;
    if (result.reason === "not_saved") return [["warn", `Can't compare: ${keys.join(", ")} isn't saved in Referee. Save the paper to check your ${kind} against it.`]];
    if (result.reason === "theorems_off") return [];   // turned off in Referee's Settings: nothing to say
    if (result.reason === "no_theorem_model" || result.reason === "local_model") return [["quote", `Not compared: comparing ${kind}s with papers needs Claude or ChatGPT connected in Referee's Settings → Keys. Models on your computer aren't careful enough for this yet.`]];
    if (result.reason === "no_api_key") return [["warn", "Add your Claude or ChatGPT key in Referee's Settings → Keys to compare statements with papers."]];
    if (!result.found) return [["warn", `Couldn't find this ${kind} in ${title(result.source)}. Check you're citing the right paper, or that the saved copy includes it.`]];
    // From a page with no reading note: a nudge to check it's been read, not an error.
    const unnoted = result.noted === false
      ? [["quote", `Not in your notes${result.page ? `: page ${result.page} of ${title(result.source)}` : ""}.`]]
      : [];
    // Checked by the model on this computer: likelier to miss a small difference, so worth a look.
    const local = result.local ? [["quote", "Compared by the model on your computer: check the wording against the paper too."]] : [];
    if (!result.differences?.length) return [["good", `Matches ${title(result.source)}.`], ...local, ...unnoted];
    return result.differences.map((d) => [d.kind === "extra_condition" ? "warn" : "bad", `${KINDS[d.kind] || "Difference"}: ${d.detail}`])
      .concat([["quote", `The paper (${name}${result.page ? `, p. ${result.page}` : ""}): ${result.quote}`]], local, unnoted);
  }

  const title = (source) => (namesByUrl[source?.url] || source?.title || source?.url || "a source").replace(/\s+[-|–—]\s+[^-|–—]+$/, "");

  // What a checked sentence needs telling, if anything: [kind, message, key to copy].
  function findings(keys, result) {
    const out = [];
    if (!result.match) {
      if (result.needs_source && !keys.length) {
        const closest = (result.closest || []).map(title).join("; ");
        out.push(["warn", `Reads like a claim that needs a citation, but nothing you've read supports it.${closest ? ` Closest: ${closest}.` : ""}`, null, result.search]);
      }
      return out;
    }
    const source = result.source || {};
    const key = keysByUrl[source.url];
    if (source.retracted) out.push(["bad", `${title(source)} has been retracted.`]);
    if (result.label === "contradicts") out.push(["bad", `Your source says otherwise: “${result.quote}” (${title(source)})`]);
    if (result.label === "supports") {
      if (!keys.length) out.push(["good", `Supported by ${title(source)}. Cite it:`, key, null, null, true]);
      else if (key && !keys.includes(key)) out.push(["warn", `You cite ${keys.join(", ")}, but the reading that supports this is ${title(source)}.`, key]);
      else out.push(["good", `Supported by ${title(source)}${keys.length ? ", which you cite" : ""}.`]);
      if (result.noted === false) out.push(["quote", `Not in your notes${result.page ? `: page ${result.page} of ${title(source)}` : ""}.`]);
    }
    if (result.misquote) out.push(["warn", `This quotation doesn't match the source. It says: “${result.quote}”`]);
    if (result.too_close) out.push(["warn", "Very close to the source's wording. Consider quoting or rephrasing."]);
    for (const figure of result.wrong_numbers || []) out.push(["warn", `“${figure}” doesn't appear in the source.`]);
    if (result.together_with) out.push(["warn", `Combines two sources: also cite ${title(result.together_with.source)}.`, keysByUrl[result.together_with.source?.url]]);
    if (result.mixed) out.push(["warn", `Mixed evidence: ${title(result.mixed)} points the other way.`]);
    return out;
  }

  // The panel, in a shadow root so Overleaf's styles and Referee's can't affect each other.
  const host = document.createElement("div");
  const shadow = host.attachShadow({ mode: "closed" });
  shadow.innerHTML = `<style>
    .box { color-scheme: light dark; position: fixed; right: 16px; bottom: 16px; z-index: 2147483647; width: 340px; max-height: 50vh; display: flex; flex-direction: column;
      font: 13px -apple-system, system-ui, sans-serif; color: #1d1d1f; background: #fff; border-radius: 10px; box-shadow: 0 4px 20px rgba(0,0,0,.2); }
    header { display: flex; justify-content: space-between; align-items: center; padding: 8px 12px; font-weight: 600; cursor: pointer; }
    .hint { padding: 0 12px 8px; font-size: 12px; color: #8e8e93; }
    .closed .hint { display: none; }
    .list { overflow-y: auto; padding: 0 12px 10px; }
    .closed .list { display: none; }
    .item { padding: 8px 0; border-top: 1px solid #eee; }
    .sentence { color: #6e6e73; font-size: 12px; margin-bottom: 4px; }
    .note { padding-left: 8px; border-left: 3px solid; margin-top: 4px; }
    h3 { font-size: 11px; text-transform: uppercase; letter-spacing: .04em; color: #8e8e93; margin: 10px 0 2px; }
    .jump { cursor: pointer; } .jump:hover .sentence { text-decoration: underline; }
    .quote { border-color: #8e8e93; color: #6e6e73; font-size: 12px; }
    .good { border-color: #34c759; } .warn { border-color: #ff9f0a; } .bad { border-color: #ff3b30; }
    button, a { font: inherit; font-size: 12px; margin-left: 4px; }
    button.ignore { opacity: 0.7; font-size: 11px; }
    code { font-size: 12px; background: #f2f2f7; padding: 1px 4px; border-radius: 4px; }
    @media (prefers-color-scheme: dark) { .box { background: #2c2c2e; color: #f5f5f7; } .item { border-color: #3a3a3c; } code { background: #3a3a3c; } a { color: #64d2ff; } }
  </style><div class="box closed"><header><span>Referee</span><span class="count"></span></header><div class="hint" hidden>New citations show as “?” until refs.bib has them: export it from Referee's Library and upload it to Overleaf.</div><div class="list"></div></div>`;
  document.documentElement.append(host);
  // KaTeX's styles in the panel, so sentences show their maths typeset.
  Maths.css().then((css) => { const style = document.createElement("style"); style.textContent = css; shadow.prepend(style); });
  const box = shadow.querySelector(".box");
  shadow.querySelector("header").addEventListener("click", (event) => {
    if (!event.target.closest(".auto")) box.classList.toggle("closed");
  });


  function heading(text) {
    const h = document.createElement("h3");
    h.textContent = text;
    return h;
  }

  function render(found) {
    const order = found ? found.map((f) => f.sentence) : Object.keys(results);
    // Sentences next to each other resting on the same numbered statement, on the same page of the same
    // source, count as one claim, as in Referee's Evidence report.
    const claims = [];
    let previous = null;
    for (const s of order.filter((s) => results[s])) {
      const r = results[s].result;
      const same = r.match && r.statement && previous && previous.r.statement === r.statement
        && previous.r.source?.url === r.source?.url && previous.r.page === r.page;
      const notes = findings(results[s].keys, r);
      if (same) {
        const group = claims[claims.length - 1];
        group[0] = `${group[0]} ${s}`;
        for (const note of notes) if (!group[1].some((n) => n[0] === note[0] && n[1] === note[1])) group[1].push(note);
        group[4].push(s);
      } else if (notes.length) {
        claims.push([s, notes, lines[s], undefined, [s]]);
      }
      previous = r.match ? { r } : null;
    }
    const theorems = Object.entries(compared).map(([s, c]) => [s, comparison(c)]);
    // A warning is known by its words without line numbers, so Ignore holds as lines move.
    const notationKey = (message) => message.replace(/\bline \d+/gi, "line");
    const notation = latest ? Latex.notation(latest).filter((n) => !ignoredNotation.includes(notationKey(n.message)))
      .map((n) => [`Line ${n.line}`, [["warn", n.message]], n.line, notationKey(n.message)]) : [];
    const programming = !code?.folder ? [] : [
      ...(code.software || []).map((s) => [`${s.name} (used in ${s.file})`, [["warn", `Your code uses ${s.name}, which asks to be cited, but your writing doesn't cite it. Add its BibTeX to your .bib file, then cite it with`, s.key, null, s.bibtex]]]),
      ...(code.numbers || []).map((n) => [`Line ${n.line}: ${n.wrote}`, [["warn", `${n.wrote} isn't in your results. The closest is ${n.closest} in ${n.file} (updated ${n.modified}). Re-run since you wrote it?`]], n.line]),
    ];
    const all = [...theorems, ...claims, ...notation, ...programming];
    const problems = all.filter(([, f]) => f.some(([kind]) => kind === "warn" || kind === "bad")).length;
    shadow.querySelector(".hint").hidden = !insertedAny;
    // After the extension is updated or reloaded, this page's panel can't reach it until the page reloads.
    shadow.querySelector(".count").textContent = !alive() ? "reload this page"
      : running ? "checking…" : all.length ? `${problems} to look at, ${all.length - problems} fine` : "nothing yet";
    const list = shadow.querySelector(".list");
    const section = (name, items) => (items.length ? [heading(name), ...items.map(item)] : []);
    list.replaceChildren(...section("Theorems and definitions", theorems), ...section("Claims", claims), ...section("Notation", notation), ...section("Code", programming));
  }

  function item([sentence, notes, line, notationKey, parts]) {
    {
      const item = document.createElement("div");
      item.className = "item";
      const at = line ?? lines[sentence];
      if (at) {
        item.classList.add("jump");
        item.title = `Go to line ${at}`;
        item.addEventListener("click", (event) => {
          if (event.target.closest("button, a")) return;
          window.postMessage({ referee: "overleaf-goto", line: at }, location.origin);
        });
      }
      const quoted = document.createElement("div");
      quoted.className = "sentence";
      Maths.fill(quoted, Maths.shorten(sentence));
      item.append(quoted);
      // A checked sentence that isn't a claim (part of a question, a hypothesis): the person says so,
      // and Referee drops it here and in Evidence, and doesn't check it again.
      if (notationKey) {
        const ignore = document.createElement("button");
        ignore.className = "ignore";
        ignore.textContent = "Ignore";
        ignore.title = "Stop showing this notation warning in this document";
        ignore.addEventListener("click", (event) => {
          event.stopPropagation();
          ignoredNotation.push(notationKey);
          chrome.storage.local.set({ [memory]: { results, compared, library, ignoredNotation } });
          render();
        });
        quoted.append(" ", ignore);
      }
      if (results[sentence] || parts?.length > 1) {
        const ignore = document.createElement("button");
        ignore.className = "ignore";
        ignore.textContent = "Ignore";
        ignore.title = "Stop checking this sentence";
        ignore.addEventListener("click", async () => {
          for (const one of parts || [sentence]) {
            await chrome.runtime.sendMessage({ type: "claims/ignore", body: { sentence: one } });
            delete results[one];
          }
          chrome.storage.local.set({ [memory]: { results, compared, library, ignoredNotation } });
          render();
        });
        quoted.append(" ", ignore);
      }
      for (const [kind, message, key, search, bibtex, insertable] of notes) {
        const note = document.createElement("div");
        note.className = `note ${kind}`;
        Maths.fill(note, message);
        if (key) {
          const cite = `\\cite{${key}}`;
          const code = document.createElement("code");
          code.textContent = cite;
          const copy = document.createElement("button");
          copy.textContent = "Copy";
          copy.addEventListener("click", () => navigator.clipboard.writeText(cite).then(() => { copy.textContent = "Copied"; }));
          note.append(" ", code, copy);
          if (insertable) {
            const add = document.createElement("button");
            add.textContent = "Insert";
            add.title = "Add it to the end of this sentence";
            add.addEventListener("click", async () => {
              const outcome = await insertCite(sentence, key, false);
              add.textContent = outcome === "ok" ? "Inserted" : outcome === "already cited" ? "Already cited" : "Couldn't find it";
              add.disabled = true;
            });
            note.append(add);
          }
        }
        if (bibtex) {
          const copy = document.createElement("button");
          copy.textContent = "Copy BibTeX";
          copy.addEventListener("click", () => navigator.clipboard.writeText(bibtex).then(() => { copy.textContent = "Copied"; }));
          note.append(copy);
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
  }

  // Earlier results for this project, so reopening it doesn't pay for checks again.
  chrome.storage.local.get(memory, (saved) => {
    ({ results = {}, compared = {}, library = "", ignoredNotation = [] } = saved[memory]?.results ? saved[memory] : { results: saved[memory] || {} });
    // Every sentence is checked again on each visit, so the panel matches Referee now: a new source, a
    // new note, or a better match since. Claude's answers are kept by Referee, so unchanged sentences
    // cost no new checks; only the panel's copy is refreshed.
    results = {};
    render();
  });
})();
