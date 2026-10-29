import AppKit
import SwiftUI

/// Settings' privacy, backup and help sections.

/// What leaves this device: everything Referee can send off the Mac, what's sent, where and when,
/// with a real switch where one can be turned off here.
struct PrivacySection: View {

    @State private var state: [String: Any] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What leaves this device").font(Fonts.heading(28, .regular)).padding(.bottom, 4)
            Text("Everything Referee can send off your Mac, and when. Your reading, notes and writing stay here unless a line below says otherwise.")
                .font(Scaled.style(10, .regular)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            heading("Checking your writing")
            line("Claim checks", to: provider == "ollama" ? "on this Mac" : provider == "openai" ? "OpenAI" : "Anthropic",
                 about: provider == "ollama"
                    ? "The model on this Mac checks each sentence. Nothing is sent."
                    : "For each check: the sentence and the few passages from your reading that might back it. With no internet, a model on this Mac checks instead, if one is installed.") {
                Text(provider == "ollama" ? "Nothing sent" : "In use").font(Scaled.style(10, .regular)).foregroundStyle(.secondary)
            }
            line("Comparing theorems with papers", to: provider == "ollama" ? "off" : provider == "openai" ? "OpenAI" : "Anthropic",
                 about: provider == "ollama" ? "Off while checking on this Mac." : "Your theorem or definition, and passages from the paper it cites.") {
                Text(provider == "ollama" ? "Nothing sent" : "In use").font(Scaled.style(10, .regular)).foregroundStyle(.secondary)
            }

            Text("Don't check writing that contains personal, financial or health data unless your organisation allows it.")
                .font(Scaled.style(10, .regular)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)

            heading("Notes")
            line("Claude writes lines for notes from search", to: "Anthropic",
                 about: "Off (the default): you write the line yourself, with the passage quoted below it, as writing it is part of learning it. On: the passage is sent to write it for you. Checking your summary (right-click a note) sends it and the passage.") {
                toggle("note_lines")
            }
            line("Sorting notes into topics", to: "Anthropic",
                 about: "For Notes → Filter → Topics: each new or changed note's title and first lines, once. Off: no topics.") {
                toggle("note_topics")
            }

            heading("Finding sources")
            line("Paper details", to: "doi.org, Crossref, arXiv",
                 about: "A saved paper's DOI, arXiv number or title, to fetch its citation details, abstract, retraction status and LaTeX source. Off: papers are saved with only what's on the page.") {
                toggle("paper_details")
            }
            line("Adding a link", to: "the site you add", about: "Referee opens the page you give it, as your browser would.") {
                Text("When you add one").font(Scaled.style(10, .regular)).foregroundStyle(.secondary)
            }
            line("Search model", to: "Hugging Face", about: "Downloaded once, the first time Referee runs (about 90 MB). Searching your reading then happens on this Mac.") {
                Text("Once").font(Scaled.style(10, .regular)).foregroundStyle(.secondary)
            }

            heading("Connected apps")
            line("Tasks", to: tasksDestination, about: tasksAbout) {
                Text(tasksApp == "none" ? "Nothing sent" : "In use").font(Scaled.style(10, .regular)).foregroundStyle(.secondary)
            }
            line("Google Docs and Notion panels", to: "your browser", about: "The browser extension reads the open document in your own browser, and sends its sentences only to Referee on this Mac.") {
                Text("Nothing sent").font(Scaled.style(10, .regular)).foregroundStyle(.secondary)
            }

            heading("Referee itself")
            line("Update checks", to: "github.com", about: "Once a day, asks GitHub for the newest release. Nothing about you is sent. Off: check by hand in About.") {
                toggle("update_checks")
            }
            line("Ollama download", to: "ollama.com", about: "Only if you choose a model on this Mac in Setup: Ollama and the model are downloaded once.") {
                Text("Once").font(Scaled.style(10, .regular)).foregroundStyle(.secondary)
            }

            Text("Things, Reminders, Calendar, Zotero and Obsidian are on this Mac, so nothing is sent to them over the internet. To encrypt everything Referee keeps, turn on FileVault in System Settings → Privacy & Security.")
                .font(Scaled.style(10, .regular)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
        }
        .task { state = await API.get("privacy") ?? [:] }
    }

    private var provider: String { state["provider"] as? String ?? "claude" }
    private var phoneOn: Bool { state["phone"] as? Bool ?? false }
    private var tasksApp: String { state["tasks_app"] as? String ?? "none" }

    private var tasksDestination: String {
        switch tasksApp {
        case "todoist": return "todoist.com"
        case "notion": return "notion.so"
        case "things": return "Things, on this Mac"
        case "reminders": return "Reminders, on this Mac"
        default: return "none"
        }
    }

    private var tasksAbout: String {
        switch tasksApp {
        case "todoist", "notion": return "Your own tasks: their text, due date and project name. Choose None in Integrations to stop."
        case "things", "reminders": return "Sent to an app on this Mac, which may sync them through its own account."
        default: return "Tasks stay in Referee."
        }
    }

    private func heading(_ text: String) -> some View {
        Text(text).font(.subheadline.weight(.medium)).padding(.top, 10)
    }

    private func line<Control: View>(_ title: String, to: String, about: String, @ViewBuilder control: () -> Control) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(title)
                        Text("· \(to)").font(Scaled.style(10, .regular)).foregroundStyle(Color.accentColor)
                    }
                    Text(about).font(Scaled.style(10, .regular)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                control()
            }
            .padding(.vertical, 8)
            Hairline()
        }
    }

    private func toggle(_ name: String) -> some View {
        Toggle("", isOn: Binding(get: { state[name] as? Bool ?? true }, set: { on in
            state[name] = on
            Task { _ = await API.post("privacy", ["name": name, "on": on]) }
        }))
        .toggleStyle(.switch).labelsHidden()
    }
}

/// Back up and restore everything Referee keeps, and weekly backups.
struct BackupSection: View {

    @State private var automatic: [String: Any] = [:]
    @State private var message: String?
    @State private var confirmRestore: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Backups").font(Scaled.style(13, .semibold)).padding(.leading, 4)
            VStack(spacing: 0) {
            HStack {
                Text("Back up Referee")
                Spacer()
                Button("Back Up…") { backUp() }
                Button("Restore…") { chooseRestore() }
            }
            .padding(.vertical, 8)
            Hairline()
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Automatic backups")
                    if let folder = automatic["folder"] as? String {
                        Text("Weekly, in \(URL(fileURLWithPath: folder).lastPathComponent), keeping the last 4").font(Scaled.style(10, .regular)).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Toggle("", isOn: Binding(get: { automatic["on"] as? Bool ?? false }, set: { setAutomatic($0) }))
                    .toggleStyle(.switch).labelsHidden()
            }
            .padding(.vertical, 8)
            }
            .settingsBox()
            Text(message ?? "Your library, notes, meetings, AI use, Evidence reports and settings, in one file. Keys stay in your Keychain and aren't included.")
                .font(Scaled.style(11, .regular)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
        }
        .task { automatic = await API.get("backups") ?? [:] }
        .confirmationDialog("Restore this backup?", isPresented: Binding(get: { confirmRestore != nil }, set: { if !$0 { confirmRestore = nil } })) {
            Button("Restore", role: .destructive) { if let url = confirmRestore { restore(url) } }
            Button("Cancel", role: .cancel) { confirmRestore = nil }
        } message: {
            Text("Everything in Referee is replaced with the backup. What's there now is backed up first, so you can go back.")
        }
    }

    private func folder(_ prompt: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = prompt
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func backUp() {
        guard let url = folder("Back Up Here") else { return }
        Task {
            let result = await API.post("backups", ["folder": url.path], timeout: 60)
            message = result?["ok"] as? Bool == true
                ? "Backed up to \((result?["path"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent } ?? "the folder")."
                : result?["reason"] as? String ?? "Couldn't back up."
        }
    }

    private func setAutomatic(_ on: Bool) {
        if on {
            guard let url = folder("Back Up Here Weekly") else { return }
            Task {
                _ = await API.post("backups", ["folder": url.path, "automatic": true], timeout: 60)
                automatic = await API.get("backups") ?? [:]
            }
        } else {
            Task {
                _ = await API.post("backups", ["folder": automatic["folder"] as? String ?? "/", "automatic": false])
                automatic = await API.get("backups") ?? [:]
            }
        }
    }

    private func chooseRestore() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.zip]
        panel.prompt = "Restore"
        if panel.runModal() == .OK, let url = panel.url { confirmRestore = url }
    }

    private func restore(_ url: URL) {
        Task {
            let result = await API.post("backups/restore", ["path": url.path], timeout: 60)
            if result?["ok"] as? Bool == true {
                message = "Restored. Referee is restarting to load it."
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                Relaunch.now()
            } else {
                message = result?["reason"] as? String ?? "Couldn't restore."
            }
        }
    }
}

/// Reopens Referee, so its server loads restored data.
enum Relaunch {
    static func now() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 1; open \"\(Bundle.main.bundlePath)\""]
        try? task.run()
        NSApp.terminate(nil)
    }
}

/// A new GitHub issue with Referee's and macOS's versions filled in. Nothing is sent: the person
/// writes the rest in their browser and posts it themselves.
@MainActor
enum ReportProblem {
    static func open() {
        let version = Updater.shared.current ?? "built from the code"
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        let body = """
        **What happened**


        **What you expected**


        **Steps to make it happen again**
        1.

        ---
        Referee \(version) · macOS \(os)
        """
        var parts = URLComponents(string: "https://github.com/reeceama/Referee/issues/new")!
        parts.queryItems = [URLQueryItem(name: "body", value: body)]
        if let url = parts.url { NSWorkspace.shared.open(url) }
    }
}
