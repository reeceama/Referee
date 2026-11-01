import SwiftUI

/// The services and apps Referee connects to, in one page: the Anthropic key, the to-do app that
/// gets meeting action points (one at a time, so a task never lands in two), Obsidian, Zotero and
/// the calendar. Keys and tokens are kept in the Keychain.
struct IntegrationsView: View {

    @ObservedObject var model: Model
    @State private var tasks: [String: Any] = [:]
    @State private var zotero: [String: Any] = [:]
    @State private var phone: [String: Any] = [:]
    @State private var app = "none"
    @State private var obsidianFolder = WordSettings.obsidianFolder

    private let apps: [(String, String, String)] = [
        ("none", "None", "Tasks stay in Referee"),
        ("things", "Things 3", "On this Mac. Ticks sync both ways"),
        ("reminders", "Apple Reminders", "On this Mac. Ticks sync both ways"),
        ("todoist", "Todoist", "Needs your Todoist token"),
        ("notion", "Notion", "Needs an integration token and a task database"),
    ]

    var body: some View {
        Page {
            Text("Apps Referee sends tasks and notes to. Tokens are kept in your Keychain; AI keys are in Settings → Keys.")
                .foregroundStyle(.secondary)
                .padding(.top, 8)

            section("Tasks: choose one", footer: "Each meeting's tasks go to your to-do app with their deadlines, in a list named after the Referee project. Only one app at a time, so tasks aren't duplicated.") {
                ForEach(apps, id: \.0) { id, name, about in
                    VStack(alignment: .leading, spacing: 8) {
                        Button { choose(id) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: app == id ? "largecircle.fill.circle" : "circle")
                                    .foregroundStyle(app == id ? Color.accentColor : Color.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(name)
                                    Text(about).font(Scaled.style(10, .regular)).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if connected(id) { Text("Connected").font(Scaled.style(10, .regular)).foregroundStyle(.green) }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if app == id && id == "todoist" { TodoistView().padding(.leading, 28) }
                        if app == id && id == "notion" { NotionView { Task { await refresh() } }.padding(.leading, 28) }
                        if app == id && (id == "things" || id == "reminders") {
                            Text("The first time, macOS asks whether Referee may control \(name). Choose Allow.")
                                .font(Scaled.style(10, .regular)).foregroundStyle(.secondary).padding(.leading, 28)
                        }
                    }
                    .padding(.vertical, 8)
                    if id != apps.last?.0 { Hairline() }
                }
                if let error = tasks["error"] as? String, !error.isEmpty {
                    Text(error).font(Scaled.style(10, .regular)).foregroundStyle(.red).padding(.top, 6)
                }
            }

            // The iPhone section returns with the iPhone app (server/phone_sync.py is ready, and off).
            section("Notes", footer: "Referee writes your reading notes (one file per source, with links that open it at the page) and meeting notes into this folder as Markdown, and keeps them up to date. Edits made to these files in Obsidian are overwritten, so keep your own notes in your own files.") {
                row("Obsidian folder") {
                    folderControl($obsidianFolder) { WordSettings.obsidianFolder = $0 }
                }
            }

            section("Reading", footer: zoteroFooter) {
                if let collections = zotero["collections"] as? [[String: Any]] {
                    row("Zotero collection") {
                        Menu {
                            Button("None") { setZotero(nil) }
                            Divider()
                            ForEach(collections.indices, id: \.self) { i in
                                Button(collections[i]["name"] as? String ?? "") { setZotero(collections[i]["key"] as? String) }
                            }
                        } label: {
                            Text(collections.first { $0["key"] as? String == zotero["collection"] as? String }?["name"] as? String ?? "None")
                        }
                        .fixedSize()
                    }
                    if zotero["collection"] as? String != nil {
                        row("Adds papers to") {
                            Text(zotero["project"] as? String ?? "No project").foregroundStyle(.secondary)
                        }
                    }
                } else {
                    row("Zotero") { Text("Not running").foregroundStyle(.secondary) }
                }
            }

            section("Meetings", footer: "In Meetings, the calendar button lists your events from two days ago to a week ahead, from the calendars on this Mac, including Google Calendar: add your Google account in System Settings → Internet Accounts, with Calendars switched on. Referee only reads them. Choosing one starts its notes with the title, date and attendees.") {
                row("Calendar") { Text("Ready in Meetings").foregroundStyle(.secondary) }
            }
        }
        .frame(minWidth: 560, idealWidth: 620, minHeight: 600, idealHeight: 720)
        .task { await refresh() }
    }

    private var zoteroFooter: String {
        if zotero["collections"] == nil {
            return "Open Zotero 7 and switch on Settings → Advanced → \"Allow other applications on this computer to communicate with Zotero\". Nothing goes online: Referee reads Zotero on this Mac."
        }
        let imported = zotero["imported"] as? Int ?? 0
        return "Papers added to this Zotero collection join the current project, with the PDF Zotero has for them and Zotero's citation details. \(imported) added so far. Nothing is removed when you delete it in Zotero."
    }

    private func connected(_ id: String) -> Bool {
        switch id {
        case "todoist": return tasks["todoist"] as? Bool ?? false
        case "notion": return (tasks["notion"] as? [String: Any])?["connected"] as? Bool ?? false
        default: return false
        }
    }

    private func refresh() async {
        tasks = await API.get("tasks") ?? [:]
        app = tasks["app"] as? String ?? "none"
        zotero = await API.get("zotero") ?? [:]
        phone = await API.get("phone") ?? [:]
    }

    private func choose(_ id: String) {
        app = id
        Task { tasks = await API.post("tasks", ["app": id]) ?? tasks }
    }

    private func setZotero(_ collection: String?) {
        Task {
            zotero = await API.post("zotero", ["collection": collection ?? "", "project": model.project], timeout: 20) ?? zotero
        }
    }

    // MARK: Layout, matching Settings

    private func section<Content: View>(_ title: String, footer: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Hairline().padding(.top, 22).padding(.bottom, 10)
            FieldLabel(title)
            VStack(alignment: .leading, spacing: 0) { content() }
            if let footer {
                Text(footer).font(Scaled.style(10, .regular)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func row<Control: View>(_ label: String, @ViewBuilder control: () -> Control) -> some View {
        HStack {
            Text(label)
            Spacer()
            control()
        }
        .padding(.vertical, 8)
    }

    private func folderControl(_ folder: Binding<String>, save: @escaping (String) -> Void) -> some View {
        HStack(spacing: 8) {
            if !folder.wrappedValue.isEmpty {
                Text(URL(fileURLWithPath: folder.wrappedValue).lastPathComponent).foregroundStyle(.secondary).help(folder.wrappedValue)
                Button("Clear") { folder.wrappedValue = ""; save("") }
            }
            Button(folder.wrappedValue.isEmpty ? "Choose" : "Change") {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                panel.canCreateDirectories = true
                panel.prompt = "Choose"
                panel.message = "Choose a folder inside your Obsidian vault, such as a new folder called Referee."
                if panel.runModal() == .OK, let url = panel.url { folder.wrappedValue = url.path; save(url.path) }
            }
        }
    }
}

/// Notion: an integration token and the task database shared with it.
struct NotionView: View {

    let changed: () -> Void
    @State private var token = ""
    @State private var database = ""
    @State private var message: String?
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SecureField("Integration token", text: $token).textFieldStyle(.roundedBorder)
            TextField("Database link", text: $database).textFieldStyle(.roundedBorder)
            HStack {
                Button(working ? "Checking…" : "Connect") { connect() }.disabled(token.isEmpty || database.isEmpty || working)
                Button("Disconnect") { Task { _ = await API.delete("notion"); changed() } }
            }
            Text(message ?? "Make an integration at notion.so/profile/integrations and copy its token. Open your task database, choose ••• → Connections and add the integration, then copy the database's link. It needs a checkbox column for done; a date column and a column called Project are used if it has them.")
                .font(Scaled.style(10, .regular)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func connect() {
        working = true
        Task {
            let result = await API.post("notion", ["token": token, "database": database], timeout: 20)
            working = false
            if result?["ok"] as? Bool == true {
                message = "Connected to \(result?["name"] as? String ?? "your database")."
                token = ""
                changed()
            } else {
                message = result?["reason"] as? String ?? "Referee isn't running. Open it and try again."
            }
        }
    }
}
