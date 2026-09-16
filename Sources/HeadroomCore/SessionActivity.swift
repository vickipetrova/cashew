import Foundation
import HeadroomShared

/// One live Claude Code session, ready to display.
struct Session: Equatable {
    let id: String
    let state: SessionState
    let label: String
    let project: String
    let branch: String?
    let turnStartedAt: Date?
    let updatedAt: Date
}

/// Reads the session files `headroom-hook` writes.
///
/// Shaped like `StatuslineFeed`: the directory is injected so tests never reach the real one, and
/// every file is parsed defensively (hard rule 3). The three checks that don't come from the file —
/// is the process alive, was the turn interrupted, which branch — are injected too.
///
/// Main thread only.
struct SessionActivity {
    let directory: URL
    var isAlive: (Int32) -> Bool = SessionActivity.processIsAlive
    var interrupted: (String, Date) -> Bool = { TranscriptTail.shared.wasInterrupted(transcript: $0, after: $1) }
    var branch: (String) -> String? = { GitBranch.shared.branch(cwd: $0) }

    /// Never call from a test — it is the running app's own folder.
    static let `default` = SessionActivity(directory: SessionFiles.defaultDirectory)

    /// Without a process to check, a session still "working" this long after its last event is
    /// assumed to have stopped without saying so.
    static let unownedWorkingLimit: TimeInterval = 2 * 3600
    /// Past this, a file is ignored whatever it says. Also covers a pid recycled by another process.
    static let ignoredAfter: TimeInterval = 24 * 3600

    func sessions(now: Date = Date()) -> [Session] {
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return [] }

        var records: [(id: String, record: SessionRecord)] = []
        for name in names where name.hasSuffix(".json") {
            let url = directory.appendingPathComponent(name)
            guard let record = SessionFiles.read(url) else { continue }
            if let pid = record.pid, !isAlive(pid) {
                // Headroom's own directory, so it cleans up after a session that was killed.
                try? fileManager.removeItem(at: url)
                continue
            }
            guard record.started, now.timeIntervalSince(record.updatedAt) <= Self.ignoredAfter else { continue }
            records.append((String(name.dropLast(".json".count)), record))
        }

        let projects = Self.projectNames(cwds: records.map { $0.record.cwd })
        let sessions = zip(records, projects).map { entry, project -> Session in
            let (state, label) = effectiveState(entry.record, now: now)
            return Session(id: entry.id, state: state, label: label, project: project,
                           branch: branch(entry.record.cwd), turnStartedAt: entry.record.turnStartedAt,
                           updatedAt: entry.record.updatedAt)
        }
        return sessions.sorted {
            let (left, right) = (Self.priority($0.state), Self.priority($1.state))
            return left != right ? left < right : $0.updatedAt > $1.updatedAt
        }
    }

    private func effectiveState(_ record: SessionRecord, now: Date) -> (SessionState, String) {
        guard record.state != .idle else { return (.idle, "") }
        if record.pid == nil, now.timeIntervalSince(record.updatedAt) > Self.unownedWorkingLimit {
            return (.idle, "")
        }
        // Esc fires no hook, including at a permission prompt.
        if !record.transcript.isEmpty, interrupted(record.transcript, record.updatedAt) {
            return (.idle, "")
        }
        return (record.state, record.label)
    }

    private static func priority(_ state: SessionState) -> Int {
        switch state {
        case .permission: return 0
        case .tool: return 1
        case .thinking: return 2
        case .idle: return 3
        }
    }

    /// `kill(pid, 0)` sends nothing; it only asks whether the process exists. `EPERM` means it does
    /// but belongs to someone else, which still counts as alive.
    static func processIsAlive(_ pid: Int32) -> Bool {
        guard pid > 1 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    /// Folder names, with the parent added where two *different* folders share a name.
    static func projectNames(cwds: [String]) -> [String] {
        let bases = cwds.map { $0.isEmpty ? "Claude Code" : ($0 as NSString).lastPathComponent }
        var folders: [String: Set<String>] = [:]
        for (base, cwd) in zip(bases, cwds) { folders[base, default: []].insert(cwd) }
        return zip(bases, cwds).map { base, cwd in
            guard (folders[base]?.count ?? 0) > 1 else { return base }
            let parent = ((cwd as NSString).deletingLastPathComponent as NSString).lastPathComponent
            return parent.isEmpty ? base : "\(parent)/\(base)"
        }
    }

    // MARK: Copy — here rather than in `MenuController`, which stays free of Claude-specific strings.

    static let menuHeading = "CLAUDE CODE"
    static let settingsHeading = "CLAUDE CODE SESSIONS"
    static let trackMenuTitle = "Track Claude Code Sessions"
    static let idleLabel = "Idle"
    static let workingLabel = "Working"
    static let endedLabel = "Ended"

    static func moreLabel(_ count: Int) -> String {
        "+\(count) more \(count == 1 ? "session" : "sessions")"
    }
}
