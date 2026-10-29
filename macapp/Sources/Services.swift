import Foundation

/// Runs referee.py, the cross-platform launcher for Referee's Python parts (the server and the
/// Word helper), while the app is open. The launcher restarts any
/// part that stops; this restarts the launcher itself if it stops, and stops it when the app quits.
final class Services {

    let repo: URL
    private var launcher: Process?
    private var stopping = false

    init(repo: URL) {
        self.repo = repo
    }

    /// The downloadable app carries its own Python and Referee's code in Resources; a build from
    /// the code folder uses that folder's .venv instead.
    static var bundled: URL? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let code = resources.appendingPathComponent("referee")
        return FileManager.default.fileExists(atPath: code.appendingPathComponent("referee.py").path) ? resources : nil
    }

    func startAll() {
        stopping = false
        let process = Process()
        if let resources = Services.bundled {
            process.executableURL = resources.appendingPathComponent("python/bin/python3")
            process.currentDirectoryURL = resources.appendingPathComponent("referee")
        } else {
            process.executableURL = repo.appendingPathComponent(".venv/bin/python")
            process.currentDirectoryURL = repo
        }
        process.arguments = ["referee.py"]
        // The Word helper only when writing in Word (Settings → Writing).
        var environment = ProcessInfo.processInfo.environment
        environment["REFEREE_WORD"] = (UserDefaults.standard.string(forKey: "settingsWritingIn") ?? "word") == "word" ? "1" : "0"
        process.environment = environment
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                guard let self, !self.stopping else { return }
                self.startAll()
            }
        }
        do {
            try process.run()
            launcher = process
        } catch {
            NSLog("Referee couldn't start its launcher: \(error)")
        }
    }

    func stopAll() {
        stopping = true
        launcher?.terminate()  // the launcher stops every part before it exits
        launcher?.waitUntilExit()
    }
}
