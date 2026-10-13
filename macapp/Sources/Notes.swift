import AppKit
import SwiftUI

/// Reading notes, by project, each optionally linked to a saved source and page. Not a notes app:
/// a note is a line of your own tied to where it came from, so clicking it opens the source there.
struct Note: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var project = ""
    var text = ""
    var url = ""
    var page: Int?
    var created: Double?
}

@MainActor
final class NotesModel: ObservableObject {

    @Published var notes: [Note] = []
    @Published var sources: [(url: String, title: String, project: String, pdf: Bool)] = []
    @Published var projects: [String] = []
    @Published var filter = "all"
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
                let title = (s["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? url
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
    }

    /// The sources a note in this project can link to: the project's own first, then the rest.
    func sourcesFor(_ project: String) -> [(url: String, title: String, project: String, pdf: Bool)] {
        sources.filter { $0.project == project } + sources.filter { $0.project != project }
    }

    func title(_ url: String) -> String { sources.first { $0.url == url }?.title ?? url }

    func add() {
        var note = Note()
        note.project = filter == "all" ? current : filter == "none" ? "" : filter
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
        Task { _ = await API.delete("notes?id=\(id)") }
    }

    /// Opens a note's source at its page.
    func open(_ note: Note) {
        let pdf = sources.first { $0.url == note.url }?.pdf ?? note.url.lowercased().hasSuffix(".pdf")
        RefereeLinks.openSource(note.url, page: note.page, pdf: pdf)
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

    /// Opens a saved source at a page, in the default browser: browsers honour "#page=" for PDFs,
    /// saved files and links alike, where Preview doesn't.
    static func openSource(_ address: String, page: Int?, pdf: Bool) {
        guard !address.isEmpty else { return }
        let link = address.hasPrefix("file://") ? URL(fileURLWithPath: String(address.dropFirst("file://".count))) : URL(string: address)
        guard var target = link else { return }
        if let page, pdf, var parts = URLComponents(url: target, resolvingAgainstBaseURL: false) {
            parts.fragment = "page=\(page)"
            target = parts.url ?? target
        }
        if let browser = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!) {
            NSWorkspace.shared.open([target], withApplicationAt: browser, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(target)
        }
    }
}

extension Notification.Name {
    static let refereeShowMeeting = Notification.Name("refereeShowMeeting")
}

struct NotesView: View {

    @StateObject private var model = NotesModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Notes").font(.title2.weight(.semibold))
                Spacer()
                Picker("Project", selection: $model.filter) {
                    Text("All Projects").tag("all")
                    ForEach(model.projects, id: \.self) { Text($0).tag($0) }
                    Text("No Project").tag("none")
                }
                .labelsHidden()
                .fixedSize()
                Button { model.add() } label: { Label("New Note", systemImage: "plus") }.glassButton()
            }
            .padding(.top, 28)
            if model.notes.isEmpty {
                Text("Notes on what you've read, each linked to the page it's about. Click a note's arrow to open the source at that page.")
                    .foregroundStyle(.secondary)
                    .padding(.top, 20)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(model.notes) { note in
                            NoteRow(model: model, note: note).id(note.id)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 20)
        .frame(minWidth: 620, idealWidth: 700, minHeight: 440, idealHeight: 620)
        .background(WindowGlass().ignoresSafeArea())
        .onAppear { model.load() }
        .onChange(of: model.filter) { _, _ in Task { await model.reload() } }
    }
}

struct NoteRow: View {

    @ObservedObject var model: NotesModel
    @State var note: Note
    @State private var armed = false
    @State private var copied = false

    private var pageText: Binding<String> {
        Binding(get: { note.page.map(String.init) ?? "" },
                set: { note.page = Int($0.filter(\.isNumber)) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                TextField("Note", text: $note.text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...6)
                Button { RefereeLinks.copy(RefereeLinks.note(note.id)); copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
                } label: { Image(systemName: copied ? "checkmark" : "link") }
                    .buttonStyle(.borderless)
                    .help("Copy a link to this note, for your planner or to-do list")
                if !note.url.isEmpty {
                    Button { model.open(note) } label: { Image(systemName: "arrow.up.right.square") }
                        .buttonStyle(.borderless)
                        .help(note.page.map { "Open at page \($0)" } ?? "Open the source")
                }
                Button {
                    if armed { model.delete(note.id) } else {
                        armed = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { armed = false }
                    }
                } label: { Image(systemName: "xmark").foregroundStyle(armed ? .red : .secondary) }
                    .buttonStyle(.borderless)
                    .help(armed ? "Click again to delete" : "Delete")
            }
            HStack(spacing: 8) {
                Menu {
                    Button("No source") { note.url = ""; note.page = nil }
                    Divider()
                    ForEach(model.sourcesFor(note.project), id: \.url) { source in
                        Button(source.title) { note.url = source.url }
                    }
                } label: {
                    Text(note.url.isEmpty ? "Link a source" : model.title(note.url)).lineLimit(1)
                }
                .menuStyle(.borderlessButton)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 360, alignment: .leading)
                if !note.url.isEmpty {
                    Text("page").foregroundStyle(.secondary).font(.callout)
                    TextField("", text: pageText).textFieldStyle(.roundedBorder).frame(width: 56)
                }
                Spacer()
                if model.filter == "all" && !note.project.isEmpty {
                    Text(note.project).font(.caption).foregroundStyle(.secondary)
                }
            }
            .font(.callout)
        }
        .padding(12)
        .glassCard()
        .onChange(of: note) { _, changed in model.save(changed) }
    }
}
