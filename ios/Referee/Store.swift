import Foundation
import SwiftUI

// Referee on the iPhone reads the copy Referee for Mac keeps in iCloud Drive → Referee, and
// writes each change as a small file in Referee/Inbox, which the Mac applies. The phone never
// edits the copy itself, so two devices never write the same file. Changes show here straight
// away, and stay shown until the Mac's next copy includes them.

struct Source: Codable, Identifiable, Hashable {
    var url: String
    var name: String?
    var title: String?
    var author: String?
    var date: String?
    var site: String?
    var project: String?
    var kept: Bool?
    var doi: String?
    var cite_key: String?

    var id: String { url }
    var shown: String { [name, title].compactMap { $0 }.first { !$0.isEmpty } ?? url }
    var isPDF: Bool { url.lowercased().hasSuffix(".pdf") }
    var year: String? { date.map { String($0.prefix(4)) } }
}

struct Note: Codable, Identifiable, Hashable {
    var id = UUID().uuidString.lowercased()
    var project: String = ""
    var text: String = ""
    var url: String = ""
    var page: Int?
    var to: Int?
    var created: Double? = Date().timeIntervalSince1970

    var pages: String? {
        guard let page else { return nil }
        if let to { return "pp. \(page)–\(to)" }
        return "p. \(page)"
    }
}

struct Meeting: Codable, Identifiable, Hashable {
    struct Action: Codable, Identifiable, Hashable {
        var id = UUID().uuidString
        var text = ""
        var who = ""
        var due = ""
        var done = false
    }
    var id = UUID().uuidString
    var project = ""
    var date = Day.today
    var title = ""
    var attendees = ""
    var notes = ""
    var decisions = ""
    var actions: [Action] = []
    var created: Double? = Date().timeIntervalSince1970
}

struct AIUse: Codable, Identifiable, Hashable {
    var id = UUID().uuidString
    var project = ""
    var date = Day.today
    var tool = ""
    var version = ""
    var purpose = ""
    var prompt = ""
    var response = ""
    var checked = ""
    var created: Double? = Date().timeIntervalSince1970
}

struct Claim: Codable, Hashable {
    struct Cited: Codable, Hashable { var title: String?; var url: String? }
    var sentence: String
    var label: String
    var quote: String?
    var source: Cited?
    var page: Int?
    var confidence: Double?
    var document: String?
    var project: String?
    var at: Double?
}

struct Projects: Codable { var current: String?; var projects: [String] }

enum Day {
    static var today: String { format.string(from: Date()) }
    static let format: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f }()
    /// "2026-10-17" -> "17 October 2026"
    static func long(_ day: String) -> String {
        guard let date = format.date(from: day) else { return day }
        return date.formatted(.dateTime.day().month(.wide).year())
    }
}

@MainActor
final class Store: ObservableObject {

    static let shared = Store()

    @Published var folder: URL?
    @Published var sources: [Source] = []
    @Published var notes: [Note] = []
    @Published var meetings: [Meeting] = []
    @Published var aiUse: [AIUse] = []
    @Published var claims: [Claim] = []
    @Published var projects: [String] = []
    @Published var project = ""
    @Published var updated: Date?
    @Published var waiting = 0          // changes in the Inbox the Mac hasn't applied yet

    private let bookmarkKey = "refereeFolder"

    init() {
        if let data = UserDefaults.standard.data(forKey: bookmarkKey) {
            var stale = false
            folder = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale)
        }
        project = UserDefaults.standard.string(forKey: "project") ?? ""
    }

    /// The iCloud Drive → Referee folder, chosen once in the Files picker.
    func choose(_ url: URL) {
        guard url.startAccessingSecurityScopedResource() else { return }
        defer { url.stopAccessingSecurityScopedResource() }
        if let data = try? url.bookmarkData() { UserDefaults.standard.set(data, forKey: bookmarkKey) }
        folder = url
        load()
    }

    private func access<T>(_ body: (URL) throws -> T) -> T? {
        guard let folder else { return nil }
        let opened = folder.startAccessingSecurityScopedResource()
        defer { if opened { folder.stopAccessingSecurityScopedResource() } }
        return try? body(folder)
    }

    private func read<T: Decodable>(_ name: String, _ type: T.Type) -> T? {
        access { folder in
            var result: T?
            var failure: NSError?
            NSFileCoordinator().coordinate(readingItemAt: folder.appendingPathComponent(name), options: [], error: &failure) { url in
                result = try? JSONDecoder().decode(T.self, from: Data(contentsOf: url))
            }
            return result
        } ?? nil
    }

    /// Reads the Mac's latest copy, then lays this phone's waiting changes over it.
    func load() {
        sources = read("library.json", [Source].self) ?? []
        notes = read("notes.json", [Note].self) ?? []
        meetings = read("meetings.json", [Meeting].self) ?? []
        aiUse = read("ai-use.json", [AIUse].self) ?? []
        claims = read("evidence.json", [Claim].self) ?? []
        if let found = read("projects.json", Projects.self) {
            projects = found.projects
            if project.isEmpty || !projects.contains(project) { project = found.current ?? projects.first ?? "" }
        }
        if let at = read("updated.json", [String: Double].self)?["at"] { updated = Date(timeIntervalSince1970: at) }
        for change in pending() { applyLocally(change) }
    }

    // MARK: Changes, through the Inbox

    private func pending() -> [[String: Any]] {
        access { folder in
            let inbox = folder.appendingPathComponent("Inbox")
            let files = (try? FileManager.default.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil)) ?? []
            let mine = files.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            waiting = mine.count
            return mine.compactMap { try? JSONSerialization.jsonObject(with: Data(contentsOf: $0)) as? [String: Any] }
        } ?? []
    }

    private func send(_ change: [String: Any]) {
        access { folder in
            let inbox = folder.appendingPathComponent("Inbox", isDirectory: true)
            try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let file = inbox.appendingPathComponent("\(stamp)-\(UUID().uuidString.prefix(8)).json")
            try JSONSerialization.data(withJSONObject: change).write(to: file, options: .atomic)
            waiting += 1
        }
        applyLocally(change)
    }

    private func encode<T: Encodable>(_ value: T) -> Any {
        (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(value))) ?? [:]
    }

    private func decode<T: Decodable>(_ value: Any?, _ type: T.Type) -> T? {
        guard let value, let data = try? JSONSerialization.data(withJSONObject: value) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    /// Shows a change straight away, before the Mac has applied it.
    private func applyLocally(_ change: [String: Any]) {
        switch change["type"] as? String {
        case "note":
            if let note = decode(change["note"], Note.self) { notes.removeAll { $0.id == note.id }; notes.append(note) }
        case "delete-note":
            notes.removeAll { $0.id == change["id"] as? String }
        case "meeting":
            if let meeting = decode(change["meeting"], Meeting.self) { meetings.removeAll { $0.id == meeting.id }; meetings.append(meeting) }
        case "delete-meeting":
            meetings.removeAll { $0.id == change["id"] as? String }
        case "action":
            if let m = meetings.firstIndex(where: { $0.id == change["meeting"] as? String }),
               let a = meetings[m].actions.firstIndex(where: { $0.id == change["action"] as? String }) {
                meetings[m].actions[a].done = change["done"] as? Bool ?? false
            }
        case "ai-use":
            if let entry = decode(change["entry"], AIUse.self) { aiUse.removeAll { $0.id == entry.id }; aiUse.append(entry) }
        case "delete-ai-use":
            aiUse.removeAll { $0.id == change["id"] as? String }
        case "rename-source":
            if let i = sources.firstIndex(where: { $0.url == change["url"] as? String }) { sources[i].name = change["name"] as? String }
        case "project":
            project = change["project"] as? String ?? project
        default:
            break
        }
    }

    func save(_ note: Note) { send(["type": "note", "note": encode(note)]) }
    func delete(note: Note) { send(["type": "delete-note", "id": note.id]) }
    func save(_ meeting: Meeting) { send(["type": "meeting", "meeting": encode(meeting)]) }
    func delete(meeting: Meeting) { send(["type": "delete-meeting", "id": meeting.id]) }
    func tick(_ action: Meeting.Action, in meeting: Meeting, done: Bool) {
        send(["type": "action", "meeting": meeting.id, "action": action.id, "done": done])
    }
    func save(_ entry: AIUse) { send(["type": "ai-use", "entry": encode(entry)]) }
    func delete(entry: AIUse) { send(["type": "delete-ai-use", "id": entry.id]) }
    func rename(_ source: Source, to name: String) { send(["type": "rename-source", "url": source.url, "name": name]) }
    /// A link for the Mac to fetch and save, into the current project.
    func saveLink(_ link: String) { send(["type": "source", "url": link, "project": project]) }

    func switchProject(_ name: String) {
        project = name
        UserDefaults.standard.set(name, forKey: "project")
        send(["type": "project", "project": name])
    }

    // MARK: The current project

    var projectSources: [Source] { sources.filter { project.isEmpty || $0.project == project } }
    var projectNotes: [Note] { notes.filter { project.isEmpty || $0.project == project }.sorted { ($0.created ?? 0) > ($1.created ?? 0) } }
    var projectMeetings: [Meeting] { meetings.filter { project.isEmpty || $0.project == project }.sorted { $0.date > $1.date } }
    var projectAIUse: [AIUse] { aiUse.filter { project.isEmpty || $0.project == project }.sorted { $0.date > $1.date } }
    var projectClaims: [Claim] { claims.filter { project.isEmpty || $0.project == project } }

    func title(_ url: String) -> String { sources.first { $0.url == url }?.shown ?? url }
}
