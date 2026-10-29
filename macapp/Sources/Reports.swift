import SwiftUI
import WebKit

/// A report (Before You Submit, Research Trail, Proof of Work) shown inside Referee, in the font
/// and size you choose, and saved as PDF, Word or HTML, or printed.
struct ReportView: View {

    let title: String
    @State var html: String
    /// The project, for the Research Trail of one project: it can then be archived.
    var trailProject: String? = nil
    @State private var summary: [String: Any] = [:]
    @State private var confirming = false
    @Environment(\.dismiss) private var dismiss
    @AppStorage("reportFont") private var font = "Times New Roman"
    @AppStorage("reportSize") private var size = 12.0
    @State private var web = WKWebView()

    // The fonts universities usually accept. Calibri and Cambria come with Microsoft Office, and
    // Computer Modern (LaTeX's) with a TeX install; without them the nearest font is used.
    static let fonts: [(String, String)] = [
        ("Times New Roman", "'Times New Roman', Times, serif"),
        ("Arial", "Arial, Helvetica, sans-serif"),
        ("Calibri", "Calibri, Carlito, 'Helvetica Neue', sans-serif"),
        ("Georgia", "Georgia, serif"),
        ("Garamond", "'EB Garamond', Garamond, 'Adobe Garamond Pro', serif"),
        ("Cambria", "Cambria, Caladea, Georgia, serif"),
        ("Computer Modern", "'CMU Serif', 'Latin Modern Roman', 'Computer Modern', serif"),
    ]

    /// The report with the chosen font and size laid over its own styles.
    private var styled: String {
        let family = Self.fonts.first { $0.0 == font }?.1 ?? Self.fonts[0].1
        let css = "<style>body, body * { font-family: \(family) !important; } body { font-size: \(Int(size))pt !important; }</style>"
        if let head = html.range(of: "</head>") { return html.replacingCharacters(in: head, with: css + "</head>") }
        return css + html
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(title).font(Scaled.style(13, .semibold))
                Spacer()
                if let project = trailProject { trailControls(project) }
                Picker("Font", selection: $font) { ForEach(Self.fonts, id: \.0) { Text($0.0).tag($0.0) } }
                    .labelsHidden().fixedSize()
                Stepper("\(Int(size)) pt", value: $size, in: 9...20).fixedSize()
                Menu("Export") {
                    Button("PDF…") { savePDF() }
                    Button("Word…") { saveWord() }
                    Button("HTML…") { saveHTML() }
                    Divider()
                    Button("Print…") { web.printOperation(with: .shared).runModal(for: NSApp.keyWindow ?? NSWindow(), delegate: nil, didRun: nil, contextInfo: nil) }
                }
                .fixedSize()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
            Divider()
            ReportWeb(web: web, html: styled)
        }
        .onAppear { if !Self.fonts.contains(where: { $0.0 == font }) { font = Self.fonts[0].0 } }
        .frame(minWidth: 820, idealWidth: 900, minHeight: 620, idealHeight: 760)
    }

    // MARK: Archiving the research trail

    private func day(_ t: Any?) -> String {
        guard let t = t as? Double else { return "" }
        return Date(timeIntervalSince1970: t).formatted(.dateTime.day().month(.abbreviated).year())
    }

    private var archived: [[String: Any]] { summary["archived"] as? [[String: Any]] ?? [] }

    @ViewBuilder private func trailControls(_ project: String) -> some View {
        if !archived.isEmpty {
            Menu("Archived") {
                Button("Current Trail") { load(project, archived: 0) }
                Divider()
                ForEach(archived.indices, id: \.self) { i in
                    let entry = archived[i]
                    Menu(entry["period"] as? String ?? "Archived trail") {
                        Button("Open") { load(project, archived: entry["to"] as? Double ?? 0) }
                        Button("Restore to Current Trail") {
                            Task {
                                _ = await API.post("trail/restore", ["project": project, "to": entry["to"] as? Double ?? 0])
                                load(project, archived: 0)
                            }
                        }
                    }
                }
            }
            .fixedSize()
        }
        Button("Archive This Trail…") { confirming = true }
            .disabled((summary["sources"] as? Int ?? 0) + (summary["checks"] as? Int ?? 0) == 0)
            .task { await loadSummary(project) }
            .alert("Archive the research trail for \(project.isEmpty ? "No project" : project)?", isPresented: $confirming) {
                Button("Save as PDF First") { savePDF() }
                Button("Cancel", role: .cancel) {}
                Button("Archive") {
                    Task {
                        _ = await API.post("trail/archive", ["project": project])
                        load(project, archived: 0)
                    }
                }
            } message: { Text(archiveMessage) }
    }

    private var archiveMessage: String {
        let sources = summary["sources"] as? Int ?? 0, checks = summary["checks"] as? Int ?? 0
        var text = "The trail so far (\(day(summary["from"])) – \(day(Date().timeIntervalSince1970)): "
            + "\(sources) \(sources == 1 ? "source" : "sources") read, \(checks) \(checks == 1 ? "check" : "checks")) "
            + "moves to the archive, and a new trail starts from today. Your sources, notes and meetings stay as they are."
            + "\n\nBest done once the work is submitted and marked. You can open, export or restore an archived trail at any time."
        if let last = summary["last_check"] as? Double, Date().timeIntervalSince1970 - last < 30 * 86400 {
            text += "\n\nWriting in this project was checked \(Date(timeIntervalSince1970: last).formatted(.relative(presentation: .named)))."
        }
        return text
    }

    private func loadSummary(_ project: String) async {
        let query = project.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        summary = await API.get("trail/archive?project=\(query)") ?? [:]
    }

    private func load(_ project: String, archived: Double) {
        Task {
            let query = project.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
            if let data = await API.request("trail?project=\(query)&archived=\(archived)", timeout: 30),
               let page = String(data: data, encoding: .utf8) { html = page }
            await loadSummary(project)
        }
    }

    private func choose(_ ext: String) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(title).\(ext)"
        panel.allowedContentTypes = [.init(filenameExtension: ext)!]
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func savePDF() {
        guard let url = choose("pdf") else { return }
        web.createPDF { result in if case .success(let data) = result { try? data.write(to: url) } }
    }

    private func saveHTML() {
        guard let url = choose("html") else { return }
        try? styled.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Word, through macOS's own converter (textutil), keeping headings, tables and the font.
    private func saveWord() {
        guard let url = choose("docx") else { return }
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("referee-report.html")
        try? styled.write(to: source, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/textutil")
        process.arguments = ["-convert", "docx", source.path, "-output", url.path]
        try? process.run()
    }
}

private struct ReportWeb: NSViewRepresentable {

    let web: WKWebView
    let html: String

    func makeNSView(context: Context) -> WKWebView { web.loadHTMLString(html, baseURL: nil); return web }

    func updateNSView(_ view: WKWebView, context: Context) {
        if context.coordinator.shown != html {
            context.coordinator.shown = html
            view.loadHTMLString(html, baseURL: nil)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var shown = "" }
}
