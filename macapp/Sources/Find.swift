import AppKit
import SwiftUI

/// ⌘K: one box for getting around Referee and finding what your sources say. Commands, then your
/// notes, sources, meetings and AI use by name, then the passages in your reading that best match
/// by meaning, each opening at its page. It never writes an answer.
/// Quick capture: a small box that saves a note, a link or an AI use entry into the current project
/// from anywhere. Both float above other apps, and close with Escape or when they lose focus.

final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { close() }
}

@MainActor
enum Floating {

    private static var panels: [String: FloatingPanel] = [:]

    static func show<V: View>(_ id: String, width: CGFloat, @ViewBuilder _ view: () -> V) {
        if let open = panels[id], open.isVisible { open.close(); return }   // the shortcut again closes it
        // Borderless, so the content starts at the very top: no room kept for a title bar.
        let m = shadowRoom
        let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        // Never wider than 60% of the screen, and the list never longer than fits below the field.
        let width = min(width, max(560, visible.width * 0.6))
        let top = visible.maxY - visible.height * (visible.height < 1100 ? 0.12 : 0.2)
        if id == "find" { FindView.list = max(240, min(640, top - visible.minY - FindView.field - 60 - 40)) }
        let panel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: width + 2 * m, height: 100),
                                  styleMask: [.borderless, .nonactivatingPanel],
                                  backing: .buffered, defer: false)
        panel.isMovableByWindowBackground = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // Fixed sizes, set by the view as results come and go (Floating.height): following the content's
        // size automatically looped with keeping the top edge in place, and crashed.
        // Liquid Glass, like Spotlight: the desktop shows softly through, with rounded corners and no lines.
        let host = NSHostingView(rootView: view()
            .frame(width: width)
            .modifier(GlassPanel()))
        // The hosting view mustn't size the panel itself: it did by default, fought Floating.height
        // over the panel's size, and crashed ("excessive recursion" in layout).
        host.sizingOptions = []
        panel.contentView = host
        panel.setContentSize(NSSize(width: width + 2 * m, height: id == "find" ? FindView.field + 2 * m : host.fittingSize.height))
        panel.setFrameTopLeftPoint(NSPoint(x: visible.midX - width / 2 - m, y: top + m))
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { _ in
            MainActor.assumeIsolated { panel.close() }
        }

        panels[id] = panel
        // Like Spotlight: the panel takes the keyboard without bringing Referee forward, so its
        // main window stays where it was.
        panel.orderFrontRegardless()
        panel.makeKey()

    }

    static func close(_ id: String) { panels[id]?.close() }

    /// Clear space around a panel for its shadow.
    static let shadowRoom: CGFloat = 0

    /// The same glass as Referee's sidebar (macOS's sidebar material, behind the window), so the two
    /// match exactly, in dark mode and light.
    struct GlassPanel: ViewModifier {
        @Environment(\.accessibilityReduceTransparency) private var solid
        @Environment(\.colorSchemeContrast) private var contrast
        func body(content: Content) -> some View {
            content
                // Solid with Reduce Transparency on, so text reads clearly over any desktop.
                .background(solid ? Color(nsColor: .windowBackgroundColor) : .clear)
                // The sidebar's glass, deepened with the window colour as Raycast's is: mostly solid,
                // with the desktop only glowing through. Light or dark, it follows the system.
                // Raycast's look: frosted glass the wallpaper's colour comes through, lightly darkened
                // (lightened in light mode), rather than covered by a solid layer.
                .background(ZStack {
                    SidebarGlass()
                    Tint()
                })
                .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                // A thin light edge, as Raycast has, so the panel stands off the desktop.
                .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .strokeBorder(Color.primary.opacity(contrast == .increased ? 0.5 : 0.14), lineWidth: 1))
        }
    }

    struct Tint: View {
        @Environment(\.colorScheme) private var scheme
        var body: some View { (scheme == .dark ? Color.black.opacity(0.32) : Color.white.opacity(0.35)) }
    }

    struct SidebarGlass: NSViewRepresentable {
        func makeNSView(context: Context) -> NSVisualEffectView {
            let view = NSVisualEffectView()
            view.material = .fullScreenUI
            view.blendingMode = .behindWindow
            view.state = .active
            return view
        }
        func updateNSView(_ view: NSVisualEffectView, context: Context) {}
    }

    /// Sets a panel's height, keeping its top where it is. Only ever called with a fixed height.
    static func height(_ id: String, _ height: CGFloat) {
        let height = height + 2 * shadowRoom
        guard let panel = panels[id], abs(panel.frame.height - height) > 0.5 else { return }
        var frame = panel.frame
        frame.origin.y = frame.maxY - height
        frame.size.height = height
        panel.setFrame(frame, display: true, animate: false)
    }
}

// MARK: ⌘K

struct FindResult: Identifiable {
    enum Kind { case command, note, source, highlight, meeting, aiUse, passage }
    let id = UUID()
    let kind: Kind
    let title: String
    let detail: String
    var image: String? = nil      // passages from PDFs on this Mac: the passage as the page prints it
    var maths: String? = nil      // otherwise: the passage with its maths as $LaTeX$, to typeset
    var addToNotes: (() -> Void)? = nil   // passages: a new note quoting it, linked to its page
    let run: () -> Void
}

@MainActor
final class FindModel: ObservableObject {

    @Published var query = "" { didSet { FindModel.last = query } }
    /// The last search, so the window reopens where you left it.
    static var last = ""
    /// Every project instead of the current one, for this search only.
    @Published var everywhere = false { didSet { update() } }
    @Published var results: [FindResult] = []
    @Published var selected = 0
    private var task: Task<Void, Never>?

    private var commands: [FindResult] {
        let open = { (id: String) in { Floating.close("find"); Windows.open(id) } }
        return [
            FindResult(kind: .command, title: "New note", detail: "Notes", run: { Floating.close("find"); Capture.show(.note) }),
            FindResult(kind: .command, title: "Save a link", detail: "Library", run: { Floating.close("find"); Capture.show(.link) }),
            FindResult(kind: .command, title: "Log AI use", detail: "AI use", run: { Floating.close("find"); Capture.show(.aiUse) }),
            FindResult(kind: .command, title: "Add source", detail: "A link or a PDF", run: open("add-source")),
            FindResult(kind: .command, title: "Open Library", detail: "", run: open("library")),
            FindResult(kind: .command, title: "Open Evidence report", detail: "", run: open("evidence")),
            FindResult(kind: .command, title: "Open Notes", detail: "", run: open("notes")),
            FindResult(kind: .command, title: "Open Meetings", detail: "", run: open("meetings")),
            FindResult(kind: .command, title: "Open AI use", detail: "", run: open("ai-use")),
            FindResult(kind: .command, title: "Open Settings", detail: "", run: open("settings")),
        ]
    }

    @Published var recent = true   // nothing typed: the latest notes and sources

    func update() {
        task?.cancel()
        let q = query.trimmingCharacters(in: .whitespaces)
        let words = q.lowercased().split(separator: " ")
        // Search only: your notes, sources and reading. Commands live in the app's menus and sidebar.
        let matching: [FindResult] = []
        _ = words
        recent = q.isEmpty
        if !q.isEmpty { results = matching }
        selected = 0
        task = Task {
            if !q.isEmpty { try? await Task.sleep(nanoseconds: 180_000_000) }   // wait for a pause in typing
            guard !Task.isCancelled,
                  // Up to 20 s: the first search by meaning loads the search model.
                  let data = await API.request("find?q=\(q.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")\(everywhere ? "&project=*" : "")", timeout: 20),
                  let found = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
            var more: [FindResult] = []
            for item in found["items"] as? [[String: Any]] ?? [] {
                let title = item["title"] as? String ?? ""
                let detail = item["detail"] as? String ?? ""
                switch item["kind"] as? String {
                case "note":
                    let url = item["url"] as? String ?? ""
                    let page = item["page"] as? Int
                    more.append(FindResult(kind: .note, title: title, detail: detail, run: {
                        Floating.close("find")
                        if url.isEmpty { Windows.open("notes") } else { RefereeLinks.openSource(url, page: page, pdf: url.lowercased().hasSuffix(".pdf")) }
                    }))
                case "source", "highlight":
                    let url = item["url"] as? String ?? ""
                    let kind: FindResult.Kind = item["kind"] as? String == "highlight" ? .highlight : .source
                    more.append(FindResult(kind: kind, title: title, detail: detail, run: {
                        Floating.close("find"); RefereeLinks.openSource(url, page: nil, pdf: url.lowercased().hasSuffix(".pdf"))
                    }))
                case "meeting":
                    let id = item["id"] as? String ?? ""
                    more.append(FindResult(kind: .meeting, title: title, detail: detail, run: {
                        Floating.close("find"); RefereeLinks.handle(URL(string: "referee://meeting/\(id)")!)
                    }))
                default:
                    more.append(FindResult(kind: .aiUse, title: title, detail: detail, run: { Floating.close("find"); Windows.open("ai-use") }))
                }
            }
            for passage in found["passages"] as? [[String: Any]] ?? [] {
                let url = passage["url"] as? String ?? ""
                let page = passage["page"] as? Int
                let source = (everywhere ? [passage["project"] as? String ?? ""] : []).filter { !$0.isEmpty }
                    .map { $0 + " · " }.joined() + (passage["title"] as? String ?? "")
                // The maths tidied into Unicode (x₁, …, xₙ), and a picture of the page where there is one.
                let quoted = passage["maths"] as? String ?? passage["display"] as? String ?? passage["text"] as? String ?? ""
                let project = passage["project"] as? String
                more.append(FindResult(kind: .passage, title: passage["display"] as? String ?? passage["text"] as? String ?? "",
                                       detail: source + (page.map { " · p. \($0)" } ?? ""), image: passage["image"] as? String, maths: passage["maths"] as? String,
                                       addToNotes: { FindModel.note(quoting: quoted, url: url, page: page, source: passage["title"] as? String ?? "", project: project) }, run: {
                    Floating.close("find"); RefereeLinks.openSource(url, page: page, pdf: url.lowercased().hasSuffix(".pdf"))
                }))
            }
            guard !Task.isCancelled else { return }
            // Passages in page order within each source; sources in the order of their best match.
            let passages = more.filter { $0.kind == .passage }
            let sourceOf = { (r: FindResult) in r.detail.components(separatedBy: " · p. ").first ?? r.detail }
            let pageOf = { (r: FindResult) in Int(r.detail.components(separatedBy: " · p. ").last ?? "") ?? Int.max }
            var order: [String] = []
            for r in passages where !order.contains(sourceOf(r)) { order.append(sourceOf(r)) }
            let sorted = passages.enumerated().sorted { a, b in
                let (sa, sb) = (order.firstIndex(of: sourceOf(a.element)) ?? 0, order.firstIndex(of: sourceOf(b.element)) ?? 0)
                if sa != sb { return sa < sb }
                let (pa, pb) = (pageOf(a.element), pageOf(b.element))
                return pa != pb ? pa < pb : a.offset < b.offset
            }.map(\.element)
            more = more.filter { $0.kind != .passage } + sorted
            // A note titled exactly what was searched for comes first.
            let exact = more.filter { $0.kind == .note && $0.title.lowercased() == q.lowercased() }
            more = exact + more.filter { r in !exact.contains { $0.id == r.id } }
            results = more + matching
            // After SwiftUI has laid out the new results, so the panel grows to show them.

        }
    }

    /// A new note from a passage, titled by the search, with a line like your other notes
    /// ("**Definition 5.1**: ...", written by Claude), linked to the passage's page. Opens Notes to show it.
    static func note(quoting text: String, url: String, page: Int?, source: String, project: String?) {
        Task {
            _ = await API.post("notes/from-passage", ["query": FindModel.last, "text": text, "url": url, "page": page as Any,
                                                      "source": source, "project": project ?? ""], timeout: 30)
            Floating.close("find")
            Windows.open("notes")
        }
    }

    func move(_ by: Int) {
        guard !results.isEmpty else { return }
        selected = (selected + by + results.count) % results.count
    }
}

/// A result with its place in the whole list, for the arrow keys.
struct Numbered: Identifiable {
    let index: Int
    let result: FindResult
    var id: UUID { result.id }
}

struct FindView: View {

    /// What to search for as it opens (from Raycast, through referee://find?q=…).
    var initial = ""

    static let field: CGFloat = 68
    /// The list's height, fitted to the screen the panel opens on (Floating.show): 640 on a large
    /// monitor, less on a laptop so the panel doesn't run off the bottom.
    static var list: CGFloat = 640
    static var full: CGFloat { field + list + 60 }

    @StateObject private var model = FindModel()
    @FocusState private var focused: Bool
    @AppStorage("textScale") private var scale = 1.0
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                // Referee's whistle, as Raycast shows its own mark in its search bar.
                Image(nsImage: {
                    let image = Bundle.main.image(forResource: "whistleOnTemplate") ?? NSImage()   // the filled whistle
                    image.isTemplate = true
                    return image
                }())
                    .resizable().scaledToFit().frame(width: 22, height: 22)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("Search your notes, sources and reading…", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: Scaled.s(19)))
                    .focused($focused)
                    .onSubmit { if model.results.indices.contains(model.selected) { model.results[model.selected].run() } }
                    .onKeyPress(.downArrow) { model.move(1); return .handled }
                    .onKeyPress(.upArrow) { model.move(-1); return .handled }
                Menu {
                    Button("This Project") { model.everywhere = false }
                    Button("All Projects") { model.everywhere = true }
                } label: {
                    HStack(spacing: 3) {
                        Text(model.everywhere ? "All projects" : "This project")
                        Image(systemName: "chevron.down").font(.system(size: Scaled.s(9), weight: .semibold))
                    }
                    .font(.system(size: Scaled.s(13)))
                    .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Search the current project, or every project")
            }
            // The same room above and below, so the bar's text and icon sit in its middle.
            .frame(height: 28)
            .padding(.horizontal, 24).padding(.vertical, 20)
            if !model.results.isEmpty {
                ScrollViewReader { scroll in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(groups, id: \.0) { name, items in
                                Text(name.uppercased())
                                    .font(.system(size: Scaled.s(11), weight: .medium)).kerning(0.4)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 22).padding(.top, 12).padding(.bottom, 4)
                                ForEach(items.map { Numbered(index: $0.0, result: $0.1) }) { item in
                                    row(item.result, selected: item.index == model.selected).id(item.index)
                                        .onTapGesture { item.result.run() }
                                        .contextMenu {
                                            if let add = item.result.addToNotes {
                                                Button("Add to Notes") { add() }
                                            }
                                            Button("Open") { item.result.run() }
                                        }
                                }
                            }
                        }
                        .padding(.bottom, 8)
                    }
                    .frame(height: FindView.list)
                    .onChange(of: model.selected) { _, i in scroll.scrollTo(i) }
                }
                // A bar of actions at the bottom right, as Raycast has.
                HStack(spacing: 14) {
                    Text(model.recent ? "Recent in this project" : "Passages found by meaning, on this Mac")
                        .font(.system(size: Scaled.s(12))).foregroundStyle(.tertiary)
                    Spacer()
                    HStack(spacing: 14) {
                        HStack(spacing: 6) { Text("Open"); KeyCap("↩") }
                        HStack(spacing: 6) { Text("Close"); KeyCap("esc") }
                    }
                    .font(.system(size: Scaled.s(13), weight: .medium))
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(Color.primary.opacity(0.08), in: Capsule())
                    .overlay(Capsule().stroke(Color.primary.opacity(0.12)))
                }
                .padding(.horizontal, 18).padding(.top, 8).padding(.bottom, 18)
            }
        }
        .onAppear { focused = true; model.query = initial.isEmpty ? FindModel.last : initial; model.update() }
        .onChange(of: model.query) { _, _ in model.update() }
        // Two fixed sizes: the field alone, or the field with a fixed-height list.
        .onChange(of: model.results.isEmpty) { _, empty in Floating.height("find", empty ? FindView.field : FindView.full) }
    }

    /// Results by group, each with its place in the whole list for the arrow keys.
    private var groups: [(String, [(Int, FindResult)])] {
        let numbered: [(Int, FindResult)] = model.results.enumerated().map { ($0.offset, $0.element) }
        let sets: [(String, [FindResult.Kind])] = [
            (model.recent ? "Recent" : "Notes and sources", [.note, .source, .highlight, .meeting, .aiUse]),
            ("In your reading", [.passage]),
        ]
        var found: [(String, [(Int, FindResult)])] = []
        for (name, kinds) in sets {
            let items = numbered.filter { kinds.contains($0.1.kind) }
            if !items.isEmpty { found.append((name, items)) }
        }
        return found
    }

    private func row(_ result: FindResult, selected: Bool) -> some View {
        Group {
            if result.kind == .passage {
                // A passage: its source and page as a small label, then the page as printed (or the text).
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 5) {
                        Image(systemName: "quote.opening").foregroundStyle(Color.accentColor)
                        Text(result.detail).lineLimit(1)
                    }
                    .font(.system(size: Scaled.s(12))).foregroundStyle(.secondary)
                    if let path = result.image, let picture = Pictures.load(path) {
                        Image(nsImage: picture)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: .infinity, maxHeight: 400, alignment: .leading)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(Color.white.opacity(0.35), lineWidth: selected ? 3 : 0))
                            // A picture of the page: VoiceOver reads the passage itself, maths in words.
                            .accessibilityElement()
                            .accessibilityLabel(Spoken.maths(result.title))
                    } else {
                        // In full, with its maths typeset.
                        MarkdownView(text: result.maths ?? result.title)
                            .font(.system(size: Scaled.s(14)))
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(Color.white.opacity(0.35), lineWidth: selected ? 3 : 0))
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(selected ? Color.primary.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            } else {
                // Anything else: one line, its details beside the name, what it is at the right, and a
                // soft grey pill when chosen, as in Raycast.
                HStack(spacing: 12) {
                    Image(systemName: symbol(result.kind))
                        .font(.system(size: Scaled.s(15)))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 20)
                    Text(result.title).font(.system(size: Scaled.s(15))).lineLimit(1)
                    if !result.detail.isEmpty {
                        Text(result.detail).font(.system(size: Scaled.s(14))).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Text(kindName(result.kind)).font(.system(size: Scaled.s(13))).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(selected ? Color.primary.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                // With Increase Contrast on, the chosen row also gets an outline.
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.primary.opacity(selected && contrast == .increased ? 0.7 : 0), lineWidth: 2))
            }
        }
        .padding(.horizontal, 10)
        .contentShape(Rectangle())
    }

    private func kindName(_ kind: FindResult.Kind) -> String {
        switch kind {
        case .command: return "Command"
        case .note: return "Note"
        case .source: return "Source"
        case .highlight: return "Highlight"
        case .meeting: return "Meeting"
        case .aiUse: return "AI use"
        case .passage: return "Passage"
        }
    }

    private func symbol(_ kind: FindResult.Kind) -> String {
        switch kind {
        case .command: return "arrow.forward"
        case .note: return "doc.plaintext"
        case .source: return "books.vertical"
        case .highlight: return "highlighter"
        case .meeting: return "person.2"
        case .aiUse: return "checkmark.shield"
        case .passage: return "quote.opening"
        }
    }
}

// MARK: Quick capture

@MainActor
enum Capture {
    enum Kind: String, CaseIterable { case note = "Note", link = "Link", aiUse = "AI use" }
    static func show(_ kind: Kind = .note) { Floating.show("capture", width: 460) { CaptureView(kind: kind) } }
}

struct CaptureView: View {

    @State var kind: Capture.Kind
    @State private var text = ""
    @State private var message: String?
    @State private var project = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            FieldLabel(project.isEmpty ? "Quick capture" : "Quick capture · \(project)")
            TextField(placeholder, text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: Scaled.s(19)))
                .lineLimit(2...6)
                .focused($focused)
                .onSubmit(save)
            HStack(spacing: 6) {
                ForEach(Capture.Kind.allCases, id: \.self) { k in
                    Button(k.rawValue) { kind = k }
                        .buttonStyle(.plain)
                        .font(Scaled.style(10, .regular))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(kind == k ? 0.35 : 0)))
                        .foregroundStyle(kind == k ? .primary : .secondary)
                }
                Spacer()
                if let message { Text(message).font(Scaled.style(10, .regular)).foregroundStyle(.secondary) }
                Button("Save", action: save).keyboardShortcut(.defaultAction).disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 18)
        .task {
            focused = true
            project = (await API.get("settings"))?["project"] as? String ?? ""
        }
    }

    private var placeholder: String {
        switch kind {
        case .note: return "A note on what you're reading"
        case .link: return "A link to save"
        case .aiUse: return "The AI tool, and what you used it for"
        }
    }

    private func save() {
        let entry = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !entry.isEmpty else { return }
        message = "Saving…"
        Task {
            let result: [String: Any]?
            switch kind {
            case .note:
                result = await API.post("notes", ["text": entry, "project": project])
            case .link:
                result = await API.post("sources/add-url", ["url": entry], timeout: 60)
            case .aiUse:
                let parts = entry.split(separator: ",", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                result = await API.post("ai-log", ["tool": parts.first ?? entry, "purpose": parts.count > 1 ? parts[1] : "",
                                                   "project": project, "date": Day.today])
            }
            if result == nil || result?["ok"] as? Bool == false {
                message = result?["reason"] as? String ?? "Referee isn't running."
            } else {
                Floating.close("capture")
            }
        }
    }
}

enum Day {
    static var today: String {
        let format = DateFormatter()
        format.dateFormat = "yyyy-MM-dd"
        return format.string(from: Date())
    }
}

/// A key, drawn as Raycast draws them in its action bar.
struct KeyCap: View {
    let key: String
    init(_ key: String) { self.key = key }
    var body: some View {
        Text(key)
            .font(.system(size: Scaled.s(11), weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5).frame(minWidth: 20, minHeight: 20)
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.primary.opacity(0.25)))
    }
}
