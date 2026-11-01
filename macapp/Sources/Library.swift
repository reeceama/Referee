import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The library: your reading, projects, reference list and proof-of-work report, in the app,
/// so Referee needs no browser extension to manage what it knows.
@MainActor
final class LibraryModel: ObservableObject {

    @Published var sources: [[String: Any]] = []
    @Published var claims: [[String: Any]] = []
    @Published var notes: [String: [String]] = [:]   // source URL -> what was highlighted on it
    @Published var projects: [String] = []
    @Published var current = ""
    @Published var links: [String: [String]] = [:]
    @Published var archived: [String] = []
    @Published var references: [String] = []
    @Published var filter = "all"            // "all", "none" or a project name
    @Published var document = ""              // References for one document ("" for all of them)
    @Published var style = WordSettings.style
    @Published var search = ""
    @Published var audits: [(document: String, issues: [(entry: String, note: String)])] = []
    @Published var warnings: [(document: String, issues: [(entry: String, note: String)])] = []

    func load() {
        Task {
            sources = await API.getList("sources")
            claims = await API.getList("claims")
            let found = await API.get("highlights") ?? [:]
            notes = found.mapValues { ($0 as? [[String: Any]] ?? []).compactMap { $0["text"] as? String } }
            if let settings = await API.get("settings") {
                projects = settings["projects"] as? [String] ?? []
                current = settings["project"] as? String ?? ""
                links = settings["links"] as? [String: [String]] ?? [:]
                archived = settings["archived"] as? [String] ?? []
            }
            if filter != "all" && filter != "none" && !projects.contains(filter) { filter = "all" }
            audits = LibraryModel.findings(await API.get("audit") ?? [:])
            warnings = LibraryModel.findings(await API.get("warnings") ?? [:])
            await loadReferences()
        }
    }

    /// The documents with checks in this view, for choosing whose references to show.
    var documents: [String] {
        Array(Set(claims.filter { inFilter($0["project"]) }.map { $0["document"] as? String ?? "Unnamed document" })).sorted()
    }

    /// Per-document findings from the Word helper, as (document, [(entry, note)]).
    static func findings(_ found: [String: Any]) -> [(document: String, issues: [(entry: String, note: String)])] {
            found.compactMap { document, value in
                let issues = ((value as? [String: Any])?["issues"] as? [[String: Any]] ?? [])
                    .compactMap { issue -> (entry: String, note: String)? in
                        guard let entry = issue["entry"] as? String, let note = issue["note"] as? String else { return nil }
                        return (entry, note)
                    }
                return issues.isEmpty ? nil : (document, issues)
            }.sorted { $0.document < $1.document }
    }

    func loadReferences() async {
        let query = "references?project=\(filter.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "all")&style=\(style)"
            + "&document=\(document.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")"
        references = (await API.getPath(query))?["entries"] as? [String] ?? []
    }

    func inFilter(_ project: Any?) -> Bool {
        let name = project as? String ?? ""
        switch filter {
        case "all": return true
        case "none": return name.isEmpty
        default: return name == filter
        }
    }

    var shown: [[String: Any]] {
        let query = search.lowercased()
        return sources
            .filter { inFilter($0["project"]) }
            .filter { source in
                query.isEmpty || ["title", "site", "author", "url"].contains { (source[$0] as? String ?? "").lowercased().contains(query) }
            }
            .sorted { ($0["captured_ts"] as? Double ?? 0) > ($1["captured_ts"] as? Double ?? 0) }
    }

    func backs(_ url: String) -> Int {
        claims.filter { ($0["label"] as? String) == "supports" && (($0["source"] as? [String: Any])?["url"] as? String) == url && inFilter($0["project"]) }.count
    }

    var summary: String {
        let mine = claims.filter { inFilter($0["project"]) }
        let backed = mine.filter { ($0["label"] as? String) == "supports" }
        if mine.isEmpty { return "No claims checked yet." }
        var line = "\(backed.count) claim\(backed.count == 1 ? "" : "s") backed by your reading"
        let against = mine.filter { ($0["label"] as? String) == "contradicts" }.count
        let unsupported = mine.filter { ($0["label"] as? String) == "needs_source" }.count
        if against > 0 { line += " · \(against) contradicted by a source" }
        if unsupported > 0 { line += " · \(unsupported) need\(unsupported == 1 ? "s" : "") a source" }
        return line
    }

    // Actions, each followed by a reload.
    func setCurrent(_ name: String) { Task { _ = await API.post("settings", ["project": name]); load() } }
    func rename(_ old: String, to new: String) { Task { _ = await API.post("projects/rename", ["old": old, "new": new]); if filter == old { filter = new.isEmpty ? "all" : new }; load() } }
    func archive(_ name: String, _ archived: Bool) { Task { _ = await API.post("projects/archive", ["project": name, "archived": archived]); load() } }
    func setLinks(_ project: String, _ others: [String]) { Task { var all = links; all[project] = others; _ = await API.post("settings", ["links": all]); load() } }
    func move(_ url: String, to project: String) { Task { _ = await API.post("sources/move", ["url": url, "project": project]); load() } }
    func keep(_ url: String) { Task { _ = await API.post("sources/keep", ["url": url]); load() } }
    func forget(_ url: String) { Task { _ = await API.delete("sources?url=\(url.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")"); load() } }
    @Published var rereading: Set<String> = []

    /// Reads a saved paper again with its maths and abstract, keeping its project and notes.
    /// The name you see for a source. References keep its citation details.
    func renameSource(_ url: String, to name: String) {
        Task {
            _ = await API.post("sources/rename", ["url": url, "name": name])
            load()
        }
    }

    /// Citation details for a source that lacks them, such as lecture notes. Its \\cite key stays the same.
    func saveDetails(_ url: String, _ details: [String: String]) {
        Task {
            _ = await API.post("sources/details", ["url": url].merging(details) { a, _ in a })
            load()
        }
    }

    func reread(_ url: String) {
        rereading.insert(url)
        Task {
            _ = await API.post("sources/reread", ["url": url], timeout: 120)
            rereading.remove(url)
            load()
        }
    }

    func forgetEverything() { Task { _ = await API.post("clear", [:]); load() } }

    /// Opens one of the server's report pages (proof of work, before you submit, research trail) in the browser.
    @Published var report: (title: String, html: String, trailProject: String?)?

    func open(_ page: String, named name: String) {
        Task {
            // The research trail is a project's: with All Reading shown, it's the current project's.
            let scope = page == "trail" && filter == "all" && !current.isEmpty ? current : filter
            let query = "\(page)?project=\(scope.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "all")&style=\(style)"
            guard let data = await API.request(query, timeout: 30), let html = String(data: data, encoding: .utf8) else { return }
            report = (name.prefix(1).uppercased() + name.dropFirst(), html,
                      page == "trail" && scope != "all" ? (scope == "none" ? "" : scope) : nil)   // shown in Referee, not the browser
        }
    }

    /// Saves this view's saved sources as BibTeX or RIS, for Zotero, Mendeley or LaTeX.
    func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Referee sources.bib"
        panel.allowedContentTypes = [.init(filenameExtension: "bib")!, .init(filenameExtension: "ris")!]
        panel.message = "Save as .bib (BibTeX, for Zotero or LaTeX) or .ris (for Zotero, Mendeley or EndNote)."
        guard panel.runModal() == .OK, let file = panel.url else { return }
        Task {
            let format = file.pathExtension.lowercased() == "ris" ? "ris" : "bibtex"
            let query = "export?format=\(format)&project=\(filter.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "all")"
            guard let data = await API.request(query) else { return }
            try? data.write(to: file)
        }
    }

    /// Imports a BibTeX or RIS file: each entry is fetched and saved to the current project.
    func importFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "bib")!, .init(filenameExtension: "ris")!]
        panel.message = "Choose a .bib or .ris file, for example exported from Zotero."
        guard panel.runModal() == .OK, let file = panel.url, let text = try? String(contentsOf: file, encoding: .utf8) else { return }
        importing = true
        Task {
            let result = await API.post("import", ["text": text], timeout: 600)
            importing = false
            load()
            let added = result?["added"] as? Int ?? 0
            let failed = result?["failed"] as? [String] ?? []
            let alert = NSAlert()
            alert.messageText = result == nil ? "Import didn't finish" : "Imported \(added) source\(added == 1 ? "" : "s")"
            alert.informativeText = result == nil ? "Referee's server didn't answer in time. Try a smaller file."
                : failed.isEmpty ? "Each one was read and saved to your current project." : "Couldn't read:\n" + failed.prefix(12).joined(separator: "\n")
            alert.runModal()
        }
    }

    @Published var importing = false
}

struct LibraryView: View {

    @StateObject private var library = LibraryModel()
    @State private var newProject = ""
    @State private var renaming: String?
    @State private var renamingSource: String?     // the source whose name is being edited
    @State private var settingDue: String?
    @State private var sourceName = ""
    @State private var detailing: String?          // the source whose citation details are open
    @State private var details: [String: String] = [:]
    @State private var renameTo = ""
    @State private var armed: String?           // a saved source or project waiting for its second click
    @State private var confirmEverything = ""
    @State private var copied = false
    @State private var forgetting: String?
    @State private var lastDocument = UserDefaults.standard.string(forKey: "lastEvidenceDocument") ?? ""
    @State private var choosing: String?          // the header list open: reports or import & export

    @State private var showingReferences = false

    var body: some View {
        Page {
            controls
            if showingReferences {
                referencesList.padding(.top, 18)
                if !library.warnings.isEmpty {
                    FieldLabel("Warnings").padding(.top, 28).padding(.bottom, 8)
                    findingsList(library.warnings)
                }
            } else {
                readingList
                forgetEverything.padding(.top, 36)
            }
        }
        .onAppear { library.load() }
        // Choosing a document in the sidebar shows its references here.
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification).receive(on: RunLoop.main)) { _ in
            let chosen = UserDefaults.standard.string(forKey: "lastEvidenceDocument") ?? ""
            if chosen != lastDocument { lastDocument = chosen; library.document = chosen; Task { await library.loadReferences() } }
        }
        .pageActions { HStack(spacing: 14) {
            searchField; reportsMenu; transferMenu
            RecentlyDeletedButton(kind: "source", project: library.filter, inHeader: true) { library.load() }
            addButton
        } }
        .sheet(isPresented: Binding(get: { library.report != nil }, set: { if !$0 { library.report = nil } })) {
            if let report = library.report { ReportView(title: report.title, html: report.html, trailProject: report.trailProject) }
        }
    }

    // MARK: Header bar: search, reports, import and export, add.

    private var searchField: some View {
        TextField("Search", text: $library.search)
            .textFieldStyle(.roundedBorder)
            .frame(width: 160)
    }

    // Plain buttons opening small lists, as on Notes: a menu's icon is drawn heavier than the
    // header's other buttons.
    // The research trail: what was read, saved, highlighted and checked, and each claim's evidence.
    private var reportsMenu: some View {
        Button { library.open("trail", named: "research trail") } label: { HeaderIcon("doc.text") }
            .buttonStyle(.borderless)
            .help("Research Trail")
    }

    private var transferMenu: some View {
        Button { choosing = "transfer" } label: { HeaderIcon(library.importing ? "hourglass" : "square.and.arrow.down") }
            .buttonStyle(.borderless)
            .disabled(library.importing)
            .help(library.importing ? "Importing…" : "Import & Export")
            .popover(isPresented: Binding(get: { choosing == "transfer" }, set: { if !$0 { choosing = nil } }), arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 6) {
                    Button("Import .bib or .ris") { choosing = nil; library.importFile() }
                    Button("Export .bib or .ris") { choosing = nil; library.export() }
                }
                .buttonStyle(.plain)
                .padding(12)
                .fixedSize()   // the same small list as every header popover
            }
    }

    private var addButton: some View {
        Button { Windows.open("add-source") } label: { HeaderIcon("plus") }
            .buttonStyle(.borderless)
            .help("Add Source")
    }

    // MARK: Reading or References, which project, and the summary.

    private var controls: some View {
        // Wraps onto a second line in a narrow window rather than running off the page.
        WrappingRow(spacing: 12, lineSpacing: 8) {
            Picker("Show", selection: $showingReferences) {
                Text("Reading").tag(false)
                Text("References").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Picker("Project", selection: $library.filter) {
                Text("All Reading").tag("all")
                ForEach(library.projects, id: \.self) { Text($0).tag($0) }
                Text("No Project").tag("none")
            }
            .labelsHidden()
            .fixedSize()
            .onChange(of: library.filter) { _, _ in Task { await library.loadReferences() } }
            Text(counts).font(Scaled.style(11, .regular)).foregroundStyle(.tertiary)
                .lineLimit(1)
        }
    }

    private var counts: String {
        let shown = library.shown.filter { ($0["kept"] as? Bool) != false }
        let cited = shown.filter { library.backs($0["url"] as? String ?? "") > 0 }.count
        return "\(shown.count) source\(shown.count == 1 ? "" : "s") · \(cited) cited"
    }

    // MARK: References

    /// "PLA - Semester 1 - Online LaTeX Editor Overleaf (Overleaf)" -> "PLA - Semester 1"
    static func short(_ document: String) -> String {
        document.replacingOccurrences(of: #"\s*\([^)]*\)$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s*[-–|]\s*(Online LaTeX Editor )?Overleaf$"#, with: "", options: .regularExpression)
    }

    private var referencesList: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("Style", selection: $library.style) {
                    ForEach(styles, id: \.0) { Text($0.1).tag($0.0) }
                }
                .labelsHidden()
                .fixedSize()
                .onChange(of: library.style) { _, _ in Task { await library.loadReferences() } }
                // Whose references: every document's, or one (follows the document chosen in the sidebar).
                if library.documents.count > 1 || !library.document.isEmpty {
                    Picker("Document", selection: $library.document) {
                        Text("All documents").tag("")
                        ForEach(library.documents, id: \.self) { Text(Self.short($0)).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .onChange(of: library.document) { _, _ in Task { await library.loadReferences() } }
                }
                Spacer()
                Button(copied ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(library.references.joined(separator: "\n"), forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                }
                .disabled(library.references.isEmpty)
                .glassButton()
            }
            if library.references.isEmpty {
                Text("Sources appear here once they back a claim in your writing.")
                    .font(Scaled.style(12, .regular)).foregroundStyle(.secondary)
            }
            ForEach(Array(library.references.enumerated()), id: \.offset) { _, entry in
                Text(entry).font(.system(.body, design: .serif)).textSelection(.enabled)
            }
        }
    }

    // MARK: Reference check, from the Word helper

    private func findingsList(_ findings: [(document: String, issues: [(entry: String, note: String)])]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(findings, id: \.document) { audit in
                Text(audit.document).fontWeight(.semibold)
                ForEach(Array(audit.issues.enumerated()), id: \.offset) { _, issue in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(issue.note).font(Scaled.style(12, .regular)).foregroundStyle(.orange)
                        Text(issue.entry).font(.system(.caption, design: .serif)).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            }
        }
    }

    // MARK: Reading

    private var readingList: some View {
        let saved = library.shown.filter { ($0["kept"] as? Bool) != false }
        let temporary = library.shown.filter { ($0["kept"] as? Bool) == false }
        return VStack(alignment: .leading, spacing: 0) {
            if library.shown.isEmpty {
                Text(library.sources.isEmpty ? "Nothing yet. Add sources with + above, or read with the browser extension." : "Nothing matches.")
                    .font(Scaled.style(12, .regular)).foregroundStyle(.secondary)
                    .padding(.top, 24)
            }
            if !saved.isEmpty {
                FieldLabel("Saved").padding(.top, 24).padding(.bottom, 6)
                rows(saved)
            }
            if !temporary.isEmpty {
                FieldLabel("Temporary · forgotten unless saved").padding(.top, 28).padding(.bottom, 6)
                rows(temporary)
            }
        }
    }

    private func rows(_ sources: [[String: Any]]) -> some View {
        ForEach(Array(sources.enumerated()), id: \.offset) { index, source in
            if index > 0 { Hairline() }
            sourceRow(source).padding(.vertical, 10)
        }
    }

    private func sourceRow(_ source: [String: Any]) -> some View {
        let url = source["url"] as? String ?? ""
        let temporary = (source["kept"] as? Bool) == false
        let backs = library.backs(url)
        let type = source["type"] as? String == "pdf" ? "PDF" : source["type"] as? String == "video" ? "Video" : "Web page"
        let read = [source["site"] as? String, source["captured_at"] as? String].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                if renamingSource == url {
                    HStack(spacing: 6) {
                        TextField("Name", text: $sourceName)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { finishSourceRename(url) }
                        Button("Save") { finishSourceRename(url) }.glassButton()
                        Button("Cancel") { renamingSource = nil }.glassButton()
                    }
                } else {
                    HStack(spacing: 6) {
                        if let link = URL(string: url), url.hasPrefix("http") {
                            titleLink(title(source)) { NSWorkspace.shared.open(link) }
                        } else if url.hasPrefix("file://") {
                            // A PDF saved from this computer: opens in the browser like a web page, at
                            // its first page (or switches to it if it's already open).
                            titleLink(title(source)) { RefereeLinks.openSource(url, page: nil, pdf: true) }
                        } else {
                            Text(title(source)).font(Fonts.heading(15, .semibold))
                        }
                    }
                }
                if detailing == url {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("How this source appears in references. Its \\cite key stays the same.")
                            .font(Scaled.style(10, .regular)).foregroundStyle(.secondary)
                        detailField("Title", "title")
                        detailField("Authors", "author", prompt: "Surname, First; Surname, First")
                        detailField("Year", "date", prompt: "e.g. 2019")
                        detailField("Publisher", "site", prompt: "e.g. Queen Mary University of London")
                        HStack {
                            Button("Save") { library.saveDetails(url, details); detailing = nil }.glassButton()
                            Button("Cancel") { detailing = nil }.glassButton()
                        }
                    }
                    .padding(.top, 4)
                }
                if !read.isEmpty { Text(read).font(Scaled.style(10, .regular)).foregroundStyle(.secondary) }
                ForEach(Array((library.notes[url] ?? []).prefix(3).enumerated()), id: \.offset) { _, note in
                    Text("“\(note)”")
                        .font(Scaled.style(10, .regular))
                        .italic()
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .padding(.leading, 8)
                        .overlay(alignment: .leading) { Rectangle().fill(.yellow.opacity(0.6)).frame(width: 2) }
                }
                HStack(spacing: 6) {
                    if source["retracted"] as? Bool == true { tag("Retracted", colour: .red) }
                    tag(type, colour: .secondary)
                    if backs > 0 { tag("Cited \(backs)×", colour: .green) }
                    if let project = source["project"] as? String, !project.isEmpty, library.filter == "all" { tag(project, colour: .secondary) }
                }
            }
            Spacer()
            if temporary {
                Button("Save") { library.keep(url) }.glassButton()
            }
            if library.rereading.contains(url) { ProgressView().controlSize(.small) }
            Menu {
                Menu("Project") {
                    Button("No Project") { library.move(url, to: "") }
                    ForEach(library.projects, id: \.self) { name in Button(name) { library.move(url, to: name) } }
                }
                Button("Rename") { renamingSource = url; sourceName = title(source) }
                Button("Citation Details") {
                    detailing = url
                    details = ["title": source["title"] as? String ?? "", "author": source["author"] as? String ?? "",
                               "date": source["date"] as? String ?? "", "site": source["site"] as? String ?? ""]
                }
                if let key = source["cite_key"] as? String {
                    Button("Copy \\cite{\(key)}") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("\\cite{\(key)}", forType: .string)
                    }
                }
                if !temporary { Button("Read Again") { library.reread(url) } }
                if url.hasPrefix("file://"), url.lowercased().hasSuffix(".pdf"), let marked = library.notes[url], !marked.isEmpty,
                   let file = URL(string: url) {
                    Button("Save a Copy with Highlights") {
                        if let written = PDFHighlights.saveCopy(of: file, highlights: marked) {
                            let done = NSAlert()
                            done.messageText = "Saved a copy with your highlights"
                            done.informativeText = written == marked.count
                                ? "\(written) highlight\(written == 1 ? "" : "s") written in. The original PDF isn't changed."
                                : "\(written) of \(marked.count) highlights written in; the rest weren't found in the PDF's text. The original isn't changed."
                            done.runModal()
                        }
                    }
                }
                Divider()
                Button("Forget", role: .destructive) { forgetting = url }
            } label: { Image(systemName: "ellipsis") }
            .menuIndicator(.hidden)
            .menuStyle(.borderlessButton)
            .fixedSize()
            .foregroundStyle(.secondary)
            .accessibilityLabel("More")
        }
        .confirmationDialog("Forget “\(title(source))”?", isPresented: Binding(get: { forgetting == url }, set: { if !$0 { forgetting = nil } })) {
            Button("Forget", role: .destructive) { library.forget(url); forgetting = nil }
            Button("Cancel", role: .cancel) { forgetting = nil }
        } message: {
            Text("It stays in Recently Deleted for 30 days, with its highlights and the checks it backed.")
        }
    }

    /// The name shown: the person's own name for it if they gave one, else its title.
    private func title(_ source: [String: Any]) -> String {
        if let name = source["name"] as? String, !name.isEmpty { return name }
        let title = source["title"] as? String ?? source["url"] as? String ?? "Untitled"
        return title.replacingOccurrences(of: #"\s+[-|–—]\s+[^-|–—]+$"#, with: "", options: .regularExpression)
    }

    private func tag(_ text: String, colour: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(colour)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(colour.opacity(0.12), in: Capsule())
    }

    // MARK: Forget everything, behind a typed confirmation.

    private var forgetEverything: some View {
        HStack {
            Spacer()
            TextField("Type forget to confirm", text: $confirmEverything)
                .textFieldStyle(.roundedBorder)
                .frame(width: 180)
            Button("Forget All Reading") {
                library.forgetEverything()
                confirmEverything = ""
            }
            .disabled(confirmEverything.trimmingCharacters(in: .whitespaces).lowercased() != "forget")
            .foregroundStyle(.red)
            .glassButton()
        }
        .font(Scaled.style(12, .regular))
    }

    // Saved things take two clicks: the first arms the button for three seconds.
    private func detailField(_ label: String, _ key: String, prompt: String = "") -> some View {
        HStack {
            Text(label).frame(width: 70, alignment: .leading).foregroundStyle(.secondary)
            TextField(label, text: Binding(get: { details[key] ?? "" }, set: { details[key] = $0 }),
                      prompt: prompt.isEmpty ? nil : Text(prompt))
                .textFieldStyle(.roundedBorder)
        }
        .font(Scaled.style(12, .regular))
    }

    private func finishSourceRename(_ url: String) {
        library.renameSource(url, to: sourceName.trimmingCharacters(in: .whitespaces))  // empty: back to its title
        renamingSource = nil
    }

    private func twoClicks(_ key: String, action: @escaping () -> Void) {
        if armed == key {
            armed = nil
            action()
        } else {
            armed = key
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { if armed == key { armed = nil } }
        }
    }

    /// A source's title as a link. Plain text with a tap, rather than a Link or link button,
    /// which macOS centres when a long title wraps.
    private func titleLink(_ title: String, open: @escaping () -> Void) -> some View {
        // The heading font, like Notes' titles; it opens the source when clicked.
        Text(title)
            .font(Fonts.heading(15, .semibold))
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .onTapGesture(perform: open)
            // Usable with VoiceOver and the keyboard too, not only a click.
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(named: "Open") { open() }
            .onHover { inside in if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() } }
    }

    private func card<Content: View>(title: String, symbol: String, @ViewBuilder content: () -> Content) -> some View {
        // The page style: a hairline, a small capital label, then the content with no box.
        VStack(alignment: .leading, spacing: 12) {
            Hairline().padding(.bottom, 6)
            FieldLabel(title)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}


/// The sidebar project's popover: switch project, and everything about projects (new, due date,
/// which others it may cite from, rename, delete), moved here from the Library.
struct ProjectPopover: View {

    let current: String
    let projects: [String]
    let choose: (String) -> Void
    let close: () -> Void
    let setDue: () -> Void     // the due date opens as a sheet: the popover kept its first size and cut it off
    @StateObject private var library = LibraryModel()
    private enum Step { case list, new, rename, citeFrom }
    @State private var step = Step.list
    @State private var name = ""
    @State private var deleting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            switch step {
            case .list: list
            case .new: nameField("New project name", button: "Create") { choose($0); close() }
            case .rename: nameField("Project name", button: "Rename") { library.rename(current, to: $0); close() }
            case .citeFrom: citeFrom
            }
        }
        .padding(8)
        .frame(minWidth: 240)
        .onAppear { library.load() }
        .confirmationDialog("Delete “\(current)”?", isPresented: $deleting) {
            Button("Delete", role: .destructive) { library.rename(current, to: ""); close() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its sources stay, with no project.")
        }
    }

    private var list: some View {
        Group {
            ForEach([""] + projects, id: \.self) { project in
                row(project.isEmpty ? "No project" : project, check: project == current) { choose(project); close() }
            }
            Divider().padding(.vertical, 4)
            row("New Project") { name = ""; step = .new }
            if !current.isEmpty {
                row("Due Date") { close(); setDue() }
                if projects.count > 1 { row("Also Cite From") { step = .citeFrom } }
                row("Rename") { name = current; step = .rename }
                row("Archive Project") { library.archive(current, true); close() }
                row("Delete Project", destructive: true) { deleting = true }
            }
            if !library.archived.isEmpty {
                Divider().padding(.vertical, 4)
                Text("Archived").font(Scaled.style(11, .regular)).foregroundStyle(.secondary).padding(.horizontal, 10)
                ForEach(library.archived, id: \.self) { project in
                    row(project) { library.archive(project, false); choose(project); close() }
                        .help("Bring it back and make it current")
                }
            }
        }
    }

    private func row(_ title: String, check: Bool? = nil, destructive: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                if let check { Image(systemName: "checkmark").opacity(check ? 1 : 0) }
                Text(title).foregroundStyle(destructive ? Color.red : Color.primary)
                Spacer()
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func nameField(_ prompt: String, button: String, _ done: @escaping (String) -> Void) -> some View {
        HStack(spacing: 8) {
            TextField(prompt, text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit { submit(done) }
            Button(button) { submit(done) }
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(6)
    }

    private func submit(_ done: (String) -> Void) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty && trimmed != current { done(trimmed) }
    }

    private var citeFrom: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(current) can also cite references from:")
                .font(Scaled.style(12, .regular)).foregroundStyle(.secondary)
            ForEach(projects.filter { $0 != current }, id: \.self) { other in
                Toggle(other, isOn: Binding(
                    get: { library.links[current]?.contains(other) ?? false },
                    set: { on in
                        var others = library.links[current] ?? []
                        if on { others.append(other) } else { others.removeAll { $0 == other } }
                        library.setLinks(current, others)
                    }))
            }
        }
        .padding(6)
    }
}
