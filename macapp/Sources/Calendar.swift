import EventKit
import SwiftUI

/// Meetings from the calendars on this Mac: Apple Calendar, and the Google, Outlook and iCloud
/// calendars added to it, which Fantastical shows too. Picking an event starts that meeting's notes
/// with its title, date and attendees. Read only: nothing in the calendar is changed.

struct CalendarEvent: Identifiable {
    let id: String
    let title: String
    let start: Date
    let attendees: String
    var calendar = ""
    var colour: Color = .accentColor

    /// "2026-10-17", the format meetings keep.
    var day: String {
        let format = DateFormatter()
        format.dateFormat = "yyyy-MM-dd"
        return format.string(from: start)
    }
}

@MainActor
final class CalendarModel: ObservableObject {

    @Published var events: [CalendarEvent] = []
    @Published var message: String?
    @Published var calendars: [(id: String, name: String, colour: Color)] = []
    /// The calendars meetings come from, chosen in the list's menu; none chosen means all of them.
    @Published var chosen: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "meetingCalendars") ?? []) {
        didSet { UserDefaults.standard.set(Array(chosen), forKey: "meetingCalendars"); load() }
    }
    private let store = EKEventStore()

    /// How many days back are loaded: two to start; scrolling to the end of the list adds a month,
    /// as far back as you like.
    @Published var back = 2

    /// A week ahead, then back in time, newest first: the meetings just had or coming up are at the top.
    func load() {
        Task {
            do {
                guard try await store.requestFullAccessToEvents() else {
                    message = "Referee can't see your calendars. Allow it in System Settings → Privacy & Security → Calendars."
                    return
                }
            } catch {
                message = "Couldn't open your calendars."
                return
            }
            let all = store.calendars(for: .event)
            calendars = all.map { ($0.calendarIdentifier, $0.title, Color(cgColor: $0.cgColor)) }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            let using = chosen.isEmpty ? nil : all.filter { chosen.contains($0.calendarIdentifier) }
            let now = Date()
            let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-Double(back) * 86_400),
                                                     end: now.addingTimeInterval(7 * 86_400), calendars: using)
            // The same event in two calendars (a Google calendar added twice, say) shows once.
            var seen = Set<String>()
            events = store.events(matching: predicate)
                .filter { !$0.isAllDay }
                .sorted { $0.startDate > $1.startDate }
                .filter { seen.insert("\($0.title ?? "")|\($0.startDate.timeIntervalSince1970)").inserted }
                .map { event in
                    let people = (event.attendees ?? []).compactMap { $0.name ?? $0.url.absoluteString.replacingOccurrences(of: "mailto:", with: "") }
                    // Each occurrence its own: a repeating event's occurrences share one identifier.
                    return CalendarEvent(id: "\(event.eventIdentifier ?? UUID().uuidString)@\(event.startDate.timeIntervalSince1970)",
                                         title: event.title ?? "Meeting", start: event.startDate,
                                         attendees: people.joined(separator: ", "),
                                         calendar: event.calendar.title, colour: Color(cgColor: event.calendar.cgColor))
                }
            message = events.isEmpty && back > 365 * 4 ? "No events in your calendars." : nil
            // Nothing in this range yet: look further back straight away.
            if events.isEmpty && back <= 365 * 4 { back += 30; load() }
        }
    }
}

/// The calendar button in Meetings: upcoming events, one click to start a meeting from one.
struct CalendarButton: View {

    let start: (CalendarEvent) -> Void
    @StateObject private var calendar = CalendarModel()
    @State private var open = false

    var body: some View {
        Button { open = true; calendar.load() } label: { HeaderIcon("calendar.badge.plus") }
            .buttonStyle(.borderless)
            .help("New meeting from your calendar")
            .popover(isPresented: $open, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        FieldLabel("From your calendar")
                        Spacer()
                        // Which calendars: all, or the ones ticked (kept for next time).
                        Menu {
                            Button("All Calendars") { calendar.chosen = [] }
                            Divider()
                            ForEach(calendar.calendars, id: \.id) { cal in
                                Toggle(cal.name, isOn: Binding(
                                    get: { calendar.chosen.contains(cal.id) },
                                    set: { on in
                                        var next = calendar.chosen
                                        if on { next.insert(cal.id) } else { next.remove(cal.id) }
                                        calendar.chosen = next
                                    }))
                            }
                        } label: {
                            Text(calendar.chosen.isEmpty ? "All calendars" : calendar.chosen.count == 1
                                 ? (calendar.calendars.first { calendar.chosen.contains($0.id) }?.name ?? "1 calendar")
                                 : "\(calendar.chosen.count) calendars")
                                .font(Scaled.style(10, .regular))
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }
                    .padding(.bottom, 8)
                    if let message = calendar.message {
                        Text(message).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    ScrollView {
                        // Lazy, so only rows actually scrolled to load more.
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(calendar.events) { event in
                                Button {
                                    start(event)
                                    open = false
                                } label: {
                                    HStack(alignment: .top, spacing: 8) {
                                        Circle().fill(event.colour).frame(width: 8, height: 8).padding(.top, 5)
                                            .accessibilityHidden(true)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(event.title).lineLimit(1)
                                            Text(event.start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
                                                 + (event.calendar.isEmpty ? "" : " · \(event.calendar)"))
                                                .font(Scaled.style(10, .regular)).foregroundStyle(.secondary)
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 6)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                // The last one shown: load a month further back.
                                .onAppear { if event.id == calendar.events.last?.id && calendar.back < 365 * 20 { calendar.back += 30; calendar.load() } }
                                Hairline()
                            }
                        }
                    }
                    .frame(maxHeight: 320)
                }
                .padding(14)
                .frame(width: 300)
            }
    }
}
