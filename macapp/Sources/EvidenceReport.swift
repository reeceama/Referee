import SwiftUI

/// The Evidence report: for each document, every claim Referee has checked, the source and page
/// that back it (or contradict it), and how sure the check was, with a summary at the top.
struct Claim: Identifiable {
    let id: String
    let sentence: String
    let label: String            // supports, contradicts, misquote, needs_source
    let sourceURL: String
    let sourceName: String
    let page: Int?
    let confidence: Double?
    let tooClose: Bool
    let document: String
    let at: Double
    var statement = ""            // what backs it in the source: "Definition 4.17"
    var parts: [String] = []      // when sentences in a row rest on the same statement: each of them
}

@MainActor
final class EvidenceModel: ObservableObject {

    @Published var claims: [Claim] = []
    @Published var documents: [String] = []
    // Remembered, so Referee reopens on the document you were looking at.
    @Published var document = UserDefaults.standard.string(forKey: "lastEvidenceDocument") ?? "" {
        didSet { UserDefaults.standard.set(document, forKey: "lastEvidenceDocument"); Task { await loadOrder() } }
    }
    @Published var project = ""
    private var names: [String: String] = [:]   // source URL -> the name shown for it
    private var pdfs: Set<String> = []

    func load() {
        Task {
            project = (await API.get("settings"))?["project"] as? String ?? ""
            for source in await API.getList("sources") {
                guard let url = source["url"] as? String else { continue }
                names[url] = [source["name"], source["title"]].compactMap { $0 as? String }.first { !$0.isEmpty } ?? url
                if source["type"] as? String == "pdf" || url.lowercased().hasSuffix(".pdf") { pdfs.insert(url) }
            }
            let query = project.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
            claims = await API.getList("claims?project=\(query)").compactMap { c in
                guard let sentence = c["sentence"] as? String, let label = c["label"] as? String else { return nil }
                let source = c["source"] as? [String: Any] ?? [:]
                let url = source["url"] as? String ?? ""
                return Claim(id: sentence, sentence: sentence, label: label, sourceURL: url,
                             sourceName: names[url] ?? (source["title"] as? String ?? ""),
                             page: c["page"] as? Int, confidence: c["confidence"] as? Double,
                             tooClose: c["too_close"] as? Bool ?? false,
                             document: c["document"] as? String ?? "Unnamed document", at: c["at"] as? Double ?? 0,
                             statement: c["statement"] as? String ?? "")
            }
            documents = Array(Set(claims.map(\.document))).sorted()
            if !documents.contains(document) { document = documents.first ?? "" }
            await loadOrder()
        }
    }

    func loadOrder() async {
        let name = document.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        order = await API.request("claims/order?document=\(name)")
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String] } ?? []
    }

    /// In the order they're written in the document (sent by its panel), then any not placed, oldest first.
    var shown: [Claim] {
        let place = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        return claims.filter { $0.document == document }.sorted {
            let (a, b) = (place[$0.sentence] ?? Int.max, place[$1.sentence] ?? Int.max)
            return a != b ? a < b : $0.at < $1.at
        }
    }
    /// As shown: sentences next to each other that rest on the same numbered statement, on the same page
    /// of the same source, count as one claim ("V has dimension n if …. This is denoted by dim V = n.").
    var rows: [Claim] {
        var merged: [Claim] = []
        for claim in shown {
            if var last = merged.last, !claim.statement.isEmpty, last.statement == claim.statement,
               last.sourceURL == claim.sourceURL, last.page == claim.page {
                let parts = (last.parts.isEmpty ? [last.sentence] : last.parts) + [claim.sentence]
                let label = last.label == "supports" ? claim.label : last.label
                last = Claim(id: last.id, sentence: parts.joined(separator: " "), label: label, sourceURL: last.sourceURL,
                             sourceName: last.sourceName, page: last.page,
                             confidence: [last.confidence, claim.confidence].compactMap { $0 }.min(),
                             tooClose: last.tooClose || claim.tooClose, document: last.document, at: last.at,
                             statement: last.statement, parts: parts)
                merged[merged.count - 1] = last
            } else {
                merged.append(claim)
            }
        }
        return merged
    }
    @Published var order: [String] = []   // the chosen document's sentences, in order

    /// "PDF" or "web", for the list of sources.
    func kind(_ claim: Claim) -> String { pdfs.contains(claim.sourceURL) ? "PDF" : "web" }

    /// Its checks leave Evidence and the current research trail (Undo brings them back).
    func removeDocument() {
        let doc = document.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        let proj = project.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        Task {
            _ = await API.delete("claims/document?document=\(doc)&project=\(proj)")
            NotificationCenter.default.post(name: .refereeDeleted, object: nil)   // offers Undo
            load()
        }
    }

    /// At the page that backs the claim (the table), or at the start (the list of sources).
    func open(_ claim: Claim, atPage: Bool = true) {
        RefereeLinks.openSource(claim.sourceURL, page: atPage ? claim.page : nil, pdf: pdfs.contains(claim.sourceURL))
    }
}

struct EvidenceReportView: View {

    @ObservedObject var model: EvidenceModel
    @State private var removing = false
    @State private var narrow = false   // the page is too narrow for the table: claims stacked instead

    /// The sources the shown claims use, numbered in the order they first appear.
    private var sources: [Claim] {
        var seen = Set<String>()
        return model.shown.filter { !$0.sourceURL.isEmpty && seen.insert($0.sourceURL).inserted }
    }

    private func number(_ claim: Claim) -> Int? {
        sources.firstIndex { $0.sourceURL == claim.sourceURL }.map { $0 + 1 }
    }

    var body: some View {
        if model.shown.isEmpty {
            EmptyPage(symbol: "checklist", title: "No checked writing yet",
                      message: "Write in Word, Overleaf or Google Docs" + (model.project.isEmpty ? "" : " with \(model.project) as your project")
                        + ", and each checked claim appears here with the source that backs it.")
        } else {
        Page(wide: true) {
            do {
                HStack(alignment: .firstTextBaseline) {
                    Text(title(model.document))
                        .font(Fonts.heading(32, .regular))
                    Spacer()
                    Button { model.load() } label: { Image(systemName: "arrow.clockwise") }
                        .accessibilityLabel("Refresh")
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Refresh")
                    Menu {
                        Button("Remove This Document…", role: .destructive) { removing = true }
                    } label: { Image(systemName: "ellipsis") }
                        .accessibilityLabel("More")
                        .menuIndicator(.hidden)
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .foregroundStyle(.secondary)
                }
                .confirmationDialog("Remove the \(model.shown.count) \(model.shown.count == 1 ? "check" : "checks") from “\(title(model.document))”?",
                                    isPresented: $removing) {
                    Button("Remove", role: .destructive) { model.removeDocument() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("They'll also leave the research trail. Checks in an archived trail stay there.")
                }
                // The same details row as every other page's title.
                DetailsRow {
                    Detail(symbol: "doc.text") { Text(editor(model.document)) }
                    if !model.project.isEmpty {
                        DetailDivider()
                        Detail(symbol: "folder") { Text(model.project) }
                    }
                    if let last = model.shown.map(\.at).max(), last > 0 {
                        DetailDivider()
                        Detail(symbol: "clock") { Text("Checked \(Date(timeIntervalSince1970: last).formatted(.relative(presentation: .named)))") }
                    }
                }
                .padding(.top, 10)
                chips.padding(.top, 18)
                table.padding(.top, 20)
                ReferenceCheck(document: model.document)
                Hairline().padding(.top, 28)
                FieldLabel("Sources").padding(.top, 18).padding(.bottom, 8)
                ForEach(Array(sources.enumerated()), id: \.element.id) { index, claim in
                    HStack(spacing: 10) {
                        Badge(number: index + 1)
                        Button(claim.sourceName) { model.open(claim, atPage: false) }
                            .buttonStyle(.plain)
                            .foregroundStyle(Color.accentColor)
                        Text("· \(model.kind(claim))").foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        }
    }

    /// "main.tex (Overleaf)" -> "main.tex", and Overleaf's tab title "Test - Online LaTeX Editor
    /// Overleaf" -> "Test"; the editor goes in the details row.
    private func title(_ document: String) -> String {
        document.replacingOccurrences(of: #"\s*\([^)]*\)$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s*[-–|]\s*(Online LaTeX Editor )?Overleaf$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s*-\s*Google Docs$"#, with: "", options: .regularExpression)
    }

    private func editor(_ document: String) -> String {
        guard let open = document.lastIndex(of: "("), document.hasSuffix(")") else { return "Word" }
        return String(document[document.index(after: open)..<document.index(before: document.endIndex)])
    }

    private var chips: some View {
        let claims = model.rows
        let backed = claims.filter { $0.label == "supports" }.count
        let needing = claims.filter { $0.label == "needs_source" }.count
        let against = claims.filter { $0.label == "contradicts" }.count
        let wording = claims.filter { $0.label == "misquote" || $0.tooClose }.count
        return HStack(spacing: 6) {
            chip("checkmark", "\(backed) of \(claims.count) \(claims.count == 1 ? "claim" : "claims") backed", .green)
            if needing > 0 { chip(nil, needing == 1 ? "1 needs a source" : "\(needing) need a source", .orange) }
            if against > 0 { chip(nil, "\(against) contradicted", .red) }
            if wording > 0 { chip(nil, "\(wording) to check the wording", .orange) }
        }
    }

    private func chip(_ symbol: String?, _ text: String, _ colour: Color) -> some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).font(.system(size: Scaled.s(10), weight: .semibold)) }
            Text(text)
        }
        .font(.system(size: Scaled.s(12)))
        .foregroundStyle(colour)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(colour.opacity(0.14), in: RoundedRectangle(cornerRadius: 7))
    }

    /// The table in columns when there's room; in a narrow window (half a laptop screen), each claim
    /// above its source, result and confidence on one line.
    private var table: some View {
        // Chosen by the page's width, measured here: letting SwiftUI pick whichever "fits" chose the
        // narrow one even in a wide window, since a long claim's ideal width is its whole length.
        VStack(spacing: 0) {
            Color.clear.frame(maxWidth: .infinity).frame(height: 0)
                .background(GeometryReader { space in
                    Color.clear
                        .onAppear { narrow = space.size.width < 600 }
                        .onChange(of: space.size.width) { _, width in narrow = width < 600 }
                })
            if narrow { narrowTable } else { wideTable }
        }
    }

    private var narrowTable: some View {
            VStack(spacing: 0) {
                ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, claim in
                    if index > 0 { Hairline() }
                    compactRow(claim)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.13), lineWidth: 1))
    }

    /// Where in the source: "Definition 4.17 · p. 50", or the page alone.
    @ViewBuilder
    private func where_(_ claim: Claim) -> some View {
        // Shortened as in maths writing: "Def. 4.17", "Thm. 4.20"; a fact stays "Fact".
        let short = ["Definition": "Def.", "Theorem": "Thm.", "Lemma": "Lem.", "Proposition": "Prop.", "Corollary": "Cor."]
            .reduce(claim.statement) { $0.replacingOccurrences(of: $1.key, with: $1.value) }
        let parts = [short.isEmpty ? nil : short, claim.page.map { "p. \($0)" }].compactMap { $0 }
        if !parts.isEmpty {
            Text(parts.joined(separator: " · ")).font(Scaled.style(11, .regular)).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private func compactRow(_ claim: Claim) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            MarkdownView(text: claim.sentence.replacingOccurrences(of: #"^\s*\[[^\]]{1,8}\]\s*"#, with: "", options: .regularExpression))
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                if let n = number(claim) {
                    Button { model.open(claim) } label: { Badge(number: n) }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Source \(n): \(claim.sourceName)")
                        .help(claim.sourceName + (claim.page.map { ", page \($0)" } ?? "") + ": click to open")
                }
                where_(claim)
                result(claim)
                confidence(claim).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Ignore") {
                Task {   // every sentence of it, when sentences were counted as one
                    for sentence in claim.parts.isEmpty ? [claim.sentence] : claim.parts { _ = await API.post("claims/ignore", ["sentence": sentence]) }
                    model.load()
                }
            }
        }
    }

    private var wideTable: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                FieldLabel("Claim").frame(minWidth: 150, maxWidth: .infinity, alignment: .leading)
                FieldLabel("Source").frame(width: 130, alignment: .leading)
                FieldLabel("Result").frame(width: 110, alignment: .leading)
                FieldLabel("Confidence").lineLimit(1).fixedSize().frame(width: 80, alignment: .leading)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.primary.opacity(0.04))
            ForEach(model.rows) { claim in
                Hairline()
                row(claim)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.13), lineWidth: 1))
    }

    private func row(_ claim: Claim) -> some View {
        HStack(alignment: .top, spacing: 12) {
            // As written, with its maths typeset; a LaTeX list label at the start ("[(b)]") left out.
            MarkdownView(text: claim.sentence.replacingOccurrences(of: #"^\s*\[[^\]]{1,8}\]\s*"#, with: "", options: .regularExpression))
                .frame(minWidth: 150, maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 4) {
                if let n = number(claim) {
                    Button { model.open(claim) } label: { Badge(number: n) }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Source \(n): \(claim.sourceName)\(claim.page.map { ", page \($0)" } ?? "")")
                        .help(claim.sourceName + (claim.page.map { ", page \($0)" } ?? "") + ": click to open")
                } else {
                    Text("—").foregroundStyle(.tertiary)
                }
                where_(claim)
            }
            .frame(width: 130, alignment: .leading)
            result(claim).frame(width: 110, alignment: .leading)
            confidence(claim).frame(width: 80, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
        // Not a claim (part of a question, a hypothesis): gone from here, and not checked again.
        .contextMenu {
            Button("Ignore") {
                Task {   // every sentence of it, when sentences were counted as one
                    for sentence in claim.parts.isEmpty ? [claim.sentence] : claim.parts { _ = await API.post("claims/ignore", ["sentence": sentence]) }
                    model.load()
                }
            }
        }
        .accessibilityAction(named: "Ignore") {
            Task {   // every sentence of it, when sentences were counted as one
                    for sentence in claim.parts.isEmpty ? [claim.sentence] : claim.parts { _ = await API.post("claims/ignore", ["sentence": sentence]) }
                    model.load()
                }
        }
    }

    private func result(_ claim: Claim) -> some View {
        let (text, colour): (String, Color) = {
            switch claim.label {
            case "supports": return (claim.tooClose ? "Backed, too close" : "Backed", claim.tooClose ? .orange : .green)
            case "contradicts": return ("Contradicted", .red)
            case "misquote": return ("Misquoted", .orange)
            default: return ("Needs a source", .orange)
            }
        }()
        return HStack(spacing: 6) {
            Circle().fill(colour).frame(width: 7, height: 7)
            Text(text)
        }
    }

    private func confidence(_ claim: Claim) -> some View {
        Group {
            if let c = claim.confidence, claim.label != "needs_source" {
                Text(c >= 0.85 ? "High" : c >= 0.7 ? "Medium" : "Low")
            } else {
                Text("—").foregroundStyle(.tertiary)
            }
        }
        .foregroundStyle(.secondary)
    }
}

/// A source's number, in a small blue box.
struct Badge: View {

    let number: Int

    var body: some View {
        Text("\(number)")
            .font(.system(size: Scaled.s(11), weight: .medium))
            .foregroundStyle(Color.accentColor)
            .frame(minWidth: 18)
            .padding(.vertical, 1)
            .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 5))
            .accessibilityLabel("Source \(number)")
    }
}


/// The Word helper's check of a document's reference list (moved here from the Library): entries
/// with problems, such as a DOI that doesn't resolve. Nothing shows when there are none.
struct ReferenceCheck: View {

    let document: String
    @State private var issues: [(entry: String, note: String)] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !issues.isEmpty {
                Hairline().padding(.top, 28)
                FieldLabel("Reference Check").padding(.top, 18)
                ForEach(Array(issues.enumerated()), id: \.offset) { _, issue in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(issue.note).font(Scaled.style(12, .regular)).foregroundStyle(.orange)
                        Text(issue.entry).font(.system(.caption, design: .serif)).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            }
        }
        .task(id: document) {
            let found = LibraryModel.findings(await API.get("audit") ?? [:])
            issues = found.first { $0.document == document || document.hasPrefix($0.document) || $0.document.hasPrefix(document) }?.issues ?? []
        }
    }
}
