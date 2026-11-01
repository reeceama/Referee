import AppKit
import SwiftUI

/// Meeting notes, by project: supervisor meetings and group project meetings. Action points not
/// yet done are carried into the next meeting, and a project's log exports as Markdown or LaTeX
/// to share with the group.
struct Meeting: Codable, Identifiable, Equatable {

    struct Action: Codable, Identifiable, Equatable {
        var id = UUID().uuidString
        var text = ""
        var who = ""
        var due = ""
        var done = false
        var notes: String? = nil   // optional, so action points saved before notes still read
        var send_files: [String]? = nil   // meeting attachments to send with its Todoist task
    }

    var id = UUID().uuidString
    var project = ""
    var date = Meeting.today
    var title = ""
    var attendees = ""
    var notes = ""
    var decisions = ""
    var actions: [Action] = []
    /// Photos and files to look at (a whiteboard, slides, a marked-up page), in meeting-files/<id>/.
    /// Optional, so meetings saved before this still read.
    var files: [String]? = nil
    var created: Double?
    /// "tasks" for a project's tasks that came from no meeting: one entry per project, shown as a list
    /// of tasks only. Optional, so meetings saved before this still read.
    var kind: String? = nil
    var isTasks: Bool { kind == "tasks" }

    var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Referee/meeting-files/\(id)", isDirectory: true)
    }

    static var today: String {
        let format = DateFormatter()
        format.dateFormat = "yyyy-MM-dd"
        return format.string(from: Date())
    }

    /// Nothing written yet: a draft, which always shows today's date.
    var isBlank: Bool {
        [title, attendees, notes, decisions].allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            && actions.allSatisfy { $0.text.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// "8 October 2026"
    var day: String {
        let read = DateFormatter()
        read.dateFormat = "yyyy-MM-dd"
        guard let parsed = read.date(from: date) else { return date }
        let write = DateFormatter()
        write.dateFormat = "d MMMM yyyy"
        return write.string(from: parsed)
    }
}

@MainActor
final class MeetingsModel: ObservableObject {

    @Published var meetings: [Meeting] = []
    @Published var projects: [String] = []
    @Published var filter = "all"            // "all", "none" or a project name
    // Remembered, so Referee reopens on the meeting you had open.
    @Published var selected: String? = UserDefaults.standard.string(forKey: "lastMeeting") {
        didSet { if let selected { UserDefaults.standard.set(selected, forKey: "lastMeeting") } }
    }
    @Published var workspace = ""            // the filtered project's shared workspace folder, if linked
    private var current = ""                 // the current project, for new meetings
    private var pending: Task<Void, Never>?
    private var linked: NSObjectProtocol?

    init() {
        // referee://meeting/<id> links: show every project's meetings, with that one selected.
        linked = NotificationCenter.default.addObserver(forName: .refereeShowMeeting, object: nil, queue: .main) { [weak self] note in
            guard let id = note.object as? String else { return }
            Task { @MainActor in
                guard let self else { return }
                if !self.meetings.contains(where: { $0.id == id }) {
                    self.filter = "all"
                    await self.reload()
                }
                self.selected = id
            }
        }
    }

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
        let query = "meetings?project=\(filter.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "all")"
        guard let data = await API.request(query),
              let found = try? JSONDecoder().decode([Meeting].self, from: data) else { return }
        meetings = found
        // Blank drafts left from an earlier day move to today, so a new meeting never opens on an old date.
        for (index, meeting) in meetings.enumerated() where meeting.isBlank && !meeting.isTasks && meeting.date != Meeting.today {
            meetings[index].date = Meeting.today
            if let body = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(meetings[index])) as? [String: Any] {
                _ = await API.post("meetings", body)  // each saved in turn: save() keeps only the latest edit
            }
        }
        if selected == nil || !meetings.contains(where: { $0.id == selected }) { selected = meetings.first?.id }
        workspace = filter == "all" || filter == "none" ? ""
            : (await API.getPath("meetings/workspace?project=\(filter.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")"))?["folder"] as? String ?? ""
    }

    /// Links the filtered project to its shared workspace folder, where notes/decision-notes.md and
    /// notes/who-did-what.md are then kept up to date ("" unlinks).
    func setWorkspace(_ folder: String) {
        workspace = folder
        Task { _ = await API.post("meetings/workspace", ["project": filter, "folder": folder], timeout: 10) }
    }

    /// Action points still to do from the project's other meetings.
    func openActions(before meeting: Meeting) -> [(meeting: Meeting, action: Meeting.Action)] {
        meetings.filter { $0.id != meeting.id && $0.project == meeting.project && $0.date <= meeting.date }
            .flatMap { m in m.actions.filter { !$0.done && !$0.text.isEmpty }.map { (m, $0) } }
    }

    /// The project's tasks without a meeting, made the first time one is added.
    func tasks(for project: String) -> Meeting {
        if let found = meetings.first(where: { $0.isTasks && $0.project == project }) { return found }
        var list = Meeting()
        (list.kind, list.title, list.project, list.date) = ("tasks", "Tasks without a meeting", project, "")
        meetings.insert(list, at: 0)
        save(list, now: true)
        return list
    }

    func add(from event: CalendarEvent? = nil) {
        var meeting = Meeting()
        if let event {
            meeting.title = event.title
            meeting.date = event.day
            meeting.attendees = event.attendees
        }
        meeting.project = filter == "all" ? current : filter == "none" ? "" : filter
        meetings.insert(meeting, at: 0)
        selected = meeting.id
        save(meeting, now: true)
    }

    /// Saves a meeting shortly after the last edit, so typing doesn't send every keystroke.
    func save(_ meeting: Meeting, now: Bool = false) {
        if let index = meetings.firstIndex(where: { $0.id == meeting.id }) { meetings[index] = meeting }
        pending?.cancel()
        pending = Task {
            if !now { try? await Task.sleep(nanoseconds: 700_000_000) }
            guard !Task.isCancelled, let body = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(meeting)) as? [String: Any] else { return }
            _ = await API.post("meetings", body)
        }
    }

    func setDone(_ actionID: String, in meetingID: String, _ done: Bool) {
        guard let index = meetings.firstIndex(where: { $0.id == meetingID }),
              let a = meetings[index].actions.firstIndex(where: { $0.id == actionID }) else { return }
        meetings[index].actions[a].done = done
        let meeting = meetings[index]
        Task {
            if let body = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(meeting)) as? [String: Any] {
                _ = await API.post("meetings", body)
            }
        }
    }

    func delete(_ id: String) {
        meetings.removeAll { $0.id == id }
        selected = meetings.first?.id
        Task {
            _ = await API.delete("meetings?id=\(id)")
            NotificationCenter.default.post(name: .refereeDeleted, object: nil)   // offers Undo
        }
    }

    func export(_ format: String) async -> String? {
        let query = "meetings/export?project=\(filter.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "all")&format=\(format)"
        guard let data = await API.request(query, timeout: 10) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

struct MeetingsView: View {

    @StateObject private var model = MeetingsModel()
    @State private var armed = false
    @State private var copied = false
    @State private var renaming: Meeting?
    @State private var newName = ""
    @State private var renames = 0
    @State private var deleting: String?   // the entry waiting for "are you sure"
    @State private var sharedFiles: [String] = []
    @State private var openFile: String?     // a shared file shown instead of a meeting

    private func loadFiles() async {
        guard !model.workspace.isEmpty, let data = await API.request("meetings/files?project=\(model.filter.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")"),
              let found = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { sharedFiles = []; return }
        sharedFiles = found.compactMap { $0["path"] as? String }
    }

    var body: some View {
        // The list: about a third of the page, 180 to 240 points, so the entry always has most of it.
        GeometryReader { space in
        HStack(spacing: 0) {
            sidebar.frame(width: min(240, max(180, space.size.width * 0.32)))
            Divider().opacity(0.4)
            if let path = openFile, model.selected == nil {
                SharedFileView(project: model.filter, path: path).id(path)
            } else if let meeting = model.meetings.first(where: { $0.id == model.selected }) {
                MeetingEditor(model: model, meeting: meeting, armed: $armed)
                    .id("\(meeting.id)-\(renames)")  // reloaded after a rename
            } else {
                EmptyPage(symbol: "person.2", title: "No meetings yet",
                          message: "Keep notes from supervisor and group meetings here, with tasks carried forward.",
                          action: ("New Meeting", { model.add() }))
            }
        }
        }
        .onAppear { model.load() }
        .onChange(of: model.filter) { _, _ in openFile = nil; Task { await model.reload() } }
        .onChange(of: model.selected) { _, selected in if selected != nil { openFile = nil } }
        .pageActions { HStack(spacing: 14) { CalendarButton { model.add(from: $0) }; RecentlyDeletedButton(kind: "meeting", project: model.filter, inHeader: true) { Task { await model.reload() } }; addButton } }
        .confirmationDialog("Delete this meeting?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete", role: .destructive) { if let id = deleting { model.delete(id) }; deleting = nil }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: {
            Text("It stays in Recently Deleted for 30 days.")
        }
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Title", text: $newName)
            Button("Rename") {
                if var meeting = renaming { meeting.title = newName; model.save(meeting, now: true); renames += 1 }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }

    private var addButton: some View {
        Button { model.add() } label: { HeaderIcon("plus") }
            .buttonStyle(.borderless)
            .help("New meeting")
    }

    @AppStorage("meetingsOldestFirst") private var oldestFirst = false

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

            // Rows drawn by Referee, full width and in line with the buttons above, at any width.
            ScrollView {
                LazyVStack(spacing: 2) {
                    // A project's tasks without a meeting come first, whichever way the meetings are ordered.
                    if model.filter != "all" && model.filter != "none" && !model.meetings.contains(where: { $0.isTasks }) {
                        Text("Tasks without a meeting").font(Fonts.heading(15, .semibold)).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10).padding(.vertical, 8)
                            .contentShape(Rectangle())
                            .onTapGesture { model.selected = model.tasks(for: model.filter).id }
                    }
                    ForEach(model.meetings.filter(\.isTasks) + (oldestFirst ? model.meetings.reversed() : model.meetings).filter { !$0.isTasks }) { meeting in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(meeting.isTasks ? "Tasks without a meeting" : meeting.title.isEmpty ? "Untitled meeting" : meeting.title).font(Fonts.heading(15, .semibold)).lineLimit(2)
                            Text((meeting.isTasks ? "\(meeting.actions.filter { !$0.done && !$0.text.isEmpty }.count) to do" : meeting.day)
                                 + (model.filter == "all" && !meeting.project.isEmpty ? " · \(meeting.project)" : ""))
                                .font(Scaled.style(10, .regular))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        // A soft grey pill for the open one, as in the main sidebar (not the system's bright blue).
                        .background(model.selected == meeting.id ? Color.primary.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                        .onTapGesture { model.selected = meeting.id }
                        .contextMenu {
                            if !meeting.isTasks { Button("Rename") { newName = meeting.title; renaming = meeting } }
                            Button("Delete", role: .destructive) { deleting = meeting.id }
                        }
            
                    }
                }
            }
            // Only once linked (group projects); link one from the Export menu below.
            if model.filter != "all" && model.filter != "none" && !model.workspace.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Shared folder").font(Scaled.style(10, .semibold)).foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        Text(model.workspace.isEmpty ? "Not linked" : URL(fileURLWithPath: model.workspace).lastPathComponent)
                            .font(Scaled.style(10, .regular))
                            .lineLimit(1)
                            .help(model.workspace.isEmpty ? "Link your group's shared folder or repository, to open and edit its Markdown files here." : model.workspace)
                        Spacer()
                        if !model.workspace.isEmpty {
                            Button("Unlink") { model.setWorkspace("") }.buttonStyle(.borderless).font(Scaled.style(10, .regular))
                        }
                        Button(model.workspace.isEmpty ? "Link" : "Change") { chooseWorkspace() }.buttonStyle(.borderless).font(Scaled.style(10, .regular))
                    }
                    // The group's Markdown files, whatever they're called: opened, never written by themselves.
                    ForEach(sharedFiles, id: \.self) { path in
                        Button { openFile = path; model.selected = nil } label: {
                            Label(path, systemImage: "doc.text").font(Scaled.style(10, .regular)).lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 3).padding(.horizontal, 6)
                                .background(openFile == path ? Color.primary.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 6))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .task(id: model.workspace) { await loadFiles() }
            }
            HStack(spacing: 8) {
                Menu {
                    Button(copied ? "Copied" : "Copy as Markdown") { copyMarkdown() }
                    Button("Save as LaTeX") { saveLatex() }
                    if model.filter != "all" && model.filter != "none" && model.workspace.isEmpty {
                        Divider()
                        Button("Link Shared Folder") { chooseWorkspace() }
                            .help("For group projects: your group's shared folder or repository, to read its files here")
                    }
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .help("Share this project's meeting log: Markdown for Teams or a document, LaTeX for Overleaf")
            }
            .padding(.bottom, 14)
        }
        .frame(maxWidth: .infinity, alignment: .leading)  // fills its column, so it doesn't shift when the editor changes
        .padding(.horizontal, 14)
    }

    private func copyMarkdown() {
        Task {
            guard let text = await model.export("markdown") else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
        }
    }

    private func saveLatex() { saveFile("latex", "meetings.tex") }

    private func chooseWorkspace() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Link"
        panel.message = "Choose your group's shared workspace: Referee keeps your own part of notes/decision-notes.md and notes/who-did-what.md up to date in it, and never changes anyone else's."
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        model.setWorkspace(folder.path)
    }

    private func saveFile(_ format: String, _ name: String) {
        Task {
            guard let text = await model.export(format) else { return }
            let panel = NSSavePanel()
            panel.nameFieldStringValue = name
            guard panel.runModal() == .OK, let file = panel.url else { return }
            try? text.write(to: file, atomically: true, encoding: .utf8)
        }
    }
}

/// One meeting, edited in place and saved as you type.
struct MeetingEditor: View {

    @ObservedObject var model: MeetingsModel
    @State var meeting: Meeting
    @Binding var armed: Bool
    @State private var copied = false

    private var date: Binding<Date> {
        Binding(get: {
            let format = DateFormatter()
            format.dateFormat = "yyyy-MM-dd"
            return format.date(from: meeting.date) ?? Date()
        }, set: { value in
            let format = DateFormatter()
            format.dateFormat = "yyyy-MM-dd"
            meeting.date = format.string(from: value)
        })
    }

    /// Copies chosen photos or files into the meeting's folder.
    private func attachFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "Attach"
        guard panel.runModal() == .OK else { return }
        try? FileManager.default.createDirectory(at: meeting.folder, withIntermediateDirectories: true)
        var files = meeting.files ?? []
        for url in panel.urls {
            var name = url.lastPathComponent
            var n = 2
            while files.contains(name) {
                name = "\(url.deletingPathExtension().lastPathComponent) \(n).\(url.pathExtension)"; n += 1
            }
            if (try? FileManager.default.copyItem(at: url, to: meeting.folder.appendingPathComponent(name))) != nil {
                files.append(name)
            }
        }
        meeting.files = files
    }

    var body: some View {
        Page {
            if meeting.isTasks {
                Text("Tasks without a meeting").font(Fonts.heading(28, .regular))
                Text(meeting.project).font(Scaled.style(12, .regular)).foregroundStyle(.secondary).padding(.top, 4)
                Hairline().padding(.vertical, 22)
            } else {
            HStack(alignment: .firstTextBaseline) {
                PageTitle(placeholder: "Untitled meeting", text: $meeting.title)
                HistoryButton(id: meeting.id, name: meeting.title)
            }
            DetailsRow {
                DateDetail(date: date)
                DetailDivider()
                ProjectDetail(project: $meeting.project, projects: model.projects)
                DetailDivider()
                TextDetail(symbol: "person.2", placeholder: "Attendees", text: $meeting.attendees)
            }
            .padding(.top, 10)
            Hairline().padding(.vertical, 22)
            }
            VStack(alignment: .leading, spacing: 26) {
                let open = meeting.isTasks ? [] : model.openActions(before: meeting)
                if !open.isEmpty {
                    PageSection("Still to do from earlier meetings") {
                        ForEach(open, id: \.action.id) { item in
                            Toggle(isOn: Binding(get: { item.action.done }, set: { model.setDone(item.action.id, in: item.meeting.id, $0) })) {
                                Text(item.action.text + detail(item.action)).foregroundStyle(.secondary)
                            }
                            .toggleStyle(.checkbox)
                        }
                    }
                }
                if !meeting.isTasks {
                PageSection("Notes") { MarkdownField(placeholder: "What was discussed: paragraphs, - lists, # headings, $maths$", text: $meeting.notes) }
                PageSection("Decisions") { MarkdownField(placeholder: "What was decided, and why", text: $meeting.decisions) }
                }
                PageSection("Tasks") {
                    // Each one: its title (wrapping), when it's due underneath, then notes.
                    ForEach($meeting.actions) { $action in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Toggle("Done", isOn: $action.done).labelsHidden().toggleStyle(.checkbox)
                                TextField("Title", text: $action.text, axis: .vertical)
                                    .textFieldStyle(.plain)
                                    .font(.system(size: Scaled.s(14), weight: .medium))
                                    .strikethrough(action.done, color: .secondary)
                                Button { meeting.actions.removeAll { $0.id == action.id } } label: { Image(systemName: "xmark") }
                                    .buttonStyle(.plain)
                                    .font(.system(size: Scaled.s(11)))
                                    .foregroundStyle(.tertiary)
                                    .help("Remove")
                            }
                            // No "who": action points are yours (blank counts as you, and goes to your to-do app).
                            HStack(spacing: 18) {
                                Label { TextField("By when", text: $action.due).textFieldStyle(.plain) } icon: { Image(systemName: "calendar") }
                                    .frame(maxWidth: 200, alignment: .leading)
                                // Which of the meeting's attachments go to this task in Todoist.
                                if let files = meeting.files, !files.isEmpty {
                                    Menu {
                                        ForEach(files, id: \.self) { name in
                                            Toggle(name, isOn: Binding(
                                                get: { action.send_files?.contains(name) ?? false },
                                                set: { on in
                                                    var chosen = action.send_files ?? []
                                                    if on { chosen.append(name) } else { chosen.removeAll { $0 == name } }
                                                    action.send_files = chosen
                                                }))
                                        }
                                    } label: {
                                        Label((action.send_files ?? []).isEmpty ? "Attach to task" : "\((action.send_files ?? []).count) attached",
                                              systemImage: "paperclip")
                                    }
                                    .menuStyle(.borderlessButton)
                                    .menuIndicator(.hidden)
                                    .fixedSize()
                                    .help("Choose which of this meeting's attachments to send with its Todoist task")
                                }
                            }
                            .font(.system(size: Scaled.s(12)))
                            .foregroundStyle(.secondary)
                            .padding(.leading, 26)
                            TextField("Notes", text: Binding(get: { action.notes ?? "" }, set: { action.notes = $0 }), axis: .vertical)
                                .textFieldStyle(.plain)
                                .font(.system(size: Scaled.s(13)))
                                .foregroundStyle(.secondary)
                                .paragraphs()
                                .padding(.leading, 26)
                        }
                        .padding(.vertical, 10)
                        Hairline()
                    }
                    Button { meeting.actions.append(Meeting.Action()) } label: {
                        Label("Add task", systemImage: "plus").font(.system(size: Scaled.s(13)))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .padding(.top, 2)
                }
            }
            // Attachments: to look at, not sources.
            if !meeting.isTasks {
            VStack(alignment: .leading, spacing: 8) {
                if let files = meeting.files, !files.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(files, id: \.self) { name in
                                FileThumbnail(url: meeting.folder.appendingPathComponent(name)) {
                                    try? FileManager.default.removeItem(at: meeting.folder.appendingPathComponent(name))
                                    meeting.files?.removeAll { $0 == name }
                                }
                            }
                        }
                    }
                }
                Button { attachFiles() } label: { Label("Attach", systemImage: "paperclip").font(.system(size: Scaled.s(13))) }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .help("Add photos or files to this meeting: a whiteboard, slides, a marked-up page")
            }
            .padding(.top, 24)
            }
            HStack {
                Button(copied ? "Copied" : "Copy link") {
                    RefereeLinks.copy(RefereeLinks.meeting(meeting.id))
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
                }
                .buttonStyle(.plain)
                .font(.system(size: Scaled.s(13)))
                .foregroundStyle(Color.accentColor)
                .help("Copy a link to this meeting, for your planner or to-do list")
                Spacer()
                DeleteLink(title: "Delete meeting", armed: $armed) { model.delete(meeting.id) }
            }
            .padding(.top, 32)
        }
        .onChange(of: meeting) { _, changed in model.save(changed) }
    }

    private func detail(_ action: Meeting.Action) -> String {
        let extra = [action.who, action.due.isEmpty ? "" : "by \(action.due)"].filter { !$0.isEmpty }.joined(separator: ", ")
        return extra.isEmpty ? "" : " (\(extra))"
    }
}


/// A Markdown file from the group's shared folder: shown formatted, edited as text, and saved
/// back exactly as written. If someone changed it since it was opened, their version is shown
/// instead of being overwritten.
struct SharedFileView: View {

    let project: String
    let path: String
    @State private var text = ""
    @State private var opened: Double = 0
    @State private var editing = false
    @State private var changed = false
    @State private var message: String?

    private var query: String { project.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "" }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(path).font(Scaled.style(12, .regular)).foregroundStyle(.secondary)
                Spacer()
                if editing {
                    Button("Insert My Action Points") { insertActions() }
                        .help("Adds your tasks at the end, as a Markdown list, for you to move where they belong")
                }
                Button(editing ? "Done" : "Edit") { editing.toggle() }
                Button("Save") { save() }.buttonStyle(.borderedProminent).disabled(!changed)
            }
            .padding(.horizontal, 24).padding(.vertical, 10)
            Hairline()
            if let message {
                Text(message).font(Scaled.style(10, .regular)).foregroundStyle(.orange).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24).padding(.top, 8)
            }
            if editing {
                TextEditor(text: $text)
                    .font(.system(size: Scaled.s(13), design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(20)
                    .onChange(of: text) { _, _ in changed = true }
            } else {
                Page { MarkdownView(text: text).frame(maxWidth: .infinity, alignment: .leading) }
                    .onTapGesture(count: 2) { editing = true }
                    // Usable with VoiceOver and the keyboard too, not only a click.
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction(named: "Edit") { editing = true }
            }
        }
        .task { await load() }
    }

    private func load() async {
        guard let found = await API.get("meetings/file?project=\(query)&path=\(path.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")") else { return }
        text = found["text"] as? String ?? ""
        opened = found["modified"] as? Double ?? 0
        DispatchQueue.main.async { changed = false }
    }

    private func insertActions() {
        Task {
            guard let data = await API.request("meetings/my-actions?project=\(query)"),
                  let actions = String(data: data, encoding: .utf8) else { return }
            text = text.trimmingCharacters(in: .newlines) + "\n\n" + actions + "\n"
        }
    }

    private func save() {
        Task {
            let result = await API.post("meetings/file", ["project": project, "path": path, "text": text, "modified": opened], timeout: 10)
            if result?["ok"] as? Bool == true {
                opened = result?["modified"] as? Double ?? opened
                changed = false
                message = nil
            } else if result?["conflict"] as? Bool == true {
                // Someone else changed it: keep their version safe, and keep yours to copy across.
                let yours = text
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(yours, forType: .string)
                text = result?["text"] as? String ?? text
                opened = result?["modified"] as? Double ?? opened
                DispatchQueue.main.async { changed = false }
                message = "Someone changed this file since you opened it. Their version is shown, and yours is on the clipboard: add your changes again, then save."
            } else {
                message = result?["reason"] as? String ?? "Couldn't save."
            }
        }
    }
}
