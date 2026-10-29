import SwiftUI

/// Referee's page style, shared by every editor: a serif title edited where it sits, a quiet row
/// of details with small icons under it, then borderless sections under small capital labels,
/// divided by hairlines. No boxes around fields: the page is the field.

/// The page's serif title, typed into directly.
struct PageTitle: View {

    let placeholder: String
    @Binding var text: String
    @FocusState private var editing: Bool

    var body: some View {
        // Long titles are set smaller, and kept to two lines unless being edited.
        TextField(placeholder, text: $text, axis: .vertical)
            .textFieldStyle(.plain)
            .font(Fonts.heading(text.count > 40 ? 22 : 32, .regular))
            .lineLimit(editing ? 1...6 : 1...2)
            .focused($editing)
    }
}

/// The row of details under a title: each one a small blue icon and its value, with a thin
/// line between them.
struct DetailsRow<Content: View>: View {

    @ViewBuilder let content: Content

    var body: some View {
        // Wraps onto a second line when the details don't fit, rather than widening the page.
        WrappingRow(spacing: 14, lineSpacing: 8) { content }
            .font(.system(size: Scaled.s(13)))
            .foregroundStyle(.secondary)
    }
}

/// One detail: an icon, then its value (text, or a control drawn as text).
struct Detail<Content: View>: View {

    let symbol: String
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: Scaled.s(12), weight: .light))
                .foregroundStyle(Color.accentColor)
            content
        }
    }
}

/// The thin upright line between details.
struct DetailDivider: View {
    var body: some View { Rectangle().fill(Color.primary.opacity(0.15)).frame(width: 1, height: 14).layoutValue(key: IsDivider.self, value: true) }
}

/// Marks a divider in a WrappingRow, so it isn't left hanging at the end or start of a line.
struct IsDivider: LayoutValueKey { static let defaultValue = false }

/// A date shown as "16 October 2026", with a calendar on click.
struct DateDetail: View {

    @Binding var date: Date
    @State private var open = false

    var body: some View {
        Detail(symbol: "calendar") {
            Button(date.formatted(.dateTime.day().month(.wide).year())) { open = true }
                .buttonStyle(.plain)
                .lineLimit(1)
                .fixedSize()       // the date never wraps onto several lines
                .popover(isPresented: $open) {
                    DatePicker("Date", selection: $date, displayedComponents: .date)
                        .datePickerStyle(.graphical)
                        .labelsHidden()
                        .padding(10)
                }
        }
    }
}

/// The project, as text, with a menu of projects on click.
struct ProjectDetail: View {

    @Binding var project: String
    let projects: [String]

    var body: some View {
        Detail(symbol: "folder") {
            Menu {
                Picker("Project", selection: $project) {
                    Text("No project").tag("")
                    ForEach(projects, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                Text(project.isEmpty ? "No project" : project)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }
}

/// A detail typed into directly, such as attendees.
struct TextDetail: View {

    let symbol: String
    let placeholder: String
    @Binding var text: String

    var body: some View {
        Detail(symbol: symbol) {
            // As wide as what's typed (or the placeholder), measured from that text, so it shows in
            // full without forcing the row wider than the page.
            ZStack(alignment: .leading) {
                Text(text.isEmpty ? placeholder : text).hidden().lineLimit(1)
                TextField(placeholder, text: $text).textFieldStyle(.plain)
            }
            .frame(minWidth: 40, maxWidth: 260, alignment: .leading)
        }
    }
}

/// A section's small capital label.
struct FieldLabel: View {

    let title: String

    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title.uppercased())
            .font(.system(size: Scaled.s(11), weight: .medium))
            .tracking(0.8)
            .foregroundStyle(.secondary)
    }
}

/// Writing with no box, growing with what's typed; the placeholder shows while it's empty.
struct PlainText: View {

    let placeholder: String
    @Binding var text: String
    var size: CGFloat = 14
    @AppStorage("textScale") private var scale = 1.0

    var body: some View {
        TextField(placeholder, text: $text, axis: .vertical)
            .textFieldStyle(.plain)
            .font(Fonts.body(size))
            .lineSpacing(4)
            .lineLimit(1...)
            .paragraphs()
    }
}

/// A labelled section of a page: the label, then its content.
struct PageSection<Content: View>: View {

    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            FieldLabel(title)
            content
        }
    }
}

/// The hairline between parts of a page.
struct Hairline: View {
    @Environment(\.colorSchemeContrast) private var contrast
    // Darker with Increase Contrast on (System Settings → Accessibility → Display).
    var body: some View { Rectangle().fill(Color.primary.opacity(contrast == .increased ? 0.4 : 0.1)).frame(height: 1) }
}

/// Referee's text size (Settings → General), as a multiplier: Mac apps don't follow a system text
/// size, so Referee has its own.
enum TextSize {
    static let choices: [(Double, String)] = [(0.9, "Small"), (1.0, "Default"), (1.15, "Large"), (1.3, "Extra large")]
}

/// A quiet red link that asks for a second click before deleting.
struct DeleteLink: View {

    let title: String
    @Binding var armed: Bool
    let action: () -> Void

    var body: some View {
        Button(armed ? "Click again to delete" : title) {
            if armed { action(); armed = false } else {
                armed = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { armed = false }
            }
        }
        .buttonStyle(.plain)
        .font(.system(size: Scaled.s(13)))
        .foregroundStyle(armed ? Color.red : Color.red.opacity(0.75))
    }
}

/// The page's frame: generous margins and a comfortable reading width.
struct Page<Content: View>: View {

    /// Tables (the Evidence report) use the whole width; pages of writing stop where lines get long.
    var wide = false
    /// A narrower page (the Calendar's column of days) when it's on its own.
    var narrow = false
    @ViewBuilder let content: Content
    @AppStorage("textScale") private var scale = 1.0

    var body: some View {
        // Grows with the window, to about three quarters of it, so full screen isn't a narrow
        // strip; never so wide that lines get hard to follow.
        ScrollView {
            VStack(alignment: .leading, spacing: 0) { content }
                .font(Fonts.body(14))
                // Readable widths: about 900 points for writing, a little more for tables.
                .frame(maxWidth: (narrow ? 620 : wide ? 1100 : 900) * max(1, scale), alignment: .leading)
                .padding(.horizontal, 36)
                // A narrow page (Calendar, Settings) on its own sits in the middle of the window.
                .frame(maxWidth: narrow ? .infinity : nil, alignment: .center)
                .padding(.vertical, 28)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Never wider than the space it's given: a wide page would push the columns beside it
        // out of place.
        .frame(minWidth: 0, maxWidth: .infinity)
    }
}


/// Lays its items out in a row, starting a new line when the next one doesn't fit.
struct WrappingRow: Layout {

    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width { y += line + lineSpacing; x = 0; line = 0 }
            x += size.width + spacing
            line = max(line, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, width), height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        for (i, view) in subviews.enumerated() {
            let size = sizes[i]
            if x > bounds.minX && x + size.width > bounds.maxX { y += line + lineSpacing; x = bounds.minX; line = 0 }
            // A divider only sits between two items on the same line: at a line's start, or with the
            // next item not fitting after it, it's hidden.
            if view[IsDivider.self] {
                let nextFits = i + 1 < subviews.count && x + size.width + spacing + sizes[i + 1].width <= bounds.maxX
                if x == bounds.minX || !nextFits {
                    view.place(at: CGPoint(x: -10_000, y: -10_000), proposal: .zero)
                    continue
                }
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            line = max(line, size.height)
        }
    }
}

/// Return starts a new line, as in any writing app (SwiftUI's text boxes otherwise finish editing).
/// For boxes holding paragraphs: notes, meeting notes, AI use sections, the disclosure.
struct NewLineOnReturn: ViewModifier {
    func body(content: Content) -> some View {
        content.onKeyPress(.return) {
            guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView else { return .ignored }
            editor.insertNewlineIgnoringFieldEditor(nil)
            return .handled
        }
    }
}

extension View {
    func paragraphs() -> some View { modifier(NewLineOnReturn()) }
}


/// What a page shows when it has nothing yet: a large faint icon in the middle, a short line, and
/// what to do, as in Mela.
struct EmptyPage: View {
    let symbol: String
    let title: String
    var message: String = ""
    var action: (String, () -> Void)? = nil
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: Scaled.s(64), weight: .ultraLight))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text(title).font(Scaled.style(15, .regular)).foregroundStyle(.secondary)
            if !message.isEmpty {
                Text(message).font(Scaled.style(12, .regular)).foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center).frame(maxWidth: 380)
            }
            if let action { Button(action.0, action: action.1).glassButton().padding(.top, 4) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}


/// A page's own buttons (＋, import, calendar), shown in its header rather than the window's toolbar,
/// so two pages side by side each keep theirs.
struct PageActions: PreferenceKey {
    static var defaultValue: AnyView? = nil
    static func reduce(value: inout AnyView?, nextValue: () -> AnyView?) { value = nextValue() ?? value }
}

extension View {
    func pageActions<V: View>(@ViewBuilder _ actions: () -> V) -> some View {
        preference(key: PageActions.self, value: AnyView(actions()))
    }
}

/// The bar across the top of every page: its title on the left; its own buttons, then ✕ (when two
/// pages are open), on the right. The same on both halves, so the ✕s are always in the same place.
struct PageHeader: View {
    let title: String
    let actions: AnyView?
    let close: (() -> Void)?
    /// The left page's header holds the sidebar button, and leaves room for the window's buttons
    /// when the sidebar is hidden.
    var sidebar: (() -> Void)? = nil
    var roomForWindowButtons = false
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                // With the sidebar hidden, the window's buttons and sidebar button sit over this header.
                // Title 14 points after the sidebar button, as after the divider; it glides as the sidebar moves.
                Color.clear.frame(width: roomForWindowButtons ? 114.5 : 0, height: 1)
                    .animation(.default, value: roomForWindowButtons)
                if let sidebar {
                    Button(action: sidebar) { HeaderIcon("sidebar.left") }
                        .buttonStyle(.borderless).help("Show or hide the sidebar").accessibilityLabel("Toggle sidebar")
                }
                Text(title).font(.system(size: Scaled.s(15), weight: .bold))
                Spacer()
                if let actions { actions.buttonStyle(.borderless).labelStyle(.iconOnly) }
                if let close {
                    Button(action: close) { HeaderIcon("xmark") }
                        .buttonStyle(.borderless)
                        .help("Close \(title)")
                        .accessibilityLabel("Close \(title)")
                }
            }
            .font(.system(size: Scaled.s(14)))
            .padding(.horizontal, 14)
            .frame(height: 52)
            .background(Color(nsColor: .titleBar))
            // Empty parts of the header move the window, as a title bar does.
            .modifier(MovesWindow())
            Hairline()
        }
    }
}


/// Every header button's icon: the same size, weight and box, so they sit level in a row.
struct HeaderIcon: View {
    let name: String
    init(_ name: String) { self.name = name }
    var body: some View {
        Image(systemName: name)
            .font(.system(size: Scaled.s(14), weight: .regular))
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
    }
}


/// Newest or oldest first, for a dated list: a full-width button like Disclosure below it,
/// which switches between the two (a menu here only grows as wide as its text).
struct OrderPicker: View {
    @Binding var oldestFirst: Bool
    var body: some View {
        Button { oldestFirst.toggle() } label: {
            HStack {
                Label(oldestFirst ? "Oldest first" : "Newest first",
                      systemImage: oldestFirst ? "arrow.up" : "arrow.down")
                Spacer()
                Image(systemName: "chevron.up.chevron.down").font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .glassButton()
        .help(oldestFirst ? "Showing oldest first. Click for newest first." : "Showing newest first. Click for oldest first.")
    }
}


struct MovesWindow: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) { content.gesture(WindowDragGesture()) } else { content }
    }
}


/// The fonts chosen in Settings → General: one for headings (titles, the sidebar's project, list and
/// note titles), one for body text (notes, meeting notes, answers). Read on each redraw; the main
/// window redraws everything when either changes.
enum Fonts {
    static let headingChoices = ["New York", "Charter", "Georgia", "System"]
    static let bodyChoices = ["System", "New York", "Charter", "Georgia"]

    static var headingName: String { UserDefaults.standard.string(forKey: "headingFont") ?? "New York" }
    static var bodyName: String { UserDefaults.standard.string(forKey: "bodyFont") ?? "System" }

    static func heading(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { font(headingName, Scaled.s(size), weight) }
    static func body(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { font(bodyName, Scaled.s(size), weight) }

    static func font(_ name: String, _ size: CGFloat, _ weight: Font.Weight) -> Font {
        switch name {
        case "New York": return .system(size: Scaled.s(size), weight: weight, design: .serif)
        case "System": return .system(size: Scaled.s(size), weight: weight)
        default: return .custom(name, size: size).weight(weight)
        }
    }
}


/// Every text size in Referee, scaled by Settings → General → Text size, so the setting reaches all
/// text, not only some (Mac apps don't follow a system text size, so Referee keeps its own).
enum Scaled {
    static var factor: CGFloat { CGFloat(UserDefaults.standard.object(forKey: "textScale") as? Double ?? 1.0) }
    static func s(_ size: CGFloat) -> CGFloat { size * factor }
    /// macOS's text styles (caption, headline, body…) at their usual sizes, scaled.
    static func style(_ size: CGFloat, _ weight: Font.Weight) -> Font { .system(size: size * factor, weight: weight) }
}


/// Settings' rows sit in a softly filled, rounded box, as in System Settings.
struct SettingsBox: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 14)
            .padding(.vertical, 2)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

extension View {
    func settingsBox() -> some View { modifier(SettingsBox()) }
}

