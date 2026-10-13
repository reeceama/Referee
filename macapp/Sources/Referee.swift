import AppKit
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

let server = URL(string: "http://localhost:8000")!

/// What the menu shows, refreshed every few seconds from the server.
@MainActor
final class Model: ObservableObject {

    static let shared = Model()

    @Published var online = false
    @Published var focus = false
    @Published var writing = false
    @Published var helper = false
    @Published var project = ""
    @Published var projects: [String] = []
    @Published var keepMinutes = 15
    @Published var saved = 0
    @Published var temporary = 0
    @Published var style = WordSettings.style
    @Published var openAtLogin = SMAppService.mainApp.status == .enabled
    @Published var hasKey = true
    @Published var keyEnds = ""
    @Published var keySource = ""

    var capturing: Bool { focus || writing }
    private var timer: Timer?

    init() {
        refresh()
        // The keyboard shortcut changes research mode outside the menu: show it straight away.
        NotificationCenter.default.addObserver(forName: .researchChanged, object: nil, queue: .main) { _ in
            Task { @MainActor in self.refresh() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            Task { @MainActor in self.refresh() }
        }
    }

    func refresh() {
        Task {
            let status = await API.get("writing")
            let settings = await API.get("settings")
            let sources = await API.getList("sources")
            online = status != nil && settings != nil
            focus = status?["focus"] as? Bool ?? false
            writing = status?["active"] as? Bool ?? false
            helper = status?["helper"] as? Bool ?? false
            project = settings?["project"] as? String ?? ""
            projects = settings?["projects"] as? [String] ?? []
            keepMinutes = settings?["keep_minutes"] as? Int ?? 15
            temporary = sources.filter { ($0["kept"] as? Bool) == false }.count
            saved = sources.count - temporary
            style = WordSettings.style
            if let key = await API.get("api-key") {
                hasKey = key["has_key"] as? Bool ?? false
                keyEnds = key["ends"] as? String ?? ""
                keySource = key["source"] as? String ?? ""
            }
        }
    }

    /// Checks the key with Anthropic and saves it in the Keychain. Returns a problem, or nil.
    func saveKey(_ key: String) async -> String? {
        let result = await API.post("api-key", ["key": key], timeout: 30)  // checked with Anthropic first
        refresh()
        if result == nil { return "Referee's server isn't running." }
        return (result?["ok"] as? Bool ?? false) ? nil : result?["reason"] as? String
    }

    /// Saves a web page, PDF link or YouTube video into the current project. Returns a problem, or nil.
    func addLink(_ link: String) async -> String? {
        // Reading and indexing a page, PDF or video takes a while: wait up to two minutes.
        let result = await API.post("sources/add-url", ["url": link], timeout: 120)
        refresh()
        if result == nil { return "Referee didn't finish reading it in time. Check the Library: it may still have been added." }
        return (result?["ok"] as? Bool ?? false) ? nil : result?["reason"] as? String ?? "Couldn't read that page."
    }

    /// Saves a PDF from this Mac into the current project. Returns a problem, or nil.
    func addPDF(_ file: URL) async -> String? {
        guard let data = try? Data(contentsOf: file) else { return "Couldn't open that file." }
        let result = await API.post("sources/add-pdf", ["name": file.path, "data": data.base64EncodedString()], timeout: 120)
        refresh()
        if result == nil { return "Referee didn't finish reading it in time. Check the Library: it may still have been added." }
        return (result?["ok"] as? Bool ?? false) ? nil : result?["reason"] as? String ?? "Couldn't read that PDF."
    }

    func removeKey() {
        Task {
            var request = URLRequest(url: server.appendingPathComponent("api-key"))
            request.httpMethod = "DELETE"
            request.setValue("1", forHTTPHeaderField: "X-Referee")
            _ = try? await URLSession.shared.data(for: request)
            refresh()
        }
    }

    func setResearch(_ on: Bool) {
        Task { _ = await API.post("focus", ["on": on]); refresh() }
    }

    func setProject(_ name: String) {
        Task { _ = await API.post("settings", ["project": name]); refresh() }
    }

    func setKeep(_ minutes: Int) {
        Task { _ = await API.post("settings", ["keep_minutes": minutes]); refresh() }
    }

    func setStyle(_ value: String) {
        WordSettings.style = value
        style = value
    }

    func setOpenAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("Referee couldn't change Open at Login: \(error)")
        }
        openAtLogin = SMAppService.mainApp.status == .enabled
    }
}

/// The server's JSON API. Requests carry the header the server requires of Referee's apps.
enum API {

    static func request(_ path: String, body: [String: Any]? = nil, timeout: TimeInterval = 4) async -> Data? {
        let url = path.contains("?") ? URL(string: "\(server.absoluteString)/\(path)")! : server.appendingPathComponent(path)
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue("1", forHTTPHeaderField: "X-Referee")
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        return try? await URLSession.shared.data(for: request).0
    }

    static func get(_ path: String) async -> [String: Any]? {
        guard let data = await request(path) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func getList(_ path: String) async -> [[String: Any]] {
        guard let data = await request(path) else { return [] }
        return (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
    }

    /// A GET whose path already carries a query string.
    static func getPath(_ path: String) async -> [String: Any]? {
        var request = URLRequest(url: URL(string: "\(server.absoluteString)/\(path)")!, timeoutInterval: 4)
        request.setValue("1", forHTTPHeaderField: "X-Referee")
        guard let data = try? await URLSession.shared.data(for: request).0 else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func delete(_ path: String) async -> [String: Any]? {
        var request = URLRequest(url: URL(string: "\(server.absoluteString)/\(path)")!, timeoutInterval: 4)
        request.httpMethod = "DELETE"
        request.setValue("1", forHTTPHeaderField: "X-Referee")
        guard let data = try? await URLSession.shared.data(for: request).0 else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func post(_ path: String, _ body: [String: Any], timeout: TimeInterval = 4) async -> [String: Any]? {
        guard let data = await request(path, body: body, timeout: timeout) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

/// The Word helper's citation style, kept in ~/.referee/config.json.
enum WordSettings {

    static let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".referee/config.json")

    private static var config: [String: Any] {
        get {
            guard let data = try? Data(contentsOf: file),
                  let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
            return config
        }
        set {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let data = try? JSONSerialization.data(withJSONObject: newValue, options: .prettyPrinted) { try? data.write(to: file) }
        }
    }

    static var style: String {
        get { config["style"] as? String ?? "apa" }
        set { config["style"] = newValue }
    }

    /// A project's code, which Referee checks the writing against: libraries that should be
    /// cited, and figures that no longer match the results. Empty when none is chosen.
    static var codeFolder: String {
        get { config["code_folder"] as? String ?? "" }
        set { config["code_folder"] = newValue.isEmpty ? nil : newValue }
    }

    /// Whether the Word helper types citations in itself, or suggests them in a comment (the default).
    static var autoCite: Bool {
        get { config["auto_cite"] as? Bool ?? false }
        set { config["auto_cite"] = newValue }
    }

    /// Whether the Overleaf panel inserts supported citations itself, or offers an Insert button (the default).
    static var overleafAutoCite: Bool {
        get { config["overleaf_auto_cite"] as? Bool ?? false }
        set { config["overleaf_auto_cite"] = newValue }
    }

    /// Your name as you write it in meetings' "who", so your action points can go to Todoist.
    static var yourName: String {
        get { config["your_name"] as? String ?? "" }
        set { config["your_name"] = newValue.trimmingCharacters(in: .whitespaces) }
    }

    /// How the Word helper marks the sentences it checks: "underline", "highlight" or "none"
    /// (citations and comments are added either way).
    static var marks: String {
        get { config["marks"] as? String ?? ((config["highlight"] as? Bool ?? true) ? "underline" : "none") }
        set { config["marks"] = newValue }
    }

    /// Asks the Word helper to remove the underlines or highlights Referee added, and shows what it did.
    static func removeMarks() {
        Task { @MainActor in
            _ = await API.post("word/request", ["request": "clear-marks", "result": ""])
            for _ in 0..<20 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                let status = await API.get("word/request")
                if (status?["request"] as? String ?? "").isEmpty, let result = status?["result"] as? String, !result.isEmpty {
                    show("Marks removed", result)
                    return
                }
            }
            _ = await API.post("word/request", ["request": "", "result": ""])
            show("Couldn't remove marks", "Open the document in Word and try again. The Word helper only works on the document in front.")
        }
    }

    @MainActor private static func show(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

/// Puts the browser extension somewhere a browser can load it from (browsers can't look inside an
/// app), shows that folder, and opens the browser's extensions page with instructions.
enum BrowserExtension {

    static let installed = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Referee/extension")

    static func install(repo: URL) {
        let source = Services.bundled?.appendingPathComponent("extension") ?? repo.appendingPathComponent("extension")
        let files = FileManager.default
        try? files.createDirectory(at: installed.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? files.removeItem(at: installed)
        do {
            try files.copyItem(at: source, to: installed)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't set up the extension"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            return
        }
        let browser = ["Brave Browser", "Google Chrome", "Chromium"].first { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID($0)) != nil }
        let alert = NSAlert()
        alert.messageText = "Install the Referee extension"
        alert.informativeText = """
        1. In \(browser ?? "Brave or Chrome"), open the extensions page (it's opening now) and turn on Developer mode.
        2. Click Load unpacked and choose the "extension" folder that Finder is showing.

        The extension collects what you read while you write. Without it, add sources with Add Source.
        """
        NSWorkspace.shared.activateFileViewerSelecting([installed])
        if let browser {
            let page = browser == "Brave Browser" ? "brave://extensions" : "chrome://extensions"
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            task.arguments = ["-a", browser, page]
            try? task.run()
        }
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private static func bundleID(_ app: String) -> String {
        ["Brave Browser": "com.brave.Browser", "Google Chrome": "com.google.Chrome", "Chromium": "org.chromium.Chromium"][app] ?? ""
    }
}

let styles = [("apa", "APA 7"), ("harvard", "Harvard"), ("mla", "MLA 9"), ("chicago", "Chicago"), ("ieee", "IEEE (Numbered)"), ("ams", "AMS (Numbered)"), ("vancouver", "Vancouver (Numbered)")]
let keepOptions = [(15, "15 Minutes"), (60, "1 Hour"), (1440, "1 Day")]

struct MenuContent: View {

    @ObservedObject var model: Model
    let repo: URL
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(statusLine)
        Text("\(model.saved) Saved · \(model.temporary) Temporary")
        if model.online && !model.hasKey {
            Button("Add API Key…") { show("integrations") }
        }
        Divider()
        Toggle("Research Mode", isOn: Binding(get: { model.focus }, set: { model.setResearch($0) }))
        Menu("Project") {
            Picker("Project", selection: Binding(get: { model.project }, set: { model.setProject($0) })) {
                Text("No Project").tag("")
                ForEach(model.projects, id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            Divider()
            Button("New Project…") { show("new-project") }
        }
        Menu("Keep Unsaved Reading For") {
            Picker("Keep", selection: Binding(get: { model.keepMinutes }, set: { model.setKeep($0) })) {
                ForEach(keepOptions, id: \.0) { Text($0.1).tag($0.0) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
        Divider()
        Button("Add Source…") { show("add-source") }
        Button("Remove Marks in Word") { WordSettings.removeMarks() }
        Button("Install Browser Extension…") { BrowserExtension.install(repo: repo) }
        Button("Open Library") { show("library") }
        Button("Notes") { show("notes") }
        Button("Meetings") { show("meetings") }
        Button("AI Use") { show("ai-use") }
        Button("Settings…") { show("settings") }
            .keyboardShortcut(",")
        if Updater.shared.current != nil {
            Button("Check for Updates…") { Updater.shared.check(manually: true) }
        }
        Divider()
        Button("Quit Referee") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private var statusLine: String {
        if !model.online { return "Server Not Running" }
        if !model.hasKey { return "No API Key" }
        let state = model.focus ? "Research Mode On" : model.writing ? "Writing: Capturing" : "Not Capturing"
        return model.helper ? state : "\(state) · Word Helper Not Running"
    }

    private func show(_ id: String) {
        openWindow(id: id)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Adds a source by hand: a link (web page, PDF or YouTube video) or a PDF on this Mac. Saved
/// into the current project, so Referee works without the browser extension.
struct AddSourceView: View {

    @ObservedObject var model: Model
    @State private var link = ""
    @State private var message: String?
    @State private var failed = false
    @State private var working = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "plus.rectangle.on.folder")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text("Add Source").font(.title3.weight(.semibold))
            }
            Text(model.project.isEmpty
                 ? "Paste a link to a page, PDF or YouTube video, or choose a PDF on this Mac."
                 : "Paste a link to a page, PDF or YouTube video, or choose a PDF on this Mac. It's saved to \(model.project).")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                TextField("https://…", text: $link)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit(addLink)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .glassCard()
                Button(working ? "Adding…" : "Add", action: addLink)
                    .disabled(link.trimmingCharacters(in: .whitespaces).isEmpty || working)
                    .prominentGlassButton()
            }
            HStack {
                Button("Choose a PDF…", action: choosePDF)
                    .disabled(working)
                    .glassButton()
                Spacer()
                if let message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(failed ? .orange : .green)
                        .multilineTextAlignment(.trailing)
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 20)
        .padding(.top, 4)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
        .background(WindowGlass().ignoresSafeArea())
        .onAppear { focused = true }
    }

    private func addLink() {
        let entered = link
        run { await model.addLink(entered) } done: { link = "" }
    }

    private func choosePDF() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let file = panel.url else { return }
        run { await model.addPDF(file) } done: {}
    }

    private func run(_ work: @escaping () async -> String?, done: @escaping () -> Void) {
        working = true
        message = nil
        Task {
            let problem = await work()
            working = false
            failed = problem != nil
            message = problem ?? "Saved."
            if problem == nil { done() }
        }
    }
}

struct NewProjectView: View {

    @ObservedObject var model: Model
    @State private var name = ""
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "folder.badge.plus")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text("New Project").font(.title3.weight(.semibold))
            }
            Text("It becomes the current project, so reading you save or cite goes into it.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Project name", text: $name)
                .textFieldStyle(.plain)
                .font(.body)
                .focused($focused)
                .onSubmit(create)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .glassCard()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .glassButton()
                Button("Create", action: create)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                    .prominentGlassButton()
            }
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 20)
        .padding(.top, 4)
        .frame(width: 360)
        .fixedSize(horizontal: false, vertical: true)
        .background(WindowGlass().ignoresSafeArea())
        .onAppear { focused = true }
    }

    private func create() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        model.setProject(trimmed)
        name = ""
        dismiss()
    }
}

struct SettingsView: View {

    @ObservedObject var model: Model
    @AppStorage("showInMenuBar") private var showInMenuBar = true
    @State private var marks = WordSettings.marks
    @State private var codeFolder = WordSettings.codeFolder
    @State private var autoCite = WordSettings.autoCite
    @State private var overleafAutoCite = WordSettings.overleafAutoCite
    @AppStorage("settingsWritingIn") private var writingIn = "word"
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // The header stays put; the cards scroll beneath it, so the window stays a sensible height.
        VStack(alignment: .leading, spacing: 14) {
            header
                .padding(.horizontal, 22)
                .padding(.top, 4)
            ScrollView {
                cards
                    .padding(.horizontal, 22)
                    .padding(.bottom, 22)
            }
            .scrollIndicators(.automatic)
        }
        .frame(width: 400, height: 560)
        .background(WindowGlass().ignoresSafeArea())
    }

    private var cards: some View {
        VStack(alignment: .leading, spacing: 18) {
            card(title: "Reading", symbol: "books.vertical") {
                row("Project") {
                    HStack(spacing: 8) {
                        Menu {
                            Picker("Project", selection: Binding(get: { model.project }, set: { model.setProject($0) })) {
                                Text("No Project").tag("")
                                ForEach(model.projects, id: \.self) { Text($0).tag($0) }
                            }
                            .pickerStyle(.inline)
                            .labelsHidden()
                        } label: {
                            Text(model.project.isEmpty ? "No Project" : model.project)
                        }
                        .fixedSize()
                        .glassButton()
                        Button {
                            openWindow(id: "new-project")
                            NSApp.activate(ignoringOtherApps: true)
                        } label: {
                            Image(systemName: "plus")
                        }
                        .help("New project")
                        .glassButton()
                    }
                }
                Divider().opacity(0.4)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Keep unsaved reading for")
                    Picker("Keep unsaved reading for", selection: Binding(get: { model.keepMinutes }, set: { model.setKeep($0) })) {
                        ForEach(keepOptions, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                }
                Divider().opacity(0.4)
                row("Research mode shortcut") {
                    ShortcutRecorder()
                }
            }
            card(title: "Writing", symbol: "doc.text") {
                Picker("Writing in", selection: $writingIn) {
                    Text("Word").tag("word")
                    Text("Overleaf").tag("overleaf")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                if writingIn == "word" {
                    row("Citation style") {
                        Menu {
                            Picker("Style", selection: Binding(get: { model.style }, set: { model.setStyle($0) })) {
                                ForEach(styles, id: \.0) { Text($0.1).tag($0.0) }
                            }
                            .pickerStyle(.inline)
                            .labelsHidden()
                        } label: {
                            Text(styles.first { $0.0 == model.style }?.1 ?? "APA 7")
                        }
                        .fixedSize()
                        .glassButton()
                    }
                    Divider().opacity(0.4)
                    row("Mark sentences with") {
                        Picker("Mark sentences with", selection: Binding(get: { marks }, set: { marks = $0; WordSettings.marks = $0 })) {
                            Text("Underline").tag("underline")
                            Text("Highlight").tag("highlight")
                            Text("Nothing").tag("none")
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    Divider().opacity(0.4)
                    row("Add citations automatically") {
                        Toggle("Add citations automatically", isOn: Binding(get: { autoCite }, set: { autoCite = $0; WordSettings.autoCite = $0 }))
                            .toggleStyle(.switch)
                            .labelsHidden()
                    }
                    Text("Green: supported. Amber: check the wording. Red: contradicted. Underlines show clearly in dark mode, where Word dims highlights. With automatic citations off, a comment suggests each citation for you to type, so you choose every one.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
            
                } else {
                    row("Citation style") {
                        Text("Set in your document").foregroundStyle(.secondary)
                    }
                    Text("LaTeX formats citations itself, using \\bibliographystyle in your document: amsplain for AMS. Referee suggests \\cite keys that match its BibTeX export.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Divider().opacity(0.4)
                    row("Add citations automatically") {
                        Toggle("Add citations automatically", isOn: Binding(get: { overleafAutoCite }, set: { overleafAutoCite = $0; WordSettings.overleafAutoCite = $0 }))
                            .toggleStyle(.switch)
                            .labelsHidden()
                    }
                    Text("Off: each suggested \\cite has an Insert button in the Referee panel, so you choose every one. On: they're added for you, except in the sentence you're editing.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Divider().opacity(0.4)
                    row("Code folder") {
                        HStack(spacing: 6) {
                            if !codeFolder.isEmpty {
                                Text(URL(fileURLWithPath: codeFolder).lastPathComponent)
                                    .foregroundStyle(.secondary)
                                    .help(codeFolder)
                                Button("Clear") { codeFolder = ""; WordSettings.codeFolder = "" }.glassButton()
                            }
                            Button(codeFolder.isEmpty ? "Choose…" : "Change…", action: chooseCodeFolder).glassButton()
                        }
                    }
                    Text("The code and results behind your writing. Referee lists libraries your code uses that should be cited, and figures in your writing that don't match your latest results.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            card(title: "Integrations", symbol: "puzzlepiece.extension") {
                HStack(spacing: 12) {
                    Text("Connect Referee to the other services you use.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Manage…") { Windows.open("integrations") }.glassButton().fixedSize()
                }
            }
            card(title: "General", symbol: "gearshape") {
                row("Open Referee at login") {
                    Toggle("Open Referee at login", isOn: Binding(get: { model.openAtLogin }, set: { model.setOpenAtLogin($0) }))
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
                Divider().opacity(0.4)
                row("Show in menu bar") {
                    Toggle("Show in menu bar", isOn: $showInMenuBar)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }

            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(nsImage: whistle(model.capturing))
                    .resizable()
                    .frame(width: 26, height: 26)
                Text("Referee").font(.title2.weight(.semibold)).fixedSize()
                Spacer()
                HStack(spacing: 6) {
                    Circle().fill(model.online ? (model.capturing ? Color.green : Color.secondary) : Color.orange)
                        .frame(width: 7, height: 7)
                    Text(!model.online ? "Server not running" : model.capturing ? "Capturing" : "Not capturing")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .glassCapsule()
            }
            // The other windows, on a row of their own so the header never squeezes them.
            HStack(spacing: 8) {
                Button { Windows.open("library") } label: { Label("Library", systemImage: "books.vertical").fixedSize() }.glassButton()
                Button { Windows.open("notes") } label: { Label("Notes", systemImage: "note.text").fixedSize() }.glassButton()
                Button { Windows.open("meetings") } label: { Label("Meetings", systemImage: "person.2").fixedSize() }.glassButton()
                Button { Windows.open("ai-use") } label: { Label("AI Use", systemImage: "checkmark.seal").fixedSize() }.glassButton()
                Spacer()
            }
        }
    }

    private func card<Content: View>(title: String, symbol: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 12) { content() }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassCard()
        }
    }

    private func row<Control: View>(_ label: String, @ViewBuilder control: () -> Control) -> some View {
        HStack {
            Text(label)
            Spacer()
            control()
        }
    }

    private func chooseCodeFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        codeFolder = folder.path
        WordSettings.codeFolder = folder.path
    }
}

/// Paste-in API key: checked with Anthropic, then kept in the Keychain. The key is never shown again.
struct ApiKeyView: View {

    @ObservedObject var model: Model
    @State private var key = ""
    @State private var problem: String?
    @State private var checking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.hasKey {
                HStack {
                    Label("Key saved, ending …\(model.keyEnds)", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                    Spacer()
                    if model.keySource == "password store" {
                        Button("Remove") { model.removeKey() }.glassButton()
                    }
                }
                if model.keySource == "env" {
                    Text("From server/.env. Paste a key below to keep it in the Keychain instead.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("Referee checks claims with Claude, using your own Anthropic API key. Create one at console.anthropic.com.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                SecureField(model.hasKey ? "Replace with a new key" : "Paste your API key (sk-ant-…)", text: $key)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .glassCard()
                    .onSubmit(save)
                Button(checking ? "Checking…" : "Save", action: save)
                    .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty || checking)
                    .prominentGlassButton()
            }
            if let problem {
                Text(problem).font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private func save() {
        let entered = key
        checking = true
        problem = nil
        Task {
            problem = await model.saveKey(entered)
            checking = false
            if problem == nil { key = "" }
        }
    }
}

func whistle(_ filled: Bool) -> NSImage {
    let image = Bundle.main.image(forResource: filled ? "whistleOnTemplate" : "whistleOffTemplate") ?? NSImage()
    image.isTemplate = true
    return image
}

// Liquid Glass on macOS 26, frosted material on earlier versions.
extension View {

    @ViewBuilder func glassCard() -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: .rect(cornerRadius: 16))
        } else {
            self.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
    }

    @ViewBuilder func glassCapsule() -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: .capsule)
        } else {
            self.background(.regularMaterial, in: Capsule())
        }
    }

    @ViewBuilder func prominentGlassButton() -> some View {
        if #available(macOS 26.0, *) {
            self.buttonStyle(.glassProminent)
        } else {
            self.buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder func glassButton() -> some View {
        if #available(macOS 26.0, *) {
            self.buttonStyle(.glass)
        } else {
            self.buttonStyle(.bordered)
        }
    }
}

/// Makes the settings window itself translucent, with its title bar hidden.
struct WindowGlass: NSViewRepresentable {

    func makeNSView(context: Context) -> NSView {
        let view = NSVisualEffectView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .active
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.styleMask.insert(.fullSizeContentView)
            window.isMovableByWindowBackground = true
            window.backgroundColor = .clear
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// The repository this app was built from: its Python parts and the extension folder.
let repository = URL(fileURLWithPath: Bundle.main.object(forInfoDictionaryKey: "RefereeRepository") as? String ?? "")

/// Connects Todoist: your meeting action points become tasks, and ticking either off ticks off both.
struct TodoistView: View {

    @State private var connected = false
    @State private var token = ""
    @State private var name = WordSettings.yourName
    @State private var message: String?
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Your name in meetings")
                Spacer()
                TextField("Your name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
                    .onSubmit { WordSettings.yourName = name }
                    .onChange(of: name) { _, value in WordSettings.yourName = value }
            }
            Divider().opacity(0.4)
            if connected {
                HStack {
                    Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    Spacer()
                    Button("Sync Now") { Task { _ = await API.post("todoist/sync", [:]); message = "Syncing…" } }.glassButton()
                    Button("Disconnect") { Task { _ = await API.delete("todoist"); await refresh() } }.glassButton()
                }
            } else {
                HStack {
                    SecureField("Todoist API token", text: $token).textFieldStyle(.roundedBorder)
                    Button(working ? "Checking…" : "Connect") { connect() }.glassButton().disabled(token.isEmpty || working)
                }
            }
            Text(message ?? (connected
                ? "Action points for you, \"me\" or everyone go to a Todoist project named after their Referee project. Ticking one off in either app ticks it off in both."
                : "Find your token in Todoist: Settings, Integrations, Developer. It's kept in your Keychain."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .task { await refresh() }
    }

    private func refresh() async {
        connected = (await API.get("todoist"))?["connected"] as? Bool ?? false
    }

    private func connect() {
        working = true
        message = nil
        let entered = token
        Task {
            let result = await API.post("todoist", ["token": entered], timeout: 20)
            working = false
            if result?["ok"] as? Bool == true {
                token = ""
                message = nil
                await refresh()
            } else {
                message = result?["reason"] as? String ?? "Referee isn't running. Open it and try again."
            }
        }
    }
}

/// Opens Referee's windows by id, from anywhere. SwiftUI only lets views open windows, so any
/// view that appears (the menu bar icon, or any window) hands over its opener. With none yet, as
/// when the menu bar icon is hidden and no window is open, the window is made directly.
@MainActor enum Windows {

    static var opener: ((String) -> Void)?
    private static var made: [String: NSWindow] = [:]

    static func open(_ id: String) {
        NSApp.activate(ignoringOtherApps: true)
        if let opener {
            opener(id)
            return
        }
        if let window = made[id] {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let view = id == "library" ? AnyView(LibraryView()) : id == "meetings" ? AnyView(MeetingsView()) : id == "ai-use" ? AnyView(AIUseView()) : id == "integrations" ? AnyView(IntegrationsView(model: .shared)) : id == "notes" ? AnyView(NotesView()) : AnyView(SettingsView(model: .shared))
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.center()
        made[id] = window
        window.makeKeyAndOrderFront(nil)
    }
}

/// Hands Windows a SwiftUI window opener. Put on the menu bar icon and on every window.
struct WindowOpener: View {

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear.frame(width: 0, height: 0).onAppear {
            Windows.opener = { id in openWindow(id: id) }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {

    let services: Services? = Services(repo: repository)
    private var openedAtLogin = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Started by macOS at login: stay in the menu bar. Opened by the person: show settings.
        let event = NSAppleEventManager.shared().currentAppleEvent
        openedAtLogin = event?.eventID == AEEventID(kAEOpenApplication)
            && event?.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == AEEventClass(keyAELaunchedAsLogInItem)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        services?.startAll()
        Updater.shared.start()
        Shortcut.shared.start()
        if !openedAtLogin { showSettingsWhenReady(attempts: 8) }
    }

    /// The menu bar icon hands over SwiftUI's window opener shortly after launch; wait briefly for
    /// it, then open settings either way (directly, if the icon is hidden).
    private func showSettingsWhenReady(attempts: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            if Windows.opener != nil || attempts == 0 { Windows.open("settings") } else { self.showSettingsWhenReady(attempts: attempts - 1) }
        }
    }

    // Clicking the app's icon again (in Applications, Spotlight or Launchpad) opens settings.
    // referee:// links clicked in a planner, Todoist or anywhere else.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { RefereeLinks.handle(url) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Windows.open("settings")
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        services?.stopAll()
    }
}

@main
struct RefereeApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var model = Model.shared
    @AppStorage("showInMenuBar") private var showInMenuBar = true
    let repo = repository

    var body: some Scene {
        MenuBarExtra(isInserted: $showInMenuBar) {
            MenuContent(model: model, repo: repo)
        } label: {
            // The whistle: filled while capturing, an outline when idle.
            Image(nsImage: icon(model.capturing ? "whistleOnTemplate" : "whistleOffTemplate"))
                .background(WindowOpener())
            if !model.online { Text("⚠︎") }
        }
        Window("Library", id: "library") {
            LibraryView().background(WindowOpener())
        }
        .windowStyle(.hiddenTitleBar)
        Window("Notes", id: "notes") {
            NotesView().background(WindowOpener())
        }
        .windowStyle(.hiddenTitleBar)
        Window("Integrations", id: "integrations") {
            IntegrationsView(model: model).background(WindowOpener())
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        Window("AI Use", id: "ai-use") {
            AIUseView().background(WindowOpener())
        }
        .windowStyle(.hiddenTitleBar)
        Window("Meetings", id: "meetings") {
            MeetingsView().background(WindowOpener())
        }
        .windowStyle(.hiddenTitleBar)
        Window("Add Source", id: "add-source") {
            AddSourceView(model: model).background(WindowOpener())
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        Window("New Project", id: "new-project") {
            NewProjectView(model: model).background(WindowOpener())
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        Window("Referee Settings", id: "settings") {
            SettingsView(model: model).background(WindowOpener())
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
    }

    private func icon(_ name: String) -> NSImage {
        let image = Bundle.main.image(forResource: name) ?? NSImage()
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        return image
    }
}
