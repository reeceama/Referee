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
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in self.refresh(full: false) }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            Task { @MainActor in
                self.ticks += 1
                // In the background (another app in front), every 30 seconds rather than 5: coming
                // back refreshes at once.
                if !NSApp.isActive && self.settingsLoaded && self.ticks % 6 != 0 { return }
                // The full refresh once a minute, and every tick until the first one has worked (at launch
                // the server may still be starting, and the project would show as "No project").
                self.refresh(full: self.ticks % 12 == 0 || !self.settingsLoaded)
            }
        }
    }

    private var ticks = 0
    private var settingsLoaded = false

    /// Every 5 seconds: whether Referee's server is up, research mode and writing (cheap). The source
    /// counts, projects and key only every minute, or when something asks (full). Values are set only
    /// when they change: each change redraws every window watching them.
    func refresh(full: Bool = true) {
        Task {
            let status = await API.get("writing")
            set(\.online, status != nil)
            set(\.focus, status?["focus"] as? Bool ?? false)
            set(\.writing, status?["active"] as? Bool ?? false)
            set(\.helper, status?["helper"] as? Bool ?? false)
            guard full else { return }
            let settings = await API.get("settings")
            if settings != nil { settingsLoaded = true }
            let sources = await API.getList("sources")
            set(\.online, status != nil && settings != nil)
            set(\.project, settings?["project"] as? String ?? "")
            set(\.projects, settings?["projects"] as? [String] ?? [])
            set(\.keepMinutes, settings?["keep_minutes"] as? Int ?? 15)
            let temporary = sources.filter { ($0["kept"] as? Bool) == false }.count
            set(\.temporary, temporary)
            set(\.saved, sources.count - temporary)
            set(\.style, WordSettings.style)
            if let key = await API.get("api-key") {
                set(\.hasKey, key["has_key"] as? Bool ?? false)
                set(\.keyEnds, key["ends"] as? String ?? "")
                set(\.keySource, key["source"] as? String ?? "")
            }
        }
    }

    private func set<Value: Equatable>(_ path: ReferenceWritableKeyPath<Model, Value>, _ value: Value) {
        if self[keyPath: path] != value { self[keyPath: path] = value }
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
        let result = await API.post("sources/add-pdf", ["name": file.path, "data": data.base64EncodedString()], timeout: 600)   // a scan is read a page at a time
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

    /// Someone who used Referee before the setup existed has settings already: no setup for them.
    static var hasConfig: Bool { FileManager.default.fileExists(atPath: file.path) }

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

    /// A switch on "What leaves this device" (on unless switched off).
    static func privacySwitch(_ name: String) -> Bool {
        (config["privacy"] as? [String: Any])?[name] as? Bool ?? true
    }

    /// A folder in the Obsidian vault that Referee writes notes and meetings into.
    static var obsidianFolder: String {
        get { config["obsidian_folder"] as? String ?? "" }
        set { config["obsidian_folder"] = newValue.isEmpty ? nil : newValue }
    }

    /// Which model checks claims: "ollama" (on this Mac) or "claude" (Anthropic, with the
    /// person's key). Empty until chosen: the server then uses Ollama if it has a model.
    static var aiProvider: String {
        get { config["ai_provider"] as? String ?? "" }
        set { config["ai_provider"] = newValue }
    }

    /// Which model compares theorems and definitions with papers: "auto" (Claude Sonnet if connected,
    /// otherwise ChatGPT), "claude", "openai" or "off". Never a model on this Mac: none is careful enough.
    static var theoremProvider: String {
        get { config["theorem_provider"] as? String ?? "auto" }
        set { config["theorem_provider"] = newValue }
    }

    static var ollamaModel: String {
        get { config["ollama_model"] as? String ?? "" }
        set { config["ollama_model"] = newValue }
    }

    /// Writing kept as files, which Referee watches and checks: an Obsidian vault, or a folder of
    /// R Markdown and Quarto documents. Empty when none is chosen.
    static var writingFolder: String {
        get { config["writing_folder"] as? String ?? "" }
        set { config["writing_folder"] = newValue.isEmpty ? nil : newValue }
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
    /// quietly: from the keyboard shortcut, success is a sound rather than a window over Word.
    static func removeMarks(quietly: Bool = false) {
        Task { @MainActor in
            _ = await API.post("word/request", ["request": "clear-marks", "result": ""])
            for _ in 0..<20 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                let status = await API.get("word/request")
                if (status?["request"] as? String ?? "").isEmpty, let result = status?["result"] as? String, !result.isEmpty {
                    if quietly { NSSound(named: "Glass")?.play() } else { show("Marks removed", result) }
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

    /// Whether web links open in Safari, which can't run the extension.
    static var defaultIsSafari: Bool {
        guard let app = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!) else { return false }
        return Bundle(url: app)?.bundleIdentifier == "com.apple.Safari"
    }

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
            Button("Add API Key") { show("integrations") }
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
            Button("New Project") { show("new-project") }
        }
        Menu("Keep Unsaved Reading For") {
            Picker("Keep", selection: Binding(get: { model.keepMinutes }, set: { model.setKeep($0) })) {
                ForEach(keepOptions, id: \.0) { Text($0.1).tag($0.0) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
        Divider()
        Button { show("add-source") } label: { Label("Add Source", systemImage: "plus") }
        Divider()
        // The main window's sections, named and drawn as in its sidebar.
        ForEach(Section.main) { item in
            Button { show(item.rawValue) } label: { Label(item.title, systemImage: item.symbol) }
        }
        Divider()
        Button { show("settings") } label: { Label("Settings", systemImage: Section.settings.symbol) }
            .keyboardShortcut(",")
        if Updater.shared.current != nil {
            Button("Check for Updates") { Updater.shared.check(manually: true) }
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
        Windows.open(id)  // sections of the main window open it there
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
                    .font(Scaled.style(17, .regular))
                    .foregroundStyle(.secondary)
                Text("Add Source").font(Scaled.style(15, .semibold))
            }
            Text(model.project.isEmpty
                 ? "Paste a link to a page, PDF or YouTube video, or choose a PDF on this Mac."
                 : "Paste a link to a page, PDF or YouTube video, or choose a PDF on this Mac. It's saved to \(model.project).")
                .font(Scaled.style(12, .regular))
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
                Button("Choose a PDF or Image", action: choosePDF)
                    .disabled(working)
                    .glassButton()
                Spacer()
                if let message {
                    Text(message)
                        .font(Scaled.style(10, .regular))
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
        panel.allowedContentTypes = [.pdf, .image]   // images are read with Apple's Vision
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
                    .font(Scaled.style(17, .regular))
                    .foregroundStyle(.secondary)
                Text("New Project").font(Scaled.style(15, .semibold))
            }
            Text("It becomes the current project, so reading you save or cite goes into it.")
                .font(Scaled.style(12, .regular))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Project name", text: $name)
                .textFieldStyle(.plain)
                .font(Scaled.style(13, .regular))
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
    @AppStorage("showInDock") private var showInDock = false
    @AppStorage("textScale") private var textScale = 1.0
    @AppStorage("headingFont") private var headingFont = "New York"
    @AppStorage("bodyFont") private var bodyFont = "System"
    @State private var marks = WordSettings.marks
    @State private var codeFolder = WordSettings.codeFolder
    @State private var writingFolder = WordSettings.writingFolder
    @State private var aiProvider = WordSettings.aiProvider
    @State private var ollamaModel = WordSettings.ollamaModel
    @State private var theoremProvider = WordSettings.theoremProvider
    @State private var local: [String: Any] = [:]   // which local models this Mac has
    @State private var openAIKey = ""
    @State private var showPrivacy = false
    @State private var copiedPairing = false

    /// The Google Docs add-on's files and its setup guide, inside the app (or the code folder).
    private var addOnFolder: URL {
        (Services.bundled ?? repository).appendingPathComponent("gdocs-addon")
    }
    @State private var keyMessage = ""
    @State private var autoCite = WordSettings.autoCite
    @State private var overleafAutoCite = WordSettings.overleafAutoCite
    @AppStorage("settingsWritingIn") private var writingIn = "word"
    @Environment(\.openWindow) private var openWindow

    var embedded = false   // shown in the main window, beside its sidebar, rather than in its own

    var body: some View {
        if embedded {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    cards.padding(.top, 12)
                }
                .frame(maxWidth: 620, alignment: .leading)   // half the window, in its middle
                .padding(.horizontal, 36)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.bottom, 28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            window
        }
    }

    private var window: some View {
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
        // Grouped like System Settings: rows with the label on the left and the control on the
        // right, and the longer explanations under each group.
        VStack(alignment: .leading, spacing: 26) {
            group("General", footer: nil) {
                row("Open Referee at login") {
                    Toggle("", isOn: Binding(get: { model.openAtLogin }, set: { model.setOpenAtLogin($0) }))
                        .toggleStyle(.switch).labelsHidden()
                }
                row("Show in menu bar") {
                    Toggle("", isOn: $showInMenuBar).toggleStyle(.switch).labelsHidden()
                }
                row("Show in Dock") {
                    Toggle("", isOn: Binding(get: { showInDock }, set: { showInDock = $0; Dock.apply($0) }))
                        .toggleStyle(.switch).labelsHidden()
                }
                row("Text size") {
                    menu(TextSize.choices.first { $0.0 == textScale }?.1 ?? "Default") {
                        Picker("Text size", selection: $textScale) {
                            ForEach(TextSize.choices, id: \.0) { Text($0.1).tag($0.0) }
                        }
                    }
                }
                row("Heading font") {
                    menu(headingFont) {
                        Picker("Heading font", selection: $headingFont) {
                            ForEach(Fonts.headingChoices, id: \.self) { Text($0).font(Fonts.font($0, 13, .semibold)).tag($0) }
                        }
                    }
                }
                row("Body font") {
                    menu(bodyFont) {
                        Picker("Body font", selection: $bodyFont) {
                            ForEach(Fonts.bodyChoices, id: \.self) { Text($0).font(Fonts.font($0, 13, .regular)).tag($0) }
                        }
                    }
                }
                row("Setup") { Button("Run Setup Again") { Windows.open("setup") } }
                row("Integrations", last: true) {
                    Button("Manage") { Windows.open("integrations") }
                }
            }
            group("Checks", footer: checksFooter) {
                row("Check claims with", last: aiProvider != "ollama") {
                    menu(providers.first { $0.0 == aiProvider }?.1 ?? "Claude") {
                        Picker("Check claims with", selection: Binding(get: { aiProvider }, set: { aiProvider = $0; WordSettings.aiProvider = $0 })) {
                            ForEach(providers, id: \.0) { Text($0.1).tag($0.0) }
                        }
                    }
                }
                if aiProvider == "ollama" {
                    row("Model", last: true) {
                        let models = local["ollama_models"] as? [String] ?? []
                        if models.isEmpty {
                            Text(local["ollama"] as? Bool == true ? "No models downloaded" : "Ollama isn't running").foregroundStyle(.secondary)
                        } else {
                            menu(ollamaModel) {
                                Picker("Ollama model", selection: Binding(get: { ollamaModel }, set: { ollamaModel = $0; WordSettings.ollamaModel = $0 })) {
                                    ForEach(models, id: \.self) { Text($0).tag($0) }
                                }
                            }
                        }
                    }
                }
            }
            .task {
                local = await API.get("ai-provider") ?? [:]
                // Nothing chosen yet: show what the server picked (Ollama's best model, or Claude).
                if aiProvider.isEmpty { aiProvider = local["provider"] as? String ?? "claude" }
                if ollamaModel.isEmpty { ollamaModel = local["ollama_model"] as? String ?? "" }
            }
            group("Theorem and definition checks", footer: "Comparing a theorem or definition in your writing with the paper it cites needs a careful model, so it's chosen separately from claim checks. Models on this Mac aren't careful enough: on 28 test statements from lecture notes, Qwen 2.5 7B got 15 right, Claude Haiku 23 and Claude Sonnet 27. Each comparison sends the statement and a few passages from the paper, and costs about a penny.") {
                row("Check theorems with", last: true) {
                    menu(theoremChoices.first { $0.0 == theoremProvider }?.1 ?? "Automatic") {
                        Picker("Check theorems with", selection: Binding(get: { theoremProvider }, set: { theoremProvider = $0; WordSettings.theoremProvider = $0 })) {
                            ForEach(theoremChoices, id: \.0) { Text($0.1).tag($0.0) }
                        }
                    }
                }
            }
            group("Keys", footer: "Kept in your Keychain. A ChatGPT subscription doesn't include the API: OpenAI's API is paid separately at platform.openai.com. Neither Anthropic nor OpenAI trains on API data.") {
                // The Claude key itself, here with the choices that use it (not in Integrations).
                VStack(alignment: .leading, spacing: 6) {
                    Text("Claude (Anthropic)").font(.system(size: Scaled.s(13), weight: .medium))
                    ApiKeyView(model: model)
                }
                .padding(.vertical, 10)
                Hairline()
                do {
                    row("ChatGPT (OpenAI)", last: true) {
                        HStack(spacing: 8) {
                            if (local["cloud"] as? [String: Any])?["openai"].flatMap({ ($0 as? [String: Any])?["connected"] as? Bool }) == true && openAIKey.isEmpty {
                                Text("Saved").foregroundStyle(.green)
                                Button("Remove") { Task { _ = await API.delete("ai-key/openai"); local = await API.get("ai-provider") ?? [:] } }
                            } else {
                                SecureField("Paste your key", text: $openAIKey).textFieldStyle(.roundedBorder).frame(width: 200)
                                Button("Save") {
                                    Task {
                                        let result = await API.post("ai-key/openai", ["key": openAIKey], timeout: 20)
                                        keyMessage = result?["ok"] as? Bool == true ? "" : (result?["reason"] as? String ?? "Couldn't check the key.")
                                        if keyMessage.isEmpty { openAIKey = "" }
                                        local = await API.get("ai-provider") ?? [:]
                                    }
                                }
                            }
                        }
                    }
                    if !keyMessage.isEmpty { Text(keyMessage).font(Scaled.style(10, .regular)).foregroundStyle(.red) }
                }
            }
            group("Reading", footer: BrowserExtension.defaultIsSafari
                  ? "Your default browser is Safari, which can't run Referee's extension: Referee works with it, but without capture while reading, highlights or the Overleaf and Google Docs panels. Chrome, Brave, Edge and Arc have everything."
                  : "The extension works in Chrome, Brave, Edge and Arc. Safari works with fewer features: no capture while reading, highlights or Overleaf and Google Docs panels.") {
                row("Project") {
                    HStack(spacing: 6) {
                        menu(model.project.isEmpty ? "No project" : model.project) {
                            Picker("Project", selection: Binding(get: { model.project }, set: { model.setProject($0) })) {
                                Text("No project").tag("")
                                ForEach(model.projects, id: \.self) { Text($0).tag($0) }
                            }
                        }
                        Button {
                            openWindow(id: "new-project")
                            NSApp.activate(ignoringOtherApps: true)
                        } label: { Image(systemName: "plus") }
                            .buttonStyle(.borderless)
                            .help("New project")
                    }
                }
                row("Keep unsaved reading for") {
                    menu(keepOptions.first { $0.0 == model.keepMinutes }?.1 ?? "") {
                        Picker("Keep unsaved reading for", selection: Binding(get: { model.keepMinutes }, set: { model.setKeep($0) })) {
                            ForEach(keepOptions, id: \.0) { Text($0.1).tag($0.0) }
                        }
                    }
                }
                row("Research mode shortcut") { ShortcutRecorder(shortcut: .shared) }
                row("Search shortcut") { ShortcutRecorder(shortcut: .find) }
                row("Quick capture shortcut") { ShortcutRecorder(shortcut: .capture) }
                ReadingFoldersRow(project: model.project)
                row("Browser extension", last: true) {
                    Button("Install") { BrowserExtension.install(repo: repository) }
                }
            }
            group("Writing", footer: writingFooter) {
                row("Writing in") {
                    menu(["word": "Word", "overleaf": "Overleaf", "gdocs": "Google Docs", "obsidian": "Obsidian", "markdown": "R Markdown", "quarto": "Quarto"][writingIn] ?? "Word") {
                        Picker("Writing in", selection: $writingIn) {
                            // Documents, then notes, then documents with code, each group apart.
                            SwiftUI.Section {
                                Text("Word").tag("word")
                                Text("Google Docs").tag("gdocs")
                                Text("Overleaf").tag("overleaf")
                            }
                            SwiftUI.Section { Text("Obsidian").tag("obsidian") }
                            SwiftUI.Section {
                                Text("R Markdown").tag("markdown")
                                Text("Quarto").tag("quarto")
                            }
                        }
                    }
                }
                if writingIn == "word" || writingIn == "gdocs" {
                    row("Citation style") {
                        menu(styles.first { $0.0 == model.style }?.1 ?? "APA 7") {
                            Picker("Style", selection: Binding(get: { model.style }, set: { model.setStyle($0) })) {
                                ForEach(styles, id: \.0) { Text($0.1).tag($0.0) }
                            }
                        }
                    }
                }
                if writingIn == "gdocs" {
                    row("Add-on") {
                        Button("Set Up") { NSWorkspace.shared.open(addOnFolder) }
                    }
                    row("Pairing code", last: true) {
                        HStack(spacing: 8) {
                            Button(copiedPairing ? "Copied" : "Copy Pairing Code") {
                                Task {
                                    let code = (await API.get("pairing"))?["code"] as? String ?? ""
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(code, forType: .string)
                                    copiedPairing = true
                                }
                            }
                            Button("New Code") { Task { _ = await API.post("pairing", [:]); copiedPairing = false } }
                                .help("Makes a fresh code. Paste it into the Google Docs panel again.")
                        }
                    }
                }
                if writingIn == "word" {
                    row("Mark sentences with") {
                        menu(["underline": "Underline", "highlight": "Highlight", "none": "Nothing"][marks] ?? "Underline") {
                            Picker("Mark sentences with", selection: Binding(get: { marks }, set: { marks = $0; WordSettings.marks = $0 })) {
                                Text("Underline").tag("underline")
                                Text("Highlight").tag("highlight")
                                Text("Nothing").tag("none")
                            }
                        }
                    }
                    row("Marks in the open document") { Button("Remove Marks") { WordSettings.removeMarks() } }
                    row("Remove marks shortcut") { ShortcutRecorder(shortcut: .removeMarks) }
                    row("Add citations automatically", last: true) {
                        Toggle("", isOn: Binding(get: { autoCite }, set: { autoCite = $0; WordSettings.autoCite = $0 }))
                            .toggleStyle(.switch).labelsHidden()
                    }
                }
                if writingIn == "overleaf" {
                    row("Citation style") { Text("Set in your document").foregroundStyle(.secondary) }
                    row("Add citations automatically") {
                        Toggle("", isOn: Binding(get: { overleafAutoCite }, set: { overleafAutoCite = $0; WordSettings.overleafAutoCite = $0 }))
                            .toggleStyle(.switch).labelsHidden()
                    }
                    row("Code folder", last: true) { folderPicker($codeFolder, save: { WordSettings.codeFolder = $0 }) }
                }
                if writingIn == "obsidian" {
                    row("Vault", last: true) { folderPicker($writingFolder, save: { WordSettings.writingFolder = $0 }) }
                }
                if writingIn == "markdown" || writingIn == "quarto" {
                    row("Writing folder") { folderPicker($writingFolder, save: { WordSettings.writingFolder = $0 }) }
                    row("Code folder", last: true) { folderPicker($codeFolder, save: { WordSettings.codeFolder = $0 }) }
                }
            }
            group("Privacy", footer: nil) {
                row("What leaves this device", last: true) {
                    Button { showPrivacy = true } label: {
                        HStack(spacing: 4) { Text("Review"); Image(systemName: "chevron.right").font(Scaled.style(10, .regular)) }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                }
            }
            .sheet(isPresented: $showPrivacy) {
                VStack(spacing: 0) {
                    ScrollView { PrivacySection().padding(28) }
                    Hairline()
                    HStack { Spacer(); Button("Done") { showPrivacy = false }.keyboardShortcut(.defaultAction) }.padding(16)
                }
                .frame(width: 620, height: 640)
            }
            BackupSection()
            group("Help", footer: "Opens a GitHub issue with Referee's version and your macOS version filled in. You write the rest, and nothing is sent until you post it.") {
                row("Report a problem", last: true) { Button("Report") { ReportProblem.open() } }
            }

        }
    }

    private let providers = [("ollama", "On this Mac (free)"), ("claude", "Claude (Anthropic)"), ("openai", "ChatGPT (OpenAI)")]
    private let theoremChoices = [("auto", "Automatic"), ("claude", "Claude Sonnet"), ("openai", "ChatGPT (GPT-5.5)"), ("off", "Off")]

    private var checksFooter: String {
        switch aiProvider {
        case "ollama":
            let speed: String = {
                guard let m = local["measured"] as? [String: Any], let seconds = m["seconds"] as? Double else {
                    return "Checks took about 5 seconds on an M1 with 16 GB; once you've written a little, this shows the time on your Mac"
                }
                return "Checks take about \(seconds.formatted(.number.precision(.fractionLength(0...1)))) seconds on this Mac"
            }()
            return "Free, and nothing leaves this Mac. Install Ollama from ollama.com, then download qwen2.5:7b (or qwen3:14b with 32 GB of memory or more). \(speed). They're a little less accurate than Claude's: about 9 in 10 claims marked as backed really are."
        case "openai":
            return "With your OpenAI API key (GPT-5.5 nano), kept in your Keychain. A ChatGPT subscription doesn't include the API: it's paid separately at platform.openai.com. Each check sends the sentence and a few passages to OpenAI, which doesn't train on API data. With no internet, a model on this Mac checks instead, if Ollama has one. Not yet measured on SciFact."
        default:
            return "The most accurate (about 24 in 25 claims marked as backed really are). Each check sends the sentence and the few passages that might back it to Anthropic, with your API key. Anthropic doesn't train on API data. With no internet, a model on this Mac checks instead, if Ollama has one."
        }
    }

    private var writingFooter: String {
        switch writingIn {
        case "overleaf":
            return "LaTeX formats citations itself, with \\bibliographystyle in your document: Referee suggests \\cite keys that match its BibTeX export. With automatic citations off, each one has an Insert button in the Referee panel. The code folder holds the code and results behind your writing: Referee lists libraries that should be cited, and figures that don't match your latest results."
        case "gdocs":
            return "The Referee add-on marks each sentence in your Google Doc, suggests citations in this style with an Insert button (or adds them for you), and removes its marks when you ask, as in Word. Set it up once with Set Up…, then pair it with the code. Without the add-on, the browser extension's panel lists the same checks beside the document, without marking it."
        case "obsidian":
            return "Referee watches your vault and checks what you write in it, without changing your notes. Results appear in the Evidence report. Citations written as [@key] count as cited."
        case "markdown", "quarto":
            return "Referee watches the writing folder and checks the \(writingIn == "quarto" ? ".qmd" : ".Rmd") files in it, without changing them. Results appear in the Evidence report. The code folder holds the code and results behind your writing: Referee lists libraries that should be cited, and figures that don't match your latest results."
        default:
            return "Green: supported. Amber: check the wording. Red: contradicted. Underlines show clearly in dark mode, where Word dims highlights. With automatic citations off, a comment suggests each citation for you to type, so you choose every one."
        }
    }

    /// A group of rows divided by hairlines, under a small capital label, with an explanation below.
    private func group<Content: View>(_ title: String, footer: String?, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(Scaled.style(13, .semibold)).padding(.leading, 4)
            VStack(spacing: 0) { content() }.settingsBox()
            if let footer {
                Text(footer)
                    .font(Scaled.style(11, .regular))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
        }
    }

    /// A compact menu showing its current choice.
    private func menu<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        Menu { content().pickerStyle(.inline).labelsHidden() } label: { Text(label) }
            .fixedSize()
    }

    private func folderPicker(_ folder: Binding<String>, save: @escaping (String) -> Void) -> some View {
        HStack(spacing: 8) {
            if !folder.wrappedValue.isEmpty {
                Text(URL(fileURLWithPath: folder.wrappedValue).lastPathComponent)
                    .foregroundStyle(.secondary)
                    .help(folder.wrappedValue)
                Button("Clear") { folder.wrappedValue = ""; save("") }
            }
            Button(folder.wrappedValue.isEmpty ? "Choose" : "Change") {
                if let chosen = chooseFolder() { folder.wrappedValue = chosen; save(chosen) }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 18) {
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
                        .font(Scaled.style(12, .regular))
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .glassCapsule()
            }
            // The other windows, as quiet links on a row of their own so the header never squeezes them.
            HStack(spacing: 18) {
                windowLink("Library", "books.vertical", "library")
                windowLink("Notes", "note.text", "notes")
                windowLink("Meetings", "person.2", "meetings")
                windowLink("AI Use", "checkmark.seal", "ai-use")
                Spacer()
            }
        }
        .padding(.bottom, 14)  // a clear gap before the first card
    }

    private func windowLink(_ title: String, _ symbol: String, _ id: String) -> some View {
        Button { Windows.open(id) } label: {
            Label(title, systemImage: symbol).font(Scaled.style(12, .regular)).fixedSize()
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help("Open \(title)")
    }

    private func row<Control: View>(_ label: String, last: Bool = false, @ViewBuilder control: () -> Control) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(label)
                Spacer()
                control()
            }
            .padding(.vertical, 9)
            if !last { Hairline() }
        }
    }

    private func chooseFolder() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        return panel.runModal() == .OK ? panel.url?.path : nil
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
                        .font(Scaled.style(10, .regular)).foregroundStyle(.secondary)
                }
            } else {
                Text("Referee checks claims with Claude, using your own Anthropic API key. Create one at console.anthropic.com.")
                    .font(Scaled.style(12, .regular)).foregroundStyle(.secondary)
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
                Text(problem).font(Scaled.style(10, .regular)).foregroundStyle(.orange)
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

// Plain surfaces: only the main window's sidebar is glass (macOS draws that itself).
extension View {

    @ViewBuilder func glassCard() -> some View {
        self.background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder func glassCapsule() -> some View {
        self.background(Color.primary.opacity(0.06), in: Capsule())
    }

    @ViewBuilder func prominentGlassButton() -> some View {
        self.buttonStyle(.borderedProminent)
    }

    @ViewBuilder func glassButton() -> some View {
        self.buttonStyle(.bordered)
    }
}

/// Makes the settings window itself translucent, with its title bar hidden.
struct WindowGlass: NSViewRepresentable {

    func makeNSView(context: Context) -> NSView {
        let view = NSVisualEffectView()
        view.material = .windowBackground   // plain: only the main window's sidebar is glass
        view.blendingMode = .withinWindow
        view.state = .active
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.styleMask.insert(.fullSizeContentView)
            window.isMovableByWindowBackground = true
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
                ? "Tasks go to a Todoist project named after their Referee project. Ticking one off in either app ticks it off in both."
                : "Find your token in Todoist: Settings, Integrations, Developer. It's kept in your Keychain."))
                .font(Scaled.style(10, .regular))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .task { await refresh() }
    }

    private func refresh() async {
        connected = (await API.get("tasks"))?["todoist"] as? Bool ?? false
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

    /// The parts of the main window: opening one opens the main window there.
    static let sections: Set<String> = ["library", "evidence", "notes", "meetings", "ai-use", "settings"]

    static func open(_ id: String) {
        var id = id
        if sections.contains(id) {
            UserDefaults.standard.set(id, forKey: "mainSection")
            id = "main"
        }
        NSApp.activate(ignoringOtherApps: true)
        if let opener {
            opener(id)
            return
        }
        if let window = made[id] {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let view = id == "setup" ? AnyView(OnboardingView(model: .shared)) : id == "main" ? AnyView(MainWindow(model: .shared)) : id == "integrations" ? AnyView(IntegrationsView(model: .shared)) : AnyView(SettingsView(model: .shared))
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
    private var wordHelper = (UserDefaults.standard.string(forKey: "settingsWritingIn") ?? "word") == "word"

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Started by macOS at login: stay in the menu bar. Opened by the person: show settings.
        let event = NSAppleEventManager.shared().currentAppleEvent
        openedAtLogin = event?.eventID == AEEventID(kAEOpenApplication)
            && event?.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == AEEventClass(keyAELaunchedAsLogInItem)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Dock.apply(UserDefaults.standard.bool(forKey: "showInDock"))
        services?.startAll()
        // The Word helper runs only for Word: changing Writing In restarts the parts.
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            let word = (UserDefaults.standard.string(forKey: "settingsWritingIn") ?? "word") == "word"
            guard let self, word != self.wordHelper else { return }
            self.wordHelper = word
            self.services?.stopAll()
            self.services?.startAll()
        }
        Updater.shared.start()
        Shortcut.shared.start()
        if !UserDefaults.standard.bool(forKey: "onboarded") && !WordSettings.hasConfig {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { Windows.open("setup") }  // first launch
        } else if !openedAtLogin {
            showSettingsWhenReady(attempts: 8)
        }
    }

    /// The menu bar icon hands over SwiftUI's window opener shortly after launch; wait briefly for
    /// it, then open the main window either way (directly, if the icon is hidden).
    private func showSettingsWhenReady(attempts: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            if Windows.opener != nil || attempts == 0 { Windows.open("main") } else { self.showSettingsWhenReady(attempts: attempts - 1) }
        }
    }

    // Clicking the app's icon again (in Applications, Spotlight or Launchpad) opens the main window.
    // referee:// links clicked in a planner, Todoist or anywhere else.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { RefereeLinks.handle(url) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Windows.open("main")
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
        Window("Integrations", id: "integrations") {
            IntegrationsView(model: model).background(WindowOpener())
        }
        .handlesExternalEvents(matching: [])   // referee:// links (from Raycast) open panels, not this window
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        Window("Referee", id: "main") {
            MainWindow(model: model).background(WindowOpener())
        }
        // No title bar of its own (the pages' headers are the top bar), but the window buttons stay.
        .windowStyle(.hiddenTitleBar)
        .handlesExternalEvents(matching: [])   // referee:// links (from Raycast) open panels, not this window
        Window("Set Up Referee", id: "setup") {
            OnboardingView(model: model).background(WindowOpener())
        }
        .handlesExternalEvents(matching: [])   // referee:// links (from Raycast) open panels, not this window
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        Window("Add Source", id: "add-source") {
            AddSourceView(model: model).background(WindowOpener())
        }
        .handlesExternalEvents(matching: [])   // referee:// links (from Raycast) open panels, not this window
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        Window("New Project", id: "new-project") {
            NewProjectView(model: model).background(WindowOpener())
        }
        .handlesExternalEvents(matching: [])   // referee:// links (from Raycast) open panels, not this window
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        Window("Referee Settings", id: "settings") {
            SettingsView(model: model).background(WindowOpener())
        }
        .handlesExternalEvents(matching: [])   // referee:// links (from Raycast) open panels, not this window
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

/// Whether Referee has a Dock icon (and a menu bar of its own when it's in front), or lives only
/// in the menu bar, its default.
enum Dock {
    static func apply(_ show: Bool) {
        NSApp.setActivationPolicy(show ? .regular : .accessory)
        if show { NSApp.activate(ignoringOtherApps: true) }
    }
}


/// Settings → Reading: folders whose PDFs become sources in a project by themselves (a module's
/// folder on OneDrive, say), kept up to date every few minutes. Each is linked to the project
/// that's current when it's added.
struct ReadingFoldersRow: View {
    let project: String
    @State private var folders: [[String: Any]] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Reading folders")
                Spacer()
                Button("Add Folder") { add() }
            }
            ForEach(Array(folders.enumerated()), id: \.offset) { _, f in
                let path = f["path"] as? String ?? ""
                HStack(spacing: 6) {
                    Image(systemName: "folder").foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(URL(fileURLWithPath: path).lastPathComponent).lineLimit(1)
                        Text("\(f["project"] as? String ?? "") · \(f["pdfs"] as? Int ?? 0) PDFs")
                            .font(Scaled.style(10, .regular)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Unlink") {
                        Task {
                            _ = await API.delete("reading-folders?path=\(path.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")")
                            await load()
                        }
                    }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
                }
                .help(path)
            }
            Text("Every PDF in a linked folder, and its subfolders, becomes a source in that folder's project, and stays up to date. Nothing is copied.")
                .font(Scaled.style(10, .regular)).foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
        .task { await load() }
    }

    private func load() async { folders = await API.getList("reading-folders") }

    private func add() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Link"
        panel.message = project.isEmpty ? "Choose a folder of PDFs to read." : "Choose a folder of PDFs for \(project)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            _ = await API.post("reading-folders", ["path": url.path, "project": project], timeout: 20)
            await load()
        }
    }
}
