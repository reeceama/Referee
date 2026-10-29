// The prose sentences in a LaTeX file, each with the keys it cites. Maths, proofs, figures and
// commands are left out: Referee checks claims about the literature, not derivations.

const Latex = (() => {
  const SKIPPED = "theorem|lemma|proposition|corollary|conjecture|definition|claim|thm|lem|prop|cor|conj|defn|dfn|equation|align|gather|multline|eqnarray|displaymath|proof|figure|table|tabular|tikzpicture|verbatim|lstlisting|minted|thebibliography";
  const CITE = /\\(?:cite|citep|citet|parencite|textcite|autocite|footcite)\*?(?:\[[^\]]*\]){0,2}\{([^}]*)\}/g;
  const ABBREVIATIONS = /\b(e\.g|i\.e|et al|cf|resp|w\.r\.t|etc|vs|Fig|Thm|Def|Prop|Lem|Cor|Sec|Ch|Eq|pp?|no|vol)\./gi;
  const SENTENCE = /[^.!?]+[.!?]+["”’')\]]*/g;
  const MIN_WORDS = 5;

  const RESULTS = ["theorem", "lemma", "proposition", "corollary", "conjecture", "definition", "claim"];

  // Theorem-like environment names, including ones defined with \newtheorem{thm}{Theorem}.
  function resultNames(text) {
    const names = new Map(RESULTS.map((r) => [r, r]));
    for (const m of text.matchAll(/\\newtheorem\*?\{(\w+)\}(?:\[\w+\])?\{([^}]+)\}/g)) {
      const kind = RESULTS.find((r) => m[2].toLowerCase().startsWith(r));
      if (kind) names.set(m[1], kind);
    }
    return names;
  }

  // Comments blanked to spaces, so positions (and line numbers) stay the same.
  const uncommented = (text) => text.replace(/(^|[^\\])(%.*)$/gm, (_, before, comment) => before + " ".repeat(comment.length));
  const lineAt = (text, index) => text.slice(0, index).split("\n").length;

  // Theorems, lemmas and definitions that cite a paper: [{kind, label, statement, keys, line}].
  function statements(text) {
    const clean = uncommented(text);
    const names = resultNames(clean);
    const found = [];
    const pattern = new RegExp(`\\\\begin\\{(${[...names.keys()].join("|")})\\*?\\}(\\[(?:[^\\[\\]]|\\[[^\\]]*\\])*\\])?([\\s\\S]*?)\\\\end\\{\\1\\*?\\}`, "g");
    for (const m of clean.matchAll(pattern)) {
      const optional = (m[2] || "").slice(1, -1);
      const keys = [...(optional + m[3]).matchAll(CITE)].flatMap((c) => c[1].split(",").map((k) => k.trim())).filter(Boolean);
      if (!keys.length) continue; // the person's own result: nothing to compare with
      // "[{\cite[Conjecture 1]{key}}]" or "[Bobrowski and Skraba \cite{key}]": the label without the key.
      const label = optional.replace(/\\\w+\*?((?:\[[^\]]*\]){0,2})\{[^}]*\}/g, (_, notes) => ` ${notes.replace(/[[\]]/g, " ")} `)
        .replace(/[{}]/g, "").replace(/\s+/g, " ").replace(/^[\s,;()]+|[\s,;()]+$/g, "");
      const statement = m[3].replace(CITE, "").replace(/\\label\{[^}]*\}/g, "").replace(/\s+/g, " ").trim();
      found.push({ kind: names.get(m[1]), label, statement, keys, line: lineAt(text, m.index) });
    }
    return found;
  }

  // Notation problems, found without AI: [{line, message}].
  function notation(text) {
    const clean = uncommented(text);
    const issues = [];
    const labels = new Map();
    for (const m of clean.matchAll(/\\label\{([^}]+)\}/g)) {
      if (labels.has(m[1])) issues.push({ line: lineAt(text, m.index), message: `The label “${m[1]}” is used twice, so references to it may point to the wrong place.` });
      else labels.set(m[1], m.index);
    }
    // Labels in other files of the project aren't visible here, so only check single-file documents.
    if (!/\\(?:input|include|subfile)\{/.test(clean)) {
      for (const m of clean.matchAll(/\\(?:eq|c|C|auto|page)?ref\{([^}]+)\}/g)) {
        for (const label of m[1].split(",").map((l) => l.trim())) {
          if (!labels.has(label)) issues.push({ line: lineAt(text, m.index), message: `\\ref{${label}} points to a label that doesn't exist, so it will show as “??”.` });
        }
      }
    }
    // A symbol introduced ("Let $X$ be", "denote by $X$", "define $X :=") after it's already been used.
    const hidden = clean.replace(new RegExp(`\\\\begin\\{(proof|${[...resultNames(clean).keys()].join("|")})\\*?\\}[\\s\\S]*?\\\\end\\{\\1\\*?\\}`, "g"), (m) => " ".repeat(m.length));
    const introduced = new Map();
    for (const m of hidden.matchAll(/\b(?:[Ll]et|denote(?:d)? by|[Dd]efine|[Ww]e write|[Ww]rite)\s+\$([^$]+?)\$/g)) {
      const symbol = m[1].split(/\s*(?:=|:=|\\coloneqq|\\in|\\subset(?:eq)?|\\colon|:|\\to|\\geq?|\\leq?|>|<|,)\s*/)[0].trim();
      if (symbol && symbol.length <= 20 && !introduced.has(symbol)) introduced.set(symbol, m.index);
    }
    const escape = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    for (const [symbol, at] of introduced) {
      const token = new RegExp(`(?<![A-Za-z\\\\])${escape(symbol)}(?![A-Za-z])`);
      for (const m of hidden.slice(0, at).matchAll(/\$([^$]+)\$|\\\(([\s\S]+?)\\\)/g)) {
        if (token.test(m[1] || m[2])) {
          issues.push({ line: lineAt(text, m.index), message: `$${symbol}$ is used here before it's introduced on line ${lineAt(text, at)}.` });
          break;
        }
      }
    }
    // The same symbol introduced again: check it still means the same thing.
    const seen = new Map();
    for (const m of hidden.matchAll(/\b(?:[Ll]et|denote(?:d)? by|[Dd]efine)\s+\$([^$]+?)\$/g)) {
      const symbol = m[1].split(/\s*(?:=|:=|\\coloneqq|\\in|\\subset(?:eq)?|\\colon|:|\\to|\\geq?|\\leq?|>|<|,)\s*/)[0].trim();
      if (!symbol || symbol.length > 20) continue;
      if (seen.has(symbol)) issues.push({ line: lineAt(text, m.index), message: `$${symbol}$ is introduced again here (first on line ${seen.get(symbol)}). Check it means the same thing, or use a different symbol.` });
      else seen.set(symbol, lineAt(text, m.index));
    }

    // Results used without being stated and cited, and steps asserted rather than justified.
    const body = clean.replace(/\\begin\{(equation|align|gather)\*?\}[\s\S]*?\\end\{\1\*?\}/g, (m) => " ".repeat(m.length));
    const VAGUE = /\b(?:from (?:the )?lectures?|(?:a |the )?(?:well[- ]known|standard) (?:theorem|result|fact)|by a (?:theorem|result)|it (?:is|can be) (?:known|shown) that)\b/gi;
    const ASSERTED = /\b(?:clearly|obviously|trivially|it is (?:easy|straightforward) to (?:see|show|check))\b/gi;
    const sentenceAt = (index) => {
      const start = Math.max(body.lastIndexOf(".", index), body.lastIndexOf("\n\n", index));
      const end = body.indexOf(".", index);
      return body.slice(start + 1, end < 0 ? body.length : end);
    };
    const flagged = new Set();  // one warning per sentence
    for (const m of body.matchAll(VAGUE)) {
      const sentence = sentenceAt(m.index);
      if (/\\cite/.test(sentence) || flagged.has(sentence)) continue;
      flagged.add(sentence);
      issues.push({ line: lineAt(text, m.index), message: `“${m[0]}”: state the result precisely, with its hypotheses, and cite where it comes from.` });
    }
    for (const m of body.matchAll(ASSERTED)) {
      issues.push({ line: lineAt(text, m.index), message: `“${m[0]}”: a marker may want this step justified rather than asserted.` });
    }

    // An "if and only if" result whose proof never mentions the other direction.
    const names = [...resultNames(clean).keys()].join("|");
    const iff = new RegExp(`\\\\begin\\{(${names})\\*?\\}[\\s\\S]*?\\\\end\\{\\1\\*?\\}\\s*\\\\begin\\{proof\\}([\\s\\S]*?)\\\\end\\{proof\\}`, "g");
    for (const m of clean.matchAll(iff)) {
      if (!/if and only if|\biff\b|\\iff|\\Leftrightarrow|\\leftrightarrow/.test(m[0].slice(0, m[0].indexOf("\\begin{proof}")))) continue;
      if (/\\Leftarrow|\\impliedby|\\Longleftarrow|[Cc]onversely|converse|other direction|\(\s*\\?(?:Leftarrow|⇐)|both directions/.test(m[2])) continue;
      issues.push({ line: lineAt(text, m.index), message: "This result says “if and only if”, but its proof doesn't seem to show the converse. Prove both directions." });
    }

    return issues.sort((a, b) => a.line - b.line);
  }

  function body(text) {
    const start = text.indexOf("\\begin{document}");
    const end = text.indexOf("\\end{document}");
    return text.slice(start < 0 ? 0 : start + 16, end < 0 ? text.length : end);
  }

  function prose(text) {
    let t = body(text).replace(/(^|[^\\])%.*$/gm, "$1");                       // comments
    t = t.replace(new RegExp(`\\\\begin\\{(${SKIPPED})\\*?\\}[\\s\\S]*?\\\\end\\{\\1\\*?\\}`, "g"), " ");
    // A block quotation (quote or quotation environment) is a quotation, as if in quotation marks: each of
    // its sentences is checked word for word against the source, and none counts as too close to it.
    t = t.replace(/\\begin\{(quote|quotation)\}([\s\S]*?)\\end\{\1\}/g, (_, __, body) =>
      "\n\n" + body.trim().split(/(?<=[.!?])\s+/).map((part) => `"${part.trim()}"`).join(" ") + "\n\n");
    t = t.replace(/\$\$[\s\S]*?\$\$|\\\[[\s\S]*?\\\]/g, " ");                  // display maths
    t = t.replace(/\\(?:part|chapter|(?:sub)*section|paragraph|caption|title|author)\*?(?:\[[^\]]*\])?\{[^}]*\}/g, "\n\n");
    t = t.replace(/\\item\b|\\(?:begin|end)\{[^}]*\}(?:\[[^\]]*\])?/g, "\n\n");
    t = t.replace(/\\(?:label|bibliography|bibliographystyle|usepackage|input|include)\{[^}]*\}/g, " ");
    t = t.replace(/\\(?:eq)?ref\{[^}]*\}/g, "(1)");
    t = t.replace(CITE, (_, keys) => `\u0001${keys}\u0002`);                     // marked, read per sentence
    for (let i = 0; i < 3; i++) t = t.replace(/\\(?:emph|textbf|textit|texttt|underline|text|mbox)\{([^{}]*)\}/g, "$1");
    return t.replace(/~/g, " ").replace(/``|''/g, "\"").replace(/\\\\|\\(?:noindent|maketitle|newpage|clearpage|medskip|bigskip|smallskip)\b/g, " ");
  }

  function sentences(text) {
    const found = [];
    for (const paragraph of prose(text).split(/\n\s*\n/)) {
      const masked = paragraph.replace(/\s+/g, " ").replace(ABBREVIATIONS, (m) => m.replace(/\./g, "․"))
        .replace(/\u0001[^\u0002]*\u0002/g, (m) => m.replace(/\./g, "․"));
      for (const match of masked.match(SENTENCE) || []) {
        const raw = match.replace(/․/g, ".");
        const keys = [...raw.matchAll(/\u0001([^\u0002]*)\u0002/g)].flatMap((m) => m[1].split(",").map((k) => k.trim())).filter(Boolean);
        const sentence = raw.replace(/\s*\u0001[^\u0002]*\u0002/g, "").replace(/\s+([.,;:])/g, "$1").trim();
        if (sentence.split(/\s+/).length >= MIN_WORDS) found.push({ sentence, keys });
      }
    }
    return found;
  }

  return { sentences, statements, notation };
})();

if (typeof module !== "undefined") module.exports = Latex;
