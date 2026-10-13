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
    }

    var id = UUID().uuidString
    var project = ""
    var date = Meeting.today
    var title = ""
    var attendees = ""
    var notes = ""
    var decisions = ""
    var actions: [Action] = []
    var created: Double?

    static var today: String {
        let format = DateFormatter()
        format.dateFormat = "yyyy-MM-dd"
        return format.string(from: Date())
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
    @Published var selected: String?
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
            }
            await reload()
        }
    }

    func reload() async {
        let query = "meetings?project=\(filter.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "all")"
        guard let data = await API.request(query),
              let found = try? JSONDecoder().decode([Meeting].self, from: data) else { return }
        meetings = found
        if selected == nil || !found.contains(where: { $0.id == selected }) { selected = found.first?.id }
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

    func add() {
        var meeting = Meeting()
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
        Task { _ = await API.delete("meetings?id=\(id)") }
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

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 230)
            Divider().opacity(0.4)
            if let meeting = model.meetings.first(where: { $0.id == model.selected }) {
                MeetingEditor(model: model, meeting: meeting, armed: $armed)
                    .id(meeting.id)
            } else {
                VStack(spacing: 10) {
                    Text("No meetings yet").font(.title3.weight(.semibold))
                    Text("Keep notes from supervisor and group meetings here, with action points carried forward.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("New Meeting") { model.add() }.glassButton()
                }
                .padding(40)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 760, idealWidth: 860, minHeight: 520, idealHeight: 680)
        .background(WindowGlass().ignoresSafeArea())
        .onAppear { model.load() }
        .onChange(of: model.filter) { _, _ in Task { await model.reload() } }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Meetings").font(.title2.weight(.semibold))
                Spacer()
                Button { model.add() } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless)
                    .help("New meeting")
            }
            .padding(.top, 28)
            Picker("Project", selection: $model.filter) {
                Text("All Projects").tag("all")
                ForEach(model.projects, id: \.self) { Text($0).tag($0) }
                Text("No Project").tag("none")
            }
            .labelsHidden()
            List(model.meetings, selection: $model.selected) { meeting in
                VStack(alignment: .leading, spacing: 2) {
                    Text(meeting.title.isEmpty ? "Untitled meeting" : meeting.title).fontWeight(.medium).lineLimit(1)
                    Text(meeting.day + (model.filter == "all" && !meeting.project.isEmpty ? " · \(meeting.project)" : ""))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .tag(meeting.id)
            }
            .scrollContentBackground(.hidden)
            if model.filter != "all" && model.filter != "none" {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Shared workspace").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        Text(model.workspace.isEmpty ? "Not linked" : URL(fileURLWithPath: model.workspace).lastPathComponent)
                            .font(.caption)
                            .lineLimit(1)
                            .help(model.workspace.isEmpty ? "Link your group's shared folder or repository: Referee keeps notes/decision-notes.md and notes/who-did-what.md up to date in it." : model.workspace)
                        Spacer()
                        if !model.workspace.isEmpty {
                            Button("Unlink") { model.setWorkspace("") }.buttonStyle(.borderless).font(.caption)
                        }
                        Button(model.workspace.isEmpty ? "Link…" : "Change…") { chooseWorkspace() }.buttonStyle(.borderless).font(.caption)
                    }
                }
            }
            Menu {
                Button(copied ? "Copied" : "Copy as Markdown") { copyMarkdown() }
                Button("Save as LaTeX…") { saveLatex() }
                Divider()
                Button("Save decision-notes.md…") { saveFile("decision-notes", "decision-notes.md") }
                Button("Save who-did-what.md…") { saveFile("who-did-what", "who-did-what.md") }
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .help("Share this project's meeting log: Markdown for Teams or a document, LaTeX for Overleaf, or the decision-notes and who-did-what files group projects ask for")
            .padding(.bottom, 14)
        }
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
        panel.message = "Choose your group's shared workspace: Referee keeps notes/decision-notes.md and notes/who-did-what.md up to date in it."
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    TextField("Title", text: $meeting.title)
                        .textFieldStyle(.plain)
                        .font(.title2.weight(.semibold))
                    DatePicker("Date", selection: date, displayedComponents: .date)
                        .labelsHidden()
                        .fixedSize()
                }
                HStack {
                    Picker("Project", selection: $meeting.project) {
                        Text("No Project").tag("")
                        ForEach(model.projects, id: \.self) { Text($0).tag($0) }
                    }
                    .fixedSize()
                    TextField("Attendees", text: $meeting.attendees)
                        .textFieldStyle(.roundedBorder)
                }
                let open = model.openActions(before: meeting)
                if !open.isEmpty {
                    section("Still to do from earlier meetings") {
                        ForEach(open, id: \.action.id) { item in
                            Toggle(isOn: Binding(get: { item.action.done }, set: { model.setDone(item.action.id, in: item.meeting.id, $0) })) {
                                Text(item.action.text + detail(item.action)).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                section("Notes") { editor($meeting.notes, height: 140) }
                section("Decisions") { editor($meeting.decisions, height: 70) }
                section("Action points") {
                    ForEach($meeting.actions) { $action in
                        HStack(spacing: 8) {
                            Toggle("Done", isOn: $action.done).labelsHidden()
                            TextField("What", text: $action.text).textFieldStyle(.roundedBorder)
                            TextField("Who", text: $action.who).textFieldStyle(.roundedBorder).frame(width: 110)
                            TextField("By when", text: $action.due).textFieldStyle(.roundedBorder).frame(width: 100)
                            Button { meeting.actions.removeAll { $0.id == action.id } } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Button("Add Action Point") { meeting.actions.append(Meeting.Action()) }.glassButton()
                }
                HStack {
                    Button(copied ? "Copied" : "Copy Link") {
                        RefereeLinks.copy(RefereeLinks.meeting(meeting.id))
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
                    }
                    .buttonStyle(.borderless)
                    .help("Copy a link to this meeting, for your planner or to-do list")
                    Spacer()
                    Button(armed ? "Click Again to Delete" : "Delete Meeting") {
                        if armed { model.delete(meeting.id); armed = false } else {
                            armed = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { armed = false }
                        }
                    }
                    .foregroundStyle(armed ? .red : .secondary)
                    .buttonStyle(.borderless)
                }
            }
            .padding(24)
        }
        .onChange(of: meeting) { _, changed in model.save(changed) }
    }

    private func detail(_ action: Meeting.Action) -> String {
        let extra = [action.who, action.due.isEmpty ? "" : "by \(action.due)"].filter { !$0.isEmpty }.joined(separator: ", ")
        return extra.isEmpty ? "" : " (\(extra))"
    }

    private func editor(_ text: Binding<String>, height: CGFloat) -> some View {
        TextEditor(text: text)
            .font(.body)
            .scrollContentBackground(.hidden)
            .padding(6)
            .frame(minHeight: height)
            .glassCard()
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
    }
}
