import AppKit
import SwiftUI

/// Reading notes, by project, each optionally linked to a saved source and page. Not a notes app:
/// a note is a line of your own tied to where it came from, so clicking it opens the source there.
/// A note: a title, a body written in Markdown with $LaTeX$ maths, the sources it's about (each at
/// a page or range of pages), and photos or files of your own.
struct Note: Codable, Identifiable, Equatable {

    struct Attachment: Codable, Equatable, Identifiable {
        var url = ""
        var page: Int?
        var to: Int?        // the last page, when it covers a range
        var id: String { "\(url)#\(page ?? 0)-\(to ?? 0)" }

        var pages: String? {
            guard let page else { return nil }
            if let to { return "pp. \(page)–\(to)" }
            return "p. \(page)"
        }
    }

    var id = UUID().uuidString
    var project = ""
    var title = ""
    var body = ""          // Markdown, with $LaTeX$ maths
    var attachments: [Attachment] = []   // the sources it's about
    var files: [String] = []             // photos and files of your own, in note-files/<id>/
    var created: Double?
    var noteFolder = ""                  // a folder of your own ("Viva prep"), for grouping

    // Missing fields are empty, so notes saved before a field existed still load.
    enum CodingKeys: String, CodingKey { case id, project, title, body, attachments, files, created, noteFolder = "folder" }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        project = try c.decodeIfPresent(String.self, forKey: .project) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        body = try c.decodeIfPresent(String.self, forKey: .body) ?? ""
        attachments = try c.decodeIfPresent([Attachment].self, forKey: .attachments) ?? []
        files = try c.decodeIfPresent([String].self, forKey: .files) ?? []
        created = try c.decodeIfPresent(Double.self, forKey: .created)
        noteFolder = try c.decodeIfPresent(String.self, forKey: .noteFolder) ?? ""
    }

    /// Where this note's photos and files are kept.
    var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Referee/note-files/\(id)", isDirectory: true)
    }

    var url: String { attachments.first?.url ?? "" }
    var page: Int? { attachments.first?.page }
}

@MainActor
final class NotesModel: ObservableObject {

    @Published var notes: [Note] = []
    @Published var sources: [(url: String, title: String, project: String, pdf: Bool)] = []
    @Published var projects: [String] = []
    @Published var filter = "all"
    @Published var loaded = false   // so "No notes yet" doesn't flash while they load
    private var current = ""
    private var pending: [String: Task<Void, Never>] = [:]

    private var query: String { filter.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "all" }

    func load() {
        Task {
            if let settings = await API.get("settings") {
                projects = settings["projects"] as? [String] ?? []
                current = settings["project"] as? String ?? ""
                if filter == "all" && !current.isEmpty { filter = current }
            }
            sources = await API.getList("sources").compactMap { s in
                guard let url = s["url"] as? String else { return nil }
                let title = [s["name"], s["title"]].compactMap { $0 as? String }.first { !$0.isEmpty } ?? url
                let pdf = s["type"] as? String == "pdf" || url.lowercased().hasSuffix(".pdf")
                return (url, title, s["project"] as? String ?? "", pdf)
            }
            await reload()
        }
    }

    func reload() async {
        guard let data = await API.request("notes?project=\(query)"),
              let found = try? JSONDecoder().decode([Note].self, from: data) else { return }
        notes = found
        loaded = true
    }

    /// The sources a note in this project can link to: the project's own first, then the rest.
    func sourcesFor(_ project: String) -> [(url: String, title: String, project: String, pdf: Bool)] {
        sources.filter { $0.project == project } + sources.filter { $0.project != project }
    }

    func title(_ url: String) -> String { sources.first { $0.url == url }?.title ?? url }

    /// The project new and imported notes go into: the one shown, or the current one.
    var importProject: String { filter == "all" ? current : filter == "none" ? "" : filter }

    func add() {
        var note = Note()
        note.project = importProject
        notes.append(note)
        save(note, now: true)
    }

    func save(_ note: Note, now: Bool = false) {
        if let index = notes.firstIndex(where: { $0.id == note.id }) { notes[index] = note }
        pending[note.id]?.cancel()
        pending[note.id] = Task {
            if !now { try? await Task.sleep(nanoseconds: 600_000_000) }
            guard !Task.isCancelled, let body = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(note)) as? [String: Any] else { return }
            _ = await API.post("notes", body)
        }
    }

    func delete(_ id: String) {
        notes.removeAll { $0.id == id }
        Task {
            _ = await API.delete("notes?id=\(id)")
            NotificationCenter.default.post(name: .refereeDeleted, object: nil)   // offers Undo
        }
    }

    /// Opens a note's first source at its page.
    func open(_ note: Note) {
        if let first = note.attachments.first { open(first) }
    }

    func open(_ attachment: Note.Attachment) {
        let pdf = sources.first { $0.url == attachment.url }?.pdf ?? attachment.url.lowercased().hasSuffix(".pdf")
        RefereeLinks.openSource(attachment.url, page: attachment.page, pdf: pdf)
    }
}

/// referee:// links, to paste into a planner, Todoist or anywhere else; clicking one opens Referee
/// right there:
///     referee://note/<id>                       a note's source at its page (or Notes)
///     referee://meeting/<id>                    that meeting in Meetings
///     referee://source?url=<url>&page=<n>       a saved source at a page
@MainActor enum RefereeLinks {

    static func note(_ id: String) -> String { "referee://note/\(id)" }
    static func meeting(_ id: String) -> String { "referee://meeting/\(id)" }

    static func copy(_ link: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(link, forType: .string)
    }

    static func handle(_ url: URL) {
        guard url.scheme == "referee" else { return }
        let id = url.pathComponents.dropFirst().first ?? ""
        switch url.host {
        case "find":
            // Referee's search, opened from elsewhere (Raycast) with the words already typed.
            let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "q" }?.value ?? ""
            Floating.close("find")
            Floating.show("find", width: 900) { FindView(initial: q) }
        case "capture":
            // Referee's quick capture, opened from elsewhere (Raycast): referee://capture?kind=link
            let kind = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "kind" }?.value
            Floating.close("capture")
            Capture.show(kind == "link" ? .link : kind == "ai-use" ? .aiUse : .note)
        case "meeting":
            Windows.open("meetings")
            // The window may still be opening: ask again shortly, and its model picks it up.
            for delay in [0.3, 1.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    NotificationCenter.default.post(name: .refereeShowMeeting, object: id)
                }
            }
        case "note":
            Task {
                guard let data = await API.request("notes"),
                      let note = (try? JSONDecoder().decode([Note].self, from: data))?.first(where: { $0.id == id }),
                      !note.url.isEmpty else { Windows.open("notes"); return }
                let source = await API.getList("sources").first { $0["url"] as? String == note.url }
                openSource(note.url, page: note.page, pdf: source?["type"] as? String == "pdf" || note.url.lowercased().hasSuffix(".pdf"))
            }
        case "source":
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            guard let target = items.first(where: { $0.name == "url" })?.value else { return }
            let page = items.first(where: { $0.name == "page" })?.value.flatMap(Int.init)
            openSource(target, page: page, pdf: target.lowercased().hasSuffix(".pdf") || target.hasPrefix("file://"))
        default:
            Windows.open("library")
        }
    }

    /// Opens a saved source at a page, in the default browser, which honours "#page=" for PDFs where
    /// Preview doesn't. If the PDF is already open in a tab, the extension switches to it instead.
    static func openSource(_ address: String, page: Int?, pdf: Bool) {
        guard !address.isEmpty else { return }
        var target: URL?
        if pdf {
            // Through Referee's /open page: the browser extension switches to the PDF if it's
            // already open, at the page; otherwise the page opens it. It also keeps "#page=",
            // which macOS drops from file:// links.
            var parts = URLComponents(string: "http://localhost:8000/open")!
            parts.queryItems = [URLQueryItem(name: "url", value: address)] + (page.map { [URLQueryItem(name: "page", value: String($0))] } ?? [])
            target = parts.url
        } else {
            target = address.hasPrefix("file://") ? URL(fileURLWithPath: String(address.dropFirst("file://".count))) : URL(string: address)
        }
        guard let target else { return }
        if let browser = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!) {
            NSWorkspace.shared.open([target], withApplicationAt: browser, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(target)
        }
    }
}

extension Notification.Name {
    static let refereeDeleted = Notification.Name("refereeDeleted")
    static let refereeShowMeeting = Notification.Name("refereeShowMeeting")
}

struct NotesView: View {

    @StateObject private var model = NotesModel()
    @State private var importingNotes = false
    @State private var choosingImport = false
    @State private var imported: String?
    @AppStorage("notesOrder") private var order = "added"   // "added", "page" or "title"
    @State private var topics: [String: String] = [:]          // note id -> topic, sorted by Claude
    // Filters: the sources, topics and folders ticked ("source:<url>", "topic:<name>", "folder:<name>").
    // Within a kind, a note matches any one ticked; across kinds, it must match each. Nothing ticked: every note.
    @State private var chosen: Set<String> = []
    @State private var filtering = false

    private func savedFilters(_ project: String) -> Set<String> {
        Set((UserDefaults.standard.stringArray(forKey: "notesFilters.\(project)") ?? []))
    }

    private func saveFilters(_ filters: Set<String>) {
        UserDefaults.standard.set(Array(filters), forKey: "notesFilters.\(model.filter)")
    }

    private func ticked(_ kind: String) -> Set<String> {
        Set(chosen.filter { $0.hasPrefix(kind + ":") }.map { String($0.dropFirst(kind.count + 1)) })
    }

    private var shown: [Note] {
        let sources = ticked("source"), topicNames = ticked("topic"), folders = ticked("folder")
        return ordered.filter { note in
            (sources.isEmpty || note.attachments.contains { sources.contains($0.url) })
                && (topicNames.isEmpty || topics[note.id].map(topicNames.contains) == true)
                && (folders.isEmpty || folders.contains(note.noteFolder))
        }
    }

    /// The filter button's label: "All notes", the one thing ticked, or how many.
    private var filterLabel: String {
        if chosen.isEmpty { return "All notes" }
        if chosen.count == 1, let one = chosen.first {
            let value = String(one.split(separator: ":", maxSplits: 1).last ?? "")
            return one.hasPrefix("source:") ? model.sources.first { $0.url == value }?.title ?? value : value
        }
        return "\(chosen.count) filters"
    }

    private func loadTopics() {
        Task {
            let p = model.filter.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "all"
            topics = (await API.request("notes/topics?project=\(p)", timeout: 60))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] } ?? [:]
        }
    }

    private var filterButton: some View {
        Button { filtering = true; loadTopics() } label: {
            HStack(spacing: 6) {
                Image(systemName: chosen.isEmpty ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                Text(filterLabel).lineLimit(1)
            }
        }
        .fixedSize()
        .help("Show only notes on chosen sources, topics or folders")
        .popover(isPresented: $filtering, arrowEdge: .bottom) {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    let sources = Set(model.notes.flatMap { $0.attachments.map(\.url) })
                    filterGroup("Sources", model.sources.filter { sources.contains($0.url) }.map { ("source:" + $0.url, $0.title) })
                    filterGroup("Topics", Set(topics.values).sorted().map { ("topic:" + $0, $0) },
                                empty: topics.isEmpty ? "Sorting into topics…" : nil)
                    filterGroup("Folders", Set(model.notes.map(\.noteFolder).filter { !$0.isEmpty }).sorted().map { ("folder:" + $0, $0) },
                                empty: "Right-click a note → Move to Folder")
                    if !chosen.isEmpty {
                        Divider().padding(.vertical, 4)
                        Button("Show All Notes") { chosen = [] }.buttonStyle(.borderless)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)   // left-aligned from the start, not centred
            }
            .frame(width: 320)
            .frame(maxHeight: 460)
        }
    }

    @ViewBuilder
    private func filterGroup(_ title: String, _ items: [(String, String)], empty: String? = nil) -> some View {
        FieldLabel(title).padding(.top, 6)
        if items.isEmpty, let empty {
            Text(empty).font(Scaled.style(11, .regular)).foregroundStyle(.secondary)
        }
        ForEach(items, id: \.0) { key, name in
            Toggle(name, isOn: Binding(get: { chosen.contains(key) },
                                       set: { if $0 { chosen.insert(key) } else { chosen.remove(key) } }))
                .lineLimit(1)
        }
    }

    /// The notes in the order chosen: newest first; by source and then page; or A to Z.
    private var ordered: [Note] {
        switch order {
        case "page":
            let title = { (url: String) in model.sources.first { $0.url == url }?.title ?? url }
            return model.notes.sorted {
                if $0.url.isEmpty != $1.url.isEmpty { return !$0.url.isEmpty }   // notes without a source last
                return (title($0.url).lowercased(), $0.page ?? Int.max) < (title($1.url).lowercased(), $1.page ?? Int.max)
            }
        case "title":
            return model.notes.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        default:
            return model.notes.sorted { ($0.created ?? 0) > ($1.created ?? 0) }
        }
    }

    var body: some View {
        Group {
        if model.notes.isEmpty && model.loaded {
            EmptyPage(symbol: "doc.text", title: "No notes yet",
                      message: "Notes on what you've read, each linked to the page it's about. Import them from Apple Notes or a Markdown folder with the button at the top.",
                      action: ("New Note", { model.add() }))
        } else {
        Page {
            // Wraps onto a second line in a narrow window rather than running off the page.
            WrappingRow(spacing: 10, lineSpacing: 8) {
                Picker("Project", selection: $model.filter) {
                    Text("All projects").tag("all")
                    ForEach(model.projects, id: \.self) { Text($0).tag($0) }
                    Text("No project").tag("none")
                }
                .labelsHidden()
                .fixedSize()
                filterButton
                Picker("Sort", selection: $order) {
                    Text("Newest first").tag("added")
                    Text("By page").tag("page")
                    Text("A to Z").tag("title")
                }
                .labelsHidden()
                .fixedSize()
                .help("Sort notes by when they were added, by source and page, or by title")
            }
            .padding(.bottom, 8)
            if shown.isEmpty && !chosen.isEmpty {
                Text("No notes match these filters.").foregroundStyle(.secondary).padding(.top, 16)
            }
            ForEach(shown) { note in
                Hairline()
                NoteRow(model: model, note: note).id(note.id)
            }
        }
        }
        }
        .onAppear { model.load() }
        // The filters are remembered for each project, and come back when you return to Notes.
        .onChange(of: model.filter) { _, project in chosen = savedFilters(project); Task { await model.reload() } }
        .onChange(of: chosen) { _, now in saveFilters(now) }
        .onAppear { chosen = savedFilters(model.filter); if !ticked("topic").isEmpty { loadTopics() } }
        .onChange(of: model.notes.count) { _, _ in if !ticked("topic").isEmpty { loadTopics() } }
        .pageActions { HStack(spacing: 14) {
            // As in every page: other actions, then the bin, then + at the end.
            importMenu
            RecentlyDeletedButton(kind: "note", project: model.filter, inHeader: true) { Task { await model.reload() } }
            addButton
        } }
        .sheet(isPresented: $importingNotes) {
            AppleNotesImportSheet(project: model.importProject) { summary in
                imported = summary
                Task { await model.reload() }
            }
        }
        .alert(imported ?? "", isPresented: Binding(get: { imported != nil }, set: { if !$0 { imported = nil } })) {
            Button("OK") {}
        }
    }

    /// A plain button (a menu's icon is drawn heavier than the header's other buttons), opening a
    /// small list of where to import from.
    private var importMenu: some View {
        Button { choosingImport = true } label: { HeaderIcon("square.and.arrow.down") }
            .buttonStyle(.borderless)
            .help("Import notes")
            .popover(isPresented: $choosingImport, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 6) {
                    Button("From Apple Notes…") { choosingImport = false; importingNotes = true }
                    Button("From a Markdown Folder…") { choosingImport = false; importFolder() }
                }
                .buttonStyle(.plain)
                .padding(12)
                .fixedSize()   // the same small list as every header popover
            }
    }

    /// Every .md file in a folder (and its subfolders), such as an Obsidian vault.
    private func importFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Import"
        panel.message = "Choose a folder of Markdown notes, such as an Obsidian vault."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            let result = await API.post("notes/import", ["project": model.importProject, "folder": url.path], timeout: 120)
            imported = NoteImport.summary(result)
            await model.reload()
        }
    }

    private var addButton: some View {
        Button { model.add() } label: { HeaderIcon("plus") }
            .buttonStyle(.borderless)
            .help("New note")
    }
}

struct NoteRow: View {

    @ObservedObject var model: NotesModel
    @State var note: Note
    @State private var armed = false   // asking "are you sure" before deleting
    @State private var namingFolder = false
    @State private var feedback: String?   // Claude's check of your summary
    @State private var newFolder = ""
    @State private var choosingSource = false
    @State private var editing = false
    @FocusState private var editingBody: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                TextField("Title", text: $note.title, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(Fonts.heading(18, .semibold))
                    .lineLimit(1...3)
                HistoryButton(id: note.id, name: note.title)
            }
            // The note itself: written as Markdown (paragraphs, - bullets, 1. lists, # headings,
            // $maths$), shown formatted when you're not editing it. Click it to edit.
            Group {
                if editing || note.body.isEmpty {
                    TextField("Write anything: paragraphs, - bullets, 1. numbered lists, # headings, $maths$",
                              text: $note.body, axis: .vertical)
                        .paragraphs()
                        .textFieldStyle(.plain)
                        .font(.system(size: Scaled.s(13), design: .monospaced))
                        .lineSpacing(3)
                        .lineLimit(1...)
                        .focused($editingBody)
                        .onChange(of: editingBody) { _, focused in if !focused { editing = false } }
                } else {
                    MarkdownView(text: note.body, sources: note.attachments.map(\.url))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture { editing = true; editingBody = true }
                        // Usable with VoiceOver and the keyboard too, not only a click.
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction(named: "Edit note") { editing = true; editingBody = true }
                        .help("Click to edit")
                }
            }
            .padding(.top, 4)

            // Sources: the saved sources it's about, at their pages.
            VStack(alignment: .leading, spacing: 3) {
                ForEach($note.attachments) { $source in
                    SourceLine(model: model, source: $source) { note.attachments.removeAll { $0.id == source.id } }
                }
                HStack(spacing: 14) {
                    Button { choosingSource = true } label: { Label("Link a source", systemImage: "book.closed").font(Scaled.style(12, .regular)) }
                        .popover(isPresented: $choosingSource) { sourcePicker }
                    Button { attachFiles() } label: { Label("Attach", systemImage: "paperclip").font(Scaled.style(12, .regular)) }
                        .help("Add photos or files of your own")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .padding(.top, 2)
            }
            .padding(.top, 8)

            // Photos and files of your own.
            if !note.files.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(note.files, id: \.self) { name in
                            FileThumbnail(url: note.folder.appendingPathComponent(name)) {
                                try? FileManager.default.removeItem(at: note.folder.appendingPathComponent(name))
                                note.files.removeAll { $0 == name }
                            }
                        }
                    }
                }
                .padding(.top, 6)
            }
        }
        .padding(.vertical, 16)
        .contentShape(Rectangle())
        .contextMenu {
            if !note.attachments.isEmpty { Button("Open Source") { model.open(note) } }
            Button("Check My Summary") { checkSummary() }
                .help("Claude compares what you wrote with the passage, and says what's wrong or missing, without rewriting it")
            Button("Copy Link") { RefereeLinks.copy(RefereeLinks.note(note.id)) }
            Menu("Move to Folder") {
                ForEach(Array(Set(model.notes.map(\.noteFolder).filter { !$0.isEmpty })).sorted(), id: \.self) { name in
                    Button { note.noteFolder = name } label: {
                        if note.noteFolder == name { Label(name, systemImage: "checkmark") } else { Text(name) }
                    }
                }
                Button("New Folder…") { newFolder = ""; namingFolder = true }
                if !note.noteFolder.isEmpty {
                    Divider()
                    Button("Remove from Folder") { note.noteFolder = "" }
                }
            }
            Divider()
            Button("Delete…", role: .destructive) { armed = true }
        }
        .alert("New Folder", isPresented: $namingFolder) {
            TextField("Folder name", text: $newFolder)
            Button("Move") {
                let name = newFolder.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { note.noteFolder = name }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Moves “\(note.title.isEmpty ? "this note" : note.title)” into a new folder.")
        }
        .alert("Your summary", isPresented: Binding(get: { feedback != nil }, set: { if !$0 { feedback = nil } })) {
            Button("OK") {}
        } message: {
            Text(feedback ?? "")
        }
        .confirmationDialog("Delete this note?", isPresented: $armed) {
            Button("Delete", role: .destructive) {
                model.delete(note.id)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It stays in Recently Deleted for 30 days.")
        }
        .onChange(of: note) { _, changed in model.save(changed) }
    }

    private func checkSummary() {
        model.save(note, now: true)
        Task {
            feedback = "Checking…"
            let reply = await API.post("notes/check", ["id": note.id], timeout: 40)
            feedback = reply?["feedback"] as? String ?? "Couldn't check it: Referee's server didn't answer."
        }
    }

    private var sourcePicker: some View {
        VStack(alignment: .leading, spacing: 0) {
            FieldLabel("Link a source").foregroundStyle(.secondary).padding(.bottom, 6)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(model.sourcesFor(note.project), id: \.url) { source in
                        Button {
                            note.attachments.append(Note.Attachment(url: source.url))
                            choosingSource = false
                        } label: {
                            // Plain text: the blue of the "Link a source" button opening this list isn't carried in.
                            Text(source.title).lineLimit(1).foregroundStyle(.primary).frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 5).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Hairline()
                    }
                }
            }
            .frame(maxHeight: 280)
        }
        .padding(12)
        .frame(width: 320)
    }

    /// Copies chosen photos or files into the note's folder.
    private func attachFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "Attach"
        guard panel.runModal() == .OK else { return }
        try? FileManager.default.createDirectory(at: note.folder, withIntermediateDirectories: true)
        for url in panel.urls {
            var name = url.lastPathComponent
            var n = 2
            while note.files.contains(name) {
                name = "\(url.deletingPathExtension().lastPathComponent) \(n).\(url.pathExtension)"; n += 1
            }
            if (try? FileManager.default.copyItem(at: url, to: note.folder.appendingPathComponent(name))) != nil {
                note.files.append(name)
            }
        }
    }
}

/// A source the note is about: the book icon, its name (click to open at the page), and its pages.
struct SourceLine: View {

    @ObservedObject var model: NotesModel
    @Binding var source: Note.Attachment
    let remove: () -> Void
    @State private var editingPages = false
    // Typed here and only saved when the popover closes (or Return is pressed), not at each digit.
    @State private var from = ""
    @State private var to = ""

    private func savePages() {
        let first = Int(from.filter(\.isNumber)), last = Int(to.filter(\.isNumber))
        if source.page != first { source.page = first }
        if source.to != last { source.to = last }
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "book.closed").font(.system(size: Scaled.s(11))).foregroundStyle(Color.accentColor)
            Button { model.open(source) } label: { Text(model.title(source.url)).lineLimit(1) }
                .buttonStyle(.plain)
                .help(source.pages.map { "Open at \($0)" } ?? "Open the source")
            Text("·").foregroundStyle(.tertiary)
            // The pages as plain text ("pp. 50–51"); click them to change.
            Button {
                from = source.page.map(String.init) ?? ""
                to = source.to.map(String.init) ?? ""
                editingPages = true
            } label: {
                Text(source.pages ?? "add pages").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Change the pages")
            .popover(isPresented: $editingPages) {
                HStack(spacing: 6) {
                    Text("Pages")
                    TextField("from", text: $from).textFieldStyle(.roundedBorder).frame(width: 52)
                        .onSubmit { editingPages = false }
                    Text("to")
                    TextField("to", text: $to).textFieldStyle(.roundedBorder).frame(width: 52)
                        .onSubmit { editingPages = false }
                }
                .padding(12)
            }
            .onChange(of: editingPages) { _, open in if !open { savePages() } }
            Button(action: remove) { Image(systemName: "xmark").font(.system(size: Scaled.s(9))) }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .help("Unlink this source")
        }
        .font(Scaled.style(12, .regular))
        .foregroundStyle(.secondary)
    }
}

/// A photo or file attached to a note: a thumbnail that opens it, with a cross to remove it.
struct FileThumbnail: View {

    let url: URL
    let remove: () -> Void
    @State private var hovering = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button { NSWorkspace.shared.open(url) } label: {
                Group {
                    if let image = NSImage(contentsOf: url) {
                        Image(nsImage: image).resizable().scaledToFill()
                    } else {
                        VStack(spacing: 4) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 28, height: 28)
                            Text(url.lastPathComponent).font(.system(size: Scaled.s(9))).lineLimit(2).multilineTextAlignment(.center)
                        }
                        .padding(6)
                    }
                }
                .frame(width: 84, height: 64)
                .background(Color.primary.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.plain)
            .help(url.lastPathComponent)
            if hovering {
                Button(action: remove) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.white, .black.opacity(0.6))
                }
                .buttonStyle(.plain)
                .padding(3)
            }
        }
        .onHover { hovering = $0 }
    }
}

