import SwiftUI

/// Earlier versions of a note, meeting or AI use entry: a list of when each was replaced, the
/// chosen one shown as the page shows it, and a button to bring it back. Restoring keeps the
/// current version as an earlier one too, so a restore can itself be gone back on.
struct HistorySheet: View {

    let id: String
    let name: String
    @Environment(\.dismiss) private var dismiss
    @State private var versions: [[String: Any]] = []
    @State private var chosen: Double?
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Earlier versions of “\(name.isEmpty ? "Untitled" : name)”").font(Scaled.style(13, .semibold)).lineLimit(1)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(16)
            Hairline()
            if loaded && versions.isEmpty {
                Text("No earlier versions yet. Referee keeps one each time you change this, for 90 days.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(30)
            } else {
                HStack(spacing: 0) {
                    List(versions.indices, id: \.self, selection: $chosen.animation(nil).asIndex(in: versions)) { i in
                        Text(when(versions[i]["at"] as? Double ?? 0)).tag(i)
                    }
                    .frame(width: 190)
                    Divider()
                    ScrollView {
                        if let version = shown {
                            VStack(alignment: .leading, spacing: 16) {
                                Text(title(version)).font(Fonts.heading(24, .regular))
                                ForEach(sections(version), id: \.0) { label, text in
                                    VStack(alignment: .leading, spacing: 6) {
                                        if !label.isEmpty { FieldLabel(label) }
                                        MarkdownView(text: text, sources: [])
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(20)
                        }
                    }
                }
                Hairline()
                HStack {
                    Spacer()
                    Button("Restore This Version") { restore() }.disabled(shown == nil)
                }
                .padding(12)
            }
        }
        .frame(width: 720, height: 480)
        .task {
            versions = await API.getList("history?id=\(id)")
            chosen = versions.first?["at"] as? Double
            loaded = true
        }
    }

    private var shown: [String: Any]? {
        versions.first { ($0["at"] as? Double) == chosen }?["item"] as? [String: Any]
    }

    private func when(_ at: Double) -> String {
        let date = Date(timeIntervalSince1970: at)
        if Calendar.current.isDateInToday(date) { return "Today, " + date.formatted(date: .omitted, time: .shortened) }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday, " + date.formatted(date: .omitted, time: .shortened) }
        return date.formatted(.dateTime.day().month(.abbreviated).hour().minute())
    }

    private func title(_ item: [String: Any]) -> String {
        [item["title"], item["purpose"]].compactMap { $0 as? String }.first { !$0.isEmpty } ?? "Untitled"
    }

    /// The written parts of the item, labelled, in the order its page shows them.
    private func sections(_ item: [String: Any]) -> [(String, String)] {
        let order: [(String, String)] = [("body", ""), ("attendees", "Attendees"), ("notes", "Notes"),
                                         ("decisions", "Decisions"), ("prompt", "What you asked"),
                                         ("response", "What it gave you"), ("checked", "How you checked it")]
        return order.compactMap { key, label in
            guard let text = item[key] as? String, !text.isEmpty else { return nil }
            return (label, text)
        }
    }

    private func restore() {
        guard let chosen else { return }
        Task {
            _ = await API.post("history/restore", ["id": id, "at": chosen])
            NotificationCenter.default.post(name: .refereeRestored, object: nil)
            dismiss()
        }
    }
}

/// The clock button beside a title that opens its earlier versions.
struct HistoryButton: View {

    let id: String
    let name: String
    @State private var showing = false

    var body: some View {
        Button { showing = true } label: { Image(systemName: "clock.arrow.circlepath") }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Earlier versions")
            .accessibilityLabel("Earlier versions")
            .sheet(isPresented: $showing) { HistorySheet(id: id, name: name) }
    }
}

extension Notification.Name {
    static let refereeRestored = Notification.Name("refereeRestored")
}

private extension Binding where Value == Double? {
    /// The list selects by row; the sheet keeps the version's time.
    func asIndex(in versions: [[String: Any]]) -> Binding<Int?> {
        Binding<Int?>(
            get: { versions.firstIndex { ($0["at"] as? Double) == wrappedValue } },
            set: { wrappedValue = $0.flatMap { versions[$0]["at"] as? Double } })
    }
}


/// Recently Deleted for one kind (meetings, AI use): kept 30 days, each restorable or deleted for good.
struct RecentlyDeletedButton: View {
    let kind: String          // "meeting", "ai-use", "note" or "source"
    let project: String       // the list's project filter ("all", "none" or a name)
    var inHeader = false      // drawn like the header bar's other icons (Notes, Library)
    let restored: () -> Void
    @State private var open = false
    @State private var items: [[String: Any]] = []

    var body: some View {
        // An icon button beside Export, the same height and style, rather than a loose line under it.
        Button { open = true } label: {
            if inHeader { HeaderIcon("trash") } else { Image(systemName: "trash") }
        }
            .buttonStyle(.borderless)
            .help("Recently Deleted")
            .accessibilityLabel("Recently Deleted")
            .foregroundStyle(.secondary)
            .popover(isPresented: $open, arrowEdge: .top) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Recently Deleted").font(Scaled.style(13, .semibold)).padding(.bottom, 4)
                    Text("Kept for 30 days.").font(Scaled.style(10, .regular)).foregroundStyle(.secondary).padding(.bottom, 10)
                    if items.isEmpty {
                        Text("Nothing deleted.").foregroundStyle(.secondary).padding(.vertical, 8)
                    }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                                let at = item["at"] as? Double ?? 0
                                HStack(spacing: 10) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text((item["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled").lineLimit(2)
                                            .fixedSize(horizontal: false, vertical: true)
                                        Text("Deleted " + Date(timeIntervalSince1970: at).formatted(.relative(presentation: .named)))
                                            .font(Scaled.style(10, .regular)).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Button("Restore") { act("restore", at) }
                                    Button("Delete") { act("forget", at) }.foregroundStyle(.red)
                                }
                                .buttonStyle(.borderless)
                                .padding(.vertical, 7)
                                Hairline()
                            }
                        }
                    }
                    // Tall enough for its rows (a scroll view in a popover otherwise shrinks to a sliver), up to 420.
                    .frame(height: min(CGFloat(max(items.count, 1)) * 62, 420))
                }
                .padding(16)
                .frame(width: 420)
                .task { await load() }
            }
    }

    private func load() async {
        let p = project.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "all"
        items = await API.getList("recently-deleted?kind=\(kind)&project=\(p)")
    }

    private func act(_ action: String, _ at: Double) {
        Task {
            _ = await API.post("recently-deleted/\(action)", ["at": at])
            await load()
            if action == "restore" { restored() }
        }
    }
}
