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
    /// A Todoist task, edited in place when clicked.
    var todoist: [String: Any]? = nil
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

    /// Todoist, when it's the to-do app: its projects (for new tasks) and the task open for editing.
    @Published var todoistOn = false
    var currentProject = ""
    @Published var todoistProjects: [[String: Any]] = []
    @Published var editing: String?

    func closeTask(_ id: String) async {
        _ = await API.post("todoist/task/close", ["id": id], timeout: 20)
        load(keepPlace: true)
    }

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
            currentProject = current
            let inScope: (String?) -> Bool = { [everyProject] project in everyProject || (project ?? "") == current }
            let calendar = Calendar.current
            let today = calendar.startOfDay(for: Date())
            let start = calendar.date(byAdding: .day, value: -back, to: today)!
            let end = calendar.date(byAdding: .day, value: ahead, to: today)!
            var items: [(Date, AgendaItem)] = []
            let day = DateFormatter()
            day.dateFormat = "yyyy-MM-dd"

            // Todoist's tasks with dates, in projects named after Referee's (your project work, not the rest
            // of your life). Action points sent there show once, as the Todoist task.
            let settings = await API.get("settings")
            let refereeProjects = Set(settings?["projects"] as? [String] ?? [])
            var sentToTodoist = Set<String>()
            let todo = (await API.get("tasks"))?["app"] as? String == "todoist" ? await API.get("todoist/tasks") : nil
            todoistOn = todo?["ok"] as? Bool == true
            todoistProjects = todo?["projects"] as? [[String: Any]] ?? []
            for t in todo?["tasks"] as? [[String: Any]] ?? [] {
                let project = t["project"] as? String ?? ""
                guard everyProject ? refereeProjects.contains(project) : project == current,
                      let id = t["id"] as? String, let date = (t["date"] as? String).flatMap(day.date(from:)) else { continue }
                sentToTodoist.insert(id)
                let shown = max(date, date < today ? today : date)   // overdue ones on today
                var time: Date?
                if let at = t["time"] as? String, at.count == 5 {
                    time = calendar.date(bySettingHour: Int(at.prefix(2)) ?? 0, minute: Int(at.suffix(2)) ?? 0, second: 0, of: shown)
                }
                let priority = t["priority"] as? Int ?? 4
                let colour: Color = [1: .red, 2: .orange, 3: .blue][priority] ?? .secondary
                let detail = (date < today ? "Overdue · " : "") + "Todoist" + (priority < 4 ? " · P\(priority)" : "")
                    + ((t["repeat"] as? String ?? "never") != "never" ? " · Repeats" : "")
                items.append((shown, AgendaItem(id: "t-\(id)", kind: .task, title: t["content"] as? String ?? "", time: time,
                                                detail: detail, colour: colour, open: { [weak self] in self?.editing = self?.editing == "t-\(id)" ? nil : "t-\(id)" },
                                                menu: [("Mark as Done", { Task { await self.closeTask(id) } })], todoist: t)))
            }

            // Referee's own meetings.
            let allMeetings = await API.getList("meetings?project=all").filter { inScope($0["project"] as? String) }
            for m in allMeetings {
                // Its action points with due dates, on the day they're due (overdue ones on today).
                for a in m["actions"] as? [[String: Any]] ?? [] where a["done"] as? Bool != true
                    && !sentToTodoist.contains(a["task_id"] as? String ?? "-") {
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
                items.append((due, AgendaItem(id: "due-\(name)", kind: .task, title: "\(name) due", time: ProjectDue.timed(due) ? due : nil,
                                              detail: done ? "Submitted" : "Project deadline", colour: done ? .green : .red, open: {},
                                              menu: [(done ? "Mark as Not Submitted" : "Mark as Submitted", {
                                                         Task { await ProjectDue.submit(name, !done); self.load(keepPlace: true) } }),
                                                     ("Delete Due Date", {
                                                         Task {
                                                             _ = await API.post("projects/due", ["project": name])
                                                             NotificationCenter.default.post(name: .refereeDueChanged, object: nil)
                                                             self.load(keepPlace: true)
                                                         } })])))
            }
            // Named deadlines besides a project's due date.
            for deadline in await ProjectDue.deadlines() where inScope(deadline.project) && deadline.date >= start && deadline.date < end {
                let done = deadline.submitted
                let (project, id) = (deadline.project, deadline.id)
                items.append((deadline.date, AgendaItem(id: "dl-\(id)", kind: .task, title: deadline.name, time: ProjectDue.timed(deadline.date) ? deadline.date : nil,
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
                            Button("Task") {
                                if model.todoistOn { newTask = day.date } else { adding = (day.date, false) }
                            }
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
                        VStack(alignment: .leading, spacing: 6) {
                            Button(action: item.open) { row }.buttonStyle(.plain)
                                .contextMenu {
                                    ForEach(item.menu.indices, id: \.self) { i in
                                        Button(item.menu[i].0, role: item.menu[i].0.hasPrefix("Delete") ? .destructive : nil, action: item.menu[i].1)
                                    }
                                }
                            if let task = item.todoist, model.editing == item.id {
                                TodoistTaskEditor(task: task, projects: model.todoistProjects) {
                                    model.editing = nil; model.load(keepPlace: true)
                                }
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
        .sheet(isPresented: Binding(get: { newTask != nil }, set: { if !$0 { newTask = nil } })) {
            if let newTask {
                VStack(alignment: .leading, spacing: 10) {
                    Text("New task").font(.headline)
                    TodoistTaskEditor(task: ["date": TodoistTaskEditor.day.string(from: newTask)], projects: model.todoistProjects,
                                      project: model.currentProject) { self.newTask = nil; model.load(keepPlace: true) }
                    HStack { Spacer(); Button("Cancel") { self.newTask = nil }.keyboardShortcut(.cancelAction) }
                }
                .padding(20).frame(width: 480)
            }
        }
        .sheet(isPresented: Binding(get: { adding != nil }, set: { if !$0 { adding = nil } })) {
            if let adding {
                AddToDay(date: adding.date, deadline: adding.deadline) { model.load(keepPlace: true) }
            }
        }
    }

    @State private var adding: (date: Date, deadline: Bool)?
    @State private var newTask: Date?   // a new Todoist task on this day
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
            if let date = (entry["date"] as? String).flatMap(format.date(from:)) { dates[name] = at(entry["time"], on: date) }
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
                found.append((project, id, d["name"] as? String ?? "Deadline", at(d["time"], on: date), d["submitted"] as? String != nil))
            }
        }
        return found
    }

    /// A day with its time ("17:00"), when one was set.
    static func at(_ time: Any?, on day: Date) -> Date {
        guard let text = time as? String, text.count == 5, let h = Int(text.prefix(2)), let m = Int(text.suffix(2)) else { return day }
        return Calendar.current.date(bySettingHour: h, minute: m, second: 0, of: day) ?? day
    }

    /// Whether a due date has a time of day (a date alone is midnight).
    static func timed(_ date: Date) -> Bool {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        return parts.hour != 0 || parts.minute != 0
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
        let clock = timed(date) ? " at " + date.formatted(date: .omitted, time: .shortened) : ""
        let when = date.formatted(.dateTime.day().month(.abbreviated)) + clock
        switch days {
        case ..<(-1): return "\(-days) days overdue · \(when)"
        case -1: return "1 day overdue · \(when)"
        case 0: return date < Date() && timed(date) ? "Overdue · today\(clock)" : "Due today\(clock)"
        case 1: return "Due tomorrow\(clock)"
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
    @State private var timed = false
    @State private var time = Calendar.current.date(bySettingHour: 17, minute: 0, second: 0, of: Date()) ?? Date()
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
                Toggle("Time", isOn: $timed)
                if timed { DatePicker("", selection: $time, displayedComponents: .hourAndMinute).labelsHidden() }
                Button("Set") {
                    let format = DateFormatter(); format.dateFormat = "yyyy-MM-dd"
                    save(["date": format.string(from: date)].merging(timed ? ["time": TodoistTaskEditor.clock.string(from: time)] : [:]) { a, _ in a })
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
        .frame(width: 440)
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
    @State private var timed = false
    @State private var time = Calendar.current.date(bySettingHour: 17, minute: 0, second: 0, of: Date()) ?? Date()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(deadline ? "New deadline" : "New task").font(Scaled.style(13, .semibold))
            TextField(deadline ? "Name" : "Task", text: $name).textFieldStyle(.roundedBorder)
            Picker("Project", selection: $project) { ForEach(projects, id: \.self) { Text($0).tag($0) } }
            DatePicker(deadline ? "Due" : "By", selection: $day, displayedComponents: .date)
            if deadline {
                HStack {
                    Toggle("Time", isOn: $timed)
                    if timed { DatePicker("", selection: $time, displayedComponents: .hourAndMinute).labelsHidden() }
                }
            }
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
            await ProjectDue.deadline(["project": project, "name": text, "date": format.string(from: day),
                                       "time": timed ? TodoistTaskEditor.clock.string(from: time) : NSNull()])
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


/// A Todoist task, edited in Referee: name, notes, date and time, repeat, priority, project and labels
/// (reminders are left to your calendar app, so they aren't sent twice). Saving sends it to Todoist at once; a new task (no "id") is created there.
struct TodoistTaskEditor: View {

    static let day: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f }()
    static let clock: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f }()

    let task: [String: Any]
    let projects: [[String: Any]]
    var project = ""
    let done: () -> Void

    @State private var content = ""
    @State private var notes = ""
    @State private var dated = true
    @State private var date = Date()
    @State private var timed = false
    @State private var time = Date()
    @State private var repeatEvery = "never"
    @State private var priority = 4
    @State private var projectID = ""
    @State private var labels = ""
    @State private var newProject = ""
    @State private var naming = false
    @State private var extraProjects: [[String: Any]] = []
    @State private var busy = false
    @State private var problem: String?
    @State private var deleting = false

    private var isNew: Bool { task["id"] == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Task", text: $content).textFieldStyle(.roundedBorder)
            TextField("Notes", text: $notes, axis: .vertical).lineLimit(1...4).textFieldStyle(.roundedBorder)
            HStack(spacing: 10) {
                Toggle("Date", isOn: $dated)
                if dated {
                    DatePicker("", selection: $date, displayedComponents: .date).labelsHidden()
                    Toggle("Time", isOn: $timed)
                    if timed { DatePicker("", selection: $time, displayedComponents: .hourAndMinute).labelsHidden() }
                }
                Spacer()
            }
            HStack(spacing: 10) {
                Picker("Priority", selection: $priority) {
                    ForEach(1...4, id: \.self) { Text("P\($0)").tag($0) }
                }.fixedSize()
                if dated {
                    Picker("Repeat", selection: $repeatEvery) {
                        Text("Never").tag("never"); Text("Daily").tag("daily"); Text("Weekly").tag("weekly")
                        Text("Monthly").tag("monthly"); Text("Yearly").tag("yearly")
                        if task["repeat"] as? String == "custom" { Text(task["repeat_text"] as? String ?? "Custom").tag("custom") }
                    }.fixedSize()
                }
                Spacer()
            }
            HStack(spacing: 10) {
                Picker("Project", selection: $projectID) {
                    ForEach(Array((projects + extraProjects).enumerated()), id: \.offset) { _, p in
                        Text(p["name"] as? String ?? "").tag(p["id"] as? String ?? "")
                    }
                }.fixedSize()
                if naming {
                    TextField("Project name", text: $newProject).textFieldStyle(.roundedBorder).frame(width: 160)
                        .onSubmit { makeProject() }
                    Button("Add") { makeProject() }.disabled(newProject.trimmingCharacters(in: .whitespaces).isEmpty)
                } else {
                    Button("New project") { naming = true }.buttonStyle(.link)
                }
                Spacer()
            }
            TextField("Labels, separated by commas", text: $labels).textFieldStyle(.roundedBorder)
            if let problem { Text(problem).font(Scaled.style(11, .regular)).foregroundStyle(.red) }
            HStack {
                if !isNew {
                    Button("Delete", role: .destructive) { deleting = true }
                }
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button(isNew ? "Add to Todoist" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy || content.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
        .confirmationDialog("Delete “\(content)”?", isPresented: $deleting) {
            Button("Delete", role: .destructive) { remove() }
        } message: { Text("It’s deleted in Todoist too.") }
        .onAppear(perform: fill)
    }

    private func fill() {
        content = task["content"] as? String ?? ""
        notes = task["description"] as? String ?? ""
        let day = (task["date"] as? String).flatMap(Self.day.date(from:))
        dated = day != nil || isNew
        date = day ?? Date()
        if let at = task["time"] as? String, let t = Self.clock.date(from: at) { timed = true; time = t }
        repeatEvery = task["repeat"] as? String ?? "never"
        priority = task["priority"] as? Int ?? 4
        labels = (task["labels"] as? [String] ?? []).joined(separator: ", ")
        projectID = task["project_id"] as? String
            ?? projects.first { $0["name"] as? String == project }?["id"] as? String
            ?? projects.first?["id"] as? String ?? ""
    }

    private func makeProject() {
        let name = newProject.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        Task {
            if let made = await API.post("todoist/project", ["name": name], timeout: 20), made["ok"] as? Bool == true {
                extraProjects.append(made)
                projectID = made["id"] as? String ?? projectID
                (naming, newProject) = (false, "")
            } else {
                problem = "Couldn’t make the project in Todoist. Try again."
            }
        }
    }

    private func save() {
        busy = true
        problem = nil
        var body: [String: Any] = [
            "content": content, "description": notes, "priority": priority, "project_id": projectID,
            "labels": labels.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty },
            "repeat": dated ? repeatEvery : "never", "repeat_text": task["repeat_text"] as? String ?? "",
            "was_project": task["project_id"] as? String ?? ""]
        if let id = task["id"] { body["id"] = id }
        if dated { body["date"] = Self.day.string(from: date) }
        if dated && timed { body["time"] = Self.clock.string(from: time) }
        Task {
            let sent = await API.post("todoist/task", body, timeout: 30)
            busy = false
            if sent?["ok"] as? Bool == true {
                done()
            } else {
                problem = "Couldn’t save to Todoist. Try again."
            }
        }
    }

    private func remove() {
        guard let id = task["id"] as? String else { return }
        Task {
            _ = await API.post("todoist/task/delete", ["id": id], timeout: 20)
            done()
        }
    }
}
