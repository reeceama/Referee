import SwiftMath
import SwiftUI

/// A note's body, shown formatted: Markdown paragraphs, bullet and numbered lists, headings and
/// quotes, with **bold**, *italic*, `code` and links inside lines, and $maths$ / $$maths$$ set
/// apart in a serif italic. Not every corner of Markdown, just what notes use.
struct MarkdownView: View {

    let text: String
    /// The sources this text is about: a line naming a theorem or definition in them shows its
    /// statement on hover.
    var sources: [String] = []

    private enum Block: Hashable {
        case heading(Int, String)
        case paragraph(String)
        case bullet(String, Int)          // the text and how far it's indented
        case numbered(String, String, Int)
        case quote(String)
        case maths(String)
        case table([[String]])
    }

    /// Each text's blocks, worked out once: the page redraws often, the text rarely changes.
    private static var parsed: [String: [Block]] = [:]

    private var blocks: [Block] {
        if let known = MarkdownView.parsed[text] { return known }
        let found = parse()
        if MarkdownView.parsed.count > 500 { MarkdownView.parsed.removeAll() }
        MarkdownView.parsed[text] = found
        return found
    }

    private func parse() -> [Block] {
        var found: [Block] = []
        var paragraph: [String] = []
        var maths: [String]? = nil
        func flush() {
            // Lines stay lines, as written (a form's "tool and version: …" rows, a poem, an address).
            if !paragraph.isEmpty { found.append(.paragraph(paragraph.joined(separator: "\n"))); paragraph = [] }
        }
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let indent = raw.prefix(while: { $0 == " " || $0 == "\t" }).count / 2
            if var open = maths {                                   // inside $$ … $$
                if line.hasSuffix("$$") { open.append(String(line.dropLast(2))); found.append(.maths(open.joined(separator: "\n"))); maths = nil }
                else { open.append(line); maths = open }
                continue
            }
            if line.hasPrefix("$$") {
                flush()
                let rest = String(line.dropFirst(2))
                if rest.hasSuffix("$$") && rest.count >= 2 { found.append(.maths(String(rest.dropLast(2)))) } else { maths = [rest] }
                continue
            }
            if line.isEmpty { flush(); continue }
            if let level = line.firstIndex(where: { $0 != "#" }).map({ line.distance(from: line.startIndex, to: $0) }),
               level > 0, level <= 4, line.dropFirst(level).hasPrefix(" ") {
                flush(); found.append(.heading(level, String(line.dropFirst(level + 1)))); continue
            }
            if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") {
                flush(); found.append(.bullet(String(line.dropFirst(2)), indent)); continue
            }
            if let dot = line.firstIndex(where: { $0 == "." || $0 == ")" }),
               line[..<dot].allSatisfy(\.isNumber), !line[..<dot].isEmpty, line[line.index(after: dot)...].hasPrefix(" ") {
                flush(); found.append(.numbered(String(line[...dot]), String(line[line.index(dot, offsetBy: 2)...]), indent)); continue
            }
            if line.hasPrefix("> ") { flush(); found.append(.quote(String(line.dropFirst(2)))); continue }
            if line.hasPrefix("|") {
                // A table row: cells between the bars; the |---| line under the header is skipped.
                flush()
                let cells = line.trimmingCharacters(in: CharacterSet(charactersIn: "|")).components(separatedBy: "|")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                if cells.allSatisfy({ !$0.isEmpty && $0.allSatisfy { "-:".contains($0) } }) { continue }
                if case .table(var rows) = found.last { rows.append(cells); found[found.count - 1] = .table(rows) }
                else { found.append(.table([cells])) }
                continue
            }
            paragraph.append(line)
        }
        flush()
        if let open = maths { found.append(.maths(open.joined(separator: "\n"))) }
        return found
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let level, let text):
                    inline(text).font(.system(size: Scaled.s(level == 1 ? 16 : 14), weight: .semibold)).padding(.top, 4)
                case .paragraph(let text):
                    if TeX.needsLayout(text) {
                        // Fractions, roots, sums: drawn by SwiftMath within the line.
                        WrappingRow(spacing: 0, lineSpacing: 4) {
                            ForEach(Array(TeX.tokens(text).enumerated()), id: \.offset) { _, token in
                                if token.maths { MathView(latex: token.text, display: false) }
                                else { inline(token.text) }
                            }
                        }
                    } else {
                        inline(text).statementPreview(text, sources: sources)
                    }
                case .bullet(let text, let indent):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(indent > 0 ? "◦" : "•").foregroundStyle(.secondary)
                        inline(text)
                    }
                    .padding(.leading, CGFloat(indent) * 16)
                    .statementPreview(text, sources: sources)
                case .numbered(let marker, let text, let indent):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(marker).foregroundStyle(.secondary).monospacedDigit()
                        inline(text)
                    }
                    .padding(.leading, CGFloat(indent) * 16)
                case .quote(let text):
                    inline(text).foregroundStyle(.secondary)
                        .padding(.leading, 10)
                        .overlay(alignment: .leading) { Rectangle().fill(Color.secondary.opacity(0.4)).frame(width: 2) }
                        .statementPreview("> " + text, sources: sources)   // shown as it's printed on the page
                case .table(let rows):
                    Grid(alignment: .topLeading, horizontalSpacing: 16, verticalSpacing: 6) {
                        ForEach(rows.indices, id: \.self) { r in
                            GridRow {
                                ForEach(rows[r].indices, id: \.self) { c in
                                    inline(rows[r][c])
                                        .fontWeight(r == 0 ? .semibold : .regular)
                                        .foregroundStyle(r == 0 ? .secondary : .primary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            if r == 0 { Divider().gridCellUnsizedAxes(.horizontal) }
                        }
                    }
                    .padding(.vertical, 2)
                case .maths(let tex):
                    MathView(latex: tex, display: true)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 2)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// A line with its inline Markdown, and $maths$ in a serif italic.
    private func inline(_ line: String) -> Text {
        var result = Text("")
        let parts = line.components(separatedBy: "$")
        for (i, part) in parts.enumerated() {
            if i % 2 == 1 && i < parts.count - 1 {
                result = result + TeX.text(part, size: 14)
            } else {
                let piece = i % 2 == 1 ? "$" + part : part
                let attributed = (try? AttributedString(markdown: piece, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                    ?? AttributedString(piece)
                result = result + Text(attributed)
            }
        }
        return result
    }
}


/// Common LaTeX as readable text, for maths in notes: v_1 → v₁, x^2 → x², \dots → …,
/// \operatorname{Span} → Span, \mathbb{R} → ℝ, Greek letters and the usual symbols. Anything it
/// doesn't know is shown without its backslash. Fractions and matrices aren't laid out.
enum TeX {

    private static let symbols: [String: String] = [
        "dots": "…", "ldots": "…", "cdots": "⋯", "vdots": "⋮", "cdot": "·", "times": "×", "div": "÷",
        "le": "≤", "leq": "≤", "ge": "≥", "geq": "≥", "ne": "≠", "neq": "≠", "approx": "≈", "equiv": "≡",
        "in": "∈", "notin": "∉", "subseteq": "⊆", "subset": "⊂", "supseteq": "⊇", "supset": "⊃",
        "cup": "∪", "cap": "∩", "emptyset": "∅", "varnothing": "∅", "setminus": "∖",
        "forall": "∀", "exists": "∃", "neg": "¬", "land": "∧", "lor": "∨", "implies": "⟹", "iff": "⟺",
        "to": "→", "rightarrow": "→", "leftarrow": "←", "Rightarrow": "⇒", "Leftrightarrow": "⇔", "mapsto": "↦",
        "infty": "∞", "partial": "∂", "nabla": "∇", "sum": "∑", "prod": "∏", "int": "∫", "pm": "±", "mp": "∓",
        "langle": "⟨", "rangle": "⟩", "|": "‖", "mid": "∣", "circ": "∘", "oplus": "⊕", "otimes": "⊗", "perp": "⊥",
        "quad": "  ", "qquad": "    ", ",": " ", ";": " ", "!": "", " ": " ", "{": "{", "}": "}",
        "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ε", "varepsilon": "ε", "zeta": "ζ",
        "eta": "η", "theta": "θ", "iota": "ι", "kappa": "κ", "lambda": "λ", "mu": "μ", "nu": "ν", "xi": "ξ",
        "pi": "π", "rho": "ρ", "sigma": "σ", "tau": "τ", "phi": "φ", "varphi": "φ", "chi": "χ", "psi": "ψ",
        "omega": "ω", "Gamma": "Γ", "Delta": "Δ", "Theta": "Θ", "Lambda": "Λ", "Xi": "Ξ", "Pi": "Π",
        "Sigma": "Σ", "Phi": "Φ", "Psi": "Ψ", "Omega": "Ω",
    ]
    private static let blackboard: [Character: String] = ["R": "ℝ", "N": "ℕ", "Z": "ℤ", "Q": "ℚ", "C": "ℂ", "F": "𝔽"]
    private static let sub: [Character: Character] = Dictionary(uniqueKeysWithValues: zip("0123456789+-=()aeoxhklmnpstijruv", "₀₁₂₃₄₅₆₇₈₉₊₋₌₍₎ₐₑₒₓₕₖₗₘₙₚₛₜᵢⱼᵣᵤᵥ"))
    private static let sup: [Character: Character] = Dictionary(uniqueKeysWithValues: zip("0123456789+-=()nTi", "⁰¹²³⁴⁵⁶⁷⁸⁹⁺⁻⁼⁽⁾ⁿᵀⁱ"))

    /// Maths as Text, set as maths usually is: letters in serif italic; numbers, brackets and
    /// symbols upright; operator names (Span, dim) upright; subscripts and superscripts smaller,
    /// lowered or raised. Drawn rather than using ₁ or ² characters, which few fonts have.
    static func text(_ tex: String, size: CGFloat) -> Text {
        var result = Text("")
        for (piece, level) in pieces(tex) {
            let scale: CGFloat = level == 0 ? 1 : 0.72
            let offset: CGFloat = level < 0 ? -size * 0.22 : level > 0 ? size * 0.36 : 0
            for run in runs(piece) {
                var t = Text(run.text).font(.system(size: Scaled.s(size), design: .serif))
                if run.italic { t = t.italic() }
                result = result + t.baselineOffset(offset)
            }
        }
        return result
    }

    /// The maths split into stretches at the same level: 0 normal, -1 subscript, 1 superscript.
    private static func pieces(_ tex: String) -> [(String, Int)] {
        var found: [(String, Int)] = []
        var current = ""
        var chars = Array(tex)
        var i = 0
        func group() -> String {
            guard i < chars.count else { return "" }
            if chars[i] == "{" {
                var depth = 0; let start = i + 1
                while i < chars.count {
                    if chars[i] == "{" { depth += 1 } else if chars[i] == "}" { depth -= 1; if depth == 0 { break } }
                    i += 1
                }
                let inner = String(chars[start..<min(i, chars.count)]); i += 1
                return inner
            }
            if chars[i] == "\\" {
                var j = i + 1
                while j < chars.count, chars[j].isLetter { j += 1 }
                let command = String(chars[i..<j]); i = j
                return command
            }
            let one = String(chars[i]); i += 1
            return one
        }
        while i < chars.count {
            if chars[i] == "_" || chars[i] == "^" {
                let level = chars[i] == "_" ? -1 : 1
                i += 1
                if !current.isEmpty { found.append((readable(current), 0)); current = "" }
                found.append((readable(group()), level))
            } else {
                current.append(chars[i]); i += 1
            }
        }
        if !current.isEmpty { found.append((readable(current), 0)) }
        chars = []
        return found
    }

    /// Runs of italic (single letters, as variables) and upright (numbers, symbols, words).
    private static let upright = Set(["Span", "span", "dim", "ker", "rank", "det", "max", "min", "sup", "inf",
                                      "lim", "log", "ln", "exp", "sin", "cos", "tan", "im", "Im", "col", "row", "nul"])
    private static func runs(_ text: String) -> [(text: String, italic: Bool)] {
        var out: [(text: String, italic: Bool)] = []
        var word = ""
        func flushWord() {
            guard !word.isEmpty else { return }
            out.append((word, !(upright.contains(word) || word.count > 1 && word.allSatisfy(\.isLetter) && word.first!.isUppercase && word.dropFirst().allSatisfy(\.isLowercase))))
            word = ""
        }
        for c in text {
            if c.isLetter && c.isASCII { word.append(c) }
            else {
                flushWord()
                if let last = out.last, !last.italic { out[out.count - 1].text.append(c) } else { out.append((String(c), false)) }
            }
        }
        flushWord()
        return out
    }

    static func readable(_ tex: String) -> String {
        var out = ""
        var chars = Array(tex)
        var i = 0

        /// A {group} or a single character, starting at i; moves i past it.
        func argument() -> String {
            while i < chars.count, chars[i] == " " { i += 1 }
            guard i < chars.count else { return "" }
            if chars[i] == "{" {
                var depth = 0, start = i + 1
                while i < chars.count {
                    if chars[i] == "{" { depth += 1 } else if chars[i] == "}" { depth -= 1; if depth == 0 { break } }
                    i += 1
                }
                let inner = String(chars[start..<min(i, chars.count)])
                i += 1
                return inner
            }
            if chars[i] == "\\" {    // a command as the argument: x^\prime, v_\alpha
                var j = i + 1
                while j < chars.count, chars[j].isLetter { j += 1 }
                let command = String(chars[i..<j]); i = j
                return readable(command)
            }
            let one = String(chars[i]); i += 1
            return one
        }

        func script(_ text: String, _ table: [Character: Character], _ fallback: String) -> String {
            let converted = text.map { table[$0] }
            if converted.allSatisfy({ $0 != nil }) { return String(converted.compactMap { $0 }) }
            return fallback + (text.count > 1 ? "(\(readable(text)))" : readable(text))
        }

        while i < chars.count {
            let c = chars[i]
            switch c {
            case "\\":
                var j = i + 1
                if j < chars.count, !chars[j].isLetter {          // \, \; \{ \|
                    out += symbols[String(chars[j])] ?? String(chars[j]); i = j + 1; continue
                }
                while j < chars.count, chars[j].isLetter { j += 1 }
                let name = String(chars[(i + 1)..<j]); i = j
                switch name {
                case "operatorname", "mathrm", "text", "textrm", "mathit", "mathbf", "textbf", "boldsymbol", "mathsf":
                    out += readable(argument())
                case "mathbb":
                    let inner = argument()
                    out += inner.count == 1 ? (blackboard[Character(inner)] ?? inner) : inner
                case "mathcal", "mathscr":
                    out += argument()
                case "frac":
                    let top = readable(argument()), bottom = readable(argument())
                    out += "\(top.count > 1 ? "(\(top))" : top)/\(bottom.count > 1 ? "(\(bottom))" : bottom)"
                case "sqrt":
                    let inner = readable(argument()); out += "√" + (inner.count > 1 ? "(\(inner))" : inner)
                case "left", "right", "big", "Big", "bigl", "bigr", "Bigl", "Bigr", "displaystyle":
                    break
                case "dim", "ker", "span", "rank", "det", "max", "min", "sup", "inf", "lim", "log", "ln", "exp", "sin", "cos", "tan":
                    out += name
                default:
                    out += symbols[name] ?? name
                }
            case "_":
                i += 1; out += script(argument(), sub, "_")
            case "^":
                i += 1
                let power = argument()
                out += power == "\\prime" || power == "′" ? "′" : script(power, sup, "^")
            case "{", "}":
                i += 1
            case "~":
                out += " "; i += 1
            default:
                out.append(c); i += 1
            }
        }
        _ = chars
        chars = []
        return out
    }
}

/// Writing in Markdown that shows formatted, and turns into text to edit when clicked: the same
/// as a note's body, for meeting notes and decisions, and the AI use log's sections.
struct MarkdownField: View {

    let placeholder: String
    @Binding var text: String
    @State private var editing = false
    @FocusState private var focused: Bool

    var body: some View {
        if editing || text.isEmpty {
            TextField(placeholder, text: $text, axis: .vertical)
                .paragraphs()
                .textFieldStyle(.plain)
                .lineSpacing(4)
                .lineLimit(1...)
                .focused($focused)
                .onChange(of: focused) { _, now in if !now { editing = false } }
        } else {
            MarkdownView(text: text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { editing = true; focused = true }
                // Usable with VoiceOver and the keyboard too, not only a click.
                .accessibilityAddTraits(.isButton)
                .accessibilityAction(named: "Edit") { editing = true; focused = true }
                .help("Click to edit")
        }
    }
}


/// LaTeX drawn by SwiftMath, in the text colour, at the body size.
struct MathView: View {

    let latex: String
    let display: Bool

    var body: some View {
        // What SwiftMath can't draw falls back to the lighter text style, never an error.
        let prepared = MathLabel.prepare(latex)
        if MathLabel.draws(prepared) {
            MathLabel(latex: prepared, display: display)
        } else {
            TeX.text(latex, size: display ? 15 : 14).frame(maxWidth: display ? .infinity : nil)
        }
    }
}

struct MathLabel: NSViewRepresentable {

    let latex: String
    let display: Bool

    /// Common LaTeX that SwiftMath doesn't know, as what it does (checked against SwiftMath 1.7.3).
    static func prepare(_ tex: String) -> String {
        var out = tex
        let swaps: [(String, String)] = [
            ("\\dots", "\\ldots"), ("\\implies", "\\Rightarrow"), ("\\impliedby", "\\Leftarrow"),
            ("\\varnothing", "\\emptyset"), ("\\nexists", "\\neg\\exists"), ("\\dfrac", "\\frac"),
            ("\\tfrac", "\\frac"), ("\\boldsymbol", "\\mathbf"), ("\\operatorname", "\\mathrm"),
            ("\\lvert", "|"), ("\\rvert", "|"), ("\\lVert", "\\|"), ("\\rVert", "\\|"), ("\\not=", "\\neq"),
            ("\\begin{cases}", "\\left\\{\\begin{matrix}"), ("\\end{cases}", "\\end{matrix}\\right."),
        ]
        for (from, to) in swaps { out = out.replacingOccurrences(of: from, with: to) }
        return out
    }

    static func draws(_ tex: String) -> Bool {
        let probe = MTMathUILabel()
        probe.latex = tex
        return probe.error == nil
    }

    func makeNSView(context: Context) -> MTMathUILabel {
        let label = MTMathUILabel()
        label.labelMode = display ? .display : .text
        label.textAlignment = display ? .center : .left
        label.fontSize = display ? 16 : 14
        label.textColor = .labelColor
        label.latex = latex
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentHuggingPriority(.required, for: .vertical)
        return label
    }

    func updateNSView(_ label: MTMathUILabel, context: Context) {
        if label.latex != latex { label.latex = latex }
        label.textColor = .labelColor
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView label: MTMathUILabel, context: Context) -> CGSize? {
        let size = label.fittingSize   // SwiftMath's size on macOS
        return display ? CGSize(width: proposal.width ?? size.width, height: size.height) : size
    }
}

extension TeX {

    /// Whether a line's maths needs real layout (fractions, roots, big operators, matrices),
    /// rather than the lighter text style.
    static func needsLayout(_ line: String) -> Bool {
        guard line.contains("$") else { return false }
        return ["\\frac", "\\dfrac", "\\sqrt", "\\sum", "\\prod", "\\int", "\\lim", "\\begin",
                "\\binom", "\\over", "\\overline", "\\hat", "\\vec", "\\bar"].contains { line.contains($0) }
    }

    /// A line split into words and $maths$, for laying out with maths drawn inline.
    static func tokens(_ line: String) -> [(text: String, maths: Bool)] {
        var out: [(text: String, maths: Bool)] = []
        for (i, part) in line.components(separatedBy: "$").enumerated() {
            if i % 2 == 1 { out.append((part, true)); continue }
            // Words keep their trailing space, so the line wraps between them.
            var word = ""
            for c in part {
                word.append(c)
                if c == " " { out.append((word, false)); word = "" }
            }
            if !word.isEmpty { out.append((word, false)) }
        }
        return out
    }
}


/// The statements a line names, fetched once and watched by the popover (so it never shows a stale,
/// empty copy).
@MainActor
final class StatementLookup: ObservableObject {
    @Published var statements: [[String: Any]] = []
    @Published var looked = false
    private var loading = false

    func load(_ line: String, sources: [String]) async {
        guard !looked, !loading else { return }
        loading = true
        defer { loading = false }
        let data = await API.request("statements/preview", body: ["text": line, "urls": sources], timeout: 15)
        guard let data, let found = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            return   // no answer (busy, or interrupted): not remembered, so the next hover asks again
        }
        await Pictures.preload(found.compactMap { $0["image"] as? String })   // ready before it opens
        statements = found
        looked = true
    }
}

/// Hovering over a line that names a theorem or definition ("Theorem 4.50(a)") shows the statement
/// as the source prints it, with its page; the page opens the source there. Only the sources' own
/// text: nothing is written or summarised.
struct StatementPreview: ViewModifier {

    let line: String
    let sources: [String]
    @StateObject private var lookup = StatementLookup()
    @State private var showing = false
    @State private var waiting: Task<Void, Never>?

    static let reference = try! NSRegularExpression(
        // Numbered statements and figures ("Theorem 4.50", "Fig. 4.2"), and equations by their printed number ("(4.1)").
        // Also a statement named by its page only ("Theorem (p. 55)").
        pattern: "\\b(Def|Defn|Definition|Definitions|Thm|Theorem|Theorems|Lem|Lemma|Prop|Proposition|Cor|Corollary|Ex|Example|Rem|Remark|Eq|Equation|Fig|Figure)\\.?\\s+\\d+(\\.\\d+)+|\\(\\d+\\.\\d+\\)|\\b(Definition|Theorem|Lemma|Proposition|Corollary)\\s*\\(\\s*pp?\\.?\\s*\\d+\\s*\\)",
        options: [.caseInsensitive])

    /// A line names a statement, or is a quote long enough to find on the page.
    static func previews(_ line: String) -> Bool {
        if line.hasPrefix("> ") { return line.filter(\.isLetter).count >= 15 }
        return reference.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
    }

    func body(content: Content) -> some View {
        if sources.isEmpty || !StatementPreview.previews(line) {
            content
        } else {
            content
                .onHover { inside in
                    waiting?.cancel()
                    guard inside else { return }
                    waiting = Task {
                        try? await Task.sleep(nanoseconds: 450_000_000)   // a pause, not a pass of the mouse
                        guard !Task.isCancelled else { return }
                        // Not cancelled by moving the pointer once started: that cut requests off
                        // mid-way and showed "Not found".
                        await Task.detached { await lookup.load(line, sources: sources) }.value
                        if lookup.looked { showing = true }
                    }
                }
                .popover(isPresented: $showing, arrowEdge: .trailing) { StatementCard(lookup: lookup, close: { showing = false }) }
        }
    }
}

struct StatementCard: View {

    @ObservedObject var lookup: StatementLookup
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if lookup.statements.isEmpty {
                Text("Not found in this note's sources.").foregroundStyle(.secondary)
            }
            ForEach(lookup.statements.indices, id: \.self) { i in
                let s = lookup.statements[i]
                VStack(alignment: .leading, spacing: 6) {
                    if s["scanned"] as? Bool == true {
                        Text("Read from a scanned page: check the wording, especially the maths, against the page.")
                            .font(Scaled.style(10, .regular)).foregroundStyle(.orange)
                    }
                    if let path = s["image"] as? String, let picture = Pictures.load(path) {
                        // As the PDF prints it: matrices and layout that text loses.
                        Image(nsImage: picture)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            // Clicking the page opens the source there, like the link below it.
                            .contentShape(Rectangle())
                            .onTapGesture {
                                close()
                                RefereeLinks.openSource(s["url"] as? String ?? "", page: s["page"] as? Int,
                                                        pdf: (s["url"] as? String ?? "").lowercased().hasSuffix(".pdf"))
                            }
                            .onHover { inside in if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() } }
                            .help("Open at this page")
                            .accessibilityElement()
                            .accessibilityLabel(Spoken.maths(s["text"] as? String ?? ""))
                            .accessibilityAddTraits(.isButton)
                    } else {
                        MarkdownView(text: s["text"] as? String ?? "")   // with its maths set as maths
                            .font(.system(size: Scaled.s(13)))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Button {
                        close()
                        RefereeLinks.openSource(s["url"] as? String ?? "", page: s["page"] as? Int,
                                                pdf: (s["url"] as? String ?? "").lowercased().hasSuffix(".pdf"))
                    } label: {
                        // Grey with an arrow, not blue: blue is hard to read on the popover's dark glass.
                        HStack(spacing: 4) {
                            Text([s["source"] as? String, (s["page"] as? Int).map { "p. \($0)" }].compactMap { $0 }.joined(separator: " · "))
                            Image(systemName: "arrow.up.right").font(.system(size: Scaled.s(9), weight: .semibold))
                        }
                        .font(Scaled.style(10, .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Open at this page")
                }
                if i < lookup.statements.count - 1 { Hairline() }
            }
        }
        .padding(14)
        .frame(width: 600, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }
}

extension View {
    /// Hover previews only on lines naming a numbered statement: every other line is left as it is,
    /// without a lookup object of its own (a long note made hundreds, and slowed scrolling).
    @ViewBuilder func statementPreview(_ line: String, sources: [String]) -> some View {
        if !sources.isEmpty && StatementPreview.previews(line) {
            modifier(StatementPreview(line: line, sources: sources))
        } else {
            self
        }
    }
}


/// Text with maths, as VoiceOver should read it: "$v_1, \\dots, v_n$" → "v sub 1, dots, v sub n",
/// "x₁" → "x sub 1".
enum Spoken {
    static func maths(_ text: String) -> String {
        var t = text
        let subscripts = Array("₀₁₂₃₄₅₆₇₈₉ₙₘₖᵢⱼ"), plain = Array("0123456789nmkij")
        for (s, p) in zip(subscripts, plain) { t = t.replacingOccurrences(of: String(s), with: " sub \(p)") }
        let words: [(String, String)] = [("\\dots", "dots"), ("\\cdots", "dots"), ("…", "dots"), ("⋯", "dots"),
            ("\\in", " in "), ("∈", " in "), ("\\mathbb{R}", "R"), ("ℝ", "R"), ("\\leq", " at most "), ("≤", " at most "),
            ("\\geq", " at least "), ("≥", " at least "), ("\\neq", " not equal to "), ("≠", " not equal to "),
            ("\\{", "{"), ("\\}", "}"), ("\\mid", " such that "), ("\\mathrm", ""), ("$", "")]
        for (from, to) in words { t = t.replacingOccurrences(of: from, with: to) }
        t = t.replacingOccurrences(of: #"_\{?([0-9a-z]+)\}?"#, with: " sub $1", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\^\{?([0-9a-z]+)\}?"#, with: " to the $1", options: .regularExpression)
        return t.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
    }
}


/// Page pictures, read from disk once each and kept while Referee is open.
enum Pictures {
    private static let cache = NSCache<NSString, NSImage>()

    /// The picture, decoded at about the size it's shown (pages are made large, for sharpness when
    /// zoomed): a full-size decode on each draw is what made previews slow to appear.
    static func load(_ path: String) -> NSImage? {
        if let known = cache.object(forKey: path as NSString) { return known }
        guard let image = decode(path) else { return nil }
        cache.setObject(image, forKey: path as NSString)
        return image
    }

    /// Decodes pictures off the main thread ahead of time, so they're ready when a preview opens.
    static func preload(_ paths: [String]) async {
        let missing = paths.filter { cache.object(forKey: $0 as NSString) == nil }
        guard !missing.isEmpty else { return }
        let decoded: [(String, NSImage)] = await Task.detached(priority: .userInitiated) {
            missing.compactMap { path in decode(path).map { (path, $0) } }
        }.value
        for (path, image) in decoded { cache.setObject(image, forKey: path as NSString) }
    }

    nonisolated private static func decode(_ path: String) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: 1800,
                  kCGImageSourceShouldCacheImmediately: true,
              ] as CFDictionary) else { return NSImage(contentsOfFile: path) }
        return NSImage(cgImage: image, size: NSSize(width: CGFloat(image.width) / 2, height: CGFloat(image.height) / 2))
    }
}
