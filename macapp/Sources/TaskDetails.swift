import MapKit
import SwiftUI

/// More about a task, for the to-do app it goes to (server/tasks.py): when to work on it, how long it takes,
/// priority, labels, a section, the flag, and reminders (minutes before, or arriving at or leaving a place).
/// Each app takes what it has, and the editor shows only those. Optional throughout, so tasks saved before
/// still read; only what's set is kept.
struct TaskDetails: Codable, Equatable {
    /// A submission: in Referee's calendar on its "by when" date, with the deadline alerts, as well as in the to-do app.
    var submission: Bool?
    /// The deadline's time, if it has one ("23:59"): the deadline's day is the task's by-when date.
    var deadline_time: String?
    /// When you plan to work on it (Todoist's date, which puts it in Today), with its time and repeat.
    var date: String?
    var time: String?
    var `repeat`: String?
    var duration: Int?
    var priority: Int?
    var labels: [String]?
    var section: String?
    var flagged: Bool?
    var reminders: [TaskReminder]?

    var isEmpty: Bool { self == TaskDetails() }

    /// A short line for the task's row: "Thu 20 Nov 17:00 · P1 · group · 2 reminders".
    var summary: String {
        var parts: [String] = submission == true ? ["Submission"] : []
        if let date, let day = TaskDetailsEditor.day.date(from: date) {
            parts.append("Do on " + day.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)) + (time.map { " \($0)" } ?? ""))
        }
        if let `repeat`, `repeat` != "never" { parts.append(`repeat`.capitalized) }
        if let duration { parts.append(duration >= 60 && duration % 60 == 0 ? "\(duration / 60) h" : "\(duration) min") }
        if let priority, priority < 4 { parts.append("P\(priority)") }
        if flagged == true { parts.append("Flagged") }
        if let section, !section.isEmpty { parts.append(section) }
        parts += labels ?? []
        if let reminders, !reminders.isEmpty { parts.append("\(reminders.count) reminder\(reminders.count == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }
}

struct TaskReminder: Codable, Equatable, Hashable {
    var minutes: Int?          // before the task's time
    var place: String?
    var lat: Double?
    var lon: Double?
    var arriving: Bool?        // false: leaving

    var description: String {
        if let place { return (arriving == false ? "Leaving " : "Arriving at ") + place }
        guard let minutes else { return "" }
        if minutes == 0 { return "At the time" }
        if minutes % 1440 == 0 { return "\(minutes / 1440) day\(minutes == 1440 ? "" : "s") before" }
        if minutes % 60 == 0 { return "\(minutes / 60) hour\(minutes == 60 ? "" : "s") before" }
        return "\(minutes) min before"
    }
}

/// Which details the chosen to-do app takes, and where reminders go, from Referee's server.
@MainActor
final class TaskFields: ObservableObject {
    static let shared = TaskFields()
    @Published var fields: [String] = []
    @Published var app: String?
    @Published var remindersTo = "app"

    func load() async {
        guard let status = await API.get("tasks") else { return }
        fields = status["fields"] as? [String] ?? []
        app = status["app"] as? String
        remindersTo = status["reminders_to"] as? String ?? "app"
    }

    func setRemindersTo(_ to: String) {
        remindersTo = to
        Task {
            if let status = await API.post("tasks/reminders", ["to": to]) {
                fields = status["fields"] as? [String] ?? fields
            }
        }
    }

    var appName: String {
        ["todoist": "Todoist", "things": "Things", "reminders": "Reminders", "notion": "Notion"][app ?? ""] ?? "your to-do app"
    }
}

/// The details of one task, showing only what the to-do app takes.
struct TaskDetailsEditor: View {
    static let day: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f }()
    static let clock: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f }()

    @Binding var details: TaskDetails
    /// The task's by-when date, its deadline, when the editor is for a task that has one (a meeting's task).
    var due: Binding<String>? = nil
    @ObservedObject private var known = TaskFields.shared
    @State private var labels = ""
    @State private var findingPlace = false

    private func has(_ field: String) -> Bool { known.fields.contains(field) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let due { deadlineRow(due) }
            Divider()
            if known.fields.isEmpty {
                Text(known.app == nil ? "Choose a to-do app in Settings → Integrations to give tasks more detail."
                                      : "\(known.appName) takes no more detail than the task and its date.")
                    .font(Scaled.style(11, .regular)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if has("date") { dateRow }
            if has("duration") {
                row("Duration") {
                    Picker("", selection: Binding(get: { details.duration ?? 0 }, set: { details.duration = $0 == 0 ? nil : $0 })) {
                        Text("None").tag(0)
                        ForEach([15, 30, 45, 60, 90, 120, 180], id: \.self) { m in
                            Text(m >= 60 && m % 60 == 0 ? "\(m / 60) h" : m > 60 ? "\(m / 60) h \(m % 60) min" : "\(m) min").tag(m)
                        }
                    }.labelsHidden().fixedSize()
                }
            }
            if has("priority") {
                row("Priority") { PriorityPicker(priority: $details.priority) }
            }
            if has("flagged") {
                row("Flag") { Toggle("", isOn: Binding(get: { details.flagged ?? false }, set: { details.flagged = $0 ? true : nil })).labelsHidden() }
            }
            if has("section") {
                row("Section") {
                    TextField("Section", text: Binding(get: { details.section ?? "" }, set: { details.section = $0.isEmpty ? nil : $0 }))
                        .textFieldStyle(.roundedBorder).frame(maxWidth: 220)
                }
            }
            if has("labels") {
                row(known.app == "things" ? "Tags" : "Labels") {
                    TextField(known.app == "things" ? "Tags" : "Labels", text: $labels)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: labels) { _, text in
                            let list = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                            details.labels = list.isEmpty ? nil : list
                        }
                }
            }
            if has("reminders") { remindersRow }
        }
        .task { await known.load() }
        .onAppear { labels = (details.labels ?? []).joined(separator: ", ") }
    }

    /// The deadline: the task's by-when date (kept as text on the task, "27/11/2026"), and a time if it has one.
    /// Never repeats: a repeat belongs to the date you work on it.
    private func deadlineRow(_ due: Binding<String>) -> some View {
        let day = DueText.date(due.wrappedValue)
        let show: DateFormatter = { let f = DateFormatter(); f.dateFormat = "dd/MM/yyyy"; return f }()
        return VStack(alignment: .leading, spacing: 3) {
            row("Deadline") {
                HStack(spacing: 8) {
                    Toggle("", isOn: Binding(get: { day != nil },
                                             set: { due.wrappedValue = $0 ? show.string(from: Date()) : "" }))
                        .labelsHidden()
                    if let day {
                        DatePicker("", selection: Binding(get: { day }, set: { due.wrappedValue = show.string(from: $0) }),
                                   displayedComponents: .date).labelsHidden().fixedSize()
                    }
                }
            }
            caption("When it must be done by\(known.app == "todoist" ? ": Todoist's deadline" : "").")
        }
    }

    /// When you plan to work on it: Todoist's date (which puts it in Today), Things' When. It can repeat.
    private var dateRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            row("Do on") {
                HStack(spacing: 8) {
                    Toggle("", isOn: Binding(get: { details.date != nil },
                                             set: { details.date = $0 ? Self.day.string(from: Date()) : nil; if !$0 { details.time = nil; details.repeat = nil } }))
                        .labelsHidden()
                    if let date = details.date {
                        DatePicker("", selection: Binding(get: { Self.day.date(from: date) ?? Date() }, set: { details.date = Self.day.string(from: $0) }),
                                   displayedComponents: .date).labelsHidden().fixedSize()
                        if has("time") {
                            Toggle("Time", isOn: Binding(get: { details.time != nil }, set: { details.time = $0 ? "09:00" : nil }))
                                .fixedSize()
                            if let time = details.time {
                                DatePicker("", selection: Binding(get: { Self.clock.date(from: time) ?? Date() }, set: { details.time = Self.clock.string(from: $0) }),
                                           displayedComponents: .hourAndMinute).labelsHidden().fixedSize()
                            }
                        }
                    }
                }
            }
            if details.date != nil && has("repeat") {
                row("Repeat") {
                    Picker("", selection: Binding(get: { details.repeat ?? "never" }, set: { details.repeat = $0 == "never" ? nil : $0 })) {
                        Text("Doesn't repeat").tag("never"); Text("Daily").tag("daily"); Text("Weekly").tag("weekly")
                        Text("Monthly").tag("monthly"); Text("Yearly").tag("yearly")
                    }.labelsHidden().fixedSize()
                }
            }
            caption(known.app == "todoist" ? "When you plan to work on it: Todoist's date, which puts it in Today."
                    : known.app == "things" ? "When you plan to work on it: Things' When, which puts it in Today."
                    : "When you plan to work on it.")
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(Scaled.style(10, .regular)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true).padding(.leading, 86)
    }

    private var remindersRow: some View {
        row("Reminders") {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array((details.reminders ?? []).enumerated()), id: \.offset) { i, reminder in
                    HStack(spacing: 6) {
                        Image(systemName: reminder.place == nil ? "bell" : "mappin.and.ellipse").foregroundStyle(.secondary)
                        Text(reminder.description)
                        Button { details.reminders?.remove(at: i); if details.reminders?.isEmpty == true { details.reminders = nil } } label: {
                            Image(systemName: "xmark")
                        }.buttonStyle(.plain).foregroundStyle(.tertiary).help("Remove")
                    }
                }
                HStack(spacing: 12) {
                    Menu("Add reminder") {
                        ForEach([0, 5, 15, 30, 60, 120, 1440], id: \.self) { m in
                            Button(TaskReminder(minutes: m).description) { add(TaskReminder(minutes: m)) }
                        }
                    }.menuStyle(.borderlessButton).fixedSize()
                    if has("places") {
                        Button("Add place") { findingPlace = true }.buttonStyle(.link)
                            .popover(isPresented: $findingPlace, arrowEdge: .bottom) {
                                PlaceSearch { add($0); findingPlace = false }
                            }
                    }
                }
                Text(known.remindersTo == "calendar" ? "As alerts in Referee's calendar, where Fantastical and Calendar show them."
                     : known.app == "todoist" && has("places") ? "In Todoist. Reminders at a place need Todoist Pro."
                     : "In \(known.appName).")
                    .font(Scaled.style(10, .regular)).foregroundStyle(.secondary)
            }
        }
    }

    private func add(_ reminder: TaskReminder) {
        var list = details.reminders ?? []
        if !list.contains(reminder) { list.append(reminder) }
        details.reminders = list
    }

    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label).foregroundStyle(.secondary).frame(width: 76, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
        .font(Scaled.style(12, .regular))
    }
}

/// Todoist's priorities with its colours: P1 red, P2 orange, P3 blue, and none (Todoist's P4) grey.
struct PriorityPicker: View {
    @Binding var priority: Int?

    static func color(_ p: Int?) -> Color {
        switch p { case 1: return .red; case 2: return .orange; case 3: return .blue; default: return .secondary }
    }

    var body: some View {
        HStack(spacing: 4) {
            ForEach([1, 2, 3, 4], id: \.self) { p in
                let chosen = (priority ?? 4) == p
                Button { priority = p == 4 ? nil : p } label: {
                    Label(p == 4 ? "None" : "P\(p)", systemImage: chosen ? "flag.fill" : "flag")
                        .foregroundStyle(Self.color(p == 4 ? nil : p))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(chosen ? Self.color(p == 4 ? nil : p).opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .help(["Priority 1: most urgent", "Priority 2", "Priority 3", "No priority"][p - 1])
            }
        }
    }
}

/// Finds a place with the Mac's map search, for a reminder on arriving or leaving.
private struct PlaceSearch: View {
    let chosen: (TaskReminder) -> Void
    @State private var query = ""
    @State private var results: [MKMapItem] = []
    @State private var arriving = true
    @State private var searching: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Place", text: $query).textFieldStyle(.roundedBorder)
                .onChange(of: query) { _, text in search(text) }
            Picker("", selection: $arriving) {
                Text("Arriving").tag(true); Text("Leaving").tag(false)
            }.labelsHidden().pickerStyle(.segmented)
            ForEach(Array(results.prefix(6).enumerated()), id: \.offset) { _, item in
                Button {
                    let at = item.placemark.coordinate
                    chosen(TaskReminder(place: item.name ?? query, lat: at.latitude, lon: at.longitude, arriving: arriving))
                } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.name ?? "")
                        Text(item.placemark.title ?? "").font(Scaled.style(10, .regular)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .frame(width: 300)
    }

    private func search(_ text: String) {
        searching?.cancel()
        guard text.trimmingCharacters(in: .whitespaces).count > 2 else { results = []; return }
        searching = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = text
            let found = try? await MKLocalSearch(request: request).start()
            if !Task.isCancelled { results = found?.mapItems ?? [] }
        }
    }
}

/// The details button on a task's row: its summary, opening the editor.
struct TaskDetailsButton: View {
    @Binding var details: TaskDetails?
    var due: Binding<String>? = nil
    @State private var open = false

    var body: some View {
        Button { open = true } label: {
            Label(details.map(\.summary).flatMap { $0.isEmpty ? nil : $0 } ?? "Details", systemImage: "slider.horizontal.3")
                .lineLimit(1)
        }
        .buttonStyle(.plain)
        .help("Deadline, when to do it, priority, labels, reminders and more, for your to-do app")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            TaskDetailsEditor(details: Binding(get: { details ?? TaskDetails() },
                                               set: { details = $0.isEmpty ? nil : $0 }), due: due)
                .padding(14)
                .frame(width: 540)
        }
    }
}
