// Typesets the $…$ and \(…\) maths in a sentence with KaTeX (vendor/katex, MIT licence), for the
// Overleaf panel and the library page. Anything KaTeX can't read is left as it was written.
globalThis.Maths = (() => {
  const MATHS = /\$\$([\s\S]+?)\$\$|\$([^$]+?)\$|\\\(([\s\S]+?)\\\)|\\\[([\s\S]+?)\\\]/g;

  // KaTeX's fonts, from the extension: declared on the page itself, since @font-face inside a shadow
  // root is ignored. Once per page.
  function loadFonts() {
    if (document.getElementById("referee-katex-fonts") || !globalThis.chrome?.runtime?.getURL) return;
    fetch(chrome.runtime.getURL("vendor/katex/katex.min.css")).then((r) => r.text()).then((css) => {
      const faces = (css.match(/@font-face\{[^}]*\}/g) || [])
        .map((face) => face.replace(/url\(fonts\//g, `url(${chrome.runtime.getURL("vendor/katex/fonts/")}`))
        .join("\n");
      const style = document.createElement("style");
      style.id = "referee-katex-fonts";
      style.textContent = faces;
      document.head.append(style);
    }).catch(() => {});
  }

  // The rest of KaTeX's styles, for a shadow root (or a page) to include.
  let styles = "";
  async function css() {
    if (!styles && globalThis.chrome?.runtime?.getURL) {
      const text = await fetch(chrome.runtime.getURL("vendor/katex/katex.min.css")).then((r) => r.text()).catch(() => "");
      styles = text.replace(/@font-face\{[^}]*\}/g, "");
    }
    return styles;
  }

  // Shortens a sentence without cutting a piece of maths in half.
  function shorten(text, most = 160) {
    if (text.length <= most) return text;
    let cut = text.slice(0, most);
    if ((cut.match(/(?<!\\)\$/g) || []).length % 2) cut = cut.slice(0, cut.lastIndexOf("$"));
    return `${cut.trimEnd()}…`;
  }

  // Fills an element with the text, its maths typeset.
  function fill(element, text) {
    element.replaceChildren();
    if (!globalThis.katex) { element.textContent = text; return; }
    loadFonts();
    let last = 0;
    for (const match of text.matchAll(MATHS)) {
      if (match.index > last) element.append(text.slice(last, match.index));
      const tex = match[1] ?? match[2] ?? match[3] ?? match[4];
      const span = document.createElement("span");
      try {
        span.innerHTML = katex.renderToString(tex, { throwOnError: true, displayMode: false, output: "html" });
      } catch {
        span.textContent = match[0];
      }
      element.append(span);
      last = match.index + match[0].length;
    }
    if (last < text.length) element.append(text.slice(last));
  }

  return { fill, css, shorten };
})();
