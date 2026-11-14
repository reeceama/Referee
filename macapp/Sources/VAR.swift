import AppKit
import PDFKit
import Vision
import AVFoundation
import Speech
import SwiftUI

/// VAR: learning your own write-up and the material around it, one question at a time, and a mock
/// viva. The questions are written once and saved; Claude assesses, and never gives the answer first. Spoken answers are transcribed on this Mac, and you
/// correct the transcript before anything is sent.

/// Records spoken answers and transcribes them on this Mac with Whisper (never sent anywhere), then has
/// the maths written as LaTeX. Every recording is kept, to play back or delete.
@MainActor
final class Transcriber: ObservableObject {

    @Published var text = ""
    @Published var listening = false
    @Published var transcribing = false
    @Published var problem: String?
    @Published var starting = false
    /// Asking to download the speech model, the first time an answer is spoken.
    @Published var needsModel = false
    /// How far the speech model's download has got, 0 to 1, while it downloads.
    @Published var downloading: Double?
    /// Made afresh for each recording, so it uses whichever microphone is current (AirPods connecting or
    /// disconnecting otherwise leave it recording silence).
    private var engine = AVAudioEngine()
    private var watching: NSObjectProtocol?
    private var current: URL?
    /// The question being answered, so Whisper spells its terms right.
    var question = ""
    /// Kept for older callers; every answer aloud is now kept.
    var keeping = true
    /// The recordings of the answer in progress.
    @Published var recordings: [URL] = []
    /// The recordings ticked: sent with the answer for marking, and transcribed by "Transcribe ticked".
    @Published var chosen: Set<URL> = []
    /// Pictures that are part of the answer: handwritten working (from GoodNotes, say), photos or screenshots.
    @Published var pictures: [String] = []

    nonisolated static let folder: URL = {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Referee/var-recordings")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }()
    nonisolated static let models = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Referee/whisper")
    /// The speech model: large-v3-turbo, downloaded on first use; small.en where an older setup has only that.
    nonisolated static let turbo = models.appendingPathComponent("ggml-large-v3-turbo-q5_0.bin")
    nonisolated static var model: URL? {
        [turbo, models.appendingPathComponent("ggml-small.en.bin")].first { FileManager.default.fileExists(atPath: $0.path) }
    }
    /// Whisper as bundled with the app, or a Homebrew install.
    nonisolated static let whisper = [Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/whisper/whisper-cli").path,
                                      "/opt/homebrew/bin/whisper-cli", "/usr/local/bin/whisper-cli"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }

    func start() {
        problem = nil
        guard Self.model != nil else {
            needsModel = true
            return
        }
        starting = true
        Task {
            let microphone = await AVCaptureDevice.requestAccess(for: .audio)
            starting = false
            guard microphone else {
                problem = "Allow the microphone for Referee in System Settings → Privacy & Security → Microphone."
                return
            }
            begin()
        }
    }

    private func begin() {
        engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            problem = "No microphone input. Check one is connected and chosen in System Settings → Sound → Input."
            return
        }
        let url = Self.folder.appendingPathComponent(UUID().uuidString + ".caf")
        input.removeTap(onBus: 0)
        // The file takes the format of the sound as it arrives, not as it was a moment before.
        var file: AVAudioFile?
        input.installTap(onBus: 0, bufferSize: 4096, format: nil) { buffer, _ in
            if file == nil { file = try? AVAudioFile(forWriting: url, settings: buffer.format.settings) }
            try? file?.write(from: buffer)
        }
        // AirPods change format a moment after the microphone starts (they switch to their call mode),
        // which stops the engine: start again in the new format.
        if let watching { NotificationCenter.default.removeObserver(watching) }
        watching = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.restart() }
        }
        do {
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            problem = "Referee can't use the microphone. Allow it in System Settings → Privacy & Security."
            return
        }
        current = url
        listening = true
    }

    private func restart() {
        guard listening else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        listening = false
        if let url = current, Self.seconds(url) > 0.5 {
            recordings.append(url)
            chosen.insert(url)
            transcribe(url)
        } else if let url = current {
            try? FileManager.default.removeItem(at: url)
        }
        current = nil
        begin()
    }

    nonisolated private static func seconds(_ url: URL) -> Double {
        guard let file = try? AVAudioFile(forReading: url) else { return 0 }
        return Double(file.length) / file.fileFormat.sampleRate
    }

    func stop() {
        guard listening else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        listening = false
        guard let url = current else { return }
        current = nil
        // Under a tenth of a second of sound: nothing reached the microphone.
        if Self.seconds(url) <= 0.1 {
            try? FileManager.default.removeItem(at: url)
            problem = "Nothing was recorded. Check the microphone in System Settings → Sound → Input, then try again."
            return
        }
        recordings.append(url)
        chosen.insert(url)
        transcribe(url)
    }

    func delete(_ url: URL) {
        recordings.removeAll { $0 == url }
        chosen.remove(url)
        try? FileManager.default.removeItem(at: url)
    }

    /// Downloads the speech model once, from whisper.cpp's own models on Hugging Face.
    func downloadModel() {
        needsModel = false
        downloading = 0
        Task {
            let source = URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin")!
            let progress = Progress()
            let watching = progress.observe(\.fractionCompleted) { progress, _ in
                let done = progress.fractionCompleted
                Task { @MainActor in self.downloading = done }
            }
            defer { watching.invalidate() }
            do {
                let (file, response) = try await URLSession.shared.download(from: source, delegate: ModelDownload(progress: progress))
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                try FileManager.default.createDirectory(at: Self.models, withIntermediateDirectories: true)
                try? FileManager.default.removeItem(at: Self.turbo)
                try FileManager.default.moveItem(at: file, to: Self.turbo)
                downloading = nil
                start()
            } catch {
                (downloading, problem) = (nil, "Couldn’t download the speech model. Check the connection and try again.")
            }
        }
    }

    /// The ticked recordings transcribed again, in order, each added to the answer.
    func transcribeChosen() {
        for url in recordings where chosen.contains(url) { transcribe(url) }
    }

    func transcribe(_ url: URL) {
        guard let whisper = Self.whisper, let model = Self.model else {
            problem = "Recorded, but Whisper isn’t installed, so it wasn’t transcribed."
            return
        }
        transcribing = true
        let question = self.question
        Task {
            let words = await Task.detached { () -> String? in
                let wav = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
                defer { try? FileManager.default.removeItem(at: wav) }
                guard Self.run("/usr/bin/afconvert", ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", url.path, wav.path]) != nil
                else { return nil }
                Self.trimSilence(wav)
                return Self.run(whisper, ["-m", model.path, "-f", wav.path, "-nt", "-np", "-l", "en",
                                          "--prompt", String(question.prefix(600))])
            }.value
            let heard = (words ?? "").split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                .joined(separator: " ")
                .replacingOccurrences(of: #"\[[A-Z_ ]+\]|\([a-z ]+\)"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard words != nil else {
                (transcribing, problem) = (false, "Recorded, but it couldn’t be transcribed.")
                return
            }
            let maths = heard.isEmpty ? nil : await API.post("var/spoken", ["text": heard, "question": question], timeout: 30)
            let written = maths?["text"] as? String ?? heard
            if !written.isEmpty { text = text.isEmpty ? written : text + " " + written }
            transcribing = false
        }
    }

    /// Cuts the silence before and after speaking (keeping a quarter of a second either side), which
    /// otherwise leads Whisper to miss the first words or invent some in the quiet.
    nonisolated private static func trimSilence(_ wav: URL) {
        guard let file = try? AVAudioFile(forReading: wav),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buffer)) != nil, let samples = buffer.floatChannelData?[0] else { return }
        let count = Int(buffer.frameLength)
        let rate = Int(file.processingFormat.sampleRate)
        let window = rate / 50
        guard count > window else { return }
        let loud: (Int) -> Bool = { start in
            var sum: Float = 0
            for i in start..<min(start + window, count) { sum += samples[i] * samples[i] }
            return (sum / Float(window)).squareRoot() > 0.01
        }
        let windows = Array(stride(from: 0, to: count, by: window))
        guard let first = windows.first(where: loud), let last = windows.last(where: loud) else { return }
        let start = max(0, first - rate / 4), end = min(count, last + window + rate / 4)
        guard start > 0 || end < count,
              let kept = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(end - start)) else { return }
        kept.frameLength = AVAudioFrameCount(end - start)
        kept.floatChannelData![0].update(from: samples + start, count: end - start)
        let settings = file.fileFormat.settings
        guard let out = try? AVAudioFile(forWriting: wav, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        else { return }
        try? out.write(from: kept)
    }

    nonisolated private static func run(_ path: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }
}


/// Reports the speech model's download progress.
private final class ModelDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let progress: Progress
    init(progress: Progress) { self.progress = progress }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
                    totalBytesWritten written: Int64, totalBytesExpectedToWrite expected: Int64) {
        progress.totalUnitCount = expected
        progress.completedUnitCount = written
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}


/// One saved recording in an answer box: play it again, or delete it.
struct RecordingRow: View {
    let url: URL
    let number: Int
    @Binding var ticked: Bool
    let delete: () -> Void
    @State private var player: AVAudioPlayer?
    @State private var playing = false

    var body: some View {
        HStack(spacing: 8) {
            Button {
                if playing { player?.stop(); playing = false; return }
                player = try? AVAudioPlayer(contentsOf: url)
                playing = player?.play() ?? false
                if let length = player?.duration {
                    DispatchQueue.main.asyncAfter(deadline: .now() + length) { playing = player?.isPlaying ?? false }
                }
            } label: { Image(systemName: playing ? "stop.fill" : "play.fill") }
            .buttonStyle(.borderless)
            Toggle("Recording \(number)", isOn: $ticked)
                .toggleStyle(.checkbox).font(Scaled.style(12, .regular))
                .help("Ticked recordings are sent with your answer for marking")
            Text(Self.length(url)).font(Scaled.style(11, .regular)).foregroundStyle(.secondary)
            Spacer()
            Button { player?.stop(); delete() } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless).help("Delete this recording")
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
    }

    static func length(_ url: URL) -> String {
        guard let file = try? AVAudioFile(forReading: url) else { return "" }
        let seconds = Int(Double(file.length) / file.fileFormat.sampleRate)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}


@MainActor
final class VARModel: ObservableObject {

    @Published var projects: [String] = []
    @Published var filter = "all"
    /// Academic (write-ups for a viva or exam) or professional (projects for interviews, reports to
    /// present): each side has its own sets, remembered separately.
    @Published var side: String = UserDefaults.standard.string(forKey: "varSide") ?? "academic" {
        didSet {
            UserDefaults.standard.set(side, forKey: "varSide")
            document = UserDefaults.standard.string(forKey: "varDocument.\(side)") ?? ""
            Task { await reload() }
        }
    }
    var professional: Bool { side == "professional" }
    @Published var documents: [[String: Any]] = []
    @Published var document: String = UserDefaults.standard.string(forKey: "varDocument") ?? "" {
        didSet { UserDefaults.standard.set(document, forKey: "varDocument"); UserDefaults.standard.set(document, forKey: "varDocument.\(side)") }
    }
    @Published var topics: [[String: Any]] = []
    @Published var files: [String] = []
    @Published var state = "none"
    @Published var strong = 0
    @Published var total = 0
    @Published var changed = false
    /// What the current set is for, and its job description or audience.
    @Published var purpose = "viva"
    /// Said when something chosen or dropped couldn't be read, rather than nothing happening.
    @Published var notice: String?
    /// Documents Referee has read in Overleaf, Google Docs or Word, newest first.
    @Published var writing: [[String: Any]] = []

    func loadWriting() async { writing = await API.getList("var/writing") }

    /// Practise on one of those documents, from its sentences as last read.
    func fromWriting(_ name: String, purpose: String) {
        Task {
            let found = await API.post("var/from-writing", ["document": name, "purpose": purpose], timeout: 15)
            guard found?["ok"] as? Bool == true, let made = found?["name"] as? String else {
                notice = "Couldn't read that document. Open it with Referee's panel showing, then try again."
                return
            }
            if purpose != "viva" && side != "professional" { side = "professional" }
            document = made
            await reload()
        }
    }
    @Published var context = ""
    @Published var selected: String?
    private var current = ""

    func load() {
        Task {
            if let settings = await API.get("settings") {
                projects = settings["projects"] as? [String] ?? []
                current = settings["project"] as? String ?? ""
                if filter == "all" && !current.isEmpty { filter = current }
            }
            await reload()
        }
    }

    func reload() async {
        // Professional sets aren't tied to a Referee project: all of them, whatever the project picker says.
        documents = await API.getList("var/documents?project=all")
            .filter { (($0["purpose"] as? String ?? "viva") == "viva") != professional }
        let names = documents.compactMap { $0["name"] as? String }
        if !names.contains(document) { document = names.first ?? "" }
        await loadItems()
    }

    /// The saved study set, checked again every few seconds while it's being built.
    func loadItems() async {
        guard !document.isEmpty, let found = await API.get("var/items?document=\(encoded(document))") else {
            (topics, state, strong, total, changed, files) = ([], "none", 0, 0, false, [])
            (purpose, context) = (professional ? "interview" : "viva", "")
            return
        }
        topics = found["topics"] as? [[String: Any]] ?? []
        files = (await API.getList("var/files?document=\(encoded(document))")).compactMap { $0["name"] as? String }
        state = found["state"] as? String ?? "none"
        strong = found["strong"] as? Int ?? 0
        total = found["total"] as? Int ?? 0
        changed = found["changed"] as? Bool ?? false
        purpose = found["purpose"] as? String ?? "viva"
        context = found["context"] as? String ?? ""
        if state == "building" {
            try? await Task.sleep(for: .seconds(4))
            await loadItems()
        }
    }

    /// The current project, for its mark scheme and new write-ups.
    var project: String {
        (documents.first { $0["name"] as? String == document }?["project"] as? String)
            ?? (filter == "all" || filter == "none" ? current : filter)
    }

    /// Takes the write-up out of VAR, with its questions, progress and mock vivas.
    func delete() {
        Task {
            _ = await API.delete("var/document?name=\(encoded(document))")
            document = ""
            selected = nil
            await reload()
        }
    }

    /// New questions from the write-up as it is now.
    func rebuild() {
        Task {
            _ = await API.post("var/rebuild", ["document": document])
            selected = nil
            await loadItems()
        }
    }

    /// .tex files to practise on, or Overleaf's "Download as source (.zip)", for writing that isn't open
    /// in Overleaf: as a new write-up, or added to this one.
    func chooseFile(adding: Bool = false, purpose: String? = nil) {
        let purpose = purpose ?? (adding ? self.purpose : "viva")
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.prompt = adding ? "Add" : "Practise on These"
        if purpose == "viva" {
            // A write-up (LaTeX, the .zip from Overleaf, R Markdown, Quarto, a PDF or Word document), its
            // code, or the project's folder.
            panel.canChooseDirectories = true
            panel.message = "Choose your write-up, its files, or the project's folder"
        } else {
            // A project folder or repository, or a report: its files' text is read.
            panel.canChooseDirectories = purpose == "interview"
            panel.message = purpose == "interview" ? "Choose the project’s folder, or its files" : "Choose the report or slides"
        }
        guard panel.runModal() == .OK else { return }
        open(panel.urls, adding: adding, purpose: purpose)
    }

    /// Text that can be read from a file: code, notebooks, Markdown, PDFs, Word and rich text.
    static func readable(_ url: URL) async -> String? {
        let kind = url.pathExtension.lowercased()
        switch kind {
        case "ipynb":
            guard let data = try? Data(contentsOf: url),
                  let notebook = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
            return (notebook["cells"] as? [[String: Any]] ?? []).map { cell in
                let source = cell["source"] as? [String] ?? [(cell["source"] as? String) ?? ""]
                return (cell["cell_type"] as? String == "markdown" ? "" : "# [code]\n") + source.joined()
            }.joined(separator: "\n\n")
        case "pdf":
            return await BriefReader.text(of: url)
        case "docx", "doc", "rtf", "odt":
            return (try? NSAttributedString(url: url, options: [:], documentAttributes: nil))?.string
        case "zip":
            return Self.latex(inZip: url)
        default:
            return try? String(contentsOf: url, encoding: .utf8)
        }
    }

    /// A project folder's files worth reading, the README first: code, notebooks and write-ups, not data
    /// or anything hidden or installed.
    static func projectFiles(in folder: URL) -> [URL] {
        let wanted: Set<String> = ["md", "txt", "py", "ipynb", "r", "rmd", "qmd", "sql", "jl", "js", "ts", "swift", "java", "scala", "tex", "pdf"]
        let skipped: Set<String> = [".git", "node_modules", ".venv", "venv", "__pycache__", "build", "dist", ".ipynb_checkpoints"]
        guard let walk = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey],
                                                        options: [.skipsHiddenFiles]) else { return [] }
        var found: [URL] = []
        for case let url as URL in walk {
            if skipped.contains(url.lastPathComponent) { walk.skipDescendants(); continue }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if wanted.contains(url.pathExtension.lowercased()) && size < 400_000 { found.append(url) }
        }
        return found.sorted { a, b in
            let readme = { (u: URL) in u.lastPathComponent.lowercased().hasPrefix("readme") }
            return readme(a) != readme(b) ? readme(a) : a.path.count < b.path.count
        }
    }

    /// Chosen or dropped .tex files or source .zips. A write-up can be several files (one per question,
    /// say), learnt and examined together, as a viva would.
    @discardableResult
    /// Files kept online only (OneDrive, iCloud Drive, Google Drive) that aren't on this Mac yet: asked
    /// to download, and named, so VAR says why it can't read them yet instead of failing.
    static func onlineOnly(_ urls: [URL]) -> [URL] {
        urls.filter { url in
            // Kept online only: macOS marks the file "dataless" until its contents are downloaded.
            var info = stat()
            guard stat(url.path, &info) == 0, info.st_flags & UInt32(0x40000000) != 0 else { return false }   // SF_DATALESS
            // Opening it through a file coordinator asks OneDrive, iCloud Drive or Google Drive to fetch it.
            DispatchQueue.global(qos: .utility).async {
                NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: nil) { _ in }
            }
            return true
        }
    }

    func open(_ urls: [URL], adding: Bool, purpose: String = "viva") -> Bool {
        let away = Self.onlineOnly(urls)
        if !away.isEmpty {
            notice = "\(away.map(\.lastPathComponent).joined(separator: ", ")) \(away.count == 1 ? "is" : "are") stored online only, so "
                + "\(away.count == 1 ? "it's" : "they're") being downloaded to this Mac. Add \(away.count == 1 ? "it" : "them") again once "
                + "the download finishes. If nothing happens, open OneDrive (or iCloud Drive) and choose Always Keep on This Device."
            return true
        }
        // Anything besides LaTeX (R Markdown, a PDF, a project folder, code): read as text, as a GitHub
        // repository is, the write-up first.
        if purpose != "viva" || urls.contains(where: { !["tex", "zip"].contains($0.pathExtension.lowercased()) }) {
            Task { await openProject(urls, adding: adding, purpose: purpose) }
            return true
        }
        let added: [[String: String]] = urls.compactMap { url in
            let kind = url.pathExtension.lowercased()
            guard ["tex", "zip"].contains(kind),
                  let latex = kind == "zip" ? Self.latex(inZip: url) : try? String(contentsOf: url, encoding: .utf8) else { return nil }
            return ["name": url.deletingPathExtension().lastPathComponent, "latex": latex]
        }
        guard let first = added.first else {
            notice = "Couldn't read any LaTeX from \(urls.map(\.lastPathComponent).joined(separator: ", "))."
            return false
        }
        let name = adding && !document.isEmpty ? document : (first["name"] ?? "Write-up") + ".tex"
        Task {
            _ = await API.post("var/files", ["document": name, "add": added, "project": project])
            document = name
            await reload()
        }
        return true
    }

    /// A project folder or report for an interview or presentation: each file's text, named by its path in
    /// the folder.
    private func openProject(_ urls: [URL], adding: Bool, purpose: String) async {
        var added: [[String: String]] = []
        for url in urls {
            let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            for file in isFolder ? Self.projectFiles(in: url) : [url] {
                guard let text = await Self.readable(file), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                let shown = isFolder ? url.lastPathComponent + "/" + file.path.dropFirst(url.path.count + 1) : file.lastPathComponent
                added.append(["name": shown, "latex": "=== \(shown) ===\n" + text])
            }
        }
        guard !added.isEmpty else {
            notice = "Couldn't read any text from \(urls.map(\.lastPathComponent).joined(separator: ", ")). VAR reads LaTeX, R Markdown, Quarto, Markdown, PDFs, Word documents, code and notebooks."
            return
        }
        if purpose != "viva" && side != "professional" { side = "professional" }
        // A write-up before the code it reports on, as for a GitHub repository.
        let writeUp = { (f: [String: String]) in
            (f["latex"] ?? "").contains("\\documentclass") || [".tex", ".rmd", ".qmd", ".pdf", ".docx"].contains { (f["name"] ?? "").lowercased().hasSuffix($0) } }
        if purpose == "viva" { added.sort { writeUp($0) && !writeUp($1) } }
        let name = adding && !document.isEmpty ? document : (urls.first?.deletingPathExtension().lastPathComponent ?? "Project")
        _ = await API.post("var/files", ["document": name, "add": added, "project": project, "purpose": purpose], timeout: 15)
        document = name
        await reload()
    }

    func setContext(_ text: String) async {
        _ = await API.post("var/context", ["document": document, "context": text])
        context = text
    }

    /// Takes one file out of the write-up.
    func remove(file: String) {
        Task {
            _ = await API.post("var/files", ["document": document, "remove": file])
            await reload()
        }
    }

    /// Every .tex file in a project's source zip, the main one (with \documentclass) first.
    static func latex(inZip url: URL) -> String? {
        func run(_ arguments: [String]) -> String? {
            let process = Process(), pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            process.arguments = arguments
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(data: data, encoding: .utf8)
        }
        guard let listing = run(["-Z1", url.path]) else { return nil }
        let files = listing.split(separator: "\n").map(String.init).filter { $0.lowercased().hasSuffix(".tex") }
        let texts = files.compactMap { run(["-p", url.path, $0]) }
        guard !texts.isEmpty else { return nil }
        return texts.sorted { $0.contains("\\documentclass") && !$1.contains("\\documentclass") }.joined(separator: "\n\n")
    }

    func encoded(_ text: String) -> String { text.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "" }
}


/// What a set is for, and the words each one uses.
enum VARPurpose {
    static let all = ["viva", "interview", "briefing"]

    static func name(_ purpose: String) -> String {
        ["viva": "Viva or exam", "interview": "Job interview", "briefing": "Presentation or Q&A"][purpose] ?? "Viva or exam"
    }
    static func mock(_ purpose: String) -> String {
        ["interview": "Mock interview", "briefing": "Mock Q&A"][purpose] ?? "Mock viva"
    }
    /// The occasion itself, in a sentence: "viva", "interview", "Q&A".
    static func noun(_ purpose: String) -> String {
        ["interview": "interview", "briefing": "Q&A"][purpose] ?? "viva"
    }
    /// With its article: "a viva", "an interview", "a Q&A".
    static func aNoun(_ purpose: String) -> String {
        (purpose == "interview" ? "an " : "a ") + noun(purpose)
    }
    static func context(_ purpose: String) -> String {
        ["interview": "Job description", "briefing": "Audience"][purpose] ?? "Project brief"
    }
    static func section(_ section: String, _ purpose: String) -> String {
        switch purpose {
        case "interview": return ["opening": "Walkthrough", "concept": "Methods and tools", "argument": "Decisions and results", "related": "Beyond the project"][section] ?? ""
        case "briefing": return ["opening": "Opening", "concept": "Key figures and claims", "argument": "Reasoning and recommendations", "related": "Likely challenges"][section] ?? ""
        default: return ["opening": "Opening", "concept": "Concepts", "argument": "Arguments", "related": "Related topics"][section] ?? ""
        }
    }
    static func task(_ task: String, _ purpose: String) -> String {
        switch purpose {
        case "interview": return ["account": "Walkthrough", "state": "Why this", "examples": "When it fails", "explain": "Explain", "perturb": "What if", "error": "Spot the flaw"][task] ?? task
        case "briefing": return ["account": "Opening summary", "state": "Where it’s from", "examples": "What it shows", "explain": "Explain", "perturb": "What if", "error": "Spot the flaw"][task] ?? task
        default: return ["account": "Opening account", "state": "State it", "examples": "Examples and non-examples", "explain": "Explain", "perturb": "Perturb", "error": "Check an argument"][task] ?? task
        }
    }
}


struct VARView: View {

    @StateObject private var model = VARModel()
    @State private var viva = false
    @State private var scheme = false
    @State private var deleting = false

    /// What can be practised on: a document Referee has read in an editor, or a file or folder.
    @ViewBuilder private func addChoices(_ purpose: String) -> some View {
        if !model.writing.isEmpty {
            SwiftUI.Section("From your writing") {
                ForEach(Array(model.writing.prefix(12).enumerated()), id: \.offset) { _, doc in
                    let editor = doc["editor"] as? String ?? ""
                    Button((doc["title"] as? String ?? "") + (editor.isEmpty ? "" : " · \(editor)")) {
                        model.fromWriting(doc["document"] as? String ?? "", purpose: purpose)
                    }
                }
            }
            Divider()
        }
        Button("Choose a file or folder") { model.chooseFile(purpose: purpose) }
    }

    var body: some View {
        GeometryReader { space in
            HStack(spacing: 0) {
                sidebar.frame(width: min(240, max(180, space.size.width * 0.32)))
                Divider().opacity(0.4)
                if viva {
                    MockViva(document: model.document, purpose: model.purpose) { viva = false; Task { await model.loadItems() } }
                        .id(model.document)
                } else if let id = model.selected, let topic = model.topics.first(where: { $0["id"] as? String == id }) {
                    Practice(document: model.document, purpose: model.purpose, topic: topic, topics: model.topics,
                             select: { model.selected = $0 }) { Task { await model.loadItems() } }
                        .id(id)
                } else if model.document.isEmpty && model.professional {
                    EmptyPage(symbol: "briefcase", title: "Nothing to practise yet",
                              message: "Add a project you’ve built (its folder or repository) to practise explaining and defending it in a job interview, or a report you’ll present to rehearse the questions on it. Questions are written once and saved for next time.",
                              action: ("Add a project for an interview", { model.chooseFile(purpose: "interview") }))
                } else if model.document.isEmpty {
                    EmptyPage(symbol: "tv", title: "Nothing to practise yet",
                              message: "Choose or drop in your write-up (LaTeX or Overleaf’s .zip, Word, PDF, R Markdown, Quarto) or its project’s folder, or pick from ＋ a document Referee has read in Overleaf, Google Docs or Word. Its concepts and arguments, and topics around them, become questions to learn from, saved for next time.",
                              action: ("Choose a file", { model.chooseFile() }))
                } else if model.state == "building" {
                    EmptyPage(symbol: "tv", title: "Writing your questions",
                              message: "Claude is reading your write-up once and writing questions on each concept, argument and related topic, using your reading for this project where it helps. This takes a minute or two, and they’re saved for next time.",
                              action: nil)
                } else if model.topics.isEmpty {
                    EmptyPage(symbol: "tv", title: "No questions yet",
                              message: model.state == "no_api_key" ? keyProblem("no_api_key")! : "Writing the questions didn’t finish. Try again.",
                              action: ("Write questions", { model.rebuild() }))
                } else {
                    EmptyPage(symbol: "tv", title: "Choose something to learn",
                              message: "Work through each topic’s tasks until it reaches Mastery, or start a \(VARPurpose.mock(model.purpose).lowercased()): questions in order, with no hints, and how it went at the end.",
                              action: ("Start \(VARPurpose.mock(model.purpose).lowercased())", { viva = true }))
                }
            }
        }
        .task { await model.loadWriting() }
        .dropDestination(for: URL.self) { urls, _ in model.open(urls, adding: false) }
        .alert(model.notice ?? "", isPresented: Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } })) {
            Button("OK") { model.notice = nil }
        }
        .onAppear { model.load() }
        .onChange(of: model.filter) { _, _ in Task { await model.reload() } }
        .onChange(of: model.document) { _, _ in model.selected = nil; Task { await model.loadItems() } }
        .onChange(of: model.selected) { _, new in if new != nil { viva = false } }
        .pageActions {
            Picker("", selection: $model.side) {
                Text("Academic").tag("academic")
                Text("Professional").tag("professional")
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            if model.professional {
                Menu {
                    Menu("Job interview") { addChoices("interview") }
                    Menu("Presentation or Q&A") { addChoices("briefing") }
                } label: { HeaderIcon("doc.badge.plus") }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().menuOrder(.fixed)
                    .help("Practise for a job interview or a presentation")
            } else {
                Menu { addChoices("viva") } label: { HeaderIcon("doc.badge.plus") }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().menuOrder(.fixed)
                    .help("Practise on your write-up")
            }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                if model.documents.isEmpty {
                    Text("No sets yet").foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Picker("Set", selection: $model.document) {
                        if model.professional {
                            ForEach(model.documents.compactMap { d -> (String, String)? in
                                guard let name = d["name"] as? String else { return nil }
                                return (name, name + (d["purpose"] as? String == "briefing" ? " · Presentation" : " · Interview"))
                            }, id: \.0) { Text($0.1).tag($0.0) }
                        } else {
                            // Write-ups grouped under their project: choosing one chooses its project too.
                            let groups = Dictionary(grouping: model.documents) { $0["project"] as? String ?? "" }
                            ForEach(groups.keys.sorted { a, b in a.isEmpty != b.isEmpty ? !a.isEmpty : a < b }, id: \.self) { project in
                                SwiftUI.Section(project.isEmpty ? "No project" : project) {
                                    ForEach(groups[project]?.compactMap { $0["name"] as? String } ?? [], id: \.self) { Text($0).tag($0) }
                                }
                            }
                        }
                    }
                    .labelsHidden()
                }
                Menu {
                    Button(VARPurpose.context(model.purpose)) { scheme = true }
                    Button("Write new questions") { model.rebuild() }.disabled(model.document.isEmpty)
                    Divider()
                    Button(model.professional ? "Delete this set" : "Delete this write-up", role: .destructive) { deleting = true }
                        .disabled(model.document.isEmpty)
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                    .help("Brief, new questions, delete")
            }
            .padding(.top, 12)
            .confirmationDialog("Take “\(model.document)” out of VAR?", isPresented: $deleting) {
                Button("Delete questions and progress", role: .destructive) { model.delete() }
            } message: {
                Text("Its questions, your progress on them and its mocks are deleted. The files themselves aren’t touched.")
            }
            .sheet(isPresented: $scheme) {
                if model.purpose == "viva" {
                    BriefSheet(project: model.project, rebuild: model.topics.isEmpty ? nil : { model.rebuild() })
                } else {
                    ContextSheet(model: model)
                }
            }
            Button { model.selected = nil; viva = true } label: {
                Label(VARPurpose.mock(model.purpose), systemImage: "person.2").frame(maxWidth: .infinity, alignment: .leading)
            }
            .glassButton()
            .disabled(model.topics.isEmpty)
            if model.total > 0 {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Mastery · \(model.strong) of \(model.total) tasks").font(Scaled.style(11, .regular)).foregroundStyle(.secondary)
                    ProgressView(value: Double(model.strong), total: Double(model.total)).controlSize(.small)
                }
            }
            if model.changed {
                Button("Write-up changed · new questions") { model.rebuild() }
                    .font(Scaled.style(11, .regular)).buttonStyle(.link)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(["opening", "concept", "argument", "related"], id: \.self) { section in
                        let inSection = model.topics.filter { $0["section"] as? String == section }
                        if !inSection.isEmpty {
                            Text(VARPurpose.section(section, model.purpose))
                                .font(Scaled.style(10, .regular)).foregroundStyle(.tertiary)
                                .padding(.horizontal, 10).padding(.top, 10)
                            ForEach(inSection.compactMap { $0["id"] as? String }, id: \.self) { id in
                                if let topic = inSection.first(where: { $0["id"] as? String == id }) { row(topic) }
                            }
                        }
                    }
                }
            }
            .padding(.bottom, 14)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
    }

    private func row(_ topic: [String: Any]) -> some View {
        let id = topic["id"] as? String ?? ""
        let tasks = topic["tasks"] as? [[String: Any]] ?? []
        return VStack(alignment: .leading, spacing: 3) {
            Text(topic["title"] as? String ?? "").font(Fonts.heading(13, .semibold)).lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 3) {
                ForEach(Array(tasks.enumerated()), id: \.offset) { _, task in
                    Circle().fill(TierDot.colour(task["grade"] as? Int)).frame(width: 6, height: 6)
                }
                Text(when(topic)).font(Scaled.style(10, .regular)).foregroundStyle(.secondary).lineLimit(1).padding(.leading, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(model.selected == id ? Color.primary.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture { model.selected = id }
    }

    /// "Not tried yet", "Due today", "In 9 days".
    private func when(_ topic: [String: Any]) -> String {
        let tasks = topic["tasks"] as? [[String: Any]] ?? []
        guard tasks.contains(where: { $0["grade"] is Int }) else { return "Not tried yet" }
        guard let due = topic["due"] as? String, let day = ISO8601DateFormatter.day.date(from: due) else { return "" }
        let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: Date()), to: day).day ?? 0
        return days <= 0 ? "Due today" : days == 1 ? "Tomorrow" : "In \(days) days"
    }
}


/// The four tiers, from not yet to mastery, as words and as the sidebar's dots.
enum TierDot {
    static let names = ["Not yet", "Developing", "Secure", "Mastery"]
    static func colour(_ grade: Int?) -> Color {
        guard let grade else { return Color.primary.opacity(0.15) }
        return [Color.red.opacity(0.7), .orange, Color.green.opacity(0.55), .green][max(0, min(3, grade))]
    }
}


extension ISO8601DateFormatter {
    static let day: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        return formatter
    }()
}


/// The answer box: speak or type, and the transcript stays editable before it's checked.
struct AnswerBox: View {
    @ObservedObject var transcriber: Transcriber
    @Binding var spoken: Bool
    /// Asking VAR a question, rather than answering one.
    var asking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    if transcriber.listening { transcriber.stop() } else { spoken = true; transcriber.start() }
                } label: {
                    Label(transcriber.listening ? "Stop" : (asking ? "Ask verbally" : "Answer verbally"), systemImage: transcriber.listening ? "stop.circle" : "mic")
                }
                .glassButton()
                if transcriber.starting {
                    Text("Asking for the microphone…").font(Scaled.style(11, .regular)).foregroundStyle(.secondary)
                }
                if transcriber.listening {
                    Text("Recording").font(Scaled.style(11, .regular)).foregroundStyle(.secondary)
                }
                if transcriber.transcribing {
                    ProgressView().controlSize(.small)
                    Text("Transcribing on this Mac…").font(Scaled.style(11, .regular)).foregroundStyle(.secondary)
                }
            }
            if transcriber.needsModel {
                HStack(spacing: 10) {
                    Text("Answering verbally needs Whisper’s speech model: a one-off download of about 550 MB, from whisper.cpp’s models on Hugging Face. Your recordings stay on this Mac.")
                        .font(Scaled.style(11, .regular)).foregroundStyle(.secondary)
                    Button("Download") { transcriber.downloadModel() }.glassButton()
                    Button("Not now") { transcriber.needsModel = false }.glassButton()
                }
            }
            if let done = transcriber.downloading {
                HStack(spacing: 8) {
                    ProgressView(value: done).frame(width: 120)
                    Text("Downloading the speech model, \(Int(done * 100))%").font(Scaled.style(11, .regular)).foregroundStyle(.secondary)
                }
            }
            if let problem = transcriber.problem {
                Text(problem).font(Scaled.style(11, .regular)).foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Text(spoken ? "Transcribed on this Mac by Whisper. Correct anything misheard before \(asking ? "asking" : "checking")."
                     : asking ? "Or type your question. Paste or drop in pictures." : "Or type your answer. Paste or drop in pictures of your written working.")
                    .font(Scaled.style(11, .regular)).foregroundStyle(.tertiary)
                Spacer()
                Button("Add file") {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [.pdf, .image]
                    panel.allowsMultipleSelection = true
                    guard panel.runModal() == .OK else { return }
                    transcriber.pictures += panel.urls.flatMap(AnswerPictures.from)
                }
                .buttonStyle(.link).font(Scaled.style(11, .regular))
                .help("Handwritten working as a PDF or picture, from GoodNotes say")
            }
            ForEach(Array(transcriber.recordings.enumerated()), id: \.element) { index, url in
                RecordingRow(url: url, number: index + 1, ticked: Binding(
                    get: { transcriber.chosen.contains(url) },
                    set: { if $0 { transcriber.chosen.insert(url) } else { transcriber.chosen.remove(url) } })) { transcriber.delete(url) }
            }
            if !transcriber.recordings.isEmpty {
                Button("Transcribe ticked") { transcriber.transcribeChosen() }
                    .buttonStyle(.link).font(Scaled.style(11, .regular))
                    .disabled(transcriber.chosen.isEmpty || transcriber.transcribing)
                    .help("Transcribe the ticked recordings again and add them to your answer")
            }
            if !transcriber.pictures.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(transcriber.pictures, id: \.self) { path in
                            if let image = NSImage(contentsOfFile: path) {
                                Image(nsImage: image).resizable().scaledToFit().frame(height: 110)
                                    .background(Color.white, in: RoundedRectangle(cornerRadius: 4))
                                    .overlay(alignment: .topTrailing) {
                                        Button { transcriber.pictures.removeAll { $0 == path } } label: { Image(systemName: "xmark.circle.fill") }
                                            .buttonStyle(.borderless).padding(3)
                                    }
                            }
                        }
                    }
                }
            }
            AnswerEditor(text: $transcriber.text) { transcriber.pictures += $0 }
                .frame(minHeight: 90)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
            if transcriber.text.contains("$") {
                Text("How it reads").font(Scaled.style(11, .regular)).foregroundStyle(.tertiary).padding(.top, 2)
                MarkdownView(text: transcriber.text)
            }
        }
    }
}


/// The answer's text box. Pictures pasted or dropped into it (a screenshot, a GoodNotes export) are
/// added to the answer as pictures rather than as their file path.
struct AnswerEditor: NSViewRepresentable {
    @Binding var text: String
    let pictures: ([String]) -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.autohidesScrollers = true
        let pictureView = PictureTextView(frame: .zero)
        pictureView.autoresizingMask = [.width]
        pictureView.isVerticallyResizable = true
        pictureView.textContainer?.widthTracksTextView = true
        pictureView.minSize = .zero
        pictureView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        scroll.documentView = pictureView
        pictureView.pictures = pictures
        pictureView.isEditable = true
        pictureView.allowsUndo = true
        pictureView.delegate = context.coordinator
        pictureView.drawsBackground = false
        pictureView.isRichText = false
        pictureView.font = .systemFont(ofSize: Scaled.s(13))
        pictureView.textContainerInset = NSSize(width: 6, height: 8)
        pictureView.registerForDraggedTypes([.fileURL, .png, .tiff])
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? PictureTextView else { return }
        view.pictures = pictures
        if view.string != text { view.string = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        func textDidChange(_ notification: Notification) {
            if let view = notification.object as? NSTextView { text.wrappedValue = view.string }
        }
    }
}

final class PictureTextView: NSTextView {
    var pictures: ([String]) -> Void = { _ in }

    /// Pictures and picture files on a pasteboard, kept as the answer's pictures; nil if there are none.
    private func take(_ board: NSPasteboard) -> Bool {
        let urls = (board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? [])
            .filter { ["pdf", "png", "jpg", "jpeg", "heic", "tiff", "gif", "webp"].contains($0.pathExtension.lowercased()) }
        var found = urls.flatMap(AnswerPictures.from)
        if urls.isEmpty, let image = NSImage(pasteboard: board), let path = AnswerPictures.save(image) { found.append(path) }
        guard !found.isEmpty else { return false }
        pictures(found)
        return true
    }

    override func paste(_ sender: Any?) {
        if !take(.general) { super.paste(sender) }
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        take(sender.draggingPasteboard) || super.performDragOperation(sender)
    }
}


/// An answer's pictures, kept on this Mac: an image as it is, a PDF (a GoodNotes export, say) a page each.
enum AnswerPictures {
    static func from(_ url: URL) -> [String] {
        if url.pathExtension.lowercased() == "pdf" {
            guard let document = PDFDocument(url: url) else { return [] }
            return (0..<min(document.pageCount, 6)).compactMap { index in
                guard let page = document.page(at: index) else { return nil }
                let box = page.bounds(for: .mediaBox)
                let scale = min(2.0, 1600 / max(box.width, box.height))
                return save(page.thumbnail(of: CGSize(width: box.width * scale, height: box.height * scale), for: .mediaBox))
            }
        }
        return NSImage(contentsOf: url).flatMap(save).map { [$0] } ?? []
    }

    static func save(_ image: NSImage) -> String? {
        guard let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return nil }
        let file = Transcriber.folder.appendingPathComponent(UUID().uuidString + ".png")
        return (try? png.write(to: file)) != nil ? file.path : nil
    }
}


/// One topic: its tasks, a saved question, your answer, then how it went, what mastery includes, the key
/// idea, and where your reading covers it.
struct Practice: View {

    let document: String
    var purpose = "viva"
    let topic: [String: Any]
    let topics: [[String: Any]]
    let select: (String) -> Void
    let done: () -> Void
    @StateObject private var transcriber = Transcriber()
    @State private var task = ""
    @State private var question = ""
    @State private var spoken = false
    @State private var result: [String: Any]?
    @State private var busy = false
    @State private var problem: String?
    @State private var showStatement = false
    @State private var grades: [String: Int] = [:]
    @State private var resetting: String?
    /// Questions about the feedback and their replies: [{"role": "user" or "assistant", "text": …}].
    @State private var conversation: [[String: String]] = []
    @State private var replying = false
    /// Every recording of the checked attempt, ticked or not, carried into "Try again".
    @State private var attempt: [URL] = []
    /// The page for questions about the feedback, in place of the practice page.
    @State private var talking = false
    /// Questions asked aloud: transcribed into the box, the recordings not kept.
    @StateObject private var voice = Transcriber()
    @State private var spokenFollow = false
    /// The answer to the feedback's follow-up question, and what was right and missing in it.
    @StateObject private var followVoice = Transcriber()
    @State private var followSpoken = false
    @State private var followBusy = false
    @State private var followAnswer = ""
    @State private var followResult: [String: Any]?
    @State private var heard: [URL] = []
    @State private var player = AVQueuePlayer()
    @State private var playing = false

    private var tasks: [String] { (topic["tasks"] as? [[String: Any]] ?? []).compactMap { $0["task"] as? String } }

    var body: some View {
        ZStack {
            if talking, let result { talk(result) } else { practice }
        }
        .task {
            for one in topic["tasks"] as? [[String: Any]] ?? [] {
                if let name = one["task"] as? String, let grade = one["grade"] as? Int { grades[name] = grade }
            }
            await ask("")
        }
        .onDisappear { transcriber.stop(); keepDraft(); player.pause(); voice.stop(); clearVoice() }
        .confirmationDialog("Reset “\(VARPurpose.task(resetting ?? "", purpose))”?",
                            isPresented: Binding(get: { resetting != nil }, set: { if !$0 { resetting = nil } })) {
            Button("Reset", role: .destructive) { if let one = resetting { reset(one) }; resetting = nil }
            Button("Cancel", role: .cancel) { resetting = nil }
        } message: {
            Text("Its grade, saved answers and review dates are removed, as if you hadn’t answered it.")
        }
    }

    private var practice: some View {
        Page {
            Text(topic["title"] as? String ?? "").font(Fonts.heading(28, .regular))
            if let place = topic["where"] as? String, !place.isEmpty {
                Text(place).font(Scaled.style(11, .regular)).foregroundStyle(.secondary)
            }
            if tasks.count > 1 {
                HStack(spacing: 6) {
                    ForEach(tasks, id: \.self) { one in
                        Button { Task { await ask(one) } } label: {
                            HStack(spacing: 4) {
                                Circle().fill(TierDot.colour(grades[one])).frame(width: 6, height: 6)
                                Text(VARPurpose.task(one, purpose))
                            }
                        }
                        .glassButton()
                        .opacity(one == task ? 1 : 0.7)
                        .contextMenu {
                            Button("Reset question", role: .destructive) { resetting = one }
                        }
                    }
                }
                .padding(.top, 8)
            }
            if question.isEmpty {
                ProgressView().controlSize(.small).padding(.top, 12)
            } else {
                MarkdownView(text: question).padding(.top, 10)
                if result == nil {
                    AnswerBox(transcriber: transcriber, spoken: $spoken).padding(.top, 12)
                    HStack(spacing: 8) {
                        Button("I don’t know") { check(saying: "I don't know.") }.glassButton().disabled(busy)
                        Spacer()
                        if busy { ProgressView().controlSize(.small) }
                        Button("Check my answer") { check() }
                            .glassButton()
                            .disabled(busy || (transcriber.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && transcriber.pictures.isEmpty))
                    }
                    .padding(.top, 6)
                } else if let result {
                    feedback(result)
                }
            }
            if let problem { Text(problem).foregroundStyle(.secondary).padding(.top, 8) }
        }
    }

    private func reset(_ one: String) {
        let topicID = topic["id"] as? String ?? ""
        Task {
            guard await API.post("var/reset", ["item": topicID, "task": one], timeout: 10)?["ok"] as? Bool == true else {
                problem = "Couldn’t reset that question. Try again."
                return
            }
            for kind in ["varChecked", "varDraft"] {
                UserDefaults.standard.removeObject(forKey: "\(kind)/\(document)/\(topicID)/\(one)")
            }
            grades[one] = nil
            if one == task {
                (transcriber.text, transcriber.pictures, transcriber.recordings) = ("", [], [])
                await ask(one)
            }
            done()
        }
    }

    @ViewBuilder private func feedback(_ result: [String: Any]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Hairline().padding(.vertical, 6)
            let grade = result["grade"] as? Int ?? 0
            HStack(spacing: 6) {
                Circle().fill(TierDot.colour(grade)).frame(width: 8, height: 8)
                Text(TierDot.names[max(0, min(3, grade))]).font(Fonts.heading(17, .regular))
            }
            ForEach(result["right"] as? [String] ?? [], id: \.self) { line in
                Label { MarkdownView(text: line) } icon: { Image(systemName: "checkmark").foregroundStyle(.green) }
            }
            ForEach(result["missing"] as? [String] ?? [], id: \.self) { line in
                Label { MarkdownView(text: line) } icon: { Image(systemName: "exclamationmark.circle").foregroundStyle(.orange) }
            }
            if let follow = result["follow_up"] as? String, !follow.isEmpty {
                MarkdownView(text: "Follow-up: " + follow).foregroundStyle(.secondary).padding(.top, 4)
                if let checked = followResult {
                    if !followAnswer.isEmpty { MarkdownView(text: "**Your answer:** " + followAnswer).padding(.top, 4) }
                    ForEach(checked["right"] as? [String] ?? [], id: \.self) { line in
                        Label { MarkdownView(text: line) } icon: { Image(systemName: "checkmark").foregroundStyle(.green) }
                    }
                    ForEach(checked["missing"] as? [String] ?? [], id: \.self) { line in
                        Label { MarkdownView(text: line) } icon: { Image(systemName: "exclamationmark.circle").foregroundStyle(.orange) }
                    }
                    Button("Answer it again") { followResult = nil; saveChecked() }.buttonStyle(.link).font(Scaled.style(11, .regular))
                } else {
                    AnswerBox(transcriber: followVoice, spoken: $followSpoken).padding(.top, 6)
                    HStack(spacing: 8) {
                        Button("I don’t know") { checkFollow(follow, saying: "I don't know.") }.glassButton().disabled(followBusy)
                        Spacer()
                        if followBusy { ProgressView().controlSize(.small) }
                        Button("Check my answer") { checkFollow(follow) }
                            .glassButton()
                            .disabled(followBusy || (followVoice.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && followVoice.pictures.isEmpty))
                    }
                }
            }
            if !heard.isEmpty {
                Button {
                    if playing { player.pause(); playing = false } else {
                        player.removeAllItems()
                        for url in heard { player.insert(AVPlayerItem(url: url), after: nil) }
                        player.play(); playing = true
                    }
                } label: { Label(playing ? "Pause" : "Play your answer", systemImage: playing ? "pause.fill" : "play.fill") }
                .buttonStyle(.link).font(Scaled.style(12, .regular)).padding(.top, 4)
            }
            PageSection("Full mastery includes") {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(result["model"] as? [String] ?? [], id: \.self) { MarkdownView(text: "· " + $0) }
                }
            }
            .padding(.top, 10)
            if let idea = result["idea"] as? String, !idea.isEmpty {
                PageSection("Key idea") { MarkdownView(text: idea) }.padding(.top, 6)
            }
            reading
            HStack(spacing: 8) {
                if !(topic["text"] as? String ?? "").isEmpty {
                    Button(showStatement ? "Hide what you wrote" : "Show what you wrote") { showStatement.toggle() }.glassButton()
                }
                Button("Try again") {
                    // The earlier recordings stay, unticked, to play back or tick again.
                    let earlier = attempt.filter { FileManager.default.fileExists(atPath: $0.path) }
                    UserDefaults.standard.removeObject(forKey: checkedKey)
                    self.result = nil   // so leaving the feedback doesn't save it straight back
                    Task {
                        await ask(task)
                        transcriber.recordings = earlier + transcriber.recordings.filter { !earlier.contains($0) }
                    }
                }
                .glassButton()
                if let next = tasks.first(where: { $0 != task && (grades[$0] ?? 0) < 3 }) {
                    Button("Next: \(VARPurpose.task(next, purpose).lowercased())") { Task { await ask(next) } }.glassButton()
                }
            }
            .padding(.top, 8)
            if showStatement, let statement = topic["text"] as? String {
                MarkdownView(text: statement)
                    .padding(12)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
            }
            Button(conversation.filter { $0["role"] == "user" }.isEmpty ? "Ask about this" : "Ask about this (\(conversation.filter { $0["role"] == "user" }.count))") { talking = true }
                .glassButton()
                .padding(.top, 4)
        }
        .padding(.top, 8)
    }

    /// Questions about the feedback, on a page of their own.
    @ViewBuilder private func talk(_ result: [String: Any]) -> some View {
        Page {
            Button { voice.stop(); talking = false } label: { Label("Back to feedback", systemImage: "chevron.left") }
                .buttonStyle(.link)
            Text(topic["title"] as? String ?? "").font(Fonts.heading(24, .regular)).padding(.top, 6)
            Text(VARPurpose.task(task, purpose)).font(Scaled.style(11, .regular)).foregroundStyle(.secondary)
            let grade = result["grade"] as? Int ?? 0
            let right = result["right"] as? [String] ?? [], missing = result["missing"] as? [String] ?? []
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 4) {
                    MarkdownView(text: question).foregroundStyle(.secondary)
                    ForEach(right, id: \.self) { line in
                        Label { MarkdownView(text: line) } icon: { Image(systemName: "checkmark").foregroundStyle(.green) }
                    }
                    ForEach(missing, id: \.self) { line in
                        Label { MarkdownView(text: line) } icon: { Image(systemName: "exclamationmark.circle").foregroundStyle(.orange) }
                    }
                }
                .padding(.top, 4)
            } label: {
                HStack(spacing: 6) {
                    Circle().fill(TierDot.colour(grade)).frame(width: 8, height: 8)
                    Text("\(TierDot.names[max(0, min(3, grade))]): \(right.count) right, \(missing.count) missing")
                }
            }
            .padding(.top, 10)
            Hairline().padding(.vertical, 8)
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(conversation.enumerated()), id: \.offset) { _, line in
                    MarkdownView(text: (line["role"] == "user" ? "**You:** " : "**VAR:** ") + (line["text"] ?? ""))
                    let shown = (line["pictures"] ?? "").split(separator: "\n").map(String.init)
                    if !shown.isEmpty {
                        HStack(spacing: 8) {
                            ForEach(shown, id: \.self) { path in
                                if let image = NSImage(contentsOfFile: path) {
                                    Image(nsImage: image).resizable().scaledToFit().frame(height: 90)
                                        .background(Color.white, in: RoundedRectangle(cornerRadius: 4))
                                }
                            }
                        }
                    }
                }
            }
            AnswerBox(transcriber: voice, spoken: $spokenFollow, asking: true).padding(.top, 12)
            HStack(spacing: 8) {
                Spacer()
                if replying { ProgressView().controlSize(.small) }
                Button("Ask", action: followUp)
                    .glassButton()
                    .disabled(replying || voice.transcribing
                              || (voice.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && voice.pictures.isEmpty))
            }
            .padding(.top, 6)
            if let problem { Text(problem).foregroundStyle(.secondary).padding(.top, 8) }
        }
        .onAppear { voice.question = (topic["title"] as? String ?? "") + ". " + question }
    }

    /// Questions asked aloud only need their words: the recordings go once transcribed and sent.
    private func clearVoice() {
        for url in voice.recordings { voice.delete(url) }
    }

    private func checkFollow(_ follow: String, saying words: String? = nil) {
        followVoice.stop()
        let answer = words ?? followVoice.text
        followBusy = true
        Task {
            let found = await API.post("var/followcheck", ["document": document, "item": topic["id"] as? String ?? "", "task": task,
                                                            "follow": follow, "answer": answer,
                                                            "pictures": words == nil ? followVoice.pictures : []], timeout: 60)
            followBusy = false
            if found?["ok"] as? Bool == true {
                (followAnswer, followResult) = (answer, found)
                (followVoice.text, followVoice.pictures) = ("", [])
                saveChecked()
            } else {
                problem = keyProblem(found?["reason"] as? String) ?? "Couldn’t check the answer. Try again."
            }
        }
    }

    private func followUp() {
        let text = voice.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let pictures = voice.pictures
        guard !text.isEmpty || !pictures.isEmpty, !replying, let result else { return }
        conversation.append(["role": "user", "text": text, "pictures": pictures.joined(separator: "\n")])
        voice.stop()
        clearVoice()
        (voice.text, voice.pictures, replying, problem, spokenFollow) = ("", [], true, nil, false)
        Task {
            let found = await API.post("var/followup", ["document": document, "item": topic["id"] as? String ?? "", "task": task,
                                                         "feedback": ["right": result["right"] ?? [], "missing": result["missing"] ?? []],
                                                         "conversation": conversation], timeout: 60)
            replying = false
            if let reply = found?["reply"] as? String {
                conversation.append(["role": "assistant", "text": reply])
                saveChecked()
            } else {
                conversation.removeLast()
                (voice.text, voice.pictures) = (text, pictures)
                problem = keyProblem(found?["reason"] as? String) ?? "Couldn’t get a reply. Try again."
            }
        }
    }

    /// The checked answer, its feedback and any questions about it, kept until "Try again".
    private func saveChecked() {
        guard let result, let data = try? JSONSerialization.data(withJSONObject: [
            "question": question, "result": result, "heard": heard.map(\.path), "attempt": attempt.map(\.path),
            "conversation": conversation, "followAnswer": followAnswer, "followResult": followResult ?? [:],
            "followDraft": ["text": followVoice.text, "pictures": followVoice.pictures,
                            "recordings": followVoice.recordings.map(\.path), "chosen": followVoice.chosen.map(\.path),
                            "spoken": followSpoken]]) else { return }
        UserDefaults.standard.set(data, forKey: checkedKey)
    }

    /// Where your reading for this project covers the topic, and the topics it connects to.
    @ViewBuilder private var reading: some View {
        let passages = topic["reading"] as? [[String: Any]] ?? []
        let connects = (topic["connects"] as? [String] ?? []).compactMap { title in topics.first { $0["title"] as? String == title } }
        if !passages.isEmpty || !connects.isEmpty {
            PageSection("To learn more") {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(passages.enumerated()), id: \.offset) { _, passage in
                        let url = passage["url"] as? String ?? ""
                        let page = passage["page"] as? Int
                        Button((passage["source"] as? String ?? "Your reading") + (page.map { ", p. \($0)" } ?? "")) {
                            RefereeLinks.openSource(url, page: page, pdf: url.lowercased().hasSuffix(".pdf"))
                        }
                        .buttonStyle(.link)
                    }
                    ForEach(Array(connects.enumerated()), id: \.offset) { _, other in
                        Button("Related: " + (other["title"] as? String ?? "")) { select(other["id"] as? String ?? "") }
                            .buttonStyle(.link)
                    }
                }
            }
            .padding(.top, 6)
        }
    }

    static func label(_ task: String) -> String {
        ["account": "Opening account", "state": "State it", "examples": "Examples and non-examples",
         "explain": "Explain", "perturb": "Perturb", "error": "Check an argument"][task] ?? task
    }

    private var draftKey: String { "varDraft/\(document)/\(topic["id"] as? String ?? "")/\(task)" }
    private var checkedKey: String { "varChecked/\(document)/\(topic["id"] as? String ?? "")/\(task)" }

    /// The answer so far, kept when moving to another question or topic, until it's checked.
    private func keepDraft() {
        guard !task.isEmpty, !question.isEmpty else { return }
        // After feedback, the follow-up answer so far is kept with it.
        if result != nil { followVoice.stop(); saveChecked(); return }
        if transcriber.text.isEmpty && transcriber.pictures.isEmpty && transcriber.recordings.isEmpty {
            UserDefaults.standard.removeObject(forKey: draftKey)
        } else {
            UserDefaults.standard.set(["text": transcriber.text, "pictures": transcriber.pictures,
                                       "recordings": transcriber.recordings.map(\.path), "chosen": transcriber.chosen.map(\.path),
                                       "spoken": spoken], forKey: draftKey)
        }
    }

    private func ask(_ wanted: String) async {
        transcriber.stop()
        keepDraft()
        transcriber.text = ""
        (question, result, problem, showStatement, spoken) = ("", nil, nil, false, false)
        (conversation, talking, followAnswer, followResult) = ([], false, "", nil)
        (followVoice.text, followVoice.pictures, followVoice.recordings, followVoice.chosen) = ("", [], [], [])
        transcriber.pictures = []
        transcriber.recordings = []
        transcriber.chosen = []
        transcriber.keeping = true
        heard = []
        player.pause()
        let found = await API.post("var/question", ["document": document, "item": topic["id"] as? String ?? "", "task": wanted], timeout: 10)
        if found?["ok"] as? Bool == true {
            question = found?["question"] as? String ?? ""
            task = found?["task"] as? String ?? ""
            transcriber.question = (topic["title"] as? String ?? "") + ". " + question
            // A checked answer stays with its feedback until "Try again".
            if let data = UserDefaults.standard.data(forKey: checkedKey),
               let checked = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let saved = checked["result"] as? [String: Any] {
                question = checked["question"] as? String ?? question
                conversation = checked["conversation"] as? [[String: String]] ?? []
                followAnswer = checked["followAnswer"] as? String ?? ""
                followResult = (checked["followResult"] as? [String: Any]).flatMap { $0.isEmpty ? nil : $0 }
                if let draft = checked["followDraft"] as? [String: Any] {
                    followVoice.text = draft["text"] as? String ?? ""
                    followVoice.pictures = (draft["pictures"] as? [String] ?? []).filter { FileManager.default.fileExists(atPath: $0) }
                    followVoice.recordings = (draft["recordings"] as? [String] ?? []).filter { FileManager.default.fileExists(atPath: $0) }
                        .map { URL(fileURLWithPath: $0) }
                    followVoice.chosen = Set((draft["chosen"] as? [String] ?? []).map { URL(fileURLWithPath: $0) })
                    followSpoken = draft["spoken"] as? Bool ?? false
                }
                attempt = (checked["attempt"] as? [String] ?? checked["heard"] as? [String] ?? [])
                    .filter { FileManager.default.fileExists(atPath: $0) }.map { URL(fileURLWithPath: $0) }
                heard = (checked["heard"] as? [String] ?? []).filter { FileManager.default.fileExists(atPath: $0) }
                    .map { URL(fileURLWithPath: $0) }
                result = saved
            } else if let draft = UserDefaults.standard.dictionary(forKey: draftKey) {
                transcriber.text = draft["text"] as? String ?? ""
                transcriber.pictures = (draft["pictures"] as? [String] ?? []).filter { FileManager.default.fileExists(atPath: $0) }
                transcriber.recordings = (draft["recordings"] as? [String] ?? []).filter { FileManager.default.fileExists(atPath: $0) }
                    .map { URL(fileURLWithPath: $0) }
                transcriber.chosen = Set((draft["chosen"] as? [String] ?? draft["recordings"] as? [String] ?? []).map { URL(fileURLWithPath: $0) })
                spoken = draft["spoken"] as? Bool ?? false
            }
        } else {
            problem = "Couldn’t find that question. Try again."
        }
    }

    private func check(saying words: String? = nil) {
        transcriber.stop()
        busy = true
        Task {
            let found = await API.post("var/assess", ["document": document, "item": topic["id"] as? String ?? "", "task": task,
                                                     "answer": words ?? transcriber.text, "spoken": words == nil && spoken,
                                                     "pictures": words == nil ? transcriber.pictures : [],
                                                     "recordings": transcriber.recordings.filter(transcriber.chosen.contains).map(\.path)], timeout: 60)
            busy = false
            if found?["ok"] as? Bool == true {
                result = found
                heard = transcriber.recordings.filter(transcriber.chosen.contains)
                attempt = transcriber.recordings
                UserDefaults.standard.removeObject(forKey: draftKey)
                saveChecked()
                grades[task] = found?["grade"] as? Int
                done()
            } else {
                problem = keyProblem(found?["reason"] as? String) ?? "Couldn’t check the answer. Try again."
            }
        }
    }
}


/// The mock viva: the questions in a row, timed, with no feedback until the end.
struct MockViva: View {

    /// The topic's title with the question, so Whisper expects their terms.
    static func vocabulary(_ question: [String: Any]) -> String {
        ((question["item"] as? [String: Any])?["title"] as? String ?? "") + ". " + (question["question"] as? String ?? "")
    }

    let document: String
    var purpose = "viva"
    let close: () -> Void
    @StateObject private var transcriber = Transcriber()
    @State private var viva: [String: Any]?
    @State private var index = 0
    @State private var answers: [[String: Any]] = []
    @State private var spoken = false
    @State private var started = Date()
    @State private var ready = false
    @State private var asking = false
    @State private var now = Date()
    @State private var paused: Date?   // when the viva was paused: the clock stops and the question is hidden
    @State private var report: [String: Any]?
    @State private var busy = false
    @State private var problem: String?
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    @State private var player = AVQueuePlayer()
    @State private var playing: Int?

    private var questions: [[String: Any]] { viva?["questions"] as? [[String: Any]] ?? [] }

    var body: some View {
        Page {
            if let report {
                ended(report)
            } else if viva == nil {
                Text(VARPurpose.mock(purpose)).font(Fonts.heading(28, .regular))
                Text(problem ?? "Writing the examiner's questions…").foregroundStyle(.secondary).padding(.top, 8)
                if problem == nil { ProgressView().controlSize(.small) }
            } else if !ready {
                Text(VARPurpose.mock(purpose)).font(Fonts.heading(28, .regular))
                Text(intro).foregroundStyle(.secondary).padding(.top, 8)
                Button("Start") { begin() }.glassButton().padding(.top, 8)
            } else if index < questions.count, paused != nil {
                Text(VARPurpose.mock(purpose)).font(Fonts.heading(28, .regular))
                Text("Paused at \(clock). The question is hidden until you carry on.").foregroundStyle(.secondary).padding(.top, 8)
                HStack(spacing: 8) {
                    Button("Resume") { resume() }.glassButton().keyboardShortcut(.defaultAction)
                    Button("End \(VARPurpose.noun(purpose))") { paused = nil; finish() }.glassButton()
                }
                .padding(.top, 8)
            } else if index < questions.count {
                HStack {
                    Text(VARPurpose.mock(purpose)).font(Scaled.style(11, .regular)).foregroundStyle(.secondary)
                    Spacer()
                    Text(clock).font(Scaled.style(11, .regular).monospacedDigit()).foregroundStyle(.secondary)
                }
                HStack(spacing: 3) {
                    ForEach(0..<questions.count, id: \.self) { n in
                        Capsule().fill(n <= index ? Color.primary : Color.primary.opacity(0.15)).frame(height: 3)
                    }
                }
                let question = questions[index]
                Text(kindLabel(question["kind"] as? String ?? "")).font(Scaled.style(11, .regular)).foregroundStyle(.secondary).padding(.top, 10)
                MarkdownView(text: question["question"] as? String ?? "").font(Fonts.heading(19, .regular))
                AnswerBox(transcriber: transcriber, spoken: $spoken).padding(.top, 12)
                    .onAppear { transcriber.question = Self.vocabulary(question) }
                    .onChange(of: index) { transcriber.question = Self.vocabulary(questions[index]) }
                HStack(spacing: 8) {
                    Button("End \(VARPurpose.noun(purpose))") { finish() }.glassButton()
                    Button("Pause") { transcriber.stop(); paused = Date() }.glassButton()
                    Spacer()
                    if busy { ProgressView().controlSize(.small) }
                    Button(index + 1 == questions.count ? "Finish" : "Next question") { next() }.glassButton().disabled(busy)
                }
                .padding(.top, 6)
            }
        }
        .task { transcriber.keeping = true; await start() }
        .alert("Start the \(VARPurpose.mock(purpose).lowercased())?", isPresented: $asking) {
            Button("Start") { begin() }
            Button("Not now", role: .cancel) {}
        } message: {
            Text(intro)
        }
        .onReceive(tick) { now = $0 }
        .onDisappear { transcriber.stop(); player.pause() }
    }

    /// Each answer given aloud, to play back: hear how the opening account and the rest came across.
    @ViewBuilder private var playback: some View {
        let spoken = answers.enumerated().filter { !($0.element["recordings"] as? [String] ?? []).isEmpty }
        if !spoken.isEmpty {
            PageSection("Your answers, to play back") {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(spoken, id: \.offset) { index, answer in
                        HStack(spacing: 8) {
                            Button {
                                if playing == index { player.pause(); playing = nil } else { play(answer["recordings"] as? [String] ?? [], index) }
                            } label: { Image(systemName: playing == index ? "pause.fill" : "play.fill") }
                            .buttonStyle(.borderless)
                            Text(index < questions.count ? kindLabel(questions[index]["kind"] as? String ?? "") : "")
                                .font(Scaled.style(12, .regular))
                        }
                    }
                }
            }
            .padding(.top, 12)
        }
    }

    private func play(_ paths: [String], _ index: Int) {
        player.pause()
        player.removeAllItems()
        for path in paths { player.insert(AVPlayerItem(url: URL(fileURLWithPath: path)), after: nil) }
        player.play()
        playing = index
    }

    private func resume() {
        if let paused { started = started.addingTimeInterval(Date().timeIntervalSince(paused)) }
        paused = nil
    }

    private var clock: String {
        let seconds = Int((paused ?? now).timeIntervalSince(started))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private func kindLabel(_ kind: String) -> String {
        if purpose != "viva" { return VARPurpose.task(kind, purpose) }
        return ["account": "Your account of the work, 2 to 3 minutes", "state": "Definition from memory", "examples": "Examples and non-examples",
         "explain": "Explain a step", "perturb": "Perturbation", "error": "Check an argument"][kind] ?? ""
    }

    @ViewBuilder private func ended(_ report: [String: Any]) -> some View {
        let seconds = report["seconds"] as? Int ?? 0
        Text("\(VARPurpose.mock(purpose)) · \(seconds / 60) min \(seconds % 60) s").font(Scaled.style(11, .regular)).foregroundStyle(.secondary)
        Text("Band \(report["band"] as? String ?? "")").font(Fonts.heading(28, .regular))
        Text("Out of 10, against what \(VARPurpose.aNoun(purpose)) usually expects.").font(Scaled.style(11, .regular)).foregroundStyle(.secondary)
        VStack(alignment: .leading, spacing: 6) {
            ForEach(report["strong"] as? [String] ?? [], id: \.self) { line in
                Label { MarkdownView(text: line) } icon: { Image(systemName: "checkmark").foregroundStyle(.green) }
            }
            ForEach(Array((report["weak"] as? [[String: Any]] ?? []).enumerated()), id: \.offset) { _, weak in
                Label { MarkdownView(text: weak["point"] as? String ?? "") } icon: { Image(systemName: "exclamationmark.circle").foregroundStyle(.orange) }
            }
        }
        .padding(.top, 10)
        let practise = report["practise"] as? [[String: Any]] ?? []
        if !practise.isEmpty {
            Text("Added to practise today: " + practise.compactMap { $0["title"] as? String }.joined(separator: ", "))
                .font(Scaled.style(11, .regular)).foregroundStyle(.secondary).padding(.top, 8)
        }
        playback
        Button("Done") { close() }.glassButton().padding(.top, 12)
    }

    /// "8 questions, usually 5 to 10 minutes. The clock starts when you do." Or where an unfinished one left off.
    private var intro: String {
        let done = answers.count
        return done > 0
            ? "You’re \(done) of \(questions.count) questions in. It carries on from the next one, with the clock where it stopped."
            : "\(questions.count) questions, in \(VARPurpose.aNoun(purpose))’s order, usually 5 to 10 minutes. The clock starts when you do."
    }

    private func start() async {
        let found = await API.post("var/viva", ["document": document], timeout: 15)
        if found?["ok"] as? Bool == true {
            viva = found
            // An unfinished one carries on from its next question.
            answers = found?["answers"] as? [[String: Any]] ?? []
            index = min(answers.count, max(0, questions.count - 1))
            asking = true
        } else {
            problem = keyProblem(found?["reason"] as? String) ?? "Couldn't start the \(VARPurpose.mock(purpose).lowercased()). Try again."
        }
    }

    private func begin() {
        started = Date().addingTimeInterval(-Double(viva?["seconds"] as? Int ?? 0))
        ready = true
    }

    /// The answer as given, kept straight away so leaving part-way carries on later.
    private func take() {
        let answer: [String: Any] = ["answer": transcriber.text, "spoken": spoken,
                                     "recordings": transcriber.recordings.map(\.path), "pictures": transcriber.pictures]
        answers.append(answer)
        Task { _ = await API.post("var/viva/answer", ["id": viva?["id"] as? String ?? "", "index": answers.count - 1,
                                                      "answer": answer, "seconds": Int(Date().timeIntervalSince(started))]) }
        transcriber.recordings = []
        transcriber.pictures = []
    }

    private func next() {
        transcriber.stop()
        take()
        transcriber.text = ""
        spoken = false
        if index + 1 < questions.count { index += 1 } else { finish() }
    }

    private func finish() {
        transcriber.stop()
        if answers.count <= index && (!transcriber.text.isEmpty || !transcriber.pictures.isEmpty) { take() }
        busy = true
        Task {
            let found = await API.post("var/viva/finish", ["id": viva?["id"] as? String ?? "", "answers": answers,
                                                          "seconds": Int(Date().timeIntervalSince(started))], timeout: 90)
            busy = false
            if found?["ok"] as? Bool == true { report = found } else { problem = keyProblem(found?["reason"] as? String) ?? "Couldn't assess the \(VARPurpose.mock(purpose).lowercased()). Try again."; viva = nil }
        }
    }
}


/// What a project was set: the questions it answers, and the mark scheme or however it's assessed.
/// Add the documents (project sheets, guidelines, screenshots) and say which parts are yours; Claude finds
/// the questions you answered and how you'll be assessed, for you to check. VAR writes questions and
/// places mock vivas with both in mind.
/// The job description, or who the audience is: optional, and used for new questions and the mock's band.
struct ContextSheet: View {
    @ObservedObject var model: VARModel
    @State private var text = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(VARPurpose.context(model.purpose)).font(Fonts.heading(22, .regular))
            Text(model.purpose == "interview" ? "Paste the job description, if you have one, and the questions lean towards what the role needs."
                                              : "Say who you’re presenting to, and the questions are the ones they’d ask.")
                .font(Scaled.style(11, .regular)).foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(Scaled.style(13, .regular))
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(minHeight: model.purpose == "interview" ? 220 : 80)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { Task { await model.setContext(text); dismiss() } }
                Button("Save and write new questions") {
                    Task { await model.setContext(text); model.rebuild(); dismiss() }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 520)
        .onAppear { text = model.context }
    }
}


struct BriefSheet: View {

    let project: String
    let rebuild: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var guide = ""
    @State private var files: [[String: String]] = []
    @State private var questions = ""
    @State private var scheme = ""
    @State private var reading = false
    @State private var finding = false
    @State private var problem: String?
    @State private var editing: Set<String> = []
    @State private var parts: [[String: String]] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Project brief").font(Fonts.heading(22, .regular))
            Text((project.isEmpty ? "For write-ups with no project." : "For \(project).")
                 + " Add the project sheet, guidelines or screenshots, say which parts are yours, and Referee finds the questions you answered and how you’ll be assessed.")
                .font(Scaled.style(11, .regular)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            documents
            VStack(alignment: .leading, spacing: 4) {
                Text("Which parts are yours (leave blank if N/A)").font(Scaled.style(11, .regular)).foregroundStyle(.secondary)
                TextField("", text: $guide, axis: .vertical)
                    .lineLimit(1...3)
                    .textFieldStyle(.roundedBorder)
            }
            HStack(spacing: 8) {
                Button("Find questions and mark scheme") { find() }
                    .glassButton()
                    .disabled(files.isEmpty || finding || reading)
                if finding { ProgressView().controlSize(.small) }
                if let problem { Text(problem).font(Scaled.style(11, .regular)).foregroundStyle(.secondary) }
            }
            box("The questions your project answers", text: $questions)
            box("Mark scheme, or how you’ll be assessed", text: $scheme)
            HStack(spacing: 8) {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if let rebuild {
                    Button("Save and write new questions") { save(); rebuild() }
                }
                Button("Save") { save() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 580, height: 680)
        .task {
            let found = await API.get("var/brief?project=\(project.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")")
            questions = found?["questions"] as? String ?? ""
            scheme = found?["scheme"] as? String ?? ""
            guide = found?["guide"] as? String ?? ""
            files = found?["files"] as? [[String: String]] ?? []
            parts = found?["parts"] as? [[String: String]] ?? []
        }
    }

    /// The documents and screenshots added, read on this Mac: choose, drop or paste them.
    private var documents: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Documents").font(Scaled.style(11, .regular)).foregroundStyle(.secondary)
                Spacer()
            }
            VStack(alignment: .leading, spacing: 4) {
                if files.isEmpty {
                    Text(reading ? "Reading…" : "Drop or paste project sheets, guidelines or screenshots here, as many as you need")
                        .font(Scaled.style(11, .regular)).foregroundStyle(.tertiary)
                }
                ForEach(Array(files.enumerated()), id: \.offset) { index, file in
                    HStack(spacing: 6) {
                        Image(systemName: "doc.text").foregroundStyle(.secondary)
                        Text(file["name"] ?? "").font(Scaled.style(12, .regular)).lineLimit(1)
                        Spacer()
                        Button { files.remove(at: index) } label: { Image(systemName: "xmark") }
                            .buttonStyle(.borderless).help("Remove")
                    }
                }
                Button {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [.pdf, .image, .plainText, .init(filenameExtension: "tex")!, .init(filenameExtension: "md")!]
                    panel.allowsMultipleSelection = true
                    guard panel.runModal() == .OK else { return }
                    let urls = panel.urls
                    add { var found: [(String, String?, String?)] = []; for url in urls { found.append((url.lastPathComponent, url.path, await BriefReader.text(of: url))) }; return found }
                } label: {
                    Label(files.isEmpty ? "Add files…" : "Add another file…", systemImage: "plus")
                }
                .buttonStyle(.link).font(Scaled.style(11, .regular))
                .padding(.top, files.isEmpty ? 0 : 4)
            }
            .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
            .padding(8)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
            .dropDestination(for: URL.self) { urls, _ in
                add { var found: [(String, String?, String?)] = []; for url in urls { found.append((url.lastPathComponent, url.path, await BriefReader.text(of: url))) }; return found }
                return !urls.isEmpty
            }
            .focusable()
            .focusEffectDisabled()
            .onPasteCommand(of: [.fileURL, .png, .tiff, .image]) { _ in pasted() }
        }
    }

    /// The questions or mark scheme with their maths typeset, or as text to edit.
    private func box(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(Scaled.style(11, .regular)).foregroundStyle(.secondary)
                Spacer()
                if !text.wrappedValue.isEmpty {
                    Button(editing.contains(title) ? "Done" : "Edit") {
                        if editing.contains(title) { editing.remove(title) } else { editing.insert(title) }
                    }
                    .buttonStyle(.link).font(Scaled.style(11, .regular))
                }
            }
            Group {
                if text.wrappedValue.isEmpty || editing.contains(title) {
                    TextEditor(text: text)
                        .font(Scaled.style(12, .regular))
                        .scrollContentBackground(.hidden)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            // Each question as its page prints it, when there's a picture of it.
                            if title.hasPrefix("The questions") && parts.contains(where: { !($0["picture"] ?? "").isEmpty }) {
                                ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                                    if let path = part["picture"], let image = NSImage(contentsOfFile: path) {
                                        Text(part["title"] ?? "").font(Scaled.style(11, .semibold))
                                        Image(nsImage: image).resizable().scaledToFit()
                                            .background(Color.white, in: RoundedRectangle(cornerRadius: 4))
                                    }
                                }
                            } else {
                                MarkdownView(text: text.wrappedValue)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(8)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    /// ⌘V on the documents: picture files, or a screenshot on the clipboard.
    private func pasted() {
        let board = NSPasteboard.general
        let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if !urls.isEmpty {
            add { var found: [(String, String?, String?)] = []; for url in urls { found.append((url.lastPathComponent, url.path, await BriefReader.text(of: url))) }; return found }
        } else if let image = NSImage(pasteboard: board) {
            add { [("Screenshot", BriefReader.save(image), await BriefReader.text(of: image))] }
        }
    }

    private func add(_ read: @escaping () async -> [(String, String?, String?)]) {
        reading = true
        Task {
            var unread: [String] = []
            for (name, path, text) in await read() {
                if let text, !text.isEmpty {
                    files.removeAll { $0["name"] == name && name != "Screenshot" }
                    files.append(["name": name, "text": text, "path": path ?? ""])
                } else {
                    unread.append(name)
                }
            }
            reading = false
            // Said, never dropped silently: often a cloud file not yet downloaded, or a picture with no text.
            problem = unread.isEmpty ? nil : "Couldn’t read " + unread.joined(separator: ", ") + ". If it’s in OneDrive or iCloud, open it once so it downloads, then add it again."
        }
    }

    /// Claude reads the documents with the guide and fills the two boxes, to check and correct.
    private func find() {
        finding = true
        problem = nil
        Task {
            let found = await API.post("var/brief/find", ["guide": guide, "files": files], timeout: 180)
            finding = false
            if found?["ok"] as? Bool == true {
                scheme = found?["scheme"] as? String ?? scheme
                await picture(found?["parts"] as? [[String: Any]] ?? [])
            } else {
                problem = keyProblem(found?["reason"] as? String) ?? ["no_credit": "Your Anthropic account is out of credit. Add credit at console.anthropic.com, then try again."][found?["reason"] as? String ?? ""]
                    ?? "Couldn’t read them. Try again."
            }
        }
    }

    /// Each question as its page prints it, like a note's preview, then read from that picture so its
    /// maths comes out as set. Without a picture, the text found in the document stands.
    private func picture(_ found: [[String: Any]]) async {
        var made: [[String: String]] = []
        for part in found {
            let index = (part["document"] as? Int ?? 0) - 1
            let file = files.indices.contains(index) ? files[index] : [:]
            let path = file["path"] ?? ""
            let picture = path.lowercased().hasSuffix(".pdf")
                ? BriefReader.crop(pdf: path, page: part["page"] as? Int ?? 1, label: part["label"] as? String ?? "")
                : (path.isEmpty ? nil : path)
            made.append(["title": part["title"] as? String ?? "", "picture": picture ?? "", "text": part["text"] as? String ?? ""])
        }
        let pictures = made.map { $0["picture"] ?? "" }
        if pictures.contains(where: { !$0.isEmpty }),
           let read = (await API.post("var/brief/read", ["pictures": pictures], timeout: 180))?["texts"] as? [Any] {
            for (n, text) in read.enumerated() where n < made.count {
                if let text = text as? String, !text.isEmpty { made[n]["text"] = text }
            }
        }
        parts = made
        let missing = files.filter { ($0["path"] ?? "").isEmpty }.compactMap { $0["name"] }
        if !missing.isEmpty {
            problem = "Add " + missing.joined(separator: ", ") + " again to see its questions as pictures: it was added before Referee kept where files are."
        } else if made.contains(where: { ($0["picture"] ?? "").isEmpty }) {
            problem = "Couldn’t find every question on its page, so those are shown as text."
        }
        questions = made.map { "**\($0["title"] ?? "")**\n\n\($0["text"] ?? "")" }.joined(separator: "\n\n")
    }

    private func save() {
        Task { _ = await API.post("var/brief", ["project": project, "questions": questions, "scheme": scheme, "guide": guide, "files": files, "parts": parts]) }
        dismiss()
    }
}


/// Reads the text of a brief's documents and screenshots on this Mac: a PDF's own text (or, for a scanned
/// page, Vision's reading of it), an image through Vision, or a text file as it is.
enum BriefReader {

    static func text(of url: URL) async -> String? {
        switch url.pathExtension.lowercased() {
        case "pdf":
            guard let document = PDFDocument(url: url) else { return nil }
            var pages: [String] = []
            for index in 0..<document.pageCount {
                guard let page = document.page(at: index) else { continue }
                let own = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if own.count > 20 {
                    pages.append("[Page \(index + 1)]\n" + own)
                } else if let scanned = await text(of: page.thumbnail(of: CGSize(width: 1800, height: 2400), for: .mediaBox)) {
                    pages.append("[Page \(index + 1)]\n" + scanned)
                }
            }
            return pages.joined(separator: "\n\n")
        case "txt", "tex", "md":
            return try? String(contentsOf: url, encoding: .utf8)
        default:
            guard let image = NSImage(contentsOf: url) else { return nil }
            return await text(of: image)
        }
    }

    /// A picture of one question on its page: from its label to the next question (or the page's end),
    /// running onto the next page when it continues there. Kept as a file, like a note's preview.
    static func crop(pdf path: String, page number: Int, label: String) -> String? {
        guard !label.isEmpty, let document = PDFDocument(url: URL(fileURLWithPath: path)),
              number >= 1, number <= document.pageCount, let page = document.page(at: number - 1) else { return nil }
        // Case matters, so a heading's "Question" isn't confused with "question" in a sentence.
        func found(_ text: String, on page: PDFPage) -> [CGFloat] {
            document.findString(text, withOptions: []).filter { $0.pages.contains(page) }.map { $0.bounds(for: page).maxY }
        }
        // The label as given, or failing that its last part ("MTH5112–3" of "Question MTH5112–3").
        let tops = found(label, on: page) + found(String(label.split(separator: " ").last ?? ""), on: page)
        guard let top = tops.first else { return nil }
        // The next question below this one ends it; headings are found by the label's first word ("Question").
        let word = label.split(separator: " ").first.map(String.init).flatMap { $0.contains(where: \.isNumber) ? nil : $0 } ?? "Question"
        let below = found(word, on: page).filter { $0 < top - 4 }.max()
        var pieces: [NSImage] = []
        if let piece = region(of: page, from: top + 4, to: below.map { $0 + 2 }) { pieces.append(piece) }
        if below == nil, number < document.pageCount, let next = document.page(at: number) {
            let first = found(word, on: next).max()
            let pageTop = next.bounds(for: .mediaBox).maxY
            if first.map({ pageTop - $0 > 90 }) ?? true, let piece = region(of: next, from: pageTop - 40, to: first.map { $0 + 2 }) {
                pieces.append(piece)
            }
        }
        guard !pieces.isEmpty else { return nil }
        let width = pieces.map(\.size.width).max() ?? 0, height = pieces.map(\.size.height).reduce(0, +)
        let joined = NSImage(size: NSSize(width: width, height: height))
        joined.lockFocus()
        var y = height
        for piece in pieces { y -= piece.size.height; piece.draw(at: NSPoint(x: 0, y: y), from: .zero, operation: .copy, fraction: 1) }
        joined.unlockFocus()
        return save(joined)
    }

    /// Part of a page between two heights (PDF points from the bottom), full width, at print resolution.
    private static func region(of page: PDFPage, from top: CGFloat, to bottom: CGFloat?) -> NSImage? {
        let box = page.bounds(for: .mediaBox)
        let low = max(bottom ?? box.minY + 40, box.minY), high = min(top, box.maxY)
        guard high - low > 10 else { return nil }
        let scale: CGFloat = 2.5
        let image = NSImage(size: NSSize(width: box.width * scale, height: (high - low) * scale))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: image.size).fill()
        guard let context = NSGraphicsContext.current?.cgContext else { image.unlockFocus(); return nil }
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -box.minX, y: -low)
        page.draw(with: .mediaBox, to: context)
        image.unlockFocus()
        return image
    }

    /// A pasted screenshot kept as a file, so its question can be shown and read from the picture.
    static func save(_ image: NSImage) -> String? {
        guard let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return nil }
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Referee/brief-screenshots")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(UUID().uuidString + ".png")
        return (try? png.write(to: file)) != nil ? file.path : nil
    }

    static func text(of image: NSImage) async -> String? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return await withCheckedContinuation { done in
            let request = VNRecognizeTextRequest { request, _ in
                let lines = (request.results as? [VNRecognizedTextObservation] ?? []).compactMap { $0.topCandidates(1).first?.string }
                done.resume(returning: lines.joined(separator: "\n"))
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            DispatchQueue.global(qos: .userInitiated).async {
                do { try VNImageRequestHandler(cgImage: cgImage).perform([request]) } catch { done.resume(returning: nil) }
            }
        }
    }
}


/// The GitHub repositories VAR may read, each on a side (and, for Academic, under a Referee project).
struct GitHubRepositories: View {
    @State private var status: [String: Any] = [:]
    @State private var repos: [[String: Any]] = []
    @State private var projects: [String] = []
    @State private var busy: String?
    @State private var problem: String?
    @State private var showAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if status["installed"] as? Bool == false {
                Text("Install the GitHub CLI (brew install gh) and run gh auth login in Terminal, then come back.")
                    .font(Scaled.style(12, .regular)).foregroundStyle(.secondary)
            } else if let login = status["login"] as? String {
                HStack {
                    Text("Connected as \(login)").font(Scaled.style(12, .regular))
                    Spacer()
                    Button("Update repositories") { Task { busy = "sync"; _ = await API.post("github/sync", [:], timeout: 300); busy = nil } }
                        .buttonStyle(.link).font(Scaled.style(11, .regular)).disabled(busy != nil)
                }
                ForEach(Array((showAll ? repos : Array(repos.prefix(8))).enumerated()), id: \.offset) { _, repo in row(repo) }
                if repos.count > 8 {
                    Button(showAll ? "Show fewer" : "Show all \(repos.count)") { showAll.toggle() }
                        .buttonStyle(.link).font(Scaled.style(11, .regular))
                }
                if let problem { Text(problem).font(Scaled.style(11, .regular)).foregroundStyle(.secondary) }
            } else if status["installed"] as? Bool == true {
                Text("Sign in with gh auth login in Terminal, then come back.").font(Scaled.style(12, .regular)).foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task { await load() }
    }

    private func load() async {
        status = await API.get("github/status") ?? ["installed": false]
        guard status["login"] is String else { return }
        repos = await API.getList("github/repos")
        projects = (await API.get("settings"))?["projects"] as? [String] ?? []
    }

    @ViewBuilder private func row(_ repo: [String: Any]) -> some View {
        let name = repo["nameWithOwner"] as? String ?? ""
        let chosen = repo["chosen"] as? [String: Any]
        HStack(spacing: 8) {
            Toggle(isOn: Binding(get: { chosen != nil }, set: { on in choose(name, on ? "professional" : nil, "") })) {
                Text(name.split(separator: "/").last.map(String.init) ?? name).font(Scaled.style(12, .regular))
            }
            .toggleStyle(.checkbox)
            if repo["isPrivate"] as? Bool == true { Image(systemName: "lock").font(.system(size: 10)).foregroundStyle(.secondary) }
            Spacer()
            if busy == name { ProgressView().controlSize(.mini) }
            if let chosen {
                Menu {
                    Button("Professional") { choose(name, "professional", "") }
                    SwiftUI.Section("Academic") {
                        ForEach(projects, id: \.self) { project in Button(project) { choose(name, "academic", project) } }
                        Button("No project") { choose(name, "academic", "") }
                    }
                } label: {
                    Text(chosen["side"] as? String == "academic"
                         ? "Academic" + ((chosen["project"] as? String).flatMap { $0.isEmpty ? nil : " · \($0)" } ?? "")
                         : "Professional").font(Scaled.style(11, .regular))
                }
                .menuStyle(.button).buttonStyle(.plain).foregroundStyle(.secondary).fixedSize()
                .menuOrder(.fixed)
            }
        }
        .padding(.vertical, 3)
    }

    private func choose(_ repo: String, _ side: String?, _ project: String) {
        Task {
            busy = repo
            problem = nil
            var body: [String: Any] = ["repo": repo, "project": project]
            if let side { body["side"] = side }
            let result = await API.post("github/repos", body, timeout: 300)
            if let failed = result?["failed"] as? [String], !failed.isEmpty {
                problem = "Nothing to read in \(repo) for that side" + (side == "academic" ? " (no write-up or code files)." : ".")
            }
            busy = nil
            await load()
        }
    }
}


/// What to say when Claude can't be asked: no key or sign-in, or the key rejected.
func keyProblem(_ reason: String?) -> String? {
    switch reason {
    case "no_api_key": return "VAR needs Claude: add your key, or sign in with the ant command-line tool, in Settings → Integrations."
    case "bad_api_key": return "Claude rejected your key. It may have expired or been revoked: add a new one in Settings → Integrations."
    default: return nil
    }
}
