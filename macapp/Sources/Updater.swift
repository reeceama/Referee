import AppKit
import CryptoKit
import Foundation

/// Keeps the downloadable Referee up to date from GitHub Releases: checks once a day (and on
/// request), and when there's a newer release, downloads it, checks it against the release's
/// SHA-256, swaps it in and restarts. Builds made from the code folder have no release name
/// and never update themselves.
@MainActor
final class Updater {

    static let shared = Updater()

    private let latest = URL(string: "https://api.github.com/repos/reeceama/Referee/releases/latest")!
    private var timer: Timer?
    private var busy = false

    /// The release this copy came from, stamped in by package.sh, e.g. "2026-10-11.2".
    var current: String? { Bundle.main.object(forInfoDictionaryKey: "RefereeRelease") as? String }

    func start() {
        guard current != nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { self.check(manually: false) }
        timer = Timer.scheduledTimer(withTimeInterval: 24 * 60 * 60, repeats: true) { _ in
            Task { @MainActor in self.check(manually: false) }
        }
    }

    func check(manually: Bool) {
        // Switched off on "What leaves this device": only a check asked for by hand goes out.
        if !manually && !WordSettings.privacySwitch("update_checks") { return }
        guard let current, !busy else {
            if manually && current == nil { tell("Updates are for the downloaded app", "This copy was built from the code folder: rebuild it to update.") }
            return
        }
        busy = true
        Task {
            defer { busy = false }
            var request = URLRequest(url: latest)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            guard let (data, _) = try? await URLSession.shared.data(for: request),
                  let release = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = release["tag_name"] as? String,
                  let assets = release["assets"] as? [[String: Any]] else {
                if manually { tell("Couldn't check for updates", "GitHub didn't answer. Check your internet connection and try again.") }
                return
            }
            guard Updater.isNewer(tag, than: current) else {
                if manually { tell("Referee is up to date", "You have the latest release (\(current)).") }
                return
            }
            let url = { (name: String) in (assets.first { $0["name"] as? String == name }?["browser_download_url"] as? String).flatMap(URL.init) }
            guard let zip = url("Referee-mac.zip"), let checksum = url("Referee-mac.zip.sha256") else {
                if manually { tell("Couldn't update", "The newest release doesn't include the Mac download.") }
                return
            }
            let ask = NSAlert()
            ask.messageText = "A new version of Referee is available"
            ask.informativeText = "Release \(tag) is out (you have \(current)). Referee will restart to update; your reading and settings stay as they are."
            ask.addButton(withTitle: "Update Now")
            ask.addButton(withTitle: "Later")
            NSApp.activate(ignoringOtherApps: true)
            guard ask.runModal() == .alertFirstButtonReturn else { return }
            await install(zip: zip, checksum: checksum)
        }
    }

    /// Release names are dates with an optional number after a full stop: 2026-10-11, 2026-10-11.2.
    /// Releases were named by date ("2026-10-12.2") until version numbers ("v1.0.0") took over:
    /// any version number is newer than any date, and version numbers compare part by part.
    static func isNewer(_ tag: String, than current: String) -> Bool {
        let versioned = { (name: String) in name.hasPrefix("v") }
        if versioned(tag) != versioned(current) { return versioned(tag) }
        if versioned(tag) {
            let numbers = { (name: String) in name.dropFirst().split(separator: ".").map { Int($0) ?? 0 } }
            let new = numbers(tag), old = numbers(current)
            for i in 0..<max(new.count, old.count) {
                let a = i < new.count ? new[i] : 0, b = i < old.count ? old[i] : 0
                if a != b { return a > b }
            }
            return false
        }
        func parts(_ name: String) -> (String, Int) {
            let pieces = name.split(separator: ".", maxSplits: 1)
            return (String(pieces.first ?? ""), pieces.count > 1 ? Int(pieces[1]) ?? 0 : 1)
        }
        let (newDate, newNumber) = parts(tag), (oldDate, oldNumber) = parts(current)
        return newDate != oldDate ? newDate > oldDate : newNumber > oldNumber
    }

    private func install(zip: URL, checksum: URL) async {
        let files = FileManager.default
        let work = files.temporaryDirectory.appendingPathComponent("referee-update-\(UUID().uuidString)")
        do {
            try files.createDirectory(at: work, withIntermediateDirectories: true)
            let (download, _) = try await URLSession.shared.download(from: zip)
            let (expectedData, _) = try await URLSession.shared.data(from: checksum)
            let expected = String(decoding: expectedData, as: UTF8.self).split(separator: " ").first.map(String.init) ?? ""
            let actual = SHA256.hash(data: try Data(contentsOf: download)).map { String(format: "%02x", $0) }.joined()
            guard !expected.isEmpty, expected == actual else {
                tell("Update stopped", "The download didn't match the release's checksum, so it wasn't installed.")
                return
            }
            let unzip = Process()
            unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            unzip.arguments = ["-x", "-k", download.path, work.path]
            try unzip.run()
            unzip.waitUntilExit()
            let newApp = work.appendingPathComponent("Referee.app")
            guard Bundle(url: newApp)?.bundleIdentifier == Bundle.main.bundleIdentifier else {
                tell("Update stopped", "The download wasn't a Referee app, so it wasn't installed.")
                return
            }
            // Swap the apps once this copy has quit, then open the new one.
            let script = """
            while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.5; done
            rm -rf "\(Bundle.main.bundlePath)"
            mv "\(newApp.path)" "\(Bundle.main.bundlePath)"
            open "\(Bundle.main.bundlePath)"
            rm -rf "\(work.path)"
            """
            let swap = Process()
            swap.executableURL = URL(fileURLWithPath: "/bin/sh")
            swap.arguments = ["-c", script]
            try swap.run()
            NSApp.terminate(nil)
        } catch {
            tell("Couldn't update", error.localizedDescription)
        }
    }

    private func tell(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
