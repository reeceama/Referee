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
    /// Choices on right-click: done or submitted, and delete.
    var menu: [(String, () -> Void)] = []
}

@MainActor
final class AgendaModel: ObservableObject {

    @Published var days: [(date: Date, items: [AgendaItem])] = []
    @Published var note: String?
    private let store = EKEventStore()

    /// How many days back are loaded: four weeks to start, four more each time you reach the top.
    @Published var back = 28
    /// How many days ahead are loaded: four weeks, or further to reach a date jumped to.
    @Published var ahead = 28
    /// A day to scroll to (from Today or Go to date), once its days are loaded; bumped each time.
    var target = Date()
    var pending: Date?
    @Published var jumps = 0
    /// Every project's, or only the current one's.
    @Published var everyProject = false { didSet { load() } }

    /// Bumped when the days first load, so the page opens on today (but not when earlier weeks arrive).
    @Published var opened = 0

    /// A task ticked off or deleted from the calendar, in the meeting (or list) it belongs to.
    func change(_ actionID: String, in meetingID: String, delete: Bool) async {
        guard let data = await API.request("meetings?project=all"),
              var meeting = (try? JSONDecoder().decode([Meeting].self, from: data))?.first(where: { $0.id == meetingID }) else { return }
        if delete { meeting.actions.removeAll { $0.id == actionID } }
        else if let i = meeting.actions.firstIndex(where: { $0.id == actionID }) { meeting.actions[i].done = true }
        if let body = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(meeting)) as? [String: Any] {
            _ = await API.post("meetings", body)
        }
        load(keepPlace: true)
    }

    func load(keepPlace: Bool = false) {
        Task {
            let current = (await API.get("settings"))?["project"] as? String ?? ""
            let inScope: (String?) -> Bool = { [everyProject] project in everyProject || (project ?? "") == current }
            let calendar = Calendar.current
            let today = calendar.startOfDay(for: Date())
            let start = calendar.date(byAdding: .day, value: -back, to: today)!
            let end = calendar.date(byAdding: .day, value: ahead, to: today)!
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
                    let aid = a["id"] as? String ?? ""
                    items.append((due, AgendaItem(id: "a-\(a["id"] as? String ?? text)", kind: .task, title: text, time: nil,
                                                              detail: due < today ? "Task · overdue" : "Task",
                                                              colour: .orange,
                                                              open: { RefereeLinks.handle(URL(string: "referee://meeting/\(mid)")!) },
                                                              menu: [("Mark as Done", { Task { await self.change(aid, in: mid, delete: false) } }),
                                                                     ("Delete Task", { Task { await self.change(aid, in: mid, delete: true) } })])))
                }
                guard m["kind"] as? String != "tasks" else { continue }   // tasks without a meeting: only their tasks show
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
            defer {
                if let day = pending { target = day; pending = nil; jumps += 1 } else if !keepPlace { opened += 1 }
            }
            // Projects' due dates; a submitted one stays, ticked off in green.
            let dues = await ProjectDue.everything()
            for (name, due) in dues.dates where inScope(name) && due >= start && due < end {
                let done = dues.submitted[name] != nil
                items.append((due, AgendaItem(id: "due-\(name)", kind: .task, title: "\(name) due", time: nil,
                                              detail: done ? "Submitted" : "Project deadline", colour: done ? .green : .red, open: {})))
            }
            // Named deadlines besides a project's due date.
            for deadline in await ProjectDue.deadlines() where inScope(deadline.project) && deadline.date >= start && deadline.date < end {
                let done = deadline.submitted
                let (project, id) = (deadline.project, deadline.id)
                items.append((deadline.date, AgendaItem(id: "dl-\(id)", kind: .task, title: deadline.name, time: nil,
                                                        detail: done ? "Submitted" : "Deadline · \(project)", colour: done ? .green : .red,
                                                        open: {},
                                                        menu: [(done ? "Mark as Not Submitted" : "Mark as Submitted", {
                                                                   Task { await ProjectDue.deadline(["project": project, "id": id, "submitted": !done]); self.load(keepPlace: true) } }),
                                                               ("Delete Deadline", {
                                                                   Task { await ProjectDue.deadline(["project": project, "id": id, "delete": true]); self.load(keepPlace: true) } })])))
            }
            days = (-back..<ahead).map { offset in
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
        HStack(spacing: 8) {
            Picker("", selection: $model.everyProject) {
                Text("This project").tag(false)
                Text("All projects").tag(true)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            Spacer(minLength: 12)
            HStack(spacing: 8) {
                Button("Today") { go(to: Date()) }
                Button { picking = true } label: { Image(systemName: "calendar") }
                    .help("Go to a date")
                    .popover(isPresented: $picking) {
                        DatePicker("", selection: $chosen, displayedComponents: .date)
                            .datePickerStyle(.graphical).labelsHidden().padding(10)
                            .onChange(of: chosen) { _, day in picking = false; go(to: day) }
                    }
            }
            .buttonStyle(.borderless)
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
                            Text(day.date.formatted(.dateTime.month(.wide).year()).uppercased())
                                .font(.system(size: Scaled.s(13), weight: .semibold)).kerning(0.4).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Menu {
                            Button("Meeting") { newMeeting(on: day.date) }
                            Button("Deadline") { adding = (day.date, true) }
                            Button("Task") { adding = (day.date, false) }
                        } label: { Image(systemName: "plus").font(.system(size: Scaled.s(16), weight: .medium)) }
                            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                            .help("Add a meeting, deadline or task on this day")
                            .accessibilityLabel("Add on \(day.date.formatted(date: .complete, time: .omitted))")
                    }
                    ForEach(day.items) { item in
                        let row = HStack(spacing: 10) {
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
                        // Left-click opens it; right-click to tick it off or delete it.
                        Button(action: item.open) { row }.buttonStyle(.plain)
                            .contextMenu {
                                ForEach(item.menu.indices, id: \.self) { i in
                                    Button(item.menu[i].0, role: item.menu[i].0.hasPrefix("Delete") ? .destructive : nil, action: item.menu[i].1)
                                }
                            }
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
            .onChange(of: model.jumps) { _, _ in
                settled = false
                DispatchQueue.main.async {
                    scroll.scrollTo(Calendar.current.startOfDay(for: model.target), anchor: .top)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { settled = true }
                }
            }
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
        .sheet(isPresented: Binding(get: { adding != nil }, set: { if !$0 { adding = nil } })) {
            if let adding {
                AddToDay(date: adding.date, deadline: adding.deadline) { model.load(keepPlace: true) }
            }
        }
    }

    @State private var adding: (date: Date, deadline: Bool)?
    @State private var picking = false
    @State private var chosen = Date()

    /// Scrolls to a day, loading the weeks around it first if they aren't loaded yet.
    private func go(to date: Date) {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let offset = calendar.dateComponents([.day], from: today, to: calendar.startOfDay(for: date)).day ?? 0
        if offset < -model.back || offset >= model.ahead {
            model.back = max(model.back, -offset + 7)
            model.ahead = max(model.ahead, offset + 28)
            model.pending = date      // scrolls once the new days arrive
            model.load(keepPlace: true)
        } else {
            model.target = date
            model.jumps += 1
        }
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
    /// Due dates of projects not yet submitted: a submitted one stops warning.
    static func all() async -> [String: Date] {
        await read().due
    }

    /// Due dates still to come, and when projects were ticked off as submitted.
    static func read() async -> (due: [String: Date], submitted: [String: Date]) {
        let found = await everything()
        return (found.dates.filter { found.submitted[$0.key] == nil }, found.submitted)
    }

    /// Every project's due date, submitted or not, and when the submitted ones were ticked off.
    static func everything() async -> (dates: [String: Date], submitted: [String: Date]) {
        let format = DateFormatter()
        format.dateFormat = "yyyy-MM-dd"
        var dates: [String: Date] = [:], submitted: [String: Date] = [:]
        for (name, value) in await API.get("projects/due") ?? [:] {
            let entry = value as? [String: Any] ?? [:]
            if let date = (entry["date"] as? String).flatMap(format.date(from:)) { dates[name] = date }
            if let when = (entry["submitted"] as? String).flatMap(format.date(from:)) { submitted[name] = when }
        }
        return (dates, submitted)
    }

    /// Named deadlines besides projects' due dates ("Draft to supervisor").
    static func deadlines() async -> [(project: String, id: String, name: String, date: Date, submitted: Bool)] {
        let format = DateFormatter()
        format.dateFormat = "yyyy-MM-dd"
        var found: [(project: String, id: String, name: String, date: Date, submitted: Bool)] = []
        for (project, value) in await API.get("projects/due") ?? [:] {
            for d in (value as? [String: Any])?["deadlines"] as? [[String: Any]] ?? [] {
                guard let id = d["id"] as? String, let date = (d["date"] as? String).flatMap(format.date(from:)) else { continue }
                found.append((project, id, d["name"] as? String ?? "Deadline", date, d["submitted"] as? String != nil))
            }
        }
        return found
    }

    static func deadline(_ body: [String: Any]) async {
        _ = await API.post("projects/deadline", body)
        NotificationCenter.default.post(name: .refereeDueChanged, object: nil)
    }

    /// Ticks a project off as submitted, or back to not submitted.
    static func submit(_ project: String, _ submitted: Bool) async {
        _ = await API.post("projects/submitted", ["project": project, "submitted": submitted])
        NotificationCenter.default.post(name: .refereeDueChanged, object: nil)
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
            Divider()
            Button("Mark as Submitted") {
                Task { await ProjectDue.submit(project, true); done(); dismiss() }
            }
            .help("Stops the due date warning. Click “Submitted” in the sidebar to undo.")
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


/// ＋ on a day: a named deadline, or a task that comes from no meeting (kept in the project's
/// "Tasks without a meeting", and sent to your to-do app like action points).
struct AddToDay: View {
    let date: Date
    let deadline: Bool
    let done: () -> Void
    @State private var projects: [String] = []
    @State private var project = ""
    @State private var name = ""
    @State private var day = Date()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(deadline ? "New deadline" : "New task").font(Scaled.style(13, .semibold))
            TextField(deadline ? "Name" : "Task", text: $name).textFieldStyle(.roundedBorder)
            Picker("Project", selection: $project) { ForEach(projects, id: \.self) { Text($0).tag($0) } }
            DatePicker(deadline ? "Due" : "By", selection: $day, displayedComponents: .date)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add") { Task { await add(); done(); dismiss() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || project.isEmpty)
            }
        }
        .padding(18).frame(width: 340)
        .task {
            day = date
            let settings = await API.get("settings")
            projects = settings?["projects"] as? [String] ?? []
            project = settings?["project"] as? String ?? projects.first ?? ""
        }
    }

    private func add() async {
        let format = DateFormatter()
        format.dateFormat = "yyyy-MM-dd"
        let text = name.trimmingCharacters(in: .whitespaces)
        if deadline {
            await ProjectDue.deadline(["project": project, "name": text, "date": format.string(from: day)])
            return
        }
        // Added to the project's tasks without a meeting, made if it isn't there yet.
        let query = "meetings?project=\(project.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")"
        let found = (try? JSONDecoder().decode([Meeting].self, from: await API.request(query) ?? Data())) ?? []
        var list = found.first(where: \.isTasks) ?? {
            var list = Meeting()
            (list.kind, list.title, list.project) = ("tasks", "Tasks without a meeting", project)
            return list
        }()
        var action = Meeting.Action()
        (action.text, action.due) = (text, format.string(from: day))
        list.actions.append(action)
        if let body = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(list)) as? [String: Any] {
            _ = await API.post("meetings", body)
        }
    }
}
