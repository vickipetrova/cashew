import Foundation
import Testing

@testable import HeadroomCore
@testable import HeadroomShared

@Suite struct SessionActivityTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("headroom-activity-\(UUID().uuidString)", isDirectory: true)

    private func activity(alive: @escaping (Int32) -> Bool = { _ in true },
                          interrupted: @escaping (String, Date) -> Bool = { _, _ in false },
                          branch: @escaping (String) -> String? = { _ in nil }) -> SessionActivity {
        SessionActivity(directory: directory, isAlive: alive, interrupted: interrupted, branch: branch)
    }

    private func seed(_ id: String, _ state: SessionState = .thinking, cwd: String = "/dev/headroom",
                      pid: Int32? = 4242, started: Bool = true, age: TimeInterval = 5,
                      transcript: String = "/t.jsonl") throws {
        let record = SessionRecord(state: state, label: state == .tool ? "Editing" : "", cwd: cwd,
                                   transcript: transcript, pid: pid, started: started,
                                   turnStartedAt: now.addingTimeInterval(-age - 60),
                                   updatedAt: now.addingTimeInterval(-age))
        try SessionFiles.write(record, to: try #require(SessionFiles.url(for: id, in: directory)))
    }

    @Test func noDirectoryMeansNoSessions() {
        #expect(activity().sessions(now: now).isEmpty)
    }

    @Test func readsASession() throws {
        try seed("a", .tool)
        let sessions = activity(branch: { _ in "main" }).sessions(now: now)
        #expect(sessions.count == 1)
        #expect(sessions.first?.id == "a")
        #expect(sessions.first?.state == .tool)
        #expect(sessions.first?.label == "Editing")
        #expect(sessions.first?.project == "headroom")
        #expect(sessions.first?.branch == "main")
    }

    @Test func unstartedSessionsAreHidden() throws {
        try seed("a", .idle, started: false)
        #expect(activity().sessions(now: now).isEmpty)
    }

    @Test func aMalformedFileCostsOnlyItself() throws {
        try seed("good")
        try Data("not json".utf8).write(to: directory.appendingPathComponent("bad.json"))
        try Data("{}".utf8).write(to: directory.appendingPathComponent("empty.json"))
        #expect(activity().sessions(now: now).map(\.id) == ["good"])
    }

    @Test func deadProcessesAreRemovedFromDisk() throws {
        try seed("dead", pid: 111)
        try seed("live", pid: 222)
        #expect(activity(alive: { $0 != 111 }).sessions(now: now).map(\.id) == ["live"])
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("dead.json").path))
    }

    @Test func workingWithoutAnOwnerGoesIdleAfterTwoHours() throws {
        try seed("fresh", pid: nil, age: 60)
        try seed("stale", pid: nil, age: 2 * 3600 + 1)
        let states = Dictionary(uniqueKeysWithValues: activity().sessions(now: now).map { ($0.id, $0.state) })
        #expect(states["fresh"] == .thinking)
        #expect(states["stale"] == .idle)
    }

    /// Also guards PID reuse: a recycled pid would otherwise keep a long-gone session alive.
    @Test func anythingUntouchedForADayIsIgnored() throws {
        try seed("old", .idle, age: 24 * 3600 + 1)
        try seed("recent", .idle, age: 24 * 3600 - 1)
        #expect(activity().sessions(now: now).map(\.id) == ["recent"])
        // Deleted, not just skipped: a session killed without a SessionEnd would otherwise leave its
        // file behind for good.
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("old.json").path))
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("recent.json").path))
    }

    @Test func anInterruptedTurnIsIdle() throws {
        try seed("a", .tool, transcript: "/t/a.jsonl")
        try seed("b", .permission, transcript: "/t/b.jsonl")
        let sessions = activity(interrupted: { path, _ in path == "/t/a.jsonl" || path == "/t/b.jsonl" })
            .sessions(now: now)
        #expect(sessions.allSatisfy { $0.state == .idle })
    }

    @Test func mostUrgentFirstThenMostRecent() throws {
        try seed("idle", .idle, age: 1)
        try seed("thinking", .thinking, age: 2)
        try seed("tool-old", .tool, age: 30)
        try seed("tool-new", .tool, age: 3)
        try seed("permission", .permission, age: 50)
        #expect(activity().sessions(now: now).map(\.id) == ["permission", "tool-new", "tool-old", "thinking", "idle"])
    }

    /// Directory listing order isn't stable, so without a last key two sessions tied on both could
    /// swap places between refreshes.
    @Test func tiesSortById() throws {
        try seed("c", .tool, age: 7)
        try seed("a", .tool, age: 7)
        try seed("b", .tool, age: 7)
        #expect(activity().sessions(now: now).map(\.id) == ["a", "b", "c"])
    }

    @Test func sameNamedProjectsShowTheirParent() {
        #expect(SessionActivity.projectNames(cwds: ["/a/work/api", "/b/personal/api", "/c/headroom"])
                == ["work/api", "personal/api", "headroom"])
        // Two sessions in the same folder: a parent wouldn't tell them apart, so don't add one.
        #expect(SessionActivity.projectNames(cwds: ["/a/api", "/a/api"]) == ["api", "api"])
        #expect(SessionActivity.projectNames(cwds: [""]) == ["Claude Code"])
    }

    @Test func moreLabel() {
        #expect(SessionActivity.moreLabel(1) == "+1 more session")
        #expect(SessionActivity.moreLabel(3) == "+3 more sessions")
    }
}
