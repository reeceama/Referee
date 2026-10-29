import SwiftUI

/// Importing notes: every Markdown file in a folder (such as an Obsidian vault), or one folder of
/// Apple Notes, read through Notes' scripting (macOS asks permission the first time).
enum NoteImport {

    /// Runs a JavaScript for Automation script and returns what it prints.
    static func script(_ source: String) async -> String? {
        await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-l", "JavaScript", "-e", source]
            let out = Pipe()
            process.standardOutput = out
            process.standardError = Pipe()
            guard (try? process.run()) != nil else { return nil }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return process.terminationStatus == 0 ? String(data: data, encoding: .utf8) : nil
        }.value
    }

    static func appleNotesFolders() async -> [String]? {
        guard let text = await script("JSON.stringify(Application('Notes').folders.name())"),
              let names = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String] else { return nil }
        return Array(Set(names)).sorted()
    }

    static func appleNotes(in folder: String) async -> [[String: String]]? {
        let name = (try? String(data: JSONSerialization.data(withJSONObject: [folder]), encoding: .utf8)) ?? "[\"\"]"
        let source = """
        const f = Application('Notes').folders.whose({name: \(name)[0]})()[0];
        const titles = f.notes.name(), bodies = f.notes.body();
        JSON.stringify(titles.map((t, i) => ({title: t, html: bodies[i]})))
        """
        guard let text = await script(source),
              let notes = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: String]] else { return nil }
        return notes
    }

    static func summary(_ result: [String: Any]?) -> String {
        guard let result, result["ok"] as? Bool == true else {
            return result?["reason"] as? String ?? "Referee couldn't import those notes."
        }
        let added = result["added"] as? Int ?? 0, skipped = result["skipped"] as? Int ?? 0
        var text = added == 1 ? "Imported 1 note" : "Imported \(added) notes"
        if skipped > 0 { text += ", skipped \(skipped) already here" }
        return text + "."
    }
}

/// Choosing which Apple Notes folder to bring in.
struct AppleNotesImportSheet: View {

    let project: String
    let done: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var folders: [String]?
    @State private var folder = ""
    @State private var failed = false
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Import from Apple Notes").font(Scaled.style(13, .semibold))
            if failed {
                Text("Referee couldn't read Apple Notes. If you said no when macOS asked, allow Referee under System Settings → Privacy & Security → Automation.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let folders {
                Picker("Folder", selection: $folder) {
                    ForEach(folders, id: \.self) { Text($0).tag($0) }
                }
                Text(project.isEmpty ? "Each note in the folder becomes a Referee note, with no project."
                                     : "Each note in the folder becomes a Referee note in \(project).")
                    .font(Scaled.style(12, .regular))
                    .foregroundStyle(.secondary)
            } else {
                HStack { ProgressView().controlSize(.small); Text("Reading your Notes folders…").foregroundStyle(.secondary) }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(working ? "Importing…" : "Import") { run() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(folder.isEmpty || working)
            }
        }
        .padding(20)
        .frame(width: 420)
        .task {
            folders = await NoteImport.appleNotesFolders()
            if folders == nil { failed = true }
            folder = folders?.first(where: { $0 == "Notes" }) ?? folders?.first ?? ""
        }
    }

    private func run() {
        working = true
        Task {
            guard let notes = await NoteImport.appleNotes(in: folder) else { failed = true; working = false; return }
            let result = await API.post("notes/import", ["project": project, "notes": notes], timeout: 120)
            done(NoteImport.summary(result))
            dismiss()
        }
    }
}
