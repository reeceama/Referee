// Talking to Referee on this Mac: the same server the app uses, at localhost, so nothing goes
// online. Referee has to be open.

const SERVER = "http://localhost:8000";

export async function referee<T>(path: string, body?: unknown): Promise<T> {
  let response: Response;
  try {
    response = await fetch(`${SERVER}/${path}`, {
      method: body === undefined ? "GET" : "POST",
      headers: { "X-Referee": "1", "Content-Type": "application/json" },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
  } catch {
    throw new Error("Referee isn't running. Open it, then try again.");
  }
  if (!response.ok) throw new Error(`Referee answered ${response.status}.`);
  return (await response.json()) as T;
}

export async function currentProject(): Promise<string> {
  const settings = await referee<{ project?: string }>("settings");
  return settings.project ?? "";
}

/** Where a source opens: at its page, in the browser (Referee's extension switches to it if open). */
export function sourceLink(url: string, page?: number | null): string {
  return `${SERVER}/open?url=${encodeURIComponent(url)}${page ? `&page=${page}` : ""}`;
}

export function today(): string {
  return new Date().toISOString().slice(0, 10);
}

// Raycast can't typeset LaTeX, so the $maths$ in notes is written with Unicode instead:
// "$\dim V = n$" -> "dim V = n", "$v_1, \dots, v_n \in \mathbb{R}^n$" -> "v₁, …, vₙ ∈ ℝⁿ".
const SUB: Record<string, string> = Object.fromEntries([..."0123456789aeijklmnoprstuvx+-=()"].map((c, i) => [c, [..."₀₁₂₃₄₅₆₇₈₉ₐₑᵢⱼₖₗₘₙₒₚᵣₛₜᵤᵥₓ₊₋₌₍₎"][i]]));
const SUP: Record<string, string> = Object.fromEntries([..."0123456789nmkT+-=()i"].map((c, i) => [c, [..."⁰¹²³⁴⁵⁶⁷⁸⁹ⁿᵐᵏᵀ⁺⁻⁼⁽⁾ⁱ"][i]]));
const SYMBOLS: [string, string][] = [
  ["\\cdots", "⋯"], ["\\ldots", "…"], ["\\dots", "…"], ["\\in", "∈"], ["\\notin", "∉"], ["\\subseteq", "⊆"],
  ["\\subset", "⊂"], ["\\cup", "∪"], ["\\cap", "∩"], ["\\emptyset", "∅"], ["\\leq", "≤"], ["\\le", "≤"],
  ["\\geq", "≥"], ["\\ge", "≥"], ["\\neq", "≠"], ["\\ne", "≠"], ["\\approx", "≈"], ["\\to", "→"], ["\\mapsto", "↦"],
  ["\\Rightarrow", "⇒"], ["\\iff", "⇔"], ["\\implies", "⇒"], ["\\forall", "∀"], ["\\exists", "∃"],
  ["\\infty", "∞"], ["\\sum", "Σ"], ["\\prod", "Π"], ["\\times", "×"], ["\\cdot", "·"], ["\\pm", "±"],
  ["\\mid", "|"], ["\\{", "{"], ["\\}", "}"], ["\\langle", "⟨"], ["\\rangle", "⟩"], ["\\circ", "∘"], ["\\oplus", "⊕"],
  ["\\alpha", "α"], ["\\beta", "β"], ["\\gamma", "γ"], ["\\delta", "δ"], ["\\epsilon", "ε"], ["\\varepsilon", "ε"],
  ["\\lambda", "λ"], ["\\mu", "μ"], ["\\pi", "π"], ["\\sigma", "σ"], ["\\theta", "θ"], ["\\phi", "φ"], ["\\omega", "ω"],
  ["\\Lambda", "Λ"], ["\\Sigma", "Σ"], ["\\Omega", "Ω"], ["\\quad", " "], ["\\,", " "], ["\;", " "],
];
const BLACKBOARD: Record<string, string> = { R: "ℝ", C: "ℂ", Q: "ℚ", Z: "ℤ", N: "ℕ", F: "𝔽" };

function plain(tex: string): string {
  let t = tex;
  t = t.replace(/\\mathbb\s*\{?([A-Z])\}?/g, (_, c) => BLACKBOARD[c] ?? c);
  t = t.replace(/\\(?:mathrm|operatorname|text|mathbf|boldsymbol|mathit)\s*\{([^}]*)\}/g, "$1");
  for (const [latex, char] of SYMBOLS) t = t.split(latex).join(char);
  t = t.replace(/\\(dim|ker|rank|span|Span|det|tr|im|Im|max|min|log|ln|sin|cos|exp)\b/g, "$1");
  const script = (map: Record<string, string>) => (s: string) => [...s].every((c) => map[c]) ? [...s].map((c) => map[c]).join("") : null;
  t = t.replace(/_\{([^}]*)\}|_(\w)/g, (m, a, b) => script(SUB)(a ?? b) ?? `_${a ?? b}`);
  t = t.replace(/\^\{([^}]*)\}|\^(\w)/g, (m, a, b) => script(SUP)(a ?? b) ?? `^${a ?? b}`);
  return t.replace(/\\/g, "").replace(/\s{2,}/g, " ");
}

export function plainMaths(markdown: string): string {
  return markdown.replace(/\$\$([^$]+)\$\$/g, (_, m) => plain(m)).replace(/\$([^$\n]+)\$/g, (_, m) => plain(m));
}
