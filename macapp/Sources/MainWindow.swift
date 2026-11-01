import SwiftUI

/// Referee's main window: one sidebar for every part of it, instead of a window each.
enum Section: String, CaseIterable, Identifiable {
    case library, evidence, notes, meetings, calendar, aiUse = "ai-use", scout, linesman, varTrainer = "var", settings

    /// The sections listed together at the top of the sidebar; Settings sits at the bottom.
    static let main: [Section] = [.library, .evidence, .notes, .meetings, .calendar, .aiUse]
    /// Tools on their way, in their own group below.
    // Scout, Linesman and VAR aren't in this release; listed here again when one is built.
    static let soon: [Section] = []

    /// What a coming section will do, for its placeholder page.
    var promise: String {
        switch self {
        case .scout: return "New papers near your reading, from arXiv and journals, as a weekly digest. One click saves one to your Library."
        case .linesman: return "A diary of your analysis: the models you fit and the changes you make, each with a line on why, feeding your meetings' decisions."
        case .varTrainer: return "Practice for your viva: Referee asks you to state definitions, give examples and explain steps from your own write-up, and comes back to your weak spots."
        default: return ""
        }
    }

    var id: String { rawValue }

    /// Dragged from the sidebar as text with this in front, so a drop zone knows it's a section.
    static let dragPrefix = "referee-section:"

    var title: String {
        switch self {
        case .library: return "Library"
        case .evidence: return "Evidence"
        case .notes: return "Notes"
        case .meetings: return "Meetings"
        case .calendar: return "Calendar"
        case .aiUse: return "AI Use"
        case .scout: return "Scout"
        case .linesman: return "Linesman"
        case .varTrainer: return "VAR"
        case .settings: return "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .library: return "books.vertical"
        case .evidence: return "checklist"
        case .notes: return "doc.text"
        case .meetings: return "person.2"
        case .calendar: return "calendar"
        case .aiUse: return "sparkles"
        case .scout: return "binoculars"
        case .linesman: return "flag"
        case .varTrainer: return "tv"
        case .settings: return "gearshape"
        }
    }
}

struct MainWindow: View {

    @ObservedObject var model: Model
    @StateObject private var evidence = EvidenceModel()
    @AppStorage("mainSection") private var section = Section.library.rawValue
    /// A second page beside the first ("" when there isn't one): opened by dragging a section onto the
    /// right half, ⌘-clicking it, or its Open Beside menu.
    @AppStorage("besideSection") private var beside = ""
    /// How much of the width the left page takes when there are two: half to start, dragged to change.
    @State private var columns = NavigationSplitViewVisibility.all
    @State private var liveSplit = 0.5   // half and half each time two pages open
    @State private var dragStart: Double?
    @State private var pageWidth: CGFloat = 1000
    @State private var settingDue = false
    @State private var dragging = false   // a section is being dragged from the sidebar
    /// Where you were before Settings, for its Done button.
    @AppStorage("beforeSettings") private var beforeSettings = Section.library.rawValue
    @State private var about = false
    @State private var choosingProject = false
    @State private var dues: [String: Date] = [:]
    private var dueDate: Date? { dues[model.project] }
    @State private var submitted: [String: Date] = [:]

    private func loadDues() async {
        (dues, submitted) = await ProjectDue.read()
    }
    /// The project's next deadline before it's due: its soonest open task with a date (from Meetings), if
    /// that comes before the project's own due date. Shown first under the title, with the due date below.
    @State private var nextTask: (title: String, date: Date, deadline: String?)?

    private func loadNextTask() async {
        let project = model.project
        let today = Calendar.current.startOfDay(for: Date())
        let meetings = await API.getList("meetings?project=\(project.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")")
        let open = meetings.flatMap { $0["actions"] as? [[String: Any]] ?? [] }
            .filter { ($0["done"] as? Bool) != true }
            .compactMap { task -> (String, Date)? in
                guard let text = task["text"] as? String, let due = DueText.date(task["due"] as? String ?? ""), due >= today else { return nil }
                return (text, due)
            }
            .map { (title: $0.0, date: $0.1, deadline: String?.none) }
        // Named deadlines not yet submitted count too, overdue ones included.
        let deadlines = await ProjectDue.deadlines().filter { $0.project == project && !$0.submitted }
            .map { (title: $0.name, date: $0.date, deadline: Optional($0.id)) }
        let soonest = (open + deadlines).min { $0.date < $1.date }
        nextTask = soonest.flatMap { task in (dues[project].map { task.date < $0 } ?? true) ? task : nil }
    }
    @State private var undoTitle: String?      // what was just deleted, offered back for a few seconds
    @State private var reload = 0

    /// A sidebar row: an icon as heavy as its name, each in the same box so the names line up. Rows are buttons
    /// rather than list selection, so a click always shows that section.
    private func row(_ item: Section, quiet: Bool = false) -> some View {
        let selected = current == item
        return Group {
            HStack(spacing: 10) {
                Image(systemName: item.symbol)
                    .font(.system(size: Scaled.s(13), weight: .regular))
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(quiet ? Color.secondary : Color.accentColor)
                    .frame(width: 18, height: 18)
                Text(item.title)
                    .font(.system(size: Scaled.s(14), weight: selected ? .bold : .regular))   // the open section in bold, as in Mela
                    .foregroundStyle(quiet && !selected ? .secondary : .primary)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(selected ? Color.primary.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .selectionDisabled()
        // A click shows it (⌘-click: beside); a drag onto the page area opens it where it's dropped.
        // Not a Button: a button takes the mouse and the drag never starts.
        // The mouse, handled natively over the row: a click opens it (⌘-click: beside), a drag
        // always starts a drag (SwiftUI's own drag only began when the list let it through).
        .overlay(RowMouse(
            click: { command in
                if item == .settings && current != .settings { beforeSettings = section }
                if command && item != current && item != .settings { beside = item.rawValue } else { section = item.rawValue }
            },
            dragName: item.rawValue,
            dragStarted: { dragging = true },
            dragEnded: { dragging = false }))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { section = item.rawValue }
        .contextMenu {
            Button("Open") { section = item.rawValue }
            Button("Open Beside") { beside = item.rawValue }.disabled(item == current)
        }
        .animation(.smooth(duration: 0.2), value: selected)
        .listRowInsets(EdgeInsets(top: 1, leading: 8, bottom: 1, trailing: 8))
    }

    // A section that isn't in this release (one remembered from a test build) opens the Library.
    private var current: Section {
        guard let found = Section(rawValue: section), ![.scout, .linesman, .varTrainer].contains(found) || Section.soon.contains(found) else { return .library }
        return found
    }

    private func open(_ name: String, beside right: Bool) {
        dragging = false
        guard let dropped = Section(rawValue: name) else { return }
        if right && dropped != current && dropped != .settings { beside = dropped.rawValue }
        else { section = dropped.rawValue; if beside == dropped.rawValue { beside = "" } }
    }

    /// The page beside the current one, if any: not with Settings (it has the window to itself, and the
    /// pages come back after), and only while the window is wide enough for two.
    private func besidePage(width: CGFloat) -> Section? {
        guard current != .settings, width >= 760, let other = Section(rawValue: beside), other != current else { return nil }
        return other
    }

    /// The page area's width, for making room when a second page opens.
    private func remember(_ width: CGFloat) { if abs(pageWidth - width) > 1 { DispatchQueue.main.async { pageWidth = width } } }

    /// A second page needs 760 points: when the page area is narrower, the sidebar hides, and if
    /// that still isn't enough, the window grows.
    private func makeRoom() {
        guard !beside.isEmpty, pageWidth < 760 else { return }
        var room = pageWidth
        if columns != .detailOnly { columns = .detailOnly; room += 260 }
        if room < 760, let window = NSApp.keyWindow {
            var frame = window.frame
            let grow = 760 - room + 20
            frame.size.width += grow
            frame.origin.x = max(window.screen?.visibleFrame.minX ?? 0, frame.origin.x - grow / 2)
            window.setFrame(frame, display: true, animate: true)
        }
    }

    /// The page area: one page, or two side by side (and what dropping a section on it does).
    private var pages: some View {
    GeometryReader { space in
        let second = besidePage(width: space.size.width)
        let _ = remember(space.size.width)
        // Two pages: half each, whichever they are; drag the line between them to change it. The
        // position lives in memory while dragging (saving it every pixel made dragging stutter).
        let left = second == nil ? space.size.width : max(360, min(space.size.width - 360, space.size.width * liveSplit))
        HStack(spacing: 0) {
            headed(current, close: second == nil ? nil : { section = beside; beside = "" })
                .id("\(section)\(model.project)\(reload)")  // a fresh view, with fresh data, when any changes
                .frame(width: left)
                .frame(maxHeight: .infinity)
            if let second {
                Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 1)
                    .overlay(Color.clear.frame(width: 10).contentShape(Rectangle())
                        .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
                        .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { drag in
                                let start = dragStart ?? liveSplit
                                dragStart = start
                                liveSplit = min(0.8, max(0.2, start + Double(drag.translation.width / space.size.width)))
                            }
                            .onEnded { _ in dragStart = nil }))
                headed(second, close: { beside = "" }, left: false)
                    .id("beside-\(beside)\(model.project)\(reload)")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // While a section is dragged from the sidebar: two drop zones over the pages.
        .overlay {
            if dragging {
                HStack(spacing: 8) {
                    DropZone(label: "Open here", symbol: "rectangle.lefthalf.filled") { open($0, beside: false) }
                    DropZone(label: "Open beside", symbol: "rectangle.righthalf.filled") { open($0, beside: true) }
                }
                .padding(12).padding(.top, 3)   // the same gap under the headers as above the window's bottom edge

            }
        }
    }
    }

    /// A page under its own header: title, its buttons, and ✕ when there are two.
    private func headed(_ item: Section, close: (() -> Void)?, left: Bool = true) -> some View {
        page(item)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // While a section is dragged, the page blurs (its header bar stays sharp), so the drop
            // zones' outlines read clearly over it.
            .blur(radius: dragging ? 14 : 0)
            .padding(.top, 53)
            .overlayPreferenceValue(PageActions.self, alignment: .top) { actions in
                PageHeader(title: item == .evidence ? "Evidence Report" : item.title, actions: actions, close: close,
                           roomForWindowButtons: left && columns != .all)
            }
            .ignoresSafeArea(edges: .top)
    }

    @ViewBuilder private func page(_ item: Section) -> some View {
        switch item {
        case .library: LibraryView()
        case .evidence: EvidenceReportView(model: evidence)
        case .notes: NotesView()
        case .meetings: MeetingsView()
        case .calendar: AgendaView()
        case .aiUse: AIUseView()
        case .scout, .linesman, .varTrainer:
            EmptyPage(symbol: item.symbol, title: "\(item.title): coming soon", message: item.promise)
        case .settings: SettingsView(model: model, embedded: true)
        }
    }

    /// The sidebar: the project, the sections, the documents, and Referee at the bottom.
    private var sidebarColumn: some View {
        // One sidebar list, so macOS draws it as glass: the project, the sections, then the documents.
        List {
            // The project, as the sidebar's title (two lines at most); click it to switch.
            Button { choosingProject = true } label: {
                Text(model.project.isEmpty ? "No project" : model.project)
                    .font(Fonts.heading(20, .bold))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 8).padding(.top, 4).padding(.bottom, 10)
            .popover(isPresented: $choosingProject, arrowEdge: .bottom) {
                ProjectPopover(current: model.project, projects: model.projects,
                               choose: { model.setProject($0) }, close: { choosingProject = false; model.refresh(full: true) },
                               setDue: { settingDue = true })
            }
            .help("Switch project")
                .accessibilityLabel("Project: \(model.project.isEmpty ? "No project" : model.project). Switch project")
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .padding(.top, 8)
            .padding(.bottom, dueDate == nil && nextTask == nil && submitted[model.project] == nil ? 20 : 0)
            .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
            .selectionDisabled()
            .help("The current project: what you read is saved to it, and your writing is checked against it")
            // The next deadline within the project, when one comes before the project's due date.
            if let nextTask {
                // "Next: Draft plan · in 15 days · 11 Nov", marked apart from the project's own due date below it.
                let line = Text("Next: \(nextTask.title) · " + ProjectDue.describe(nextTask.date).replacingOccurrences(of: "Due ", with: ""))
                    .font(.system(size: Scaled.s(12)))
                    .foregroundStyle(nextTask.date < Calendar.current.startOfDay(for: Date()) ? Color.red : Color.secondary)
                    .lineLimit(2)
                Group {
                    if let id = nextTask.deadline {
                        // A named deadline: ticked off here, like the project's own due date.
                        Menu {
                            Button("Mark as Submitted") {
                                Task { await ProjectDue.deadline(["project": model.project, "id": id, "submitted": true]) }
                            }
                        } label: { line }
                        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                    } else {
                        line
                    }
                }
                    .padding(.horizontal, 8).padding(.top, 0).padding(.bottom, dueDate == nil && submitted[model.project] == nil ? 12 : 2)
                    .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
                    .selectionDisabled()
                    .help(nextTask.deadline == nil ? "The project's next deadline, from a task in Meetings" : "The project's next deadline. Click to mark it as submitted")
            }
            // Days until the project is due (set in Library → Due…).
            if let when = submitted[model.project] {
                Menu {
                    Button("Mark as Not Submitted") { Task { await ProjectDue.submit(model.project, false) } }
                } label: {
                    Text("Submitted · " + when.formatted(.dateTime.day().month(.abbreviated)))
                        .font(.system(size: Scaled.s(12)))
                        .foregroundStyle(Color.secondary)
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                .padding(.horizontal, 8).padding(.top, 0).padding(.bottom, 12)
                .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
                .selectionDisabled()
                .help("Ticked off as submitted, so its due date no longer warns. Click to undo.")
            } else if let dueDate {
                // Words, not icons, tell the two apart: "Next: …" above, "Project due …" below.
                Menu {
                    Button("Mark as Submitted") { Task { await ProjectDue.submit(model.project, true) } }
                } label: {
                    Text(nextTask == nil ? ProjectDue.describe(dueDate)
                                         : ProjectDue.describe(dueDate).replacingOccurrences(of: "Due ", with: "Project due "))
                        .font(.system(size: Scaled.s(12)))
                        .foregroundStyle(dueDate < Date() ? Color.red : Color.secondary)
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                .padding(.horizontal, 8).padding(.top, 0).padding(.bottom, 12)
                .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
                .selectionDisabled()
                .help("Click to mark the project as submitted")
            }
            ForEach(Section.main) { item in
                row(item)
            }
            if current == .evidence && !evidence.documents.isEmpty {
                // Headed like the sidebar's other small headings, and in line with them.
                Text("Documents")
                    .font(.system(size: Scaled.s(11), weight: .medium)).foregroundStyle(.secondary)
                    .padding(.top, 14).padding(.leading, 8)
                    .selectionDisabled()
                ForEach(evidence.documents, id: \.self) { name in
                    Button { evidence.document = name } label: {
                        // "PLA - Semester 1 - Online LaTeX Editor Overleaf (Overleaf)" -> "PLA - Semester 1"
                        Text(name.replacingOccurrences(of: #"\s*\([^)]*\)$"#, with: "", options: .regularExpression)
                                .replacingOccurrences(of: #"\s*[-–|]\s*(Online LaTeX Editor )?Overleaf$"#, with: "", options: .regularExpression))
                            .fontWeight(name == evidence.document ? .semibold : .regular)
                            .foregroundStyle(name == evidence.document ? .primary : .secondary)
                            .lineLimit(1)
                            .padding(.leading, 8).padding(.vertical, 3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .selectionDisabled()
                }
            }
            if !Section.soon.isEmpty {
                Text("Assistants (coming soon)")
                    .font(.system(size: Scaled.s(11), weight: .medium)).foregroundStyle(.secondary)
                    .padding(.top, 14).padding(.leading, 8)
                ForEach(Section.soon) { item in row(item, quiet: true) }
            }
            row(.settings)
                .padding(.top, 14)
        }
        .listStyle(.sidebar)
        // The desktop showing softly through, as in Finder's sidebar: the system's sidebar
        // material, blended with what's behind the window.
        .scrollContentBackground(.hidden)
        .background(SidebarGlass().ignoresSafeArea())
        .safeAreaInset(edge: .bottom) {
            Button { about = true } label: {
                VStack(spacing: 6) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 40, height: 40)
                    HStack(spacing: 4) {
                        Text("Referee").fontWeight(.medium)
                        Text(Updater.shared.current ?? "from code").foregroundStyle(.secondary)
                    }
                    .font(Scaled.style(12, .regular))
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.bottom, 16)
            .help("About Referee")
        }
        .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 280)
    }

    /// The page side: one page or two, under the window's title band.
    private var detailColumn: some View {
        pages
        .navigationTitle("")   // each page has its title in its own header
        // No subtitle: the project is the sidebar's title, and one line sits in the middle of the bar,
        // with the sidebar open or closed.
        // The window's own bar is clear, so the sidebar's glass runs to the top; the page side
        // gets a solid band of its own under the title and buttons, as in Mela.
        // No window toolbar: each page's header is the top bar, so there's one bar, not two.

    }

    @AppStorage("headingFont") private var headingFont = "New York"
    @AppStorage("bodyFont") private var bodyFont = "System"
    @AppStorage("textScale") private var textScale = 1.0

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            sidebarColumn
                .id("side-\(headingFont)-\(textScale)")
        } detail: {
            detailColumn
                .id("fonts-\(headingFont)-\(bodyFont)-\(textScale)")   // a font or size change redraws every page
        }
        .onAppear { evidence.load() }
        .onChange(of: model.project) { evidence.load() }
        // New checks arrive while you write: the Evidence report reloads every 10 seconds while it's
        // showing and Referee is in front, and when you switch back to Referee.
        .onReceive(Timer.publish(every: 10, on: .main, in: .common).autoconnect()) { _ in
            if NSApp.isActive && (current == .evidence || beside == Section.evidence.rawValue) { evidence.load() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in evidence.load() }
        // Read again once the server answers (at launch it may still be starting, and the due date was
        // missing until the next restart), when the project changes, and on coming back to Referee.
        .task { await loadDues(); await loadNextTask() }
        .onChange(of: model.online) { _, online in if online { Task { await loadDues(); await loadNextTask(); evidence.load() } } }
        .onChange(of: model.project) { _, _ in Task { await loadDues(); await loadNextTask() } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in Task { await loadDues(); await loadNextTask() } }
        .onReceive(NotificationCenter.default.publisher(for: .refereeDueChanged)) { _ in Task { await loadDues(); await loadNextTask() } }
        .onChange(of: beside) { _, _ in liveSplit = 0.5; makeRoom() }
        // Pages change instantly (a fade felt jarring); only the sidebar's label animates.
        .sheet(isPresented: $about) { AboutSheet(online: model.online) }
        .sheet(isPresented: $settingDue) {
            DueDatePicker(project: model.project) { NotificationCenter.default.post(name: .refereeDueChanged, object: nil) }
        }
        .frame(minWidth: 620, idealWidth: 1040, minHeight: 500, idealHeight: 720)   // half a MacBook screen fits
        // A restored version replaces what's on the page.
        .onReceive(NotificationCenter.default.publisher(for: .refereeRestored)) { _ in reload += 1 }
        // After a deletion: "Deleted …  Undo", for 10 seconds.
        .onReceive(NotificationCenter.default.publisher(for: .refereeDeleted)) { _ in
            Task {
                guard let last = await API.get("undo"), let title = last["title"] as? String else { return }
                undoTitle = title
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                if undoTitle == title { undoTitle = nil }
            }
        }
        .overlay(alignment: .bottom) {
            if let title = undoTitle {
                HStack(spacing: 14) {
                    Text("Deleted “\(title.count > 40 ? String(title.prefix(40)) + "…" : title)”").lineLimit(1)
                    Button("Undo") {
                        Task {
                            _ = await API.post("undo", [:])
                            undoTitle = nil
                            reload += 1
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .fontWeight(.semibold)
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
                .padding(.bottom, 20)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.default, value: undoTitle)
        .background {
            // ⌘K inside Referee, whatever the shortcut from other apps is.
            Button("") { Floating.show("find", width: 900) { FindView() } }.keyboardShortcut("k", modifiers: .command).hidden()
        }
    }
}

/// The sheet behind the sidebar badge: which Referee this is, and where to find more.
struct AboutSheet: View {

    let online: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 72, height: 72)
            HStack(spacing: 6) {
                Text("Referee").fontWeight(.semibold)
                Text(Updater.shared.current ?? "from code").foregroundStyle(.secondary)
            }
            .font(Scaled.style(17, .regular))
            Form {
                SwiftUI.Section {
                    LabeledContent("Version", value: Updater.shared.current ?? "Built from the code folder")
                    LabeledContent("Server") {
                        Text(online ? "Running" : "Not running").foregroundStyle(online ? .green : .secondary)
                    }
                    LabeledContent("Updates") {
                        Button("Check Now") { Updater.shared.check(manually: true) }
                    }
                }
                SwiftUI.Section("Links") {
                    link("GitHub", "https://github.com/reeceama/Referee")
                    link("Changelog", "https://github.com/reeceama/Referee/blob/main/CHANGELOG.md")
                    link("Releases", "https://github.com/reeceama/Referee/releases")
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380, height: 520)
    }

    private func link(_ title: String, _ url: String) -> some View {
        Button { NSWorkspace.shared.open(URL(string: url)!) } label: {
            HStack {
                Text(title)
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}


/// The translucent sidebar material, blended with whatever is behind the window.
struct SidebarGlass: NSViewRepresentable {

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        // The standard sidebar glass, as in Mela: the desktop shows through softly, its colours muted.
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

extension NSColor {
    /// The main window's title bar: a shade lighter than the page in dark mode, darker in light.
    static let titleBar = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 0.21, alpha: 1) : NSColor(white: 0.93, alpha: 1)
    }
}


/// One half of the page area while a section is dragged: highlights when it's under the pointer.
struct DropZone: View {
    let label: String   // for VoiceOver only
    let symbol: String
    let drop: (String) -> Void
    @State private var over = false

    var body: some View {
        Image(systemName: symbol).font(.system(size: Scaled.s(34), weight: .light))
            .accessibilityLabel(label)
        .foregroundStyle(over ? Color.accentColor : .secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.primary.opacity(over ? 0.08 : 0.03), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(over ? Color.accentColor : Color.primary.opacity(0.15),
                                                                  style: StrokeStyle(lineWidth: 2, dash: over ? [] : [6, 4])))
        .onDrop(of: [.plainText], isTargeted: $over) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: NSString.self) { item, _ in
                guard let text = item as? String, text.hasPrefix(Section.dragPrefix) else { return }
                let name = String(text.dropFirst(Section.dragPrefix.count))
                DispatchQueue.main.async { drop(name) }
            }
            return true
        }
    }
}




/// A sidebar row's mouse: click, or drag the section onto the pages.
struct RowMouse: NSViewRepresentable {
    let click: (Bool) -> Void
    let dragName: String
    let dragStarted: () -> Void
    let dragEnded: () -> Void

    func makeNSView(context: Context) -> MouseView { MouseView() }
    func updateNSView(_ view: MouseView, context: Context) {
        view.click = click; view.dragName = dragName; view.dragStarted = dragStarted; view.dragEnded = dragEnded
    }

    final class MouseView: NSView, NSDraggingSource {
        var click: (Bool) -> Void = { _ in }
        var dragName = ""
        var dragStarted: () -> Void = {}
        var dragEnded: () -> Void = {}
        private var down: NSEvent?

        override func mouseDown(with event: NSEvent) { down = event }

        override func mouseDragged(with event: NSEvent) {
            guard let start = down else { return }
            let moved = hypot(event.locationInWindow.x - start.locationInWindow.x, event.locationInWindow.y - start.locationInWindow.y)
            guard moved > 4 else { return }
            down = nil
            let item = NSPasteboardItem()
            item.setString(Section.dragPrefix + dragName, forType: .string)
            let dragged = NSDraggingItem(pasteboardWriter: item)
            // The row itself as the picture under the pointer.
            if let image = bitmapImageRepForCachingDisplay(in: bounds) {
                cacheDisplay(in: bounds, to: image)
                let picture = NSImage(size: bounds.size); picture.addRepresentation(image)
                dragged.setDraggingFrame(bounds, contents: picture)
            }
            dragStarted()
            beginDraggingSession(with: [dragged], event: start, source: self)
        }

        override func mouseUp(with event: NSEvent) {
            if down != nil { click(event.modifierFlags.contains(.command)) }
            down = nil
        }

        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            context == .withinApplication ? .copy : []
        }

        // However the drag ends (a drop, or let go elsewhere), the zones go.
        func draggingSession(_ session: NSDraggingSession, endedAt point: NSPoint, operation: NSDragOperation) {
            dragEnded()
        }
    }
}
