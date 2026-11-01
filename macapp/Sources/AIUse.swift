import AppKit
import SwiftUI

/// A running record of AI use, by project, and the declaration drafted from it. The draft is
/// assembled from the entries by the server with a fixed template, not written by AI.
struct AIUse: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var project = ""
    var date = Meeting.today
    var tool = ""
    var version = ""
    var purpose = ""
    var prompt = ""
    var response = ""
    var checked = ""
    var created: Double?
    var order: Double?       // set when moved within its day; higher is nearer the top

    var rank: Double { order ?? created ?? 0 }
    var day: String { Meeting(date: date).day }

    /// Nothing written yet: a draft, which always shows today's date.
    var isBlank: Bool {
        [tool, version, purpose, prompt, response, checked].allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}


@MainActor
final class AIUseModel: ObservableObject {

    @Published var entries: [AIUse] = []
    @Published var projects: [String] = []
    @Published var filter = "all"
    // Remembered, so Referee reopens on the entry you had open.
    @Published var selected: String? = UserDefaults.standard.string(forKey: "lastAIUse") {
        didSet { if let selected { UserDefaults.standard.set(selected, forKey: "lastAIUse") } }
    }
    @Published var declaration = ""
    @Published var preset = "custom"         // this project's template: "paragraph" or "custom" (its own wording)
    @Published var used = ""                 // its wording when AI was used, with {tools} and so on
    @Published var unused = ""               // and when it wasn't
    private var current = ""
    private var pending: Task<Void, Never>?

    private var query: String { filter.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "all" }

    func load() {
        Task {
            if let settings = await API.get("settings") {
                projects = settings["projects"] as? [String] ?? []
                current = settings["project"] as? String ?? ""
                if filter == "all" && !current.isEmpty { filter = current }  // follow the main window's project
            }
            await reload()
        }
    }

    func reload() async {
        guard let data = await API.request("ai-log?project=\(query)"),
              let found = try? JSONDecoder().decode([AIUse].self, from: data) else { return }
        entries = found
        // Blank drafts left from an earlier day move to today, as in Meetings.
        for (index, entry) in entries.enumerated() where entry.isBlank && entry.date != Meeting.today {
            entries[index].date = Meeting.today
            if let body = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(entries[index])) as? [String: Any] {
                _ = await API.post("ai-log", body)
            }
        }
        if selected == nil || !entries.contains(where: { $0.id == selected }) { selected = entries.first?.id }
        await draft()
    }

    func draft() async {
        let found = await API.getPath("ai-log/declaration?project=\(query)") ?? [:]
        declaration = found["text"] as? String ?? ""
        preset = found["preset"] as? String ?? "custom"
        used = found["used"] as? String ?? ""
        unused = found["unused"] as? String ?? ""
    }

    /// Sets this project's template: a preset as it is, or custom wording.
    func setTemplate(_ preset: String, used: String = "", unused: String = "") {
        Task {
            _ = await API.post("ai-log/template", ["project": filter, "preset": preset, "used": used, "unused": unused])
            await draft()
        }
    }

    func add() {
        var entry = AIUse()
        entry.created = Date().timeIntervalSince1970   // newest of its day, so it's at the end the list adds to
        entry.project = filter == "all" ? current : filter == "none" ? "" : filter
        entries.insert(entry, at: 0)
        selected = entry.id
        save(entry, now: true)
    }

    /// Newest day first, then the order within a day, as the server sorts them.
    private func sort() {
        entries.sort { $0.date != $1.date ? $0.date > $1.date : $0.rank > $1.rank }
    }

    /// The entry next to this one on the same day, above (-1) or below (1), if there is one.
    func neighbour(of entry: AIUse, _ step: Int) -> AIUse? {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }),
              entries.indices.contains(index + step), entries[index + step].date == entry.date else { return nil }
        return entries[index + step]
    }

    /// Swaps an entry with its neighbour on the same day.
    func move(_ entry: AIUse, _ step: Int) {
        guard var other = neighbour(of: entry, step) else { return }
        var moved = entry
        (moved.order, other.order) = (other.rank, entry.rank)
        if moved.order == other.order { moved.order = other.rank - Double(step) }
        for changed in [moved, other] {
            if let index = entries.firstIndex(where: { $0.id == changed.id }) { entries[index] = changed }
            if let body = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(changed)) as? [String: Any] {
                Task { _ = await API.post("ai-log", body) }
            }
        }
        sort()
    }

    /// Drops one entry just above another on the same day.
    /// Drops one entry onto another on the same day: dragged down, it goes below it; dragged up, above.
    /// `flipped` when the list is shown oldest first.
    func place(_ id: String, onto target: AIUse, flipped: Bool = false) {
        let shown = flipped ? Array(entries.reversed()) : entries
        guard id != target.id, var moved = entries.first(where: { $0.id == id }), moved.date == target.date,
              let from = shown.firstIndex(where: { $0.id == id }), let to = shown.firstIndex(where: { $0.id == target.id }) else { return }
        let others = shown.filter { $0.id != id }
        guard let at = others.firstIndex(where: { $0.id == target.id }) else { return }
        let side = from < to ? 1 : -1                   // after the target on screen, or before it
        let beside = others.indices.contains(at + side) && others[at + side].date == target.date ? others[at + side] : nil
        // On screen, ranks fall going down (newest first) or rise (oldest first).
        let down: Double = flipped ? 1 : -1
        moved.order = beside.map { ($0.rank + target.rank) / 2 } ?? target.rank + Double(side) * down
        if let index = entries.firstIndex(where: { $0.id == id }) { entries[index] = moved }
        if let body = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(moved)) as? [String: Any] {
            Task { _ = await API.post("ai-log", body) }
        }
        sort()
    }

    func save(_ entry: AIUse, now: Bool = false) {
        if let index = entries.firstIndex(where: { $0.id == entry.id }) { entries[index] = entry; sort() }
        pending?.cancel()
        pending = Task {
            if !now { try? await Task.sleep(nanoseconds: 700_000_000) }
            guard !Task.isCancelled, let body = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as? [String: Any] else { return }
            _ = await API.post("ai-log", body)
            await draft()
        }
    }

    func delete(_ id: String) {
        entries.removeAll { $0.id == id }
        selected = entries.first?.id
        Task {
            _ = await API.delete("ai-log?id=\(id)")
            NotificationCenter.default.post(name: .refereeDeleted, object: nil)   // offers Undo
            await draft()
        }
    }

    func export(_ format: String) async -> String? {
        guard let data = await API.request("ai-log/export?project=\(query)&format=\(format)", timeout: 10) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

struct AIUseView: View {

    @StateObject private var model = AIUseModel()
    @State private var armed = false
    @State private var copied = ""
    @State private var showDeclaration = false
    @State private var showReflection = false
    @State private var renaming: AIUse?
    @State private var newName = ""
    @State private var renames = 0
    @State private var deleting: String?   // the entry waiting for "are you sure"
    @AppStorage("aiUseOldestFirst") private var oldestFirst = false

    var body: some View {
        // The list: about a third of the page, 180 to 240 points, so the entry always has most of it.
        GeometryReader { space in
        HStack(spacing: 0) {
            sidebar.frame(width: min(240, max(180, space.size.width * 0.32)))
            Divider().opacity(0.4)
            if showDeclaration {
                declaration
            } else if showReflection {
                ReflectionView(project: model.filter, entries: model.entries).id(model.filter)
            } else if let entry = model.entries.first(where: { $0.id == model.selected }) {
                AIUseEditor(model: model, entry: entry, armed: $armed).id("\(entry.id)-\(renames)")  // reloaded after a rename
            } else {
                EmptyPage(symbol: "sparkles", title: "No AI use logged",
                          message: "Note each use of an AI tool as it happens: what you used it for, and how you checked what it gave you. Your disclosure is drafted from these.",
                          action: ("Log AI Use", { model.add() }))
            }
        }
        }
        .onAppear { model.load() }
        .onChange(of: model.filter) { _, _ in Task { await model.reload() } }
        .onChange(of: model.selected) { _, _ in showDeclaration = false; showReflection = false }
        .pageActions { HStack(spacing: 14) { RecentlyDeletedButton(kind: "ai-use", project: model.filter, inHeader: true) { Task { await model.reload() } }; addButton } }
        .confirmationDialog("Delete this entry?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete", role: .destructive) { if let id = deleting { model.delete(id) }; deleting = nil }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: {
            Text("It stays in Recently Deleted for 30 days.")
        }
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("What you used it for", text: $newName)
            Button("Rename") {
                if var entry = renaming { entry.purpose = newName; model.save(entry, now: true); renames += 1 }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }

    private var up: Int { oldestFirst ? 1 : -1 }   // a step up the list as shown

    private var addButton: some View {
        Button { showDeclaration = false; showReflection = false; model.add() } label: { HeaderIcon("plus") }
            .buttonStyle(.borderless)
            .help("Log AI use")
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Project", selection: $model.filter) {
                Text("All Projects").tag("all")
                ForEach(model.projects, id: \.self) { Text($0).tag($0) }
                Text("No Project").tag("none")
            }
            .labelsHidden()
            .padding(.top, 12)
            OrderPicker(oldestFirst: $oldestFirst)
            Button { showReflection = false; showDeclaration = true; Task { await model.draft() } } label: {
                Label("Disclosure", systemImage: "checkmark.seal").frame(maxWidth: .infinity, alignment: .leading)
            }
            .glassButton()
            Button { showDeclaration = false; showReflection = true } label: {
                Label("Reflection", systemImage: "pencil.line").frame(maxWidth: .infinity, alignment: .leading)
            }
            .glassButton()
            // Rows drawn by Referee, full width and in line with the buttons above, at any width.
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(oldestFirst ? model.entries.reversed() : model.entries) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.purpose.isEmpty ? "AI use" : entry.purpose).font(Fonts.heading(15, .semibold)).lineLimit(2)
                            Text([entry.day, entry.tool].filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(Scaled.style(10, .regular))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        // A soft grey pill for the open one, as in the main sidebar (not the system's bright blue).
                        .background(model.selected == entry.id ? Color.primary.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                        .onTapGesture { model.selected = entry.id }
                        // Drag to reorder within a day; the date still decides the order between days.
                        .draggable(entry.id)
                        .dropDestination(for: String.self) { ids, _ in
                            guard let id = ids.first, model.entries.first(where: { $0.id == id })?.date == entry.date else { return false }
                            withAnimation { model.place(id, onto: entry, flipped: oldestFirst) }
                            return true
                        }
                        .contextMenu {
                            Button("Rename…") { newName = entry.purpose; renaming = entry }
                            if model.neighbour(of: entry, up) != nil { Button("Move Up") { model.move(entry, up) } }
                            if model.neighbour(of: entry, -up) != nil { Button("Move Down") { model.move(entry, -up) } }
                            Button("Delete…", role: .destructive) { deleting = entry.id }
                        }
            
                    }
                }
            }
            Menu {
                SwiftUI.Section("Declaration and reflection") {
                    Button(copied == "reflection" ? "Copied" : "Copy as LaTeX") { copyReflection() }
                    Button(copied == "reflection-text" ? "Copied" : "Copy as Text") { copyReflection(as: "text") }
                    Button("Save as a Separate Page…") { saveReflection() }
                }
                SwiftUI.Section("Full record") {
                    Button(copied == "markdown" ? "Copied" : "Copy as Markdown") { copy("markdown") }
                    Button("Save as LaTeX…") { saveLatex() }
                }
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .fixedSize()
            .help("The declaration and reflection, or the full record for an appendix")
            .padding(.bottom, 14)
        }
        .frame(maxWidth: .infinity, alignment: .leading)  // fills its column, so it doesn't shift when the editor changes
        .padding(.horizontal, 14)
    }

    private var declaration: some View {
        DisclosureView(project: model.filter)
    }

    private func flash(_ what: String) {
        copied = what
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { if copied == what { copied = "" } }
    }

    private func copy(_ format: String) {
        Task {
            guard let text = await model.export(format) else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            flash(format)
        }
    }

    private var reflectionQuery: String { model.filter.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "" }

    /// The declaration and reflection, to paste where you want them: LaTeX, or plain text for Word or Markdown.
    private func copyReflection(as format: String = "latex") {
        Task {
            guard let data = await API.request("ai-log/reflection/export?project=\(reflectionQuery)&format=\(format)", timeout: 10),
                  let text = String(data: data, encoding: .utf8) else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            flash(format == "text" ? "reflection-text" : "reflection")
        }
    }

    /// Or as a page of its own, a .tex file starting with \newpage, for \input.
    private func saveReflection() {
        Task {
            guard let data = await API.request("ai-log/reflection/export?project=\(reflectionQuery)&page=true", timeout: 10),
                  let text = String(data: data, encoding: .utf8) else { return }
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "declaration-and-reflection.tex"
            guard panel.runModal() == .OK, let file = panel.url else { return }
            try? text.write(to: file, atomically: true, encoding: .utf8)
        }
    }

    private func saveLatex() {
        Task {
            guard let text = await model.export("latex") else { return }
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "ai-use.tex"
            guard panel.runModal() == .OK, let file = panel.url else { return }
            try? text.write(to: file, atomically: true, encoding: .utf8)
        }
    }
}

struct AIUseEditor: View {

    @ObservedObject var model: AIUseModel
    @State var entry: AIUse
    @Binding var armed: Bool

    private var date: Binding<Date> {
        Binding(get: {
            let format = DateFormatter()
            format.dateFormat = "yyyy-MM-dd"
            return format.date(from: entry.date) ?? Date()
        }, set: { value in
            let format = DateFormatter()
            format.dateFormat = "yyyy-MM-dd"
            entry.date = format.string(from: value)
        })
    }

    var body: some View {
        Page {
            // The title is what it was used for: that's what tells entries apart, not the tool.
            HStack(alignment: .firstTextBaseline) {
                PageTitle(placeholder: "What you used it for", text: $entry.purpose)
                HistoryButton(id: entry.id, name: entry.purpose)
            }
            DetailsRow {
                DateDetail(date: date)
                DetailDivider()
                ProjectDetail(project: $entry.project, projects: model.projects)
                DetailDivider()
                TextDetail(symbol: "sparkles", placeholder: "AI tool", text: $entry.tool)
                DetailDivider()
                TextDetail(symbol: "tag", placeholder: "Version", text: $entry.version)
            }
            .padding(.top, 10)
            Hairline().padding(.vertical, 22)
            VStack(alignment: .leading, spacing: 24) {
                PageSection("What you asked") { MarkdownField(placeholder: "The substantive part of your prompt", text: $entry.prompt) }
                PageSection("What it gave you") { MarkdownField(placeholder: "A short summary, or the key part of its answer", text: $entry.response) }
                PageSection("How you checked it") { MarkdownField(placeholder: "Worked each step by hand, re-ran the code, found the references…", text: $entry.checked) }
            }
            HStack {
                Spacer()
                DeleteLink(title: "Delete entry", armed: $armed) { model.delete(entry.id) }
            }
            .padding(.top, 32)
        }
        .onChange(of: entry) { _, changed in model.save(changed) }
    }
}


/// The disclosure: a short statement drafted from the log (facts only: which tools, used for what,
/// how checked), in the format chosen, and editable. Edits are kept until a fresh draft is asked for.
struct DisclosureView: View {

    let project: String
    @State private var format = "statement"
    @State private var text = ""
    @State private var edited = false
    @State private var drafted = ""       // the draft from the log, to tell a real edit from a click
    @State private var given = ""
    @State private var unused = ""
    @State private var opening = ""
    @State private var savingOpening: Task<Void, Never>?
    @State private var savingWording: Task<Void, Never>?
    @State private var groups: [[String: Any]] = []
    @State private var entries = 0
    @State private var editing = false
    @State private var copied = false
    @State private var saving: Task<Void, Never>?
    @FocusState private var focused: Bool

    private let formats = [("statement", "Short statement"), ("by-tool", "By tool"), ("table", "Table"), ("given", "Wording you've been given")]

    var body: some View {
        Page {
            if project == "all" || project == "none" {
                Text("Choose a project above: each has its own disclosure.").foregroundStyle(.secondary)
            } else {
                Text("AI use disclosure").font(Fonts.heading(28, .regular))
                DetailsRow {
                    Detail(symbol: "folder") { Text(project) }
                    DetailDivider()
                    Detail(symbol: "list.bullet") { Text(entries == 1 ? "From 1 log entry" : "From \(entries) log entries") }
                    if edited {
                        DetailDivider()
                        Detail(symbol: "pencil") { Text("Edited by you") }
                    }
                }
                .padding(.top, 8)

                // An opening paragraph for this project, above the disclosure in any format but the
                // given wording (which has its own): an own-work statement, say.
                if format != "given" {
                    PageSection("Opening (optional)") {
                        PlainText(placeholder: "A paragraph to put first, such as a statement that the work is your own", text: $opening)
                            .onChange(of: opening) { _, value in keepOpening(value) }
                    }
                    .padding(.top, 18)
                }

                // A compact menu: four long tabs couldn't shrink, and pushed the page wider than its space.
                HStack(spacing: 8) {
                    Text("Format").foregroundStyle(.secondary)
                    Menu {
                        Picker("Format", selection: Binding(get: { format }, set: { choose($0) })) {
                            ForEach(formats, id: \.0) { Text($0.1).tag($0.0) }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    } label: {
                        Text(formats.first { $0.0 == format }?.1 ?? "Short statement")
                    }
                    .fixedSize()
                }
                .padding(.top, 18)

                if format == "given" {
                    VStack(alignment: .leading, spacing: 18) {
                        PageSection("Wording when AI was used") {
                            PlainText(placeholder: "Paste it here, with {tools}, {system}, {purposes} and {checks} where your log should go", text: $given)
                                .onChange(of: given) { _, _ in keepWording() }
                        }
                        PageSection("Wording when AI wasn't used") {
                            PlainText(placeholder: "Paste it here", text: $unused)
                                .onChange(of: unused) { _, _ in keepWording() }
                        }
                    }
                    .padding(.top, 16)
                }

                // The statement: formatted, click to edit; your edits are kept.
                Group {
                    if editing {
                        TextField("", text: $text, axis: .vertical)
                            .textFieldStyle(.plain)
                            .paragraphs()
                            .lineSpacing(4)
                            .focused($focused)
                            .onChange(of: text) { _, value in keep(value) }
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
                .padding(16)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.13)))
                .padding(.top, 14)

                HStack(spacing: 14) {
                    Button(copied ? "Copied" : "Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
                    }
                    Button("Draft Again from the Log") { send(["redraft": true]) }
                    Spacer()
                    if edited { Text("Your edits are kept until you draft again").font(Scaled.style(10, .regular)).foregroundStyle(.secondary) }
                }
                .padding(.top, 10)

                if !groups.isEmpty {
                    Hairline().padding(.top, 26)
                    FieldLabel("From your log").padding(.top, 16).padding(.bottom, 6)
                    ForEach(groups.indices, id: \.self) { i in
                        let g = groups[i]
                        VStack(alignment: .leading, spacing: 3) {
                            Text(g["name"] as? String ?? "").fontWeight(.medium)
                            ForEach((g["purposes"] as? [String] ?? []), id: \.self) { p in
                                Text("· " + p).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                        .padding(.vertical, 6)
                    }
                }
            }
        }
        .task(id: project) { await load() }
    }

    private var query: String { project.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "" }

    private func apply(_ found: [String: Any]?) {
        guard let found else { return }
        format = found["format"] as? String ?? "statement"
        text = found["text"] as? String ?? ""
        drafted = found["draft"] as? String ?? text
        edited = found["edited"] as? Bool ?? false
        given = found["given"] as? String ?? given
        unused = found["unused"] as? String ?? unused
        if savingOpening == nil { opening = found["opening"] as? String ?? opening }
        groups = found["groups"] as? [[String: Any]] ?? []
        entries = found["entries"] as? Int ?? 0
    }

    private func load() async { apply(await API.get("ai-log/disclosure?project=\(query)")) }

    /// Shows another format: each keeps its own edits, so nothing is lost by switching.
    private func choose(_ value: String) {
        editing = false
        send(["format": value])
    }

    private func send(_ change: [String: Any]) {
        Task { apply(await API.post("ai-log/disclosure", ["project": project].merging(change) { $1 })) }
    }

    /// Saves the given wording shortly after typing stops, without putting older text back in the boxes.
    private func keepWording() {
        savingWording?.cancel()
        savingWording = Task {
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            let (typedGiven, typedUnused) = (given, unused)
            apply(await API.post("ai-log/disclosure", ["project": project, "given": typedGiven, "unused": typedUnused]))
            if given != typedGiven || unused != typedUnused { (given, unused) = (typedGiven, typedUnused) }
        }
    }

    /// Saves the opening paragraph shortly after typing stops, then shows the drafts with it.
    private func keepOpening(_ value: String) {
        savingOpening?.cancel()
        savingOpening = Task {
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            apply(await API.post("ai-log/disclosure", ["project": project, "opening": value]))
            savingOpening = nil
        }
    }

    /// Saves edits shortly after typing stops.
    private func keep(_ value: String) {
        guard edited || value != drafted else { return }   // a click into the box isn't an edit
        edited = true
        saving?.cancel()
        saving = Task {
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            _ = await API.post("ai-log/disclosure", ["project": project, "text": value])
        }
    }
}


/// The reflection on your work, for the separate page with the declaration: the guidelines' two
/// prompts, answered in your own words, with your own record beside them for reference. Nothing is
/// written for you; Check asks questions about your draft and never rewrites it.
struct ReflectionView: View {

    let project: String
    let entries: [AIUse]
    @State private var structure = ""
    @State private var difficulty = ""
    @State private var loaded = false
    @State private var saving: Task<Void, Never>?
    @State private var feedback: String?
    @State private var checking = false
    @State private var meetings: [[String: Any]] = []

    var body: some View {
        Page {
            if project == "all" || project == "none" {
                Text("Choose a project above: each has its own reflection.").foregroundStyle(.secondary)
            } else {
                Text("Reflection on your work").font(Fonts.heading(28, .regular))
                Text("A few sentences, in your own words.")
                    .font(Scaled.style(11, .regular)).foregroundStyle(.secondary)
                    .padding(.top, 2)
                Hairline().padding(.vertical, 22)
                VStack(alignment: .leading, spacing: 24) {
                    PageSection("How did you structure your arguments?") {
                        MarkdownField(placeholder: "How you approached each part, and in what order", text: $structure)
                    }
                    PageSection("Where did you find the main difficulty?") {
                        MarkdownField(placeholder: "What was hard, and what made it hard", text: $difficulty)
                    }
                    HStack(spacing: 8) {
                        Button("Check My Reflection") { check() }.glassButton().disabled(checking)
                        if checking { ProgressView().controlSize(.small) }
                    }
                    if let feedback {
                        Text(feedback).font(Scaled.style(12, .regular)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(10)
                            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                    }
                    PageSection("Your record, for reference") { record }
                }
            }
        }
        .task { await load() }
        .onChange(of: structure) { _, _ in keep() }
        .onChange(of: difficulty) { _, _ in keep() }
    }

    /// Your AI use entries, oldest first, and this project's meetings: what you did, to write from.
    private var record: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(entries.filter { !$0.isBlank }.sorted { $0.date != $1.date ? $0.date < $1.date : $0.rank < $1.rank }) { entry in
                (Text(entry.day).foregroundStyle(.secondary) + Text(" · " + (entry.purpose.isEmpty ? "AI use" : entry.purpose)))
                    .font(Scaled.style(12, .regular))
            }
            if !meetings.isEmpty {
                ForEach(Array(meetings.enumerated()), id: \.offset) { _, meeting in
                    Text("Meeting · " + [meeting["date"] as? String, meeting["title"] as? String].compactMap { $0 }.joined(separator: " · "))
                        .font(Scaled.style(12, .regular)).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var query: String { project.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "" }

    private func load() async {
        let saved = await API.getPath("ai-log/reflection?project=\(query)") ?? [:]
        structure = saved["structure"] as? String ?? ""
        difficulty = saved["difficulty"] as? String ?? ""
        meetings = await API.getList("meetings?project=\(query)")
        loaded = true
    }

    /// Saved shortly after typing stops.
    private func keep() {
        guard loaded else { return }
        saving?.cancel()
        saving = Task {
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            _ = await API.post("ai-log/reflection", ["project": project, "structure": structure, "difficulty": difficulty])
        }
    }

    private func check() {
        checking = true
        Task {
            _ = await API.post("ai-log/reflection", ["project": project, "structure": structure, "difficulty": difficulty])
            let found = await API.post("ai-log/reflection/check", ["project": project], timeout: 60)
            feedback = found?["feedback"] as? String ?? "Couldn't check it. Try again."
            checking = false
        }
    }
}
