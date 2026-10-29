import EventKit
import SwiftUI

/// Calendar: your project work for the next four weeks, day by day, and nothing else from your life:
/// Referee's meetings, their action points with due dates, and events from the calendars you chose for
/// meetings (a timetable, a supervisor's calendar). For the current project, or all of them. Read only:
/// events are made in your calendar app; ＋ on a day starts a meeting note for it.

struct AgendaItem: Identifiable {
    enum Kind { case meeting, event, task }
    let id: String
    let kind: Kind
    let title: String
    let time: Date?          // nil for all-day things: tasks, deadlines
    let detail: String       // where it's from
    let colour: Color
    let open: () -> Void
}

@MainActor
final class AgendaModel: ObservableObject {

    @Published var days: [(date: Date, items: [AgendaItem])] = []
    @Published var note: String?
    private let store = EKEventStore()

    /// How many days back are loaded: four weeks to start, four more each time you reach the top.
    @Published var back = 28
    /// Every project's, or only the current one's.
    @Published var everyProject = false { didSet { load() } }

    /// Bumped when the days first load, so the page opens on today (but not when earlier weeks arrive).
    @Published var opened = 0

    func load(keepPlace: Bool = false) {
        Task {
            let current = (await API.get("settings"))?["project"] as? String ?? ""
            let inScope: (String?) -> Bool = { [everyProject] project in everyProject || (project ?? "") == current }
            let calendar = Calendar.current
            let today = calendar.startOfDay(for: Date())
            let start = calendar.date(byAdding: .day, value: -back, to: today)!
            let end = calendar.date(byAdding: .day, value: 28, to: today)!
            var items: [(Date, AgendaItem)] = []
            let day = DateFormatter()
            day.dateFormat = "yyyy-MM-dd"

            // Referee's own meetings.
            let allMeetings = await API.getList("meetings?project=all").filter { inScope($0["project"] as? String) }
            for m in allMeetings {
                // Its action points with due dates, on the day they're due (overdue ones on today).
                for a in m["actions"] as? [[String: Any]] ?? [] where a["done"] as? Bool != true {
                    guard let text = a["text"] as? String, !text.isEmpty,
                          let due = (a["due"] as? String).flatMap(DueText.date), due < end, let mid = m["id"] as? String else { continue }
                    items.append((due, AgendaItem(id: "a-\(a["id"] as? String ?? text)", kind: .task, title: text, time: nil,
                                                              detail: due < today ? "Task · overdue" : "Task",
                                                              colour: .orange,
                                                              open: { RefereeLinks.handle(URL(string: "referee://meeting/\(mid)")!) })))
                }
                guard let id = m["id"] as? String, let date = (m["date"] as? String).flatMap(day.date(from:)),
                      date >= start, date < end else { continue }
                items.append((date, AgendaItem(id: "m-\(id)", kind: .meeting, title: (m["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Meeting",
                                               time: nil, detail: "Meeting" + ((m["project"] as? String).map { $0.isEmpty ? "" : " · \($0)" } ?? ""),
                                               colour: .accentColor,
                                               open: { RefereeLinks.handle(URL(string: "referee://meeting/\(id)")!) })))
            }
            // The calendars on this Mac, as chosen for meetings.
            if (try? await store.requestFullAccessToEvents()) == true {
                // Only the calendars chosen for meetings: none chosen, no events, rather than your whole life.
                let chosen = Set(UserDefaults.standard.stringArray(forKey: "meetingCalendars") ?? [])
                let using = store.calendars(for: .event).filter { chosen.contains($0.calendarIdentifier) }
                if chosen.isEmpty { note = "Choose your project calendars (a timetable, a supervisor's) in Meetings' calendar menu to see their events here." }
                var seen = Set<String>()
                for event in (using.isEmpty ? [] : store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: using)))
                    where seen.insert("\(event.title ?? "")|\(event.startDate.timeIntervalSince1970)").inserted {
                    let identifier = event.calendarItemIdentifier
                    items.append((event.startDate, AgendaItem(id: "e-\(identifier)@\(event.startDate.timeIntervalSince1970)", kind: .event,
                                                              title: event.title ?? "Event", time: event.isAllDay ? nil : event.startDate,
                                                              detail: event.calendar.title, colour: Color(cgColor: event.calendar.cgColor),
                                                              open: { NSWorkspace.shared.open(URL(string: "ical://")!) })))
                }
            } else {
                note = "Allow Referee to see your calendars in System Settings → Privacy & Security → Calendars to show events here."
            }
            defer { if !keepPlace { opened += 1 } }
            // Projects' due dates.
            for (name, due) in await ProjectDue.all() where inScope(name) && due >= start && due < end {
                items.append((due, AgendaItem(id: "due-\(name)", kind: .task, title: "\(name) due", time: nil,
                                              detail: "Project deadline", colour: .red, open: {})))
            }
            days = (-back..<28).map { offset in
                let date = calendar.date(byAdding: .day, value: offset, to: today)!
                let mine = items.filter { calendar.isDate($0.0, inSameDayAs: date) }.map(\.1)
                    .sorted { ($0.time ?? .distantPast) < ($1.time ?? .distantPast) }
                return (date, mine)
            }
        }
    }
}

struct AgendaView: View {

    @StateObject private var model = AgendaModel()
    @StateObject private var meetings = MeetingsModel()
    @State private var settled = false   // on today: from now on, reaching the top loads earlier weeks

    var body: some View {
        VStack(spacing: 0) {
        // Stays put while the days scroll beneath it.
        VStack(alignment: .leading, spacing: 8) {
            Picker("", selection: $model.everyProject) {
                Text("This project").tag(false)
                Text("All projects").tag(true)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
        }
        .frame(maxWidth: 620, alignment: .leading)
        .padding(.horizontal, 36).padding(.top, 16).padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .center)
        Hairline()
        Page(narrow: true) {
            ScrollViewReader { scroll in
            LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(model.days, id: \.date) { day in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .center, spacing: 12) {
                        Text(day.date.formatted(.dateTime.day()))
                            .font(.system(size: Scaled.s(40), weight: .semibold, design: .rounded))
                            .foregroundStyle(Calendar.current.isDateInToday(day.date) ? Color.accentColor : .primary)
                            .frame(minWidth: 56, alignment: .trailing)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(day.date.formatted(.dateTime.weekday(.wide)).uppercased())
                                .font(.system(size: Scaled.s(13), weight: .semibold)).kerning(0.4)
                            Text(day.date.formatted(.dateTime.month(.wide)).uppercased())
                                .font(.system(size: Scaled.s(13), weight: .semibold)).kerning(0.4).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { newMeeting(on: day.date) } label: { Image(systemName: "plus").font(.system(size: Scaled.s(16), weight: .medium)) }
                            .buttonStyle(.borderless)
                            .help("New meeting on this day")
                            .accessibilityLabel("New meeting on \(day.date.formatted(date: .complete, time: .omitted))")
                    }
                    ForEach(day.items) { item in
                        Button(action: item.open) {
                            HStack(spacing: 10) {
                                Image(systemName: item.kind == .task ? "checkmark.circle" : "circle.fill")
                                    .font(.system(size: Scaled.s(item.kind == .task ? 12 : 8))).foregroundStyle(item.colour)
                                    .frame(width: 14)
                                // The time, only when there is one: an untimed item's name sits right by its dot.
                                if let time = item.time {
                                    Text(time.formatted(date: .omitted, time: .shortened))
                                        .monospacedDigit().foregroundStyle(.secondary)
                                }
                                Text(item.title).lineLimit(1)
                                Spacer(minLength: 8)
                                Text(item.detail).font(Scaled.style(10, .regular)).foregroundStyle(.secondary).lineLimit(1)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.leading, 68)
                    }
                    Hairline().padding(.leading, 68).padding(.top, 8)
                }
                .padding(.vertical, 10)
                .id(day.date)
                .opacity(day.date < Calendar.current.startOfDay(for: Date()) ? 0.6 : 1)   // past days, quieter
                // Reaching the earliest day loads four weeks more, so the past goes back as far as you like.
                .onAppear { if settled && day.date == model.days.first?.date { model.back += 28; model.load(keepPlace: true) } }
            }
            }
            // Opens on today; scroll up for the past weeks.
            // Open on today; only then does reaching the top load earlier weeks (the list starts at its
            // oldest day, which would otherwise count as reaching the top before it ever got to today).
            .onChange(of: model.opened) { _, _ in
                settled = false
                DispatchQueue.main.async {
                    scroll.scrollTo(Calendar.current.startOfDay(for: Date()), anchor: .top)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { settled = true }
                }
            }
            }
        }
        }
        .onAppear { model.load(); meetings.load() }
    }

    private func newMeeting(on date: Date) {
        meetings.add()
        // The new meeting is the last one; give it this day, then show it.
        if var meeting = meetings.meetings.last {
            let format = DateFormatter()
            format.dateFormat = "yyyy-MM-dd"
            meeting.date = format.string(from: date)
            meetings.save(meeting, now: true)
            RefereeLinks.handle(URL(string: "referee://meeting/\(meeting.id)")!)
        }
    }
}

/// Projects' due dates, as Referee's server keeps them (typed in, or followed from a Todoist task).
enum ProjectDue {
    static func all() async -> [String: Date] {
        let format = DateFormatter()
        format.dateFormat = "yyyy-MM-dd"
        var found: [String: Date] = [:]
        for (name, value) in await API.get("projects/due") ?? [:] {
            if let date = ((value as? [String: Any])?["date"] as? String).flatMap(format.date(from:)) { found[name] = date }
        }
        return found
    }

    /// "Due in 32 days · 23 Nov", "Due tomorrow", "Due today", "3 days overdue".
    static func describe(_ date: Date) -> String {
        let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: Date()),
                                                   to: Calendar.current.startOfDay(for: date)).day ?? 0
        let when = date.formatted(.dateTime.day().month(.abbreviated))
        switch days {
        case ..<(-1): return "\(-days) days overdue · \(when)"
        case -1: return "1 day overdue · \(when)"
        case 0: return "Due today"
        case 1: return "Due tomorrow"
        default: return "Due in \(days) days · \(when)"
        }
    }
}

/// Setting a project's due date: follow a Todoist task's, or pick a date.
struct DueDatePicker: View {
    let project: String
    let done: () -> Void
    @State private var tasks: [[String: Any]] = []
    @State private var date = Date()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Due date for \(project)").font(Scaled.style(13, .semibold))
            if !tasks.isEmpty {
                FieldLabel("Follow a Todoist task")
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(tasks.enumerated()), id: \.offset) { _, task in
                            Button { save(["task": task["id"] as? String ?? "", "title": task["content"] as? String ?? "",
                                           "date": task["due"] as? String ?? ""]) } label: {
                                HStack {
                                    Text(task["content"] as? String ?? "").lineLimit(1)
                                    Spacer()
                                    Text(task["due"] as? String ?? "").foregroundStyle(.secondary).monospacedDigit()
                                }
                                .padding(.vertical, 5).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 200)
            }
            FieldLabel("Or pick a date")
            HStack {
                DatePicker("", selection: $date, displayedComponents: .date).labelsHidden()
                Button("Set") {
                    let format = DateFormatter(); format.dateFormat = "yyyy-MM-dd"
                    save(["date": format.string(from: date)])
                }
                Spacer()
                Button("Clear") { save([:]) }
            }
        }
        .padding(16)
        .frame(width: 380)
        .task { tasks = await API.getList("todoist/dated") }
    }

    private func save(_ due: [String: Any]) {
        Task {
            _ = await API.post("projects/due", due.merging(["project": project]) { a, _ in a })
            done()
            dismiss()
        }
    }
}

extension Notification.Name {
    static let refereeDueChanged = Notification.Name("refereeDueChanged")
}


/// An action point's "by when" as written: "2026-11-11", "11/11/2026" (day first, as in the UK),
/// "11 Nov", "next Friday".
enum DueText {
    static func date(_ text: String) -> Date? {
        let text = text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        for pattern in ["yyyy-MM-dd", "d/M/yyyy", "d/M/yy", "d MMM yyyy", "d MMMM yyyy"] {
            let format = DateFormatter()
            format.locale = Locale(identifier: "en_GB")
            format.dateFormat = pattern
            if let date = format.date(from: text) { return Calendar.current.startOfDay(for: date) }
        }
        // Anything else readable as a date: "11 Nov", "next Friday", "tomorrow".
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)
        let found = detector?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))?.date
        return found.map { Calendar.current.startOfDay(for: $0) }
    }
}
