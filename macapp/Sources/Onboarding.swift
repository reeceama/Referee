import AppKit
import SwiftUI

/// The first-run setup: what Referee does, how claims are checked (a model on this Mac, suited to
/// its memory, or Claude or ChatGPT with the person's key), where they write, and their
/// first project. Every step can be skipped, and Settings changes everything later.
/// Shown once, on the first launch; Settings can open it again.

/// This Mac, for recommending a local model.
struct ThisMac {

    let chip: String
    let memoryGB: Int
    let freeGB: Int
    let appleSilicon: Bool

    static var current: ThisMac {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var brand = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("machdep.cpu.brand_string", &brand, &size, nil, 0)
        let chip = String(cString: brand)
        let free = (try? URL(fileURLWithPath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage) ?? 0
        return ThisMac(chip: chip.isEmpty ? "This Mac" : chip,
                       memoryGB: Int((Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824).rounded()),
                       freeGB: Int(free / 1_000_000_000),
                       appleSilicon: chip.hasPrefix("Apple"))
    }

    /// The local model that suits this Mac, or nil when a local model wouldn't run well.
    var recommended: LocalModel? {
        // 32 GB or more (decided 24 Oct 2026): on 16 GB only 7B models fit, and they were slow and much weaker
        // than Claude (theorems 15 of 27, topics one per note). Others can still pick an Ollama model in Settings.
        guard appleSilicon, freeGB >= 12, memoryGB >= 32 else { return nil }
        return .large
    }
}

/// The local models Referee offers, as measured on SciFact (see the README).
enum LocalModel: String, CaseIterable {

    // Qwen 3 4B was measured too (precision 0.59, calling 17 of 30 contradictions "backed"): left out.
    // Qwen 3 8B too (23 Oct 2026): precision 0.91 and recall 0.70 only at full confidence (0.79 otherwise), 6 of 15 hard negatives marked against 1, and a third slower: left out.
    case small = "qwen2.5:7b"
    case large = "qwen3:14b"

    var name: String { self == .small ? "Qwen 2.5 7B" : "Qwen 3 14B" }
    var download: String { self == .small ? "4.7 GB" : "9.3 GB" }
    var memory: String { self == .small ? "about 5 GB" : "about 9 GB" }
    /// Measured on 100 SciFact pairs on an M1 with 16 GB (see the README).
    var speed: String { self == .small ? "about 5 seconds" : "about 12 seconds" }
    var memoryNeeded: Int { self == .small ? 8 : 24 }   // GB of memory for it to run alongside other apps
}

/// Installs Ollama (if it isn't already) and downloads a model, reporting progress.
@MainActor
final class LocalSetup: ObservableObject {

    @Published var stage = ""          // what's happening, for the person
    @Published var progress: Double?   // 0...1 while downloading
    @Published var done = false
    @Published var failed: String?

    private let ollama = URL(string: "http://127.0.0.1:11434")!

    private func running() async -> Bool {
        (try? await URLSession.shared.data(from: ollama.appendingPathComponent("api/tags"))) != nil
    }

    func install(_ model: LocalModel) {
        failed = nil
        Task {
            do {
                if !(await running()) {
                    if !FileManager.default.fileExists(atPath: "/Applications/Ollama.app") {
                        stage = "Downloading Ollama…"
                        progress = nil
                        let (zip, _) = try await URLSession.shared.download(from: URL(string: "https://ollama.com/download/Ollama-darwin.zip")!)
                        stage = "Installing Ollama…"
                        let unzip = Process()
                        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                        unzip.arguments = ["-x", "-k", zip.path, "/Applications"]
                        try unzip.run()
                        unzip.waitUntilExit()
                    }
                    stage = "Starting Ollama…"
                    _ = try? await NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/Applications/Ollama.app"),
                                                                       configuration: NSWorkspace.OpenConfiguration())
                    for _ in 0..<30 {
                        if await running() { break }
                        try await Task.sleep(nanoseconds: 1_000_000_000)
                    }
                    guard await running() else { throw SetupError("Ollama didn't start. Open it from Applications, then try again.") }
                }
                try await pull(model)
                WordSettings.aiProvider = "ollama"
                WordSettings.ollamaModel = model.rawValue
                stage = "\(model.name) is ready."
                progress = 1
                done = true
            } catch let error as SetupError {
                failed = error.message
            } catch {
                failed = "Couldn't finish: \(error.localizedDescription)"
            }
        }
    }

    /// Ollama's download, read line by line for its progress.
    private func pull(_ model: LocalModel) async throws {
        stage = "Downloading \(model.name) (\(model.download))…"
        var request = URLRequest(url: ollama.appendingPathComponent("api/pull"))
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": model.rawValue, "stream": true])
        request.timeoutInterval = 3600
        let (lines, _) = try await URLSession.shared.bytes(for: request)
        for try await line in lines.lines {
            guard let data = line.data(using: .utf8),
                  let update = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if let error = update["error"] as? String { throw SetupError("Ollama couldn't download the model: \(error)") }
            if let total = update["total"] as? Double, let completed = update["completed"] as? Double, total > 0 {
                progress = completed / total
            }
        }
    }
}

struct SetupError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

struct OnboardingView: View {

    @ObservedObject var model: Model
    @StateObject private var local = LocalSetup()
    @Environment(\.dismiss) private var dismiss
    @State private var step = 0
    @State private var checks = "claude"   // Claude is recommended on every Mac
    @State private var localModel: LocalModel = ThisMac.current.recommended ?? .small
    @State private var key = ""
    @State private var keyMessage: String?
    @AppStorage("settingsWritingIn") private var writingIn = "word"
    @State private var project = ""
    private let mac = ThisMac.current

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("STEP \(step + 1) OF 4")
                .font(.system(size: Scaled.s(11), weight: .medium)).tracking(0.8).foregroundStyle(.secondary)
            Group {
                switch step {
                case 0: welcome
                case 1: checksStep
                case 2: writingStep
                default: projectStep
                }
            }
            .padding(.top, 6)
            Spacer(minLength: 16)
            HStack {
                if step > 0 { Button("Back") { step -= 1 }.buttonStyle(.plain).foregroundStyle(.secondary) }
                Spacer()
                Button("Skip for now") { next() }.buttonStyle(.plain).foregroundStyle(.secondary)
                Button(primaryTitle, action: primary)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(step == 1 && checks == "local" && !local.stage.isEmpty && !local.done && local.failed == nil)
            }
            HStack(spacing: 6) {
                ForEach(0..<4) { i in Circle().fill(i == step ? Color.primary : Color.primary.opacity(0.2)).frame(width: 6, height: 6) }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 16)
        }
        .padding(32)
        .frame(width: 560, height: 560)
    }

    // MARK: Steps

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Welcome to Referee").font(Fonts.heading(28, .regular))
            Text("Referee checks what you write against what you've read. As you write in Word, Google Docs, Overleaf, Notion, Obsidian, R Markdown or Quarto, each claim is matched to the source and page that back it, and anything unsupported or contradicted is pointed out.")
                .fixedSize(horizontal: false, vertical: true)
            Text("It never writes for you, and your reading and writing stay on this Mac unless you choose otherwise in the next step.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var checksStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("How should claims be checked?").font(Fonts.heading(26, .regular))
            DetailsRow {
                Detail(symbol: "cpu") { Text(mac.chip.replacingOccurrences(of: "(R)", with: "")) }
                DetailDivider()
                Detail(symbol: "memorychip") { Text("\(mac.memoryGB) GB memory") }
                DetailDivider()
                Detail(symbol: "internaldrive") { Text("\(mac.freeGB) GB free") }
            }
            .padding(.bottom, 6)
            ScrollView {
                VStack(spacing: 8) {
                    option("claude", "Claude", tag: "recommended", about: "The most accurate and the fastest, and compares theorems with papers (Claude Sonnet). Paid per check with your Anthropic key, usually a fraction of a penny; each check sends the sentence and a few passages to Anthropic, which doesn't train on API data.")
                    option("openai", "ChatGPT", about: "With your OpenAI API key (GPT-5.5 nano). A ChatGPT subscription doesn't include the API: it's paid separately at platform.openai.com. OpenAI doesn't train on API data.")
                    if ["claude", "openai"].contains(checks) { keyField }
                    option("local", "On this Mac", about: localAbout)
                    if checks == "local" && mac.recommended != nil { localPicker }
                }
            }
        }
    }

    private var localAbout: String {
        guard mac.recommended != nil else {
            if mac.appleSilicon && mac.memoryGB < 32 {
                return "Free and offline, but needs a Mac with 32 GB of memory or more: this one has \(mac.memoryGB) GB. Models small enough for it were slower and much less accurate than Claude. You can still choose a model you've installed with Ollama in Settings."
            }
            return mac.appleSilicon
                ? "Needs about 12 GB of free disk space, and this Mac has \(mac.freeGB) GB. Free some space, or choose one of the options below."
                : "Local models need an Apple silicon Mac (M1 or later). Choose one of the options below."
        }
        // Describes the model chosen in the menu below, not only the recommended one.
        let chosen = localModel
        let fit = mac.memoryGB >= chosen.memoryNeeded
            ? "It suits this Mac's \(mac.memoryGB) GB of memory."
            : "It's heavy for this Mac's \(mac.memoryGB) GB of memory: other apps may slow down while it checks."
        return "Free, and nothing leaves your Mac. Referee installs Ollama and \(chosen.name) (\(chosen.download) download), which uses \(chosen.memory) of memory while checking. \(fit) Each check took \(chosen.speed) on an M1 with 16 GB (yours may be faster or slower: Settings shows the time on this Mac once you've written a little); about 9 in 10 claims it marks as backed really are, against 24 in 25 for Claude."
    }

    private var localPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Model", selection: $localModel) {
                ForEach(LocalModel.allCases, id: \.self) { m in
                    Text("\(m.name): \(m.download), uses \(m.memory) while checking").tag(m)
                }
            }
            .labelsHidden()
            if !local.stage.isEmpty {
                if let progress = local.progress { ProgressView(value: progress) } else if !local.done { ProgressView().controlSize(.small) }
                Text(local.failed ?? local.stage).font(Scaled.style(10, .regular)).foregroundStyle(local.failed == nil ? Color.secondary : Color.red)
            }
        }
        .padding(.leading, 30)
    }

    private var keyField: some View {
        VStack(alignment: .leading, spacing: 6) {
            SecureField(checks == "claude" ? "Anthropic API key" : "OpenAI API key", text: $key)
                .textFieldStyle(.roundedBorder)
            if let keyMessage { Text(keyMessage).font(Scaled.style(10, .regular)).foregroundStyle(.secondary) }
        }
        .padding(.leading, 30)
    }

    private var writingStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Where do you write?").font(Fonts.heading(26, .regular))
            Picker("Writing in", selection: $writingIn) {
                SwiftUI.Section {
                    Text("Word").tag("word")
                    Text("Google Docs").tag("gdocs")
                    Text("Overleaf").tag("overleaf")
                    Text("Notion").tag("notion")
                }
                SwiftUI.Section { Text("Obsidian").tag("obsidian") }
                SwiftUI.Section {
                    Text("R Markdown").tag("markdown")
                    Text("Quarto").tag("quarto")
                }
            }
            .fixedSize()
            Text(writingAbout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if ["gdocs", "overleaf", "notion"].contains(writingIn) {
                Button("Install Browser Extension…") { BrowserExtension.install(repo: repository) }
            }
            if ["obsidian", "markdown", "quarto"].contains(writingIn) {
                Button(writingIn == "obsidian" ? "Choose Your Vault…" : "Choose Your Writing Folder…") { chooseWritingFolder() }
                if !WordSettings.writingFolder.isEmpty {
                    Text(URL(fileURLWithPath: WordSettings.writingFolder).lastPathComponent).font(Scaled.style(10, .regular)).foregroundStyle(.secondary)
                }
            }
            Text("Referee also collects what you read through the browser extension (Chrome, Brave, Edge or Arc), or Add Source in the menu bar.")
                .font(Scaled.style(10, .regular)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var writingAbout: String {
        switch writingIn {
        case "word": return "Referee checks as you type in Word, marking sentences and suggesting citations. Nothing to install."
        case "gdocs", "notion": return "A Referee panel appears in the corner of the page, through the browser extension."
        case "overleaf": return "A Referee panel appears in Overleaf, through the browser extension, with \\cite keys to insert."
        case "obsidian": return "Referee watches your vault and checks what you write, without changing your notes."
        default: return "Referee watches the folder and checks your \(writingIn == "quarto" ? ".qmd" : ".Rmd") files, without changing them."
        }
    }

    private var projectStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Your first project").font(Fonts.heading(26, .regular))
            Text("A project is one piece of work, such as a report, a proposal, an article or a dissertation. What you read is saved to the current project, and your writing is checked against it.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("Project name", text: $project).textFieldStyle(.roundedBorder)
            Text("Zotero, to-do apps, Obsidian and your calendar can be connected later in Settings → Integrations.")
                .font(Scaled.style(10, .regular)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func option(_ id: String, _ title: String, tag: String? = nil, about: String) -> some View {
        Button { checks = id; key = ""; keyMessage = nil } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: checks == id ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(checks == id ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(title).fontWeight(.medium)
                        if let tag {
                            Text(tag).font(.system(size: Scaled.s(10.5))).foregroundStyle(.green)
                                .padding(.horizontal, 5).overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.green.opacity(0.5)))
                        }
                    }
                    Text(about).font(Scaled.style(12, .regular)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .contentShape(Rectangle())
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(checks == id ? Color.accentColor : Color.primary.opacity(0.15), lineWidth: checks == id ? 1.5 : 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: Buttons

    private var primaryTitle: String {
        switch step {
        case 1:
            if checks == "local" { return local.done ? "Continue" : mac.recommended == nil ? "Continue" : "Download and Continue" }
            return "Save and Continue"
        case 3: return "Finish"
        default: return "Continue"
        }
    }

    private func primary() {
        switch step {
        case 1 where checks == "local":
            if local.done || mac.recommended == nil { next() } else { local.install(localModel) }
        case 1:
            Task {
                let trimmed = key.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { keyMessage = "Paste your key, or skip for now."; return }
                keyMessage = "Checking…"
                let result = checks == "claude"
                    ? await API.post("api-key", ["key": trimmed], timeout: 20)
                    : await API.post("ai-key/\(checks)", ["key": trimmed], timeout: 20)
                if result?["ok"] as? Bool == true {
                    WordSettings.aiProvider = checks
                    next()
                } else {
                    keyMessage = result?["reason"] as? String ?? result?["error"] as? String ?? "Couldn't check the key."
                }
            }
        case 3:
            let trimmed = project.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { model.setProject(trimmed) }
            next()
        default:
            next()
        }
    }

    private func next() {
        if step < 3 { step += 1; return }
        UserDefaults.standard.set(true, forKey: "onboarded")
        dismiss()
        Windows.open("main")
    }

    private func chooseWritingFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url { WordSettings.writingFolder = url.path }
    }
}
