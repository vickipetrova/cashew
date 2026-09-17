# Session Activity, Automatic Hooks, and Update Checks — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show live Claude Code session activity in Headroom's menu bar and dropdown, fed by hooks Headroom installs itself, and add a daily GitHub Releases update check.

**Architecture:** A Foundation-only helper executable (`headroom-hook`), bundled at `Contents/Helpers/`, is registered as a Claude Code hook and writes one small JSON file per session into Headroom's Application Support folder. `HookInstaller` keeps those hooks in `~/.claude/settings.json`. `SessionActivity` reads the files (liveness, interrupt detection, git branch) and `MenuController` renders an animated/dotted spark plus a `CLAUDE CODE` section. `UpdateCheck` asks GitHub once a day.

**Tech Stack:** Swift 6 toolchain in Swift 5 language mode, SwiftPM, AppKit + SwiftUI, swift-testing. No third-party dependencies.

**Spec:** `docs/superpowers/specs/2026-09-16-session-activity-design.md` — read it before starting any task.

## Global Constraints

- Zero third-party dependencies. `Package.swift` never gets a `dependencies:` array.
- `swiftLanguageModes: [.v5]` and `platforms: [.macOS(.v13)]` stay exactly as they are.
- Tests use swift-testing (`import Testing`), never XCTest. Run with `swift test --disable-xctest`.
- Parsing tests feed **JSON text** through `JSONSerialization`, never Swift dictionary literals, so values arrive as real `NSNumber`s.
- All parsing is defensive: missing, null, or wrong-typed fields drop that one item; never force-unwrap a parsed field; never throw on an unexpected shape.
- JSON booleans bridge to `NSNumber` — check `isJSONBoolean` before reading any number.
- Never call from a test: `HookInstaller.default`, `SessionActivity.default`, `SessionFiles.defaultDirectory`, `UpdateCheck.fetch`, plus everything already listed in `CLAUDE.md` ("Never called from a test").
- `MenuController` holds no Claude-specific strings; copy lives in `SessionActivity`, `HookInstaller`, `UpdateCheck`.
- The helper never records prompt text, tool input, or tool output — only the tool *name*.
- Network destinations: `api.anthropic.com` (existing) and `api.github.com` (update check only).
- Headroom edits `~/.claude/settings.json` only to add/remove hooks whose command contains `headroom-hook`.
- `main` is protected: all work lands on `feat/session-activity`; commit after each task. End every commit message with `Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>`.
- Match the surrounding code's comment density: doc comments explain *why*, citing the measured trap.

## File Map

| File | Status | Responsibility |
|---|---|---|
| `Package.swift` | modify | Add `HeadroomShared` library and `headroom-hook` executable |
| `Sources/HeadroomShared/JSON.swift` | create | `isJSONBoolean`, moved from `UsageAPI.swift` |
| `Sources/HeadroomShared/SessionRecord.swift` | create | `SessionState`, `SessionRecord` (JSON in/out), `SessionFiles` (location, id sanitizing, read/write) |
| `Sources/HeadroomShared/HookEvent.swift` | create | Hook event → record transition, tool labels |
| `Sources/HeadroomShared/SessionOwner.swift` | create | Find the Claude Code process above the helper (skip shells) |
| `Sources/headroom-hook/main.swift` | create | The helper: read stdin with cap/timeout, apply event, write/delete |
| `Sources/HeadroomCore/UsageAPI.swift` | modify | Remove `isJSONBoolean`, `import HeadroomShared` |
| `Sources/HeadroomCore/Credentials.swift` | modify | `import HeadroomShared` |
| `Sources/HeadroomCore/HookInstaller.swift` | create | Merge/remove hooks in `~/.claude/settings.json`, status copy |
| `Sources/HeadroomCore/SessionActivity.swift` | create | `Session`, reading/filtering/ordering session files, menu copy |
| `Sources/HeadroomCore/TranscriptTail.swift` | create | Esc-interrupt detection from the transcript's tail |
| `Sources/HeadroomCore/GitBranch.swift` | create | Branch from `.git/HEAD` without running git |
| `Sources/HeadroomCore/UpdateCheck.swift` | create | `Release`, version compare, release parsing, due rule, fetch |
| `Sources/HeadroomCore/SessionPanel.swift` | create | `SessionRow` view model, `SessionRowView`, `PanelHeadingView`, row cap |
| `Sources/HeadroomCore/DirectoryWatcher.swift` | create | Debounced `DispatchSource` on the sessions folder |
| `Sources/HeadroomCore/Format.swift` | modify | `Fmt.elapsed`, `Fmt.statusImage` (rotation + permission dot) |
| `Sources/HeadroomCore/Settings.swift` | modify | `trackSessions`, `checkForUpdates`, `lastUpdateCheck`, `knownRelease` |
| `Sources/HeadroomCore/MenuController.swift` | modify | Title image, `CLAUDE CODE` rows, update item, settings toggles |
| `Sources/HeadroomCore/AppDelegate.swift` | modify | Installer, watcher, animation timer, update scheduling |
| `Sources/HeadroomCore/StatuslineFeed.swift` | modify | Correct the "never edits settings.json" comment |
| `Tests/HeadroomCoreTests/*` | create/modify | One test file per new unit (named in each task) |
| `build.sh` | modify | Build, place and sign the helper |
| `.github/workflows/build.yml` | modify | Verify the helper; extend the test-bounds grep |
| `docs/RELEASING.md` | modify | Sign the helper before the app |
| `CLAUDE.md`, `README.md`, `SECURITY.md`, `CHANGELOG.md` | modify | Rules, architecture, privacy, changelog |

---

### Task 1: `HeadroomShared` — package targets, JSON guard, session record, hook events

**Files:**
- Modify: `Package.swift`
- Create: `Sources/HeadroomShared/JSON.swift`, `Sources/HeadroomShared/SessionRecord.swift`, `Sources/HeadroomShared/HookEvent.swift`
- Modify: `Sources/HeadroomCore/UsageAPI.swift:59-68` (remove `isJSONBoolean`, add import), `Sources/HeadroomCore/Credentials.swift` (add import)
- Test: `Tests/HeadroomCoreTests/SessionRecordTests.swift`, `Tests/HeadroomCoreTests/HookEventTests.swift`

**Interfaces:**
- Produces:
  - `public func isJSONBoolean(_ any: Any) -> Bool`
  - `public enum SessionState: String { case thinking, tool, permission, idle }`
  - `public struct SessionRecord: Equatable` with `state, label, tool, cwd, transcript: String`, `pid: Int32?`, `started: Bool`, `turnStartedAt: Date?`, `updatedAt: Date`; `public var jsonObject: [String: Any]`; `public init?(jsonObject: [String: Any])`
  - `public enum SessionFiles` with `static var defaultDirectory: URL`, `static func sanitizedID(_:) -> String?`, `static func url(for:in:) -> URL?`, `static func read(_: URL) -> SessionRecord?`, `static func write(_: SessionRecord, to: URL) throws`
  - `public enum HookEvent: String, CaseIterable` (`start prompt pre post notify permreq stop end`) with `hookName: String`, `needsMatcher: Bool`, `func outcome(payload:previous:pid:now:) -> Outcome`; `enum Outcome: Equatable { case write(SessionRecord), delete, ignore }` with `var record: SessionRecord?`
  - `public enum SessionLabels` constants: `thinking = "Thinking"`, `permission = "Awaiting permission"`

- [ ] **Step 1: Add the targets to `Package.swift`**

Replace the `targets:` array with:

```swift
    targets: [
        // Foundation only. Shared by the app and by `headroom-hook`, which Claude Code runs on every
        // prompt and tool call — so it must never pull in AppKit or SwiftUI, and neither may this.
        .target(name: "HeadroomShared"),
        .target(name: "HeadroomCore", dependencies: ["HeadroomShared"]),
        .executableTarget(name: "Headroom", dependencies: ["HeadroomCore"]),
        .executableTarget(name: "headroom-hook", dependencies: ["HeadroomShared"]),
        .testTarget(name: "HeadroomCoreTests", dependencies: ["HeadroomCore", "HeadroomShared"]),
    ],
```

- [ ] **Step 2: Move `isJSONBoolean` into `Sources/HeadroomShared/JSON.swift`**

Cut the function *and its doc comment* from `Sources/HeadroomCore/UsageAPI.swift` (the block directly above `/// Which of the numbers still on screen are worth showing.`) and paste into the new file, made `public`:

```swift
import CoreFoundation

/// `JSONSerialization` turns `true`/`false` into `NSNumber`s, and `NSNumber as? Double` happily
/// yields 1.0 and 0.0 — so a boolean sails through any numeric parse unless it is rejected first.
/// Comparing the CoreFoundation type id is the only reliable discriminator: `as? Bool` is no good,
/// because `NSNumber(42) as? Bool` succeeds too.
///
/// Lives in `HeadroomShared` because the session files are parsed by both the app and the hook
/// helper, and a second copy of this is exactly the kind of guard that drifts.
public func isJSONBoolean(_ any: Any) -> Bool {
    CFGetTypeID(any as CFTypeRef) == CFBooleanGetTypeID()
}
```

(Keep the original doc comment text verbatim if it differs from the above; only add the last paragraph.)

Add `import HeadroomShared` below `import Foundation` in `Sources/HeadroomCore/UsageAPI.swift` and in `Sources/HeadroomCore/Credentials.swift`.

- [ ] **Step 3: Confirm nothing regressed**

Run: `swift test --disable-xctest 2>&1 | tail -3`
Expected: `Test run with 220 tests in 16 suites passed`. (An empty `headroom-hook` target will fail to build — create `Sources/headroom-hook/main.swift` containing just `import HeadroomShared` for now so the package resolves.)

- [ ] **Step 4: Write the failing tests for `SessionRecord` / `SessionFiles`**

Create `Tests/HeadroomCoreTests/SessionRecordTests.swift`:

```swift
import Foundation
import Testing

@testable import HeadroomShared

/// The session file is the contract between `headroom-hook` and the app. The helper writes it and
/// the app parses it — defensively, because an old helper, a hand edit or a half-written file must
/// cost that one session and nothing else.
@Suite struct SessionRecordTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func object(_ text: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    @Test func roundTripsThroughJSON() throws {
        let record = SessionRecord(state: .tool, label: "Editing", tool: "Edit",
                                   cwd: "/Users/v/dev/headroom", transcript: "/t/a.jsonl",
                                   pid: 4242, started: true,
                                   turnStartedAt: now.addingTimeInterval(-65), updatedAt: now)
        let data = try JSONSerialization.data(withJSONObject: record.jsonObject)
        let parsed = try #require(SessionRecord(jsonObject: try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])))
        #expect(parsed == record)
    }

    @Test func missingOrUnknownStateIsRejected() throws {
        #expect(SessionRecord(jsonObject: try object(#"{"updatedAt": 1790000000}"#)) == nil)
        #expect(SessionRecord(jsonObject: try object(#"{"state": "dancing", "updatedAt": 1790000000}"#)) == nil)
    }

    /// `true` must not read as 1970-01-01T00:00:01.
    @Test func booleanTimestampIsRejected() throws {
        #expect(SessionRecord(jsonObject: try object(#"{"state": "idle", "updatedAt": true}"#)) == nil)
    }

    @Test func wrongTypedOptionalFieldsFallBackInsteadOfFailing() throws {
        let record = try #require(SessionRecord(jsonObject: try object("""
            {"state": "thinking", "updatedAt": 1790000000, "pid": true, "started": 1,
             "cwd": 5, "label": null, "turnStartedAt": "soon"}
            """)))
        #expect(record.pid == nil)
        #expect(record.started == false)
        #expect(record.cwd == "")
        #expect(record.label == "")
        #expect(record.turnStartedAt == nil)
    }

    @Test(arguments: ["-5", "0", "1", "3000000000", "12.5"])
    func implausiblePIDsAreDropped(_ raw: String) throws {
        let record = try #require(SessionRecord(jsonObject: try object(
            #"{"state": "idle", "updatedAt": 1790000000, "pid": \#(raw)}"#)))
        #expect(record.pid == nil)
    }

    @Test func sanitizedIDKeepsSafeCharactersOnly() {
        #expect(SessionFiles.sanitizedID("3f1c-9a_b.2") == "3f1c-9a_b.2")
        #expect(SessionFiles.sanitizedID("../../etc/passwd") == "....etcpasswd")
        #expect(SessionFiles.sanitizedID(String(repeating: "a", count: 100))?.count == 64)
    }

    /// No id means no file: a phantom "unknown" session in the menu is worse than nothing.
    @Test(arguments: ["", "///", "..", "."])
    func unusableIDsYieldNoFile(_ raw: String) {
        #expect(SessionFiles.sanitizedID(raw) == nil)
        #expect(SessionFiles.url(for: raw, in: URL(fileURLWithPath: "/tmp")) == nil)
    }

    @Test func writeThenReadFromDisk() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("headroom-sessions-\(UUID().uuidString)", isDirectory: true)
        let url = try #require(SessionFiles.url(for: "abc", in: directory))
        let record = SessionRecord(state: .idle, updatedAt: now)
        try SessionFiles.write(record, to: url)
        #expect(SessionFiles.read(url) == record)
    }
}
```

- [ ] **Step 5: Write the failing tests for `HookEvent`**

Create `Tests/HeadroomCoreTests/HookEventTests.swift`:

```swift
import Foundation
import Testing

@testable import HeadroomShared

/// Claude Code hook payloads → the session file. Payload shapes follow the hooks docs and what the
/// probe in the design session observed; everything is optional, because the payload is not ours.
@Suite struct HookEventTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func payload(_ text: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    private let base = #"{"session_id": "s1", "cwd": "/Users/v/dev/headroom", "transcript_path": "/t/s1.jsonl"}"#

    @Test func promptStartsATurn() throws {
        let record = try #require(HookEvent.prompt
            .outcome(payload: try payload(base), previous: nil, pid: 42, now: now).record)
        #expect(record.state == .thinking)
        #expect(record.label == SessionLabels.thinking)
        #expect(record.turnStartedAt == now)
        #expect(record.started)
        #expect(record.cwd == "/Users/v/dev/headroom")
        #expect(record.transcript == "/t/s1.jsonl")
        #expect(record.pid == 42)
    }

    @Test func toolUseKeepsTheTurnStart() throws {
        let previous = SessionRecord(state: .thinking, label: SessionLabels.thinking, started: true,
                                     turnStartedAt: now.addingTimeInterval(-30),
                                     updatedAt: now.addingTimeInterval(-1))
        let record = try #require(HookEvent.pre.outcome(
            payload: try payload(#"{"session_id": "s1", "tool_name": "Edit"}"#),
            previous: previous, pid: 42, now: now).record)
        #expect(record.state == .tool)
        #expect(record.label == "Editing")
        #expect(record.tool == "Edit")
        #expect(record.turnStartedAt == now.addingTimeInterval(-30))
    }

    @Test(arguments: ["mcp__github__create_issue", "SomethingNew", ""])
    func unknownToolsGetAGenericLabel(_ tool: String) throws {
        let record = try #require(HookEvent.pre.outcome(
            payload: try payload(#"{"tool_name": "\#(tool)"}"#), previous: nil, pid: nil, now: now).record)
        #expect(record.label == "Using tool")
    }

    @Test func postToolGoesBackToThinking() throws {
        let record = try #require(HookEvent.post
            .outcome(payload: try payload(base), previous: nil, pid: nil, now: now).record)
        #expect(record.state == .thinking)
        #expect(record.turnStartedAt == now)
    }

    /// "Claude is waiting for your input" is a Notification too. Treating it as a permission prompt
    /// parks the menu bar on a yellow dot every time a turn ends.
    @Test func idleNotificationIsIgnored() throws {
        let outcome = HookEvent.notify.outcome(payload: try payload("""
            {"notification_type": "idle_prompt", "message": "Claude is waiting for your input"}
            """), previous: nil, pid: nil, now: now)
        #expect(outcome == .ignore)
    }

    @Test func permissionNotificationByType() throws {
        let record = try #require(HookEvent.notify.outcome(payload: try payload("""
            {"notification_type": "permission_prompt", "message": "Claude needs your permission to use Bash"}
            """), previous: nil, pid: nil, now: now).record)
        #expect(record.state == .permission)
        #expect(record.label == SessionLabels.permission)
    }

    /// Older Claude Code versions send no `notification_type`; the message is all there is.
    @Test func permissionNotificationByMessageWhenUntyped() throws {
        let record = try #require(HookEvent.notify.outcome(payload: try payload("""
            {"message": "Claude needs your permission to use Bash"}
            """), previous: nil, pid: nil, now: now).record)
        #expect(record.state == .permission)
    }

    @Test func permissionRequestIsPermission() throws {
        let record = try #require(HookEvent.permreq
            .outcome(payload: try payload(base), previous: nil, pid: nil, now: now).record)
        #expect(record.state == .permission)
    }

    @Test func stopEndsTheTurn() throws {
        let previous = SessionRecord(state: .tool, started: true, turnStartedAt: now, updatedAt: now)
        let record = try #require(HookEvent.stop
            .outcome(payload: try payload(base), previous: previous, pid: nil, now: now).record)
        #expect(record.state == .idle)
        #expect(record.turnStartedAt == nil)
        #expect(record.started)
    }

    @Test func sessionEndDeletes() throws {
        #expect(HookEvent.end.outcome(payload: try payload(base), previous: nil, pid: nil, now: now) == .delete)
    }

    /// A merely opened (or resumed) conversation is seeded but hidden until something happens in it.
    @Test func sessionStartSeedsAnUnstartedIdleSession() throws {
        let record = try #require(HookEvent.start
            .outcome(payload: try payload(base), previous: nil, pid: 42, now: now).record)
        #expect(record.state == .idle)
        #expect(record.started == false)
    }

    @Test func fieldsMissingFromThePayloadCarryOver() throws {
        let previous = SessionRecord(state: .thinking, cwd: "/a", transcript: "/t.jsonl", pid: 7,
                                     started: true, turnStartedAt: now, updatedAt: now)
        let record = try #require(HookEvent.post.outcome(
            payload: try payload(#"{"cwd": 5, "transcript_path": false}"#),
            previous: previous, pid: nil, now: now).record)
        #expect(record.cwd == "/a")
        #expect(record.transcript == "/t.jsonl")
        #expect(record.pid == 7)
    }

    @Test func hookNamesMatchClaudeCode() {
        #expect(HookEvent.allCases.map(\.hookName) == [
            "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
            "Notification", "PermissionRequest", "Stop", "SessionEnd",
        ])
        #expect(HookEvent.allCases.filter(\.needsMatcher) == [.pre, .post, .permreq])
    }
}
```

- [ ] **Step 6: Run to confirm they fail**

Run: `swift test --disable-xctest 2>&1 | grep -E "error:|failed" | head`
Expected: compile errors — `cannot find 'SessionRecord' in scope`, `cannot find 'HookEvent' in scope`.

- [ ] **Step 7: Implement `Sources/HeadroomShared/SessionRecord.swift`**

```swift
import Foundation

/// What one Claude Code session is doing, as far as its hooks have said.
public enum SessionState: String, Equatable {
    case thinking
    case tool
    case permission
    case idle
}

/// Copy written into the session file by the helper. Kept here so the app's fallbacks and the
/// helper's writes can't disagree about the words.
public enum SessionLabels {
    public static let thinking = "Thinking"
    public static let permission = "Awaiting permission"
}

/// One session's file: written by `headroom-hook`, read by `SessionActivity`.
public struct SessionRecord: Equatable {
    public var state: SessionState
    public var label: String
    /// The tool's *name* only. Never its input — see the helper's privacy note.
    public var tool: String
    public var cwd: String
    public var transcript: String
    /// The Claude Code process, for liveness. Nil when it could not be identified.
    public var pid: Int32?
    /// False until the session does something. A conversation that was merely opened stays hidden.
    public var started: Bool
    public var turnStartedAt: Date?
    public var updatedAt: Date

    public init(state: SessionState, label: String = "", tool: String = "", cwd: String = "",
                transcript: String = "", pid: Int32? = nil, started: Bool = false,
                turnStartedAt: Date? = nil, updatedAt: Date) {
        self.state = state
        self.label = label
        self.tool = tool
        self.cwd = cwd
        self.transcript = transcript
        self.pid = pid
        self.started = started
        self.turnStartedAt = turnStartedAt
        self.updatedAt = updatedAt
    }

    public static let schemaVersion = 1

    public var jsonObject: [String: Any] {
        var object: [String: Any] = [
            "version": Self.schemaVersion,
            "state": state.rawValue,
            "label": label,
            "tool": tool,
            "cwd": cwd,
            "transcript": transcript,
            "started": started,
            "updatedAt": updatedAt.timeIntervalSince1970,
        ]
        if let pid { object["pid"] = Int(pid) }
        if let turnStartedAt { object["turnStartedAt"] = turnStartedAt.timeIntervalSince1970 }
        return object
    }

    /// Nil only when the two fields nothing works without — `state` and `updatedAt` — are unusable.
    /// Everything else falls back to empty, so an odd field costs that field, not the session.
    public init?(jsonObject object: [String: Any]) {
        guard let raw = object["state"] as? String, let state = SessionState(rawValue: raw),
              let updated = Self.timestamp(object["updatedAt"]) else { return nil }
        self.state = state
        label = Self.text(object["label"])
        tool = Self.text(object["tool"])
        cwd = Self.text(object["cwd"])
        transcript = Self.text(object["transcript"])
        pid = Self.processID(object["pid"])
        if let flag = object["started"], isJSONBoolean(flag) { started = (flag as? Bool) ?? false }
        else { started = false }
        turnStartedAt = Self.timestamp(object["turnStartedAt"]).map(Date.init(timeIntervalSince1970:))
        updatedAt = Date(timeIntervalSince1970: updated)
    }

    /// Capped, because these land in a menu row and nothing legitimate is this long.
    static func text(_ any: Any?) -> String {
        guard let string = any as? String else { return "" }
        return String(string.prefix(4096))
    }

    /// Unix seconds between 2001 and 2286. Anything else is junk, and a wild value would overflow the
    /// `Int` conversion in `Fmt.elapsed`.
    static func timestamp(_ any: Any?) -> Double? {
        guard let any, !isJSONBoolean(any), let value = any as? Double,
              value.isFinite, (978_307_200...9_999_999_999).contains(value) else { return nil }
        return value
    }

    static func processID(_ any: Any?) -> Int32? {
        guard let any, !isJSONBoolean(any), let value = any as? Double, value.isFinite,
              value.rounded() == value, value > 1, value <= Double(Int32.max) else { return nil }
        return Int32(value)
    }
}

/// Where session files live, and how they are named, read and written.
public enum SessionFiles {
    /// Alongside Headroom's other state. Never call from a test — tests pass a temp directory.
    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.vickipetrova.headroom", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
    }

    /// `session_id` comes from a payload, so it is reduced to characters that can't escape the
    /// directory or collide with the temp files an atomic write leaves behind. Nil when nothing
    /// usable is left — dots alone would name `.` or `..`.
    public static func sanitizedID(_ raw: String) -> String? {
        let allowed = raw.unicodeScalars.filter { scalar in
            ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar)
                || ("0"..."9").contains(scalar) || "_.-".unicodeScalars.contains(scalar)
        }
        let id = String(String.UnicodeScalarView(allowed).prefix(64))
        return id.isEmpty || id.allSatisfy({ $0 == "." }) ? nil : id
    }

    public static func url(for rawID: String, in directory: URL) -> URL? {
        sanitizedID(rawID).map { directory.appendingPathComponent("\($0).json") }
    }

    /// Nil for anything unreadable, oversized or malformed — never a throw.
    public static func read(_ url: URL) -> SessionRecord? {
        guard let data = try? Data(contentsOf: url), data.count <= 64_000,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return SessionRecord(jsonObject: object)
    }

    /// Atomic, so the app can never read a half-written file.
    public static func write(_ record: SessionRecord, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: record.jsonObject, options: [.sortedKeys])
        try data.write(to: url, options: .atomic)
    }
}
```

- [ ] **Step 8: Implement `Sources/HeadroomShared/HookEvent.swift`**

```swift
import Foundation

/// A Claude Code hook, as `headroom-hook` receives it: the first command-line argument.
public enum HookEvent: String, CaseIterable {
    case start
    case prompt
    case pre
    case post
    case notify
    case permreq
    case stop
    case end

    /// The event name in `~/.claude/settings.json`.
    public var hookName: String {
        switch self {
        case .start: return "SessionStart"
        case .prompt: return "UserPromptSubmit"
        case .pre: return "PreToolUse"
        case .post: return "PostToolUse"
        case .notify: return "Notification"
        case .permreq: return "PermissionRequest"
        case .stop: return "Stop"
        case .end: return "SessionEnd"
        }
    }

    /// Tool events take a `matcher`; the rest don't.
    public var needsMatcher: Bool {
        self == .pre || self == .post || self == .permreq
    }

    public enum Outcome: Equatable {
        case write(SessionRecord)
        case delete
        case ignore

        public var record: SessionRecord? {
            if case .write(let record) = self { return record }
            return nil
        }
    }

    /// Pure: the whole state machine, reachable from a test without a process, a file or stdin.
    ///
    /// `pid` is the Claude Code process as `SessionOwner` found it; nil keeps the previous one.
    public func outcome(payload: [String: Any], previous: SessionRecord?, pid: Int32?,
                        now: Date) -> Outcome {
        if self == .end { return .delete }

        var record = SessionRecord(
            state: .idle,
            cwd: (payload["cwd"] as? String).map { SessionRecord.text($0) } ?? previous?.cwd ?? "",
            transcript: (payload["transcript_path"] as? String).map { SessionRecord.text($0) }
                ?? previous?.transcript ?? "",
            pid: pid ?? previous?.pid,
            started: previous?.started ?? false,
            turnStartedAt: previous?.turnStartedAt,
            updatedAt: now)

        switch self {
        case .start:
            // Also fires on resume, where no turn is running — so this clears rather than carries.
            record.started = false
            record.turnStartedAt = nil
        case .prompt:
            record.state = .thinking
            record.label = SessionLabels.thinking
            record.turnStartedAt = now
            record.started = true
        case .pre:
            let tool = payload["tool_name"] as? String ?? ""
            record.state = .tool
            record.tool = String(tool.prefix(64))
            record.label = Self.label(forTool: tool)
            record.turnStartedAt = previous?.turnStartedAt ?? now
            record.started = true
        case .post:
            record.state = .thinking
            record.label = SessionLabels.thinking
            record.turnStartedAt = previous?.turnStartedAt ?? now
            record.started = true
        case .notify:
            guard Self.isPermissionNotification(payload) else { return .ignore }
            record.state = .permission
            record.label = SessionLabels.permission
            record.started = true
        case .permreq:
            record.state = .permission
            record.label = SessionLabels.permission
            record.started = true
        case .stop:
            record.turnStartedAt = nil
            record.started = true
        case .end:
            return .delete
        }
        return .write(record)
    }

    static let toolLabels: [String: String] = [
        "Bash": "Running command", "Edit": "Editing", "MultiEdit": "Editing",
        "NotebookEdit": "Editing", "Write": "Writing", "Read": "Reading",
        "Grep": "Searching", "Glob": "Searching", "WebFetch": "Browsing web",
        "WebSearch": "Searching web", "Task": "Delegating", "Agent": "Delegating",
        "TodoWrite": "Planning",
    ]

    static func label(forTool tool: String) -> String {
        toolLabels[tool] ?? "Using tool"
    }

    /// Only a permission prompt should light the dot. `notification_type` decides when present;
    /// older payloads carry only the message.
    static func isPermissionNotification(_ payload: [String: Any]) -> Bool {
        if let type = payload["notification_type"] as? String { return type == "permission_prompt" }
        let message = (payload["message"] as? String ?? "").lowercased()
        return message.contains("permission") || message.contains("approve") || message.contains("allow")
    }
}
```

- [ ] **Step 9: Run the tests**

Run: `swift test --disable-xctest 2>&1 | tail -3`
Expected: all pass (220 + the new ones).

- [ ] **Step 10: Commit**

```bash
git add Package.swift Sources/HeadroomShared Sources/headroom-hook Sources/HeadroomCore/UsageAPI.swift Sources/HeadroomCore/Credentials.swift Tests/HeadroomCoreTests/SessionRecordTests.swift Tests/HeadroomCoreTests/HookEventTests.swift
git commit -m "feat: shared session record and hook event state machine

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: `headroom-hook` executable and `SessionOwner`

**Files:**
- Create: `Sources/HeadroomShared/SessionOwner.swift`
- Modify: `Sources/headroom-hook/main.swift` (replace the placeholder)
- Modify: `docs/superpowers/specs/2026-09-16-session-activity-design.md` (the "Parent process" paragraph)
- Test: `Tests/HeadroomCoreTests/SessionOwnerTests.swift`

**Interfaces:**
- Consumes: `HookEvent`, `SessionFiles`, `SessionRecord` (Task 1)
- Produces: `public enum SessionOwner` with `static let shells: Set<String>`, `static func find(start: Int32, parent: (Int32) -> Int32?, name: (Int32) -> String?, maxDepth: Int = 5) -> Int32?`, `static func parentPID(of: Int32) -> Int32?`, `static func executableName(of: Int32) -> String?`; `public enum HookInput` with `static let maxBytes`, `static func payload(from: Data) -> [String: Any]`. The built binary `headroom-hook <event>`.

**Why shells, not "claude":** measured in the design session — a native Claude Code install's executable path ends in its *version* (`~/.local/share/claude/versions/2.1.273`), so matching on the name `claude` never matches. With a bare hook command the helper's parent *is* Claude Code; a shell only appears if something wraps the command. So the rule is "skip shells".

- [ ] **Step 1: Write the failing tests**

Create `Tests/HeadroomCoreTests/SessionOwnerTests.swift`:

```swift
import Foundation
import Testing

@testable import HeadroomShared

@Suite struct SessionOwnerTests {
    private func find(_ start: Int32, names: [Int32: String], parents: [Int32: Int32]) -> Int32? {
        SessionOwner.find(start: start, parent: { parents[$0] }, name: { names[$0] })
    }

    /// Verified on Claude Code 2.1.273: a bare hook command's parent is Claude Code itself, whose
    /// executable is named after its version.
    @Test func directParentIsTheOwner() {
        #expect(find(90, names: [90: "2.1.273", 80: "zsh"], parents: [90: 80]) == 90)
    }

    @Test func npmInstallRunsUnderNode() {
        #expect(find(90, names: [90: "node"], parents: [:]) == 90)
    }

    /// A wrapped command (`PATH=… cmd`, `a && b`) interposes a shell that exits with the hook.
    @Test func shellsAreSkipped() {
        #expect(find(100, names: [100: "sh", 90: "2.1.273"], parents: [100: 90]) == 90)
    }

    @Test func onlyShellsMeansNoOwner() {
        #expect(find(100, names: [100: "sh", 90: "zsh", 80: "bash"], parents: [100: 90, 90: 80]) == nil)
    }

    @Test func depthIsBounded() {
        var names: [Int32: String] = [:]
        var parents: [Int32: Int32] = [:]
        for pid in Int32(10)...Int32(30) { names[pid] = "sh"; parents[pid] = pid - 1 }
        names[9] = "2.1.273"
        #expect(find(30, names: names, parents: parents) == nil)
    }

    @Test func unknownProcessOrLaunchdIsNoOwner() {
        #expect(find(90, names: [:], parents: [:]) == nil)
        #expect(find(1, names: [1: "launchd"], parents: [:]) == nil)
    }

    @Test func payloadParsing() {
        #expect(HookInput.payload(from: Data(#"{"session_id": "a"}"#.utf8))["session_id"] as? String == "a")
        #expect(HookInput.payload(from: Data("not json".utf8)).isEmpty)
        #expect(HookInput.payload(from: Data("[1, 2]".utf8)).isEmpty)
        #expect(HookInput.payload(from: Data(count: HookInput.maxBytes + 1)).isEmpty)
    }

    /// The real lookups, against this test process — no fixtures, just "does the syscall work".
    @Test func realLookupsWork() {
        #expect(SessionOwner.parentPID(of: getpid()) == getppid())
        #expect(SessionOwner.executableName(of: getpid()) != nil)
    }
}
```

- [ ] **Step 2: Run to confirm failure**

Run: `swift test --disable-xctest 2>&1 | grep -E "error:" | head -3`
Expected: `cannot find 'SessionOwner' in scope`.

- [ ] **Step 3: Implement `Sources/HeadroomShared/SessionOwner.swift`**

```swift
import Foundation

/// Which process owns this session, for the app's liveness check.
///
/// The helper's parent is Claude Code when the hook command is a single bare command — verified on
/// 2.1.273, stable across events in one session. Matching Claude Code by *name* does not work: a
/// native install's executable is `~/.local/share/claude/versions/<version>`, and an npm install
/// runs as `node`. What can be recognised reliably is a shell, which is the one thing that should
/// never be taken as the owner — it exits with the hook, and every session would look dead a second
/// later.
public enum SessionOwner {
    public static let shells: Set<String> = ["sh", "bash", "zsh", "dash", "fish", "ksh", "tcsh", "csh"]

    /// The first non-shell at or above `start`, or nil. Nil makes the app fall back to an age limit.
    public static func find(start: Int32, parent: (Int32) -> Int32?, name: (Int32) -> String?,
                            maxDepth: Int = 5) -> Int32? {
        var pid = start
        for _ in 0..<maxDepth {
            guard pid > 1, let executable = name(pid) else { return nil }
            if !shells.contains(executable) { return pid }
            guard let next = parent(pid) else { return nil }
            pid = next
        }
        return nil
    }

    public static func parentPID(of pid: Int32) -> Int32? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }

    public static func executableName(of pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return URL(fileURLWithPath: String(cString: buffer)).lastPathComponent
    }
}

/// The hook's stdin.
public enum HookInput {
    /// Hook payloads are a few hundred bytes. Anything this big is not one.
    public static let maxBytes = 1_000_000

    public static func payload(from data: Data) -> [String: Any] {
        guard data.count <= maxBytes,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return object
    }
}
```

- [ ] **Step 4: Implement `Sources/headroom-hook/main.swift`**

```swift
import Foundation
import HeadroomShared

// Claude Code runs this on every prompt and every tool call, so three rules hold everywhere below:
// it is fast, it prints nothing, and it exits 0 whatever happens — a hook that fails or talks can
// disturb the session it is observing.
//
// Privacy: only the tool *name*, cwd and transcript path are kept. Prompt text, tool input and tool
// output are in the payload and are never written anywhere.

guard CommandLine.arguments.count > 1,
      let event = HookEvent(rawValue: CommandLine.arguments[1]) else { exit(0) }

/// Read on a separate thread so a stdin that never closes can't hold up the session.
final class Collected: @unchecked Sendable { var data = Data() }
let collected = Collected()
let finished = DispatchSemaphore(value: 0)
Thread.detachNewThread {
    var data = Data()
    while data.count <= HookInput.maxBytes {
        let chunk = FileHandle.standardInput.availableData
        if chunk.isEmpty { break }
        data.append(chunk)
    }
    collected.data = data
    finished.signal()
}
// Only read `collected` after the signal: on timeout the reader may still be writing to it.
let payload = finished.wait(timeout: .now() + 2) == .success ? HookInput.payload(from: collected.data) : [:]

guard let url = SessionFiles.url(for: payload["session_id"] as? String ?? "",
                                 in: SessionFiles.defaultDirectory) else { exit(0) }

let owner = SessionOwner.find(start: getppid(),
                              parent: SessionOwner.parentPID(of:),
                              name: SessionOwner.executableName(of:))

switch event.outcome(payload: payload, previous: SessionFiles.read(url), pid: owner, now: Date()) {
case .write(let record): try? SessionFiles.write(record, to: url)
case .delete: try? FileManager.default.removeItem(at: url)
case .ignore: break
}
exit(0)
```

- [ ] **Step 5: Run the tests**

Run: `swift test --disable-xctest 2>&1 | tail -3`
Expected: all pass.

- [ ] **Step 6: Exercise the real binary**

```bash
swift build --product headroom-hook
DIR="$HOME/Library/Application Support/com.vickipetrova.headroom/sessions"
echo '{"session_id":"plan-check","cwd":"/tmp"}' | .build/debug/headroom-hook start
cat "$DIR/plan-check.json"; echo
echo '{"session_id":"plan-check"}' | .build/debug/headroom-hook end
ls "$DIR/plan-check.json" 2>&1
time (echo '{"session_id":"plan-check"}' | .build/debug/headroom-hook bogus)
```
Expected: the `start` file shows `"state":"idle"`, `"started":false`, `"cwd":"/tmp"` and a `pid`; after `end`, `No such file or directory`; the bogus event exits immediately (well under 0.1s). Uses `start` so the file is never shown as a session even if a new Headroom is running.

- [ ] **Step 7: Update the spec's parent-process paragraph**

In `docs/superpowers/specs/2026-09-16-session-activity-design.md`, replace the bullet that begins "The helper checks its parent's executable name. If it is not `claude`…" with:

```markdown
- The helper takes its parent unless that parent is a shell (`sh`, `bash`, `zsh`, `dash`, `fish`,
  `ksh`, `tcsh`, `csh`), in which case it walks up (bounded, 5 levels) to the first non-shell.
  Matching on the name `claude` does not work: measured, a native install's executable is named
  after its version (`…/claude/versions/2.1.273`), and an npm install runs as `node`. If no
  non-shell is found it omits `pid`, and the reader falls back to the age cap.
```

- [ ] **Step 8: Commit**

```bash
git add Sources/HeadroomShared/SessionOwner.swift Sources/headroom-hook/main.swift Tests/HeadroomCoreTests/SessionOwnerTests.swift docs/superpowers/specs/2026-09-16-session-activity-design.md
git commit -m "feat: headroom-hook helper that records session state from Claude Code hooks

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: `HookInstaller`

**Files:**
- Create: `Sources/HeadroomCore/HookInstaller.swift`
- Test: `Tests/HeadroomCoreTests/HookInstallerTests.swift`

**Interfaces:**
- Consumes: `HookEvent.allCases`, `.hookName`, `.needsMatcher`, `.rawValue` (Task 1)
- Produces:
  - `struct HookInstaller { let claudeDirectory: URL; let helperPath: String; static let default; func apply(enabled: Bool) -> Outcome }`
  - `enum HookInstaller.Outcome: Equatable { case claudeNotFound, notInApplications, helperMissing, unreadableSettings, upToDate, wrote, changedMeanwhile, writeFailed }`
  - `static func merged(_ settings: [String: Any], helperPath: String?) -> [String: Any]` (nil path = remove)
  - `static func command(helperPath: String, event: HookEvent) -> String`
  - `static func isRunnableLocation(_ path: String) -> Bool`
  - `static func statusLabel(_ outcome: Outcome?, enabled: Bool, sessionCount: Int) -> String`

- [ ] **Step 1: Write the failing tests**

Create `Tests/HeadroomCoreTests/HookInstallerTests.swift`:

```swift
import Foundation
import Testing

@testable import HeadroomCore
@testable import HeadroomShared

/// Headroom edits the user's own Claude Code settings. Every test here guards a way that goes wrong
/// for someone who didn't ask for it: losing another tool's hook, rewriting the file on every launch,
/// replacing a dotfiles symlink, or touching a file it couldn't parse.
@Suite struct HookInstallerTests {
    private let helper = "/Applications/Headroom.app/Contents/Helpers/headroom-hook"

    private func object(_ text: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    private func entries(_ settings: [String: Any], _ event: String) -> [Any] {
        ((settings["hooks"] as? [String: Any])?[event] as? [Any]) ?? []
    }

    private func commands(_ settings: [String: Any], _ event: String) -> [String] {
        entries(settings, event).flatMap { entry -> [String] in
            (((entry as? [String: Any])?["hooks"] as? [Any]) ?? [])
                .compactMap { ($0 as? [String: Any])?["command"] as? String }
        }
    }

    private func same(_ a: [String: Any], _ b: [String: Any]) -> Bool {
        NSDictionary(dictionary: a).isEqual(to: b)
    }

    // MARK: Merge

    @Test func installsEveryEventIntoEmptySettings() {
        let merged = HookInstaller.merged([:], helperPath: helper)
        for event in HookEvent.allCases {
            #expect(commands(merged, event.hookName) == ["'\(helper)' \(event.rawValue)"])
            let entry = entries(merged, event.hookName).first as? [String: Any]
            #expect((entry?["matcher"] as? String) == (event.needsMatcher ? "*" : nil))
        }
    }

    @Test func preservesUnrelatedKeysAndOtherHooks() throws {
        let settings = try object("""
            {"model": "opus", "statusLine": {"type": "command", "command": "~/.claude/statusline.sh"},
             "hooks": {"Stop": [{"hooks": [{"type": "command", "command": "afplay done.aiff"}]}]}}
            """)
        let merged = HookInstaller.merged(settings, helperPath: helper)
        #expect(merged["model"] as? String == "opus")
        #expect(same(try #require(merged["statusLine"] as? [String: Any]),
                     try #require(settings["statusLine"] as? [String: Any])))
        #expect(commands(merged, "Stop") == ["afplay done.aiff", "'\(helper)' stop"])
    }

    @Test func replacesAStalePath() throws {
        let settings = try object("""
            {"hooks": {"Stop": [{"hooks": [{"type": "command",
              "command": "'/Volumes/Headroom/Headroom.app/Contents/Helpers/headroom-hook' stop"}]}]}}
            """)
        #expect(commands(HookInstaller.merged(settings, helperPath: helper), "Stop") == ["'\(helper)' stop"])
    }

    /// A later tool appending its own hook after ours must not make Headroom move itself to the end
    /// on every launch — two tools doing that to each other rewrite the file forever.
    @Test func leavesItsHookInPlaceWhenOthersFollowIt() {
        var settings = HookInstaller.merged([:], helperPath: helper)
        var hooks = settings["hooks"] as! [String: Any]
        var stop = hooks["Stop"] as! [Any]
        stop.append(["hooks": [["type": "command", "command": "afplay done.aiff"]]])
        hooks["Stop"] = stop
        settings["hooks"] = hooks
        #expect(same(HookInstaller.merged(settings, helperPath: helper), settings))
    }

    @Test func mergeIsIdempotent() throws {
        let settings = try object(#"{"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "x"}]}]}}"#)
        let once = HookInstaller.merged(settings, helperPath: helper)
        #expect(same(HookInstaller.merged(once, helperPath: helper), once))
    }

    @Test func removalRestoresTheOriginal() throws {
        let original = try object("""
            {"model": "opus", "hooks": {"Stop": [{"hooks": [{"type": "command", "command": "afplay done.aiff"}]}]}}
            """)
        let installed = HookInstaller.merged(original, helperPath: helper)
        #expect(same(HookInstaller.merged(installed, helperPath: nil), original))
        #expect(same(HookInstaller.merged(HookInstaller.merged([:], helperPath: helper), helperPath: nil), [:]))
    }

    @Test func sharedEntryKeepsTheOtherCommand() throws {
        let settings = try object("""
            {"hooks": {"PreToolUse": [{"matcher": "*", "hooks": [
              {"type": "command", "command": "other-tool pre"},
              {"type": "command", "command": "'/old/headroom-hook' pre"}]}]}}
            """)
        #expect(commands(HookInstaller.merged(settings, helperPath: nil), "PreToolUse") == ["other-tool pre"])
    }

    @Test func oddEntriesSurviveInstallAndRemoval() throws {
        let settings = try object(#"{"hooks": {"Stop": ["weird", 5]}}"#)
        let removed = HookInstaller.merged(HookInstaller.merged(settings, helperPath: helper), helperPath: nil)
        #expect(entries(removed, "Stop").count == 2)
    }

    /// Removing when nothing of ours is there must not tidy away an empty array the user wrote.
    @Test func userWrittenEmptyArrayIsKeptByRemoval() throws {
        let settings = try object(#"{"hooks": {"SessionEnd": []}}"#)
        #expect(same(HookInstaller.merged(settings, helperPath: nil), settings))
    }

    @Test func pathsAreShellQuoted() {
        #expect(HookInstaller.command(helperPath: "/Users/o'neil/Headroom.app/Contents/Helpers/headroom-hook",
                                      event: .stop)
                == #"'/Users/o'\''neil/Headroom.app/Contents/Helpers/headroom-hook' stop"#)
    }

    @Test func translocatedAndMountedLocationsAreRefused() {
        #expect(!HookInstaller.isRunnableLocation(
            "/private/var/folders/x/T/AppTranslocation/ABC/d/Headroom.app/Contents/Helpers/headroom-hook"))
        #expect(!HookInstaller.isRunnableLocation("/Volumes/Headroom/Headroom.app/Contents/Helpers/headroom-hook"))
        #expect(HookInstaller.isRunnableLocation(helper))
    }

    // MARK: Files

    private struct Sandbox {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("headroom-installer-\(UUID().uuidString)", isDirectory: true)
        var claude: URL { root.appendingPathComponent(".claude", isDirectory: true) }
        var settings: URL { claude.appendingPathComponent("settings.json") }
        var backup: URL { claude.appendingPathComponent("settings.json.bak-headroom") }
        var helper: URL { root.appendingPathComponent("headroom-hook") }

        func make(claudeDirectory: Bool = true, helper makeHelper: Bool = true) throws -> HookInstaller {
            if claudeDirectory {
                try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
            } else {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            }
            if makeHelper {
                try Data().write(to: helper)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
            }
            return HookInstaller(claudeDirectory: claude, helperPath: helper.path)
        }
    }

    @Test func noClaudeDirectoryDoesNothing() throws {
        let sandbox = Sandbox()
        #expect(try sandbox.make(claudeDirectory: false).apply(enabled: true) == .claudeNotFound)
    }

    @Test func missingHelperRefusesToInstallButStillRemoves() throws {
        let sandbox = Sandbox()
        let installer = try sandbox.make(helper: false)
        #expect(installer.apply(enabled: true) == .helperMissing)
        #expect(!FileManager.default.fileExists(atPath: sandbox.settings.path))
        #expect(installer.apply(enabled: false) == .upToDate)
    }

    @Test func writesOnceThenLeavesTheFileAlone() throws {
        let sandbox = Sandbox()
        let installer = try sandbox.make()
        #expect(installer.apply(enabled: true) == .wrote)
        let first = try Data(contentsOf: sandbox.settings)
        #expect(installer.apply(enabled: true) == .upToDate)
        #expect(try Data(contentsOf: sandbox.settings) == first)
        // No original existed, so there is nothing to back up.
        #expect(!FileManager.default.fileExists(atPath: sandbox.backup.path))
    }

    @Test func backupIsTakenOnceAndNeverOverwritten() throws {
        let sandbox = Sandbox()
        let installer = try sandbox.make()
        let original = Data(#"{"model": "opus"}"#.utf8)
        try original.write(to: sandbox.settings)
        #expect(installer.apply(enabled: true) == .wrote)
        #expect(installer.apply(enabled: false) == .wrote)
        #expect(try Data(contentsOf: sandbox.backup) == original)
    }

    @Test(arguments: [#"{ not json"#, #"{"hooks": []}"#, #"[1, 2]"#])
    func unparseableSettingsAreNeverTouched(_ text: String) throws {
        let sandbox = Sandbox()
        let installer = try sandbox.make()
        try Data(text.utf8).write(to: sandbox.settings)
        #expect(installer.apply(enabled: true) == .unreadableSettings)
        #expect(try Data(contentsOf: sandbox.settings) == Data(text.utf8))
        #expect(!FileManager.default.fileExists(atPath: sandbox.backup.path))
    }

    /// Dotfile managers symlink `settings.json`. An atomic write to the link's path would replace the
    /// link with a plain file and silently detach it from the user's repo.
    @Test func symlinkedSettingsStayASymlink() throws {
        let sandbox = Sandbox()
        let installer = try sandbox.make()
        let real = sandbox.root.appendingPathComponent("dotfiles-settings.json")
        try Data(#"{"model": "opus"}"#.utf8).write(to: real)
        try FileManager.default.createSymbolicLink(at: sandbox.settings, withDestinationURL: real)
        #expect(installer.apply(enabled: true) == .wrote)
        let attributes = try FileManager.default.attributesOfItem(atPath: sandbox.settings.path)
        #expect(attributes[.type] as? FileAttributeType == .typeSymbolicLink)
        let written = try object(String(decoding: try Data(contentsOf: real), as: UTF8.self))
        #expect(!commands(written, "Stop").isEmpty)
    }

    // MARK: Status

    @Test func statusLabels() {
        #expect(HookInstaller.statusLabel(.upToDate, enabled: false, sessionCount: 3) == "Off")
        #expect(HookInstaller.statusLabel(.wrote, enabled: true, sessionCount: 0)
                == "On · new Claude Code sessions will appear")
        #expect(HookInstaller.statusLabel(.upToDate, enabled: true, sessionCount: 0) == "On · no active sessions")
        #expect(HookInstaller.statusLabel(.upToDate, enabled: true, sessionCount: 1) == "On · 1 session")
        #expect(HookInstaller.statusLabel(.wrote, enabled: true, sessionCount: 2) == "On · 2 sessions")
        #expect(HookInstaller.statusLabel(.notInApplications, enabled: true, sessionCount: 0)
                == "Move Headroom to Applications to turn this on")
        #expect(HookInstaller.statusLabel(.unreadableSettings, enabled: false, sessionCount: 0)
                == "Off · couldn't remove hooks from settings.json")
    }
}
```

- [ ] **Step 2: Run to confirm failure**

Run: `swift test --disable-xctest 2>&1 | grep -E "error:" | head -3`
Expected: `cannot find 'HookInstaller' in scope`.

- [ ] **Step 3: Implement `Sources/HeadroomCore/HookInstaller.swift`**

```swift
import Foundation
import HeadroomShared

/// Keeps Headroom's hooks in `~/.claude/settings.json`.
///
/// **The only thing Headroom ever changes in that file is its own hooks** — entries whose command
/// contains `headroom-hook`. Every other key, and every other tool's hook, is carried through.
///
/// Claude Code has no drop-in directory for another app's hooks (a plugin would need the user to run
/// `/plugin install`), so editing the user's settings is the only automatic route. Three things
/// about it were checked against the docs: hooks added this way are not flagged or refused; they are
/// read when a session *starts*, so already-open sessions don't see them; and a hook whose command no
/// longer exists is skipped silently, so a deleted Headroom leaves harmless leftovers.
struct HookInstaller {
    static let marker = "headroom-hook"

    let claudeDirectory: URL
    let helperPath: String

    /// Never call from a test — it is the real `~/.claude`.
    static let `default` = HookInstaller(
        claudeDirectory: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true),
        helperPath: Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/headroom-hook").path)

    var settingsURL: URL { claudeDirectory.appendingPathComponent("settings.json") }
    var backupURL: URL { claudeDirectory.appendingPathComponent("settings.json.bak-headroom") }

    enum Outcome: Equatable {
        case claudeNotFound
        /// Running from a DMG or a translocated copy: that path disappears, and hooks would point
        /// at nothing.
        case notInApplications
        case helperMissing
        /// Not JSON, or `hooks` isn't an object. Never written to.
        case unreadableSettings
        case upToDate
        case wrote
        /// The file changed between reading and writing — most likely Claude Code saving it. Retried
        /// on the next launch rather than risking overwriting that change.
        case changedMeanwhile
        case writeFailed
    }

    func apply(enabled: Bool) -> Outcome {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: claudeDirectory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return .claudeNotFound }
        if enabled {
            guard Self.isRunnableLocation(helperPath) else { return .notInApplications }
            guard fileManager.isExecutableFile(atPath: helperPath) else { return .helperMissing }
        }

        // Resolved, so a dotfiles symlink is written *through* rather than replaced.
        let target = settingsURL.resolvingSymlinksInPath()
        guard let loaded = Self.load(target) else { return .unreadableSettings }
        let next = Self.merged(loaded.settings, helperPath: enabled ? helperPath : nil)
        guard !NSDictionary(dictionary: loaded.settings).isEqual(to: next) else { return .upToDate }
        guard Self.modificationDate(of: target) == loaded.modified else { return .changedMeanwhile }

        do {
            if loaded.modified != nil, !fileManager.fileExists(atPath: backupURL.path) {
                try fileManager.copyItem(at: target, to: backupURL)
            }
            let permissions = (try? fileManager.attributesOfItem(atPath: target.path))?[.posixPermissions]
            // Sorted keys: `JSONSerialization` can't preserve the user's order, so the first write
            // reorders the file once — and sorting makes every later write stable.
            var data = try JSONSerialization.data(
                withJSONObject: next, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            data.append(0x0A)
            try data.write(to: target, options: .atomic)
            if let permissions {
                try? fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: target.path)
            }
            return .wrote
        } catch {
            return .writeFailed
        }
    }

    // MARK: Pure

    /// The settings with Headroom's hooks installed (a path) or removed (nil).
    static func merged(_ settings: [String: Any], helperPath: String?) -> [String: Any] {
        let originalHooks = settings["hooks"] as? [String: Any]
        var hooks = originalHooks ?? [:]

        for event in HookEvent.allCases {
            let name = event.hookName
            let original = hooks[name]
            // Not an array: not ours to interpret, so not ours to touch.
            if let original, !(original is [Any]) { continue }
            // `[Any]` and filter, never `[[String: Any]]` — a conditional cast to the concrete type
            // fails the whole array over one odd entry (the same trap as the usage `limits` array).
            let before = original as? [Any] ?? []

            if let helperPath {
                let ours = entry(for: event, helperPath: helperPath)
                let alreadyThere = before.contains { existing in
                    guard let existing = existing as? [String: Any] else { return false }
                    return NSDictionary(dictionary: existing).isEqual(to: ours)
                }
                // Present exactly once and current: leave its position alone. Moving it to the end
                // would fight any other tool that also appends, rewriting the file on every launch.
                if alreadyThere, before.reduce(0, { $0 + ourHookCount(in: $1) }) == 1 { continue }
            }

            var entries = before.compactMap(stripOurs)
            if let helperPath { entries.append(entry(for: event, helperPath: helperPath)) }
            if entries.isEmpty {
                // Only remove a key this call emptied. An empty array the user wrote stays.
                if !before.isEmpty { hooks.removeValue(forKey: name) }
            } else {
                hooks[name] = entries
            }
        }

        var result = settings
        if hooks.isEmpty, let originalHooks, !originalHooks.isEmpty {
            result.removeValue(forKey: "hooks")
        } else if !hooks.isEmpty || originalHooks != nil {
            result["hooks"] = hooks
        }
        return result
    }

    /// A single bare command, deliberately. The helper finds Claude Code as its parent process; a
    /// wrapper like `PATH=… cmd` or `a && b` can put a shell in between.
    static func command(helperPath: String, event: HookEvent) -> String {
        "'\(helperPath.replacingOccurrences(of: "'", with: #"'\''"#))' \(event.rawValue)"
    }

    static func isRunnableLocation(_ path: String) -> Bool {
        !path.contains("/AppTranslocation/") && !path.hasPrefix("/Volumes/")
    }

    private static func entry(for event: HookEvent, helperPath: String) -> [String: Any] {
        // 5 seconds: the helper finishes in milliseconds and gives up on stdin after 2. The default
        // hook timeout is minutes, which is far too long to hold a session up if something is wrong.
        var entry: [String: Any] = ["hooks": [[
            "type": "command", "command": command(helperPath: helperPath, event: event), "timeout": 5,
        ]]]
        if event.needsMatcher { entry["matcher"] = "*" }
        return entry
    }

    private static func ourHookCount(in entry: Any) -> Int {
        guard let hooks = (entry as? [String: Any])?["hooks"] as? [Any] else { return 0 }
        return hooks.filter { (($0 as? [String: Any])?["command"] as? String)?.contains(marker) == true }.count
    }

    /// The entry with Headroom's hooks taken out; nil when nothing of it remains.
    private static func stripOurs(_ entry: Any) -> Any? {
        guard var dictionary = entry as? [String: Any], let hooks = dictionary["hooks"] as? [Any]
        else { return entry }
        let kept = hooks.filter { (($0 as? [String: Any])?["command"] as? String)?.contains(marker) != true }
        guard kept.count != hooks.count else { return entry }
        guard !kept.isEmpty else { return nil }
        dictionary["hooks"] = kept
        return dictionary
    }

    // MARK: Files

    private static func load(_ url: URL) -> (settings: [String: Any], modified: Date?)? {
        guard FileManager.default.fileExists(atPath: url.path) else { return ([:], nil) }
        let modified = modificationDate(of: url)
        guard let data = try? Data(contentsOf: url) else { return nil }
        if data.allSatisfy({ [0x20, 0x09, 0x0A, 0x0D].contains($0) }) { return ([:], modified) }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let hooks = object["hooks"], !(hooks is [String: Any]) { return nil }
        return (object, modified)
    }

    private static func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    // MARK: Copy

    static func statusLabel(_ outcome: Outcome?, enabled: Bool, sessionCount: Int) -> String {
        guard enabled else {
            switch outcome {
            case .unreadableSettings, .writeFailed, .changedMeanwhile:
                return "Off · couldn't remove hooks from settings.json"
            default:
                return "Off"
            }
        }
        switch outcome {
        case nil: return "Starting…"
        case .claudeNotFound: return "Claude Code not found"
        case .notInApplications: return "Move Headroom to Applications to turn this on"
        case .helperMissing: return "Headroom is incomplete — reinstall it"
        case .unreadableSettings: return "Couldn't read Claude Code's settings.json"
        case .changedMeanwhile, .writeFailed: return "Couldn't update Claude Code's settings.json"
        case .wrote where sessionCount == 0: return "On · new Claude Code sessions will appear"
        case .wrote, .upToDate:
            switch sessionCount {
            case 0: return "On · no active sessions"
            case 1: return "On · 1 session"
            default: return "On · \(sessionCount) sessions"
            }
        }
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `swift test --disable-xctest 2>&1 | tail -3`
Expected: all pass. If `symlinkedSettingsStayASymlink` fails, check `apply` writes to `target`, not `settingsURL`.

- [ ] **Step 5: Commit**

```bash
git add Sources/HeadroomCore/HookInstaller.swift Tests/HeadroomCoreTests/HookInstallerTests.swift
git commit -m "feat: install Headroom's hooks into Claude Code settings, touching nothing else

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: `TranscriptTail` and `GitBranch`

**Files:**
- Create: `Sources/HeadroomCore/TranscriptTail.swift`, `Sources/HeadroomCore/GitBranch.swift`
- Test: `Tests/HeadroomCoreTests/TranscriptTailTests.swift`, `Tests/HeadroomCoreTests/GitBranchTests.swift`

**Interfaces:**
- Produces:
  - `final class TranscriptTail { static let shared; static let marker; func wasInterrupted(transcript: String, after: Date) -> Bool; static func endsInInterrupt(_ data: Data) -> Bool }`
  - `final class GitBranch { static let shared; func branch(cwd: String) -> String?; static func headPath(from directory: String) -> String?; static func branch(fromHead: String) -> String? }`

- [ ] **Step 1: Write the failing tests**

Create `Tests/HeadroomCoreTests/TranscriptTailTests.swift`:

```swift
import Foundation
import Testing

@testable import HeadroomCore

/// `Stop` does not fire when a turn is interrupted with Esc (Claude Code docs), so without this an
/// interrupted session shows "working" forever. The fixtures are shaped on real transcripts: the
/// interrupt marker is frequently *not* the last line.
@Suite struct TranscriptTailTests {
    private func lines(_ entries: String...) -> Data { Data(entries.joined(separator: "\n").utf8) }

    private let assistant = #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"ok"}]}}"#
    private let interrupt = #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]}}"#
    private let toolInterrupt = #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user for tool use]"}]}}"#

    @Test func markerFollowedByBookkeepingEntries() {
        #expect(TranscriptTail.endsInInterrupt(lines(assistant, interrupt,
            #"{"type":"last-prompt"}"#, #"{"type":"ai-title"}"#, #"{"type":"mode"}"#,
            #"{"type":"permission-mode"}"#, #"{"type":"attachment"}"#, #"{"type":"file-history-snapshot"}"#)))
    }

    @Test func toolUseInterrupt() {
        #expect(TranscriptTail.endsInInterrupt(lines(assistant, toolInterrupt)))
    }

    @Test func stringContentForm() {
        #expect(TranscriptTail.endsInInterrupt(lines(
            #"{"type":"user","message":{"role":"user","content":"[Request interrupted by user]"}}"#)))
    }

    @Test func aNewPromptAfterTheMarkerIsNotAnInterrupt() {
        #expect(!TranscriptTail.endsInInterrupt(lines(interrupt,
            #"{"type":"user","message":{"role":"user","content":"try again please"}}"#, #"{"type":"attachment"}"#)))
    }

    @Test func assistantOrToolResultLastIsNotAnInterrupt() {
        #expect(!TranscriptTail.endsInInterrupt(lines(interrupt, assistant)))
        #expect(!TranscriptTail.endsInInterrupt(lines(interrupt,
            #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"ok"}]}}"#)))
    }

    /// The tail starts mid-file, so its first line is usually a fragment.
    @Test func partialFirstLineIsSkipped() {
        #expect(TranscriptTail.endsInInterrupt(lines(#"nt":[{"type":"text"}]}}"#, interrupt)))
        #expect(!TranscriptTail.endsInInterrupt(Data()))
    }

    /// The marker only counts if the transcript was written after the session's last hook event —
    /// otherwise a new turn right after an interrupted one reads as interrupted until Claude replies.
    @Test func olderTranscriptIsNotTrusted() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("t-\(UUID().uuidString).jsonl")
        try lines(assistant, interrupt).write(to: url)
        let written = Date(timeIntervalSince1970: 1_790_000_000)
        try FileManager.default.setAttributes([.modificationDate: written], ofItemAtPath: url.path)
        let tail = TranscriptTail()
        #expect(tail.wasInterrupted(transcript: url.path, after: written.addingTimeInterval(-5)))
        #expect(!tail.wasInterrupted(transcript: url.path, after: written.addingTimeInterval(5)))
        #expect(!tail.wasInterrupted(transcript: "/nonexistent/t.jsonl", after: .distantPast))
    }
}
```

Create `Tests/HeadroomCoreTests/GitBranchTests.swift`:

```swift
import Foundation
import Testing

@testable import HeadroomCore

@Suite struct GitBranchTests {
    private func scratch() throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("headroom-git-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    private func write(_ text: String, to path: String) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        try Data(text.utf8).write(to: URL(fileURLWithPath: path))
    }

    @Test func parsesHead() {
        #expect(GitBranch.branch(fromHead: "ref: refs/heads/feat/session-activity\n") == "feat/session-activity")
        #expect(GitBranch.branch(fromHead: "0a1b2c3d4e5f60718293a4b5c6d7e8f901234567\n") == "0a1b2c3")
        #expect(GitBranch.branch(fromHead: "ref: refs/heads/\n") == nil)
        #expect(GitBranch.branch(fromHead: "garbage") == nil)
    }

    @Test func findsHeadFromANestedDirectory() throws {
        let repo = try scratch()
        try write("ref: refs/heads/main\n", to: "\(repo)/.git/HEAD")
        try FileManager.default.createDirectory(atPath: "\(repo)/Sources/App", withIntermediateDirectories: true)
        // Suffix, not equality: `standardizingPath` may rewrite the temp directory's /private prefix.
        #expect(GitBranch.headPath(from: "\(repo)/Sources/App")?.hasSuffix("/.git/HEAD") == true)
        #expect(GitBranch().branch(cwd: "\(repo)/Sources/App") == "main")
    }

    /// A worktree's `.git` is a file pointing at the real git directory.
    @Test func followsWorktreeGitdirFiles() throws {
        let root = try scratch()
        try write("gitdir: \(root)/main/.git/worktrees/wt\n", to: "\(root)/wt/.git")
        try write("ref: refs/heads/feat/x\n", to: "\(root)/main/.git/worktrees/wt/HEAD")
        #expect(GitBranch().branch(cwd: "\(root)/wt") == "feat/x")
    }

    @Test func relativeGitdir() throws {
        let root = try scratch()
        try write("gitdir: ../main/.git/worktrees/wt\n", to: "\(root)/wt/.git")
        try write("ref: refs/heads/rel\n", to: "\(root)/main/.git/worktrees/wt/HEAD")
        #expect(GitBranch().branch(cwd: "\(root)/wt") == "rel")
    }

    @Test func noRepository() throws {
        #expect(GitBranch().branch(cwd: "") == nil)
        #expect(GitBranch().branch(cwd: "/nonexistent/path") == nil)
    }

    @Test func checkoutIsNoticed() throws {
        let repo = try scratch()
        let head = "\(repo)/.git/HEAD"
        try write("ref: refs/heads/one\n", to: head)
        let git = GitBranch()
        #expect(git.branch(cwd: repo) == "one")
        try write("ref: refs/heads/two\n", to: head)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(10)], ofItemAtPath: head)
        #expect(git.branch(cwd: repo) == "two")
    }
}
```

- [ ] **Step 2: Run to confirm failure**

Run: `swift test --disable-xctest 2>&1 | grep -E "error:" | head -3`
Expected: `cannot find 'TranscriptTail' in scope`.

- [ ] **Step 3: Implement `Sources/HeadroomCore/TranscriptTail.swift`**

```swift
import Foundation

/// Whether a session's turn was interrupted with Esc, read from the end of its transcript.
///
/// Needed because `Stop` does not fire on an interrupt (Claude Code docs), so the session file keeps
/// saying "thinking". Claude Code records the interrupt as a `user` entry whose text starts with
/// `[Request interrupted by user` — measured in real transcripts, and often followed by bookkeeping
/// entries (`last-prompt`, `ai-title`, `mode`, `permission-mode`, `attachment`,
/// `file-history-snapshot`), which is why this looks for the last *conversational* entry rather
/// than the last line.
///
/// Main thread only, like everything that reads sessions.
final class TranscriptTail {
    static let shared = TranscriptTail()
    static let marker = "[Request interrupted by user"
    static let tailBytes = 64_000

    private var cache: [String: (modified: Date, interrupted: Bool)] = [:]

    /// True only if the transcript was written at or after `after` — the session's last hook event.
    /// An older marker belongs to a previous turn: a new prompt fires its hook before Claude Code
    /// writes the prompt into the transcript.
    func wasInterrupted(transcript path: String, after: Date) -> Bool {
        guard let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date,
              modified >= after else { return false }
        if let hit = cache[path], hit.modified == modified { return hit.interrupted }
        let interrupted = Self.endsInInterrupt(Self.tail(of: path))
        cache[path] = (modified, interrupted)
        return interrupted
    }

    static func tail(of path: String) -> Data {
        guard let handle = FileHandle(forReadingAtPath: path) else { return Data() }
        defer { try? handle.close() }
        let size = handle.seekToEndOfFile()
        handle.seek(toFileOffset: size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0)
        return handle.readDataToEndOfFile()
    }

    static func endsInInterrupt(_ data: Data) -> Bool {
        for line in data.split(separator: 0x0A).reversed() {
            // The first line of a tail is usually a fragment; it fails to parse and is skipped.
            guard let entry = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let type = entry["type"] as? String, type == "user" || type == "assistant"
            else { continue }
            guard type == "user", let message = entry["message"] as? [String: Any] else { return false }
            return text(of: message["content"]).hasPrefix(marker)
        }
        return false
    }

    private static func text(of content: Any?) -> String {
        if let string = content as? String { return string }
        for block in content as? [Any] ?? [] {
            if let block = block as? [String: Any], block["type"] as? String == "text",
               let text = block["text"] as? String { return text }
        }
        return ""
    }
}
```

- [ ] **Step 4: Implement `Sources/HeadroomCore/GitBranch.swift`**

```swift
import Foundation

/// The branch a session is on, from `.git/HEAD` directly — no `git` process per poll.
///
/// Main thread only.
final class GitBranch {
    static let shared = GitBranch()

    private var cache: [String: (head: String, modified: Date?, branch: String?)] = [:]

    func branch(cwd: String) -> String? {
        guard !cwd.isEmpty, let head = Self.headPath(from: cwd) else { return nil }
        // Keyed on HEAD's mtime: git rewrites the file on checkout, so a switch is picked up.
        let modified = (try? FileManager.default.attributesOfItem(atPath: head))?[.modificationDate] as? Date
        if let hit = cache[cwd], hit.head == head, hit.modified == modified { return hit.branch }
        let branch = (try? String(contentsOfFile: head, encoding: .utf8)).flatMap(Self.branch(fromHead:))
        cache[cwd] = (head, modified, branch)
        return branch
    }

    /// Walks up to the nearest `.git`. A directory holds `HEAD`; a file (a worktree or submodule)
    /// names the real git directory with `gitdir:`, absolute or relative.
    static func headPath(from directory: String) -> String? {
        let fileManager = FileManager.default
        var current = (directory as NSString).standardizingPath
        for _ in 0..<64 {
            let dotGit = (current as NSString).appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: dotGit, isDirectory: &isDirectory) {
                if isDirectory.boolValue { return (dotGit as NSString).appendingPathComponent("HEAD") }
                guard let text = try? String(contentsOfFile: dotGit, encoding: .utf8),
                      let line = text.split(whereSeparator: \.isNewline).first,
                      line.hasPrefix("gitdir:") else { return nil }
                let raw = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
                let gitDirectory = raw.hasPrefix("/") ? raw : (current as NSString).appendingPathComponent(raw)
                return ((gitDirectory as NSString).standardizingPath as NSString).appendingPathComponent("HEAD")
            }
            guard current != "/" else { return nil }
            current = (current as NSString).deletingLastPathComponent
        }
        return nil
    }

    /// `ref: refs/heads/<name>` → name; a detached SHA → its first 7 characters.
    static func branch(fromHead text: String) -> String? {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "ref: refs/heads/"
        if line.hasPrefix(prefix) {
            let name = line.dropFirst(prefix.count)
            return name.isEmpty ? nil : String(name.prefix(64))
        }
        if line.count >= 7, line.allSatisfy(\.isHexDigit) { return String(line.prefix(7)) }
        return nil
    }
}
```

- [ ] **Step 5: Run the tests**

Run: `swift test --disable-xctest 2>&1 | tail -3`
Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/HeadroomCore/TranscriptTail.swift Sources/HeadroomCore/GitBranch.swift Tests/HeadroomCoreTests/TranscriptTailTests.swift Tests/HeadroomCoreTests/GitBranchTests.swift
git commit -m "feat: detect Esc interrupts from transcripts and read git branches without git

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: `SessionActivity`

**Files:**
- Create: `Sources/HeadroomCore/SessionActivity.swift`
- Test: `Tests/HeadroomCoreTests/SessionActivityTests.swift`

**Interfaces:**
- Consumes: `SessionFiles`, `SessionRecord`, `SessionState`, `SessionLabels` (Task 1); `TranscriptTail.shared.wasInterrupted(transcript:after:)`, `GitBranch.shared.branch(cwd:)` (Task 4)
- Produces:
  - `struct Session: Equatable { let id: String; let state: SessionState; let label: String; let project: String; let branch: String?; let turnStartedAt: Date?; let updatedAt: Date }`
  - `struct SessionActivity { let directory: URL; var isAlive: (Int32) -> Bool; var interrupted: (String, Date) -> Bool; var branch: (String) -> String?; static let default; func sessions(now: Date = Date()) -> [Session]; static func projectNames(cwds: [String]) -> [String] }`
  - Copy: `static let menuHeading = "CLAUDE CODE"`, `settingsHeading = "CLAUDE CODE SESSIONS"`, `trackMenuTitle = "Track Claude Code Sessions"`, `idleLabel = "Idle"`, `workingLabel = "Working"`, `endedLabel = "Ended"`, `static func moreLabel(_ count: Int) -> String`

- [ ] **Step 1: Write the failing tests**

Create `Tests/HeadroomCoreTests/SessionActivityTests.swift`:

```swift
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
        #expect(activity().sessions(now: now).isEmpty)
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
```

- [ ] **Step 2: Run to confirm failure**

Run: `swift test --disable-xctest 2>&1 | grep -E "error:" | head -3`
Expected: `cannot find 'SessionActivity' in scope`.

- [ ] **Step 3: Implement `Sources/HeadroomCore/SessionActivity.swift`**

```swift
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
```

- [ ] **Step 4: Run the tests**

Run: `swift test --disable-xctest 2>&1 | tail -3`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/HeadroomCore/SessionActivity.swift Tests/HeadroomCoreTests/SessionActivityTests.swift
git commit -m "feat: read live Claude Code sessions with liveness, interrupt and age rules

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: `UpdateCheck` and the new settings

**Files:**
- Create: `Sources/HeadroomCore/UpdateCheck.swift`
- Modify: `Sources/HeadroomCore/Settings.swift` (keys + four properties)
- Test: `Tests/HeadroomCoreTests/UpdateCheckTests.swift`; modify `Tests/HeadroomCoreTests/DefaultsBackedTests.swift` (inside `SettingsTests`)

**Interfaces:**
- Consumes: `isJSONBoolean` (Task 1)
- Produces:
  - `struct Release: Equatable { let version: [Int]; let tag: String; let url: URL }`
  - `enum UpdateCheck` with `endpoint`, `launchDelay: TimeInterval = 60`, `interval: TimeInterval = 86_400`, `static func version(_:) -> [Int]?`, `static func isNewer(_:than:) -> Bool`, `static func release(in: [String: Any]) -> Release?`, `static func available(data:response:error:currentVersion:) -> Release?`, `static func isDue(lastAttempt: Date?, now: Date) -> Bool`, `static func pending(known: Release?, currentVersion: String) -> Release?`, `static func menuTitle(_: Release) -> String`, `static let settingsTitle`, `static func fetch(currentVersion:completion:)`
  - `Settings.trackSessions: Bool` (default true), `Settings.checkForUpdates: Bool` (default true), `Settings.lastUpdateCheck: Date?`, `Settings.knownRelease: Release?`

- [ ] **Step 1: Write the failing tests**

Create `Tests/HeadroomCoreTests/UpdateCheckTests.swift`:

```swift
import Foundation
import Testing

@testable import HeadroomCore

@Suite struct UpdateCheckTests {
    private func object(_ text: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    private func response(_ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: UpdateCheck.endpoint, statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    private let release = """
        {"tag_name": "v0.2.0", "html_url": "https://github.com/vickipetrova/headroom/releases/tag/v0.2.0",
         "draft": false, "prerelease": false}
        """

    @Test(arguments: [("v0.2.0", [0, 2, 0]), ("0.10.1", [0, 10, 1]), ("V1", [1]), ("1.2.3.4", [1, 2, 3, 4])])
    func versionsParse(_ raw: String, _ expected: [Int]) {
        #expect(UpdateCheck.version(raw) == expected)
    }

    @Test(arguments: ["v0.2.0-beta.1", "", "v", "1..2", "latest", "1.2.3.4.5", "1.x", "１.２"])
    func junkVersionsDoNot(_ raw: String) {
        #expect(UpdateCheck.version(raw) == nil)
    }

    /// Compared numerically — a string compare says 0.9.0 is newer than 0.10.0.
    @Test func comparison() {
        #expect(UpdateCheck.isNewer([0, 10, 0], than: [0, 9, 0]))
        #expect(!UpdateCheck.isNewer([0, 1, 0], than: [0, 1, 0]))
        #expect(!UpdateCheck.isNewer([0, 1], than: [0, 1, 0]))
        #expect(UpdateCheck.isNewer([1], than: [0, 99, 99]))
        #expect(!UpdateCheck.isNewer([0, 1, 0], than: [0, 2, 0]))
    }

    @Test func parsesTheLatestRelease() throws {
        let parsed = try #require(UpdateCheck.release(in: try object(release)))
        #expect(parsed.tag == "v0.2.0")
        #expect(parsed.version == [0, 2, 0])
        #expect(parsed.url.absoluteString == "https://github.com/vickipetrova/headroom/releases/tag/v0.2.0")
    }

    @Test(arguments: [
        #"{"tag_name": "v0.2.0", "html_url": "https://evil.example/headroom"}"#,
        #"{"tag_name": "v0.2.0", "html_url": "http://github.com/vickipetrova/headroom/releases/tag/v0.2.0"}"#,
        #"{"tag_name": "v0.2.0", "html_url": "https://github.com/someone-else/headroom/releases/tag/v0.2.0"}"#,
        #"{"tag_name": 2, "html_url": "https://github.com/vickipetrova/headroom/releases/tag/v0.2.0"}"#,
        #"{"html_url": "https://github.com/vickipetrova/headroom/releases/tag/v0.2.0"}"#,
        #"{"tag_name": "v0.2.0", "html_url": "https://github.com/vickipetrova/headroom/releases/tag/v0.2.0", "draft": true}"#,
        #"{"tag_name": "v0.2.0", "html_url": "https://github.com/vickipetrova/headroom/releases/tag/v0.2.0", "prerelease": true}"#,
    ])
    func untrustworthyReleasesAreIgnored(_ text: String) throws {
        #expect(UpdateCheck.release(in: try object(text)) == nil)
    }

    @Test func availableOnlyWhenNewer() {
        let data = Data(release.utf8)
        #expect(UpdateCheck.available(data: data, response: response(200), error: nil, currentVersion: "0.1.0") != nil)
        #expect(UpdateCheck.available(data: data, response: response(200), error: nil, currentVersion: "0.2.0") == nil)
        #expect(UpdateCheck.available(data: data, response: response(200), error: nil, currentVersion: "0.3.0") == nil)
    }

    /// Before the first release GitHub answers 404. That is the normal state, not an error to show.
    @Test func failuresAreSilent() {
        let data = Data(release.utf8)
        #expect(UpdateCheck.available(data: Data("{}".utf8), response: response(404), error: nil, currentVersion: "0.1.0") == nil)
        #expect(UpdateCheck.available(data: data, response: response(403), error: nil, currentVersion: "0.1.0") == nil)
        #expect(UpdateCheck.available(data: nil, response: nil, error: URLError(.notConnectedToInternet), currentVersion: "0.1.0") == nil)
        #expect(UpdateCheck.available(data: Data("<html>".utf8), response: response(200), error: nil, currentVersion: "0.1.0") == nil)
    }

    @Test func dueOncePerDayMeasuredFromTheLastAttempt() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        #expect(UpdateCheck.isDue(lastAttempt: nil, now: now))
        #expect(!UpdateCheck.isDue(lastAttempt: now.addingTimeInterval(-3600), now: now))
        #expect(UpdateCheck.isDue(lastAttempt: now.addingTimeInterval(-86_400), now: now))
        // The clock moved backwards: don't wait up to a day on a timestamp from the future.
        #expect(UpdateCheck.isDue(lastAttempt: now.addingTimeInterval(3600), now: now))
    }

    /// A release found yesterday must still show after a restart today, and vanish once installed.
    @Test func pendingSurvivesUntilInstalled() throws {
        let known = try #require(UpdateCheck.release(in: try object(release)))
        #expect(UpdateCheck.pending(known: known, currentVersion: "0.1.0") == known)
        #expect(UpdateCheck.pending(known: known, currentVersion: "0.2.0") == nil)
        #expect(UpdateCheck.pending(known: nil, currentVersion: "0.1.0") == nil)
    }

    @Test func menuTitle() throws {
        let known = try #require(UpdateCheck.release(in: try object(release)))
        #expect(UpdateCheck.menuTitle(known) == "Update Available: v0.2.0…")
    }
}
```

In `Tests/HeadroomCoreTests/DefaultsBackedTests.swift`, inside `@Suite struct SettingsTests { … }`, add:

```swift
        @Test func sessionTrackingAndUpdateChecksDefaultOn() {
            #expect(Settings.trackSessions)
            #expect(Settings.checkForUpdates)
            #expect(Settings.lastUpdateCheck == nil)
            #expect(Settings.knownRelease == nil)
        }

        /// Same trap as the threshold: `bool(forKey:)` is false for a missing key, so "off" has to be
        /// told apart from "never set" or turning it off would not survive a relaunch.
        @Test func turningThemOffIsPersisted() {
            Settings.trackSessions = false
            Settings.checkForUpdates = false
            #expect(!Settings.trackSessions)
            #expect(!Settings.checkForUpdates)
        }

        @Test func knownReleaseRoundTripsAndIsRevalidated() throws {
            let release = try #require(UpdateCheck.release(in: [
                "tag_name": "v0.2.0",
                "html_url": "https://github.com/vickipetrova/headroom/releases/tag/v0.2.0",
            ]))
            Settings.knownRelease = release
            #expect(Settings.knownRelease == release)
            // A hand-edited plist can't smuggle in a link to somewhere else.
            defaults.set(["tag_name": "v9.9.9", "html_url": "https://evil.example/"], forKey: "knownRelease")
            #expect(Settings.knownRelease == nil)
            Settings.knownRelease = nil
            #expect(defaults.object(forKey: "knownRelease") == nil)
        }
```

- [ ] **Step 2: Run to confirm failure**

Run: `swift test --disable-xctest 2>&1 | grep -E "error:" | head -3`
Expected: `cannot find 'UpdateCheck' in scope`.

- [ ] **Step 3: Implement `Sources/HeadroomCore/UpdateCheck.swift`**

```swift
import Foundation
import HeadroomShared

struct Release: Equatable {
    let version: [Int]
    let tag: String
    let url: URL
}

/// Once a day, asks GitHub whether a newer Headroom has been published.
///
/// Headroom's second network destination, and the only one besides the usage endpoint (hard rule 5).
/// It sends no identifiers, can be turned off, and never downloads anything: it only puts a menu item
/// up that opens the release page.
///
/// `releases/latest` returns the newest release that is neither a draft nor a pre-release, and 404
/// when there is none (GitHub REST docs) — which is the normal answer until the first release, and is
/// treated as "no update", silently.
enum UpdateCheck {
    static let endpoint = URL(string: "https://api.github.com/repos/vickipetrova/headroom/releases/latest")!
    static let releasePathPrefix = "/vickipetrova/headroom/"
    /// Not at launch: the first seconds belong to the usage poll and the menu bar appearing.
    static let launchDelay: TimeInterval = 60
    static let interval: TimeInterval = 24 * 3600

    static let settingsTitle = "Check for Updates Automatically"

    static func menuTitle(_ release: Release) -> String { "Update Available: \(release.tag)…" }

    /// `v0.2.0` → `[0, 2, 0]`. Anything with a suffix (`-beta.1`) is nil: `latest` excludes
    /// pre-releases already, and an odd tag is safer ignored than misread.
    static func version(_ string: String) -> [Int]? {
        var text = Substring(string)
        if text.hasPrefix("v") || text.hasPrefix("V") { text = text.dropFirst() }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(parts.count) else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard (1...6).contains(part.count), part.allSatisfy({ ("0"..."9").contains($0) }),
                  let number = Int(part) else { return nil }
            numbers.append(number)
        }
        return numbers
    }

    /// Component-wise, missing components count as zero, so `0.1` equals `0.1.0`.
    static func isNewer(_ candidate: [Int], than current: [Int]) -> Bool {
        for index in 0..<max(candidate.count, current.count) {
            let left = index < candidate.count ? candidate[index] : 0
            let right = index < current.count ? current[index] : 0
            if left != right { return left > right }
        }
        return false
    }

    static func release(in object: [String: Any]) -> Release? {
        guard let tag = object["tag_name"] as? String, let version = version(tag),
              let raw = object["html_url"] as? String, let url = URL(string: raw),
              url.scheme == "https", url.host == "github.com",
              url.path.hasPrefix(releasePathPrefix) else { return nil }
        for flag in ["draft", "prerelease"] {
            if let value = object[flag], isJSONBoolean(value), (value as? Bool) == true { return nil }
        }
        return Release(version: version, tag: tag, url: url)
    }

    /// Everything between the socket and the menu, pure — the same split as `ClaudeProvider.result`.
    static func available(data: Data?, response: URLResponse?, error: Error?,
                          currentVersion: String) -> Release? {
        guard error == nil, (response as? HTTPURLResponse)?.statusCode == 200, let data,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let release = release(in: object) else { return nil }
        return pending(known: release, currentVersion: currentVersion)
    }

    static func pending(known: Release?, currentVersion: String) -> Release? {
        guard let known, let current = version(currentVersion),
              isNewer(known.version, than: current) else { return nil }
        return known
    }

    static func isDue(lastAttempt: Date?, now: Date) -> Bool {
        guard let lastAttempt else { return true }
        let elapsed = now.timeIntervalSince(lastAttempt)
        return elapsed >= interval || elapsed < 0
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 15
        return URLSession(configuration: config)
    }()

    /// Real network. Never call from a test.
    static func fetch(currentVersion: String, completion: @escaping (Release?) -> Void) {
        var request = URLRequest(url: endpoint)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // Required: GitHub rejects API requests without a User-Agent.
        request.setValue("Headroom/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        session.dataTask(with: request) { data, response, error in
            completion(available(data: data, response: response, error: error, currentVersion: currentVersion))
        }.resume()
    }
}
```

- [ ] **Step 4: Add the settings to `Sources/HeadroomCore/Settings.swift`**

Add to `private enum Key`:

```swift
        static let trackSessions = "trackSessions"
        static let checkForUpdates = "checkForUpdates"
        static let lastUpdateCheck = "lastUpdateCheck"
        static let knownRelease = "knownRelease"
```

Add above `launchAtLogin`:

```swift
    /// On by default. Probed for existence first, because `bool(forKey:)` returns false for a missing
    /// key and "off" has to survive a relaunch.
    static var trackSessions: Bool {
        get { defaults.object(forKey: Key.trackSessions) == nil ? true : defaults.bool(forKey: Key.trackSessions) }
        set { defaults.set(newValue, forKey: Key.trackSessions) }
    }

    static var checkForUpdates: Bool {
        get { defaults.object(forKey: Key.checkForUpdates) == nil ? true : defaults.bool(forKey: Key.checkForUpdates) }
        set { defaults.set(newValue, forKey: Key.checkForUpdates) }
    }

    /// When the update check last *tried*, successful or not — so a network that is down doesn't turn
    /// once a day into once an hour.
    static var lastUpdateCheck: Date? {
        get { defaults.object(forKey: Key.lastUpdateCheck) as? Date }
        set { defaults.set(newValue, forKey: Key.lastUpdateCheck) }
    }

    /// The newest release seen, kept so an update found yesterday still shows after a restart today.
    /// Stored in the API's own shape and re-read through `UpdateCheck.release(in:)`, so a hand-edited
    /// plist gets the same URL checks as the network does.
    static var knownRelease: Release? {
        get { defaults.dictionary(forKey: Key.knownRelease).flatMap(UpdateCheck.release(in:)) }
        set {
            guard let newValue else { return defaults.removeObject(forKey: Key.knownRelease) }
            defaults.set(["tag_name": newValue.tag, "html_url": newValue.url.absoluteString],
                         forKey: Key.knownRelease)
        }
    }
```

- [ ] **Step 5: Run the tests**

Run: `swift test --disable-xctest 2>&1 | tail -3`
Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/HeadroomCore/UpdateCheck.swift Sources/HeadroomCore/Settings.swift Tests/HeadroomCoreTests/UpdateCheckTests.swift Tests/HeadroomCoreTests/DefaultsBackedTests.swift
git commit -m "feat: daily GitHub Releases update check and settings for the new features

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 7: Formatting, title image, and session rows

**Files:**
- Modify: `Sources/HeadroomCore/Format.swift` (add `elapsed`; replace `sparkImage(mode:)` with `statusImage(mode:rotation:permissionDot:)`)
- Modify: `Sources/HeadroomCore/MenuController.swift:142` (the one `Fmt.sparkImage` call, temporarily → `Fmt.statusImage(mode: Settings.colorMode)`)
- Create: `Sources/HeadroomCore/SessionPanel.swift`
- Test: `Tests/HeadroomCoreTests/FormatTests.swift` (append), `Tests/HeadroomCoreTests/SessionPanelTests.swift`

**Interfaces:**
- Consumes: `Session`, `SessionActivity` copy (Task 5); `SessionState` (Task 1); `PanelMetrics` (existing)
- Produces:
  - `Fmt.elapsed(since: Date?, now: Date = Date()) -> String`
  - `Fmt.statusImage(mode: Settings.ColorMode, rotation: CGFloat = 0, permissionDot: Bool = false) -> NSImage`
  - `struct SessionRow: Equatable { let title: String; let status: String; let needsAttention: Bool; var spoken: String; init(_ session: Session, now: Date); var ended: SessionRow }`
  - `enum SessionPanel { static let rowLimit = 6; static func visible(_ sessions: [Session], limit: Int = rowLimit) -> (shown: [Session], hidden: Int) }`
  - `struct SessionRowView: View { let row: SessionRow; let mode: Settings.ColorMode }`, `struct PanelHeadingView: View { let text: String }`

- [ ] **Step 1: Write the failing tests**

Append to `Tests/HeadroomCoreTests/FormatTests.swift` a new suite at file end (add `import AppKit` at the top of the file if it isn't there — the suite reads `NSImage` members):

```swift
@Suite struct ElapsedAndImageTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    @Test(arguments: [(0.0, "0s"), (59, "59s"), (60, "1m 00s"), (65, "1m 05s"),
                      (3599, "59m 59s"), (3600, "1h 00m"), (3720, "1h 02m")])
    func elapsed(_ seconds: Double, _ expected: String) {
        #expect(Fmt.elapsed(since: now.addingTimeInterval(-seconds), now: now) == expected)
    }

    @Test func elapsedEdges() {
        #expect(Fmt.elapsed(since: nil, now: now) == "")
        #expect(Fmt.elapsed(since: now.addingTimeInterval(30), now: now) == "0s")
    }

    @Test func statusImage() {
        let plain = Fmt.statusImage(mode: .alertsOnly)
        let dotted = Fmt.statusImage(mode: .alertsOnly, permissionDot: true)
        #expect(dotted.size.width > plain.size.width)
        #expect(dotted.size.height == plain.size.height)
        #expect(!plain.isTemplate)
        #expect(Fmt.statusImage(mode: .system, rotation: 22.5, permissionDot: true).isTemplate)
        // Rotation must not change the size, or the title would jitter sideways as it spins.
        #expect(Fmt.statusImage(mode: .alertsOnly, rotation: 33.75).size == plain.size)
    }
}
```

Create `Tests/HeadroomCoreTests/SessionPanelTests.swift`:

```swift
import Foundation
import Testing

@testable import HeadroomCore
@testable import HeadroomShared

@Suite struct SessionPanelTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func session(_ state: SessionState, label: String = "", branch: String? = "main",
                         id: String = "a", started: TimeInterval? = 65) -> Session {
        Session(id: id, state: state, label: label, project: "headroom", branch: branch,
                turnStartedAt: started.map { now.addingTimeInterval(-$0) }, updatedAt: now)
    }

    @Test func toolRowShowsLabelAndElapsed() {
        let row = SessionRow(session(.tool, label: "Editing"), now: now)
        #expect(row.title == "headroom · main")
        #expect(row.status == "Editing · 1m 05s")
        #expect(!row.needsAttention)
        #expect(row.spoken == "headroom · main, Editing · 1m 05s")
    }

    @Test func thinkingWithoutALabelOrStart() {
        #expect(SessionRow(session(.thinking, started: nil), now: now).status == "Working")
    }

    @Test func permissionNeedsAttention() {
        let row = SessionRow(session(.permission, label: "Awaiting permission"), now: now)
        #expect(row.status == "Awaiting permission")
        #expect(row.needsAttention)
    }

    @Test func idleAndNoBranch() {
        let row = SessionRow(session(.idle, branch: nil), now: now)
        #expect(row.title == "headroom")
        #expect(row.status == "Idle")
    }

    @Test func endedKeepsTheTitle() {
        let ended = SessionRow(session(.permission, label: "Awaiting permission"), now: now).ended
        #expect(ended.title == "headroom · main")
        #expect(ended.status == "Ended")
        #expect(!ended.needsAttention)
    }

    @Test func rowCap() {
        let sessions = (0..<8).map { session(.idle, id: "s\($0)") }
        let visible = SessionPanel.visible(sessions)
        #expect(visible.shown.count == 6)
        #expect(visible.hidden == 2)
        #expect(SessionPanel.visible(Array(sessions.prefix(6))).hidden == 0)
    }
}
```

- [ ] **Step 2: Run to confirm failure**

Run: `swift test --disable-xctest 2>&1 | grep -E "error:" | head -3`
Expected: `type 'Fmt' has no member 'elapsed'`.

- [ ] **Step 3: Add `Fmt.elapsed` and `Fmt.statusImage` in `Sources/HeadroomCore/Format.swift`**

Add after `age(of:from:)`:

```swift
    /// How long a turn has been running: `12s`, `1m 05s`, `1h 02m`. Empty without a start.
    static func elapsed(since start: Date?, now: Date = Date()) -> String {
        guard let start else { return "" }
        let interval = now.timeIntervalSince(start)
        // Bounded before the Int conversion, which traps on anything non-finite or out of range.
        guard interval.isFinite, interval < 1_000_000_000 else { return "" }
        let seconds = max(0, Int(interval))
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return String(format: "%dm %02ds", minutes, seconds % 60) }
        return String(format: "%dh %02dm", minutes / 60, minutes % 60)
    }
```

Replace the whole `sparkImage(mode:)` function (keep its doc comment, extended) with:

```swift
    /// The spark for the menu bar, drawn as an image rather than set as a character in the title.
    ///
    /// (Keep the existing paragraphs about template images, opaque black, and the drawing handler.)
    ///
    /// `rotation` spins the glyph while a Claude Code session is working. ✻ has eight spokes, so
    /// four frames of 11.25° read as continuous motion, and rotating about the centre within the
    /// unrotated canvas keeps the image the same size — the title must not jitter sideways.
    /// `permissionDot` draws a dot after the spark when a session is waiting on the user: yellow in
    /// Alerts-only, and part of the template (so monochrome) in System.
    static func statusImage(mode: Settings.ColorMode, rotation: CGFloat = 0,
                            permissionDot: Bool = false) -> NSImage {
        let glyph = "✻" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: mode == .system ? NSColor.black : spark,
        ]
        let glyphSize = glyph.size(withAttributes: attributes)
        let sparkWidth = ceil(glyphSize.width)
        let height = ceil(glyphSize.height)
        let dotDiameter: CGFloat = 6
        let dotGap: CGFloat = 2
        let width = sparkWidth + (permissionDot ? dotGap + dotDiameter : 0)

        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            if rotation != 0, let context = NSGraphicsContext.current?.cgContext {
                context.saveGState()
                context.translateBy(x: sparkWidth / 2, y: height / 2)
                context.rotate(by: -rotation * .pi / 180)
                context.translateBy(x: -sparkWidth / 2, y: -height / 2)
                glyph.draw(at: .zero, withAttributes: attributes)
                context.restoreGState()
            } else {
                glyph.draw(at: .zero, withAttributes: attributes)
            }
            if permissionDot {
                (mode == .system ? NSColor.black : NSColor.systemYellow).setFill()
                NSBezierPath(ovalIn: NSRect(x: sparkWidth + dotGap, y: (height - dotDiameter) / 2,
                                            width: dotDiameter, height: dotDiameter)).fill()
            }
            return true
        }
        image.isTemplate = mode == .system
        return image
    }
```

In `Sources/HeadroomCore/MenuController.swift`, change `button.image = Fmt.sparkImage(mode: Settings.colorMode)` to `button.image = Fmt.statusImage(mode: Settings.colorMode)` (Task 8 replaces it properly). Run `grep -rn sparkImage Sources Tests` and update any remaining call the same way.

- [ ] **Step 4: Create `Sources/HeadroomCore/SessionPanel.swift`**

```swift
import AppKit
import HeadroomShared
import SwiftUI

/// One row of the dropdown's `CLAUDE CODE` section. Pure, for the same reason as `UsageRow`:
/// `MenuController` can't be constructed in a test.
struct SessionRow: Equatable {
    /// "headroom · feat/session-activity"
    let title: String
    /// "Editing · 1m 05s", "Awaiting permission", "Idle"
    let status: String
    let needsAttention: Bool

    var spoken: String { "\(title), \(status)" }

    init(title: String, status: String, needsAttention: Bool) {
        self.title = title
        self.status = status
        self.needsAttention = needsAttention
    }

    init(_ session: Session, now: Date) {
        title = session.branch.map { "\(session.project) · \($0)" } ?? session.project
        needsAttention = session.state == .permission
        switch session.state {
        case .permission:
            status = session.label.isEmpty ? SessionLabels.permission : session.label
        case .idle:
            status = SessionActivity.idleLabel
        case .thinking, .tool:
            let label = session.label.isEmpty ? SessionActivity.workingLabel : session.label
            let elapsed = Fmt.elapsed(since: session.turnStartedAt, now: now)
            status = elapsed.isEmpty ? label : "\(label) · \(elapsed)"
        }
    }

    /// What a held-open row shows once its session has gone. Rows can't be removed from an open menu.
    var ended: SessionRow {
        SessionRow(title: title, status: SessionActivity.endedLabel, needsAttention: false)
    }
}

enum SessionPanel {
    static let rowLimit = 6

    static func visible(_ sessions: [Session], limit: Int = rowLimit) -> (shown: [Session], hidden: Int) {
        (Array(sessions.prefix(limit)), max(0, sessions.count - limit))
    }
}

struct SessionRowView: View {
    let row: SessionRow
    let mode: Settings.ColorMode

    var body: some View {
        HStack(spacing: 8) {
            Text(row.title)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            if row.needsAttention {
                Circle()
                    .fill(Color(nsColor: mode == .system ? .labelColor : .systemYellow))
                    .frame(width: 6, height: 6)
            }
            Text(row.status)
                .font(.callout)
                .foregroundStyle(.secondary)
                // The elapsed time ticks every second; it must not shuffle the row sideways.
                .monospacedDigit()
                .lineLimit(1)
        }
        .padding(.horizontal, PanelMetrics.horizontalPadding)
        .padding(.vertical, 3)
        .frame(minWidth: PanelMetrics.minimumWidth, maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.spoken)
    }
}

/// A section heading in the main dropdown, matching the weight of `UsageRowView`'s headings.
struct PanelHeadingView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.callout.weight(.semibold))
            .padding(.horizontal, PanelMetrics.horizontalPadding)
            .padding(.top, 5)
            .padding(.bottom, 1)
            .frame(minWidth: PanelMetrics.minimumWidth, maxWidth: .infinity, alignment: .leading)
    }
}
```

- [ ] **Step 5: Run the tests**

Run: `swift test --disable-xctest 2>&1 | tail -3`
Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/HeadroomCore/Format.swift Sources/HeadroomCore/MenuController.swift Sources/HeadroomCore/SessionPanel.swift Tests/HeadroomCoreTests/FormatTests.swift Tests/HeadroomCoreTests/SessionPanelTests.swift
git commit -m "feat: elapsed-time formatting, animated status image, and session row views

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 8: Wire it into the menu and the app delegate

Not unit-testable (`MenuController` and `AppDelegate` must never be constructed in a test); verified by building and running the app.

**Files:**
- Create: `Sources/HeadroomCore/DirectoryWatcher.swift`
- Modify: `Sources/HeadroomCore/MenuController.swift`, `Sources/HeadroomCore/AppDelegate.swift`

**Interfaces:**
- Consumes: everything from Tasks 3–7.
- Produces on `MenuController`: `var onTrackSessionsChanged: (() -> Void)?`, `var onCheckForUpdatesChanged: (() -> Void)?`, `var hookOutcome: HookInstaller.Outcome?`, `func update(sessions: [Session])`, `func update(release: Release?)`, `func advanceAnimation()`.

- [ ] **Step 1: Create `Sources/HeadroomCore/DirectoryWatcher.swift`**

```swift
import Foundation

/// Calls back when files in a directory are added, replaced or removed.
///
/// The hook helper writes atomically — a rename into the directory — which changes the directory
/// itself, so watching the directory catches every write without watching each file. Debounced,
/// because one tool call produces a PreToolUse and a PostToolUse within milliseconds.
final class DirectoryWatcher {
    private let source: DispatchSourceFileSystemObject
    private var pending: DispatchWorkItem?

    init?(directory: URL, debounce: TimeInterval = 0.1, onChange: @escaping () -> Void) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let descriptor = open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .delete, .rename], queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.pending?.cancel()
            let work = DispatchWorkItem(block: onChange)
            self.pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + debounce, execute: work)
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
    }

    deinit {
        pending?.cancel()
        source.cancel()
    }
}
```

- [ ] **Step 2: Add state and inputs to `MenuController`**

Add `import HeadroomShared` at the top. Below `var onSettingsChanged`, add:

```swift
    /// Called when Track Claude Code Sessions is toggled, so hooks are installed or removed.
    var onTrackSessionsChanged: (() -> Void)?

    /// Called when automatic update checks are toggled.
    var onCheckForUpdatesChanged: (() -> Void)?

    /// The last result of installing hooks, for the Settings status line.
    var hookOutcome: HookInstaller.Outcome?
```

Below `private var lastError: Error?`, add:

```swift
    /// Most urgent first (`SessionActivity` sorts them), so the first one decides the title.
    private var sessions: [Session] = []
    private var animationFrame = 0
    private var availableRelease: Release?
```

In the `// MARK: - Input` section, add:

```swift
    func update(sessions: [Session]) {
        self.sessions = sessions
        renderTitle()
        refreshLiveRows()
    }

    func update(release: Release?) {
        availableRelease = release
        // Shape change (an item appears), so it shows on the next open, like any new row.
    }

    /// One step of the working spark. Driven by `AppDelegate`'s fast timer, which only runs while a
    /// session is active.
    func advanceAnimation() {
        animationFrame = (animationFrame + 1) % 4
        renderTitle()
    }
```

- [ ] **Step 3: Draw activity in the title**

In `renderTitle()`, replace `button.image = Fmt.statusImage(mode: Settings.colorMode)` with:

```swift
        let activity = sessions.first?.state
        let working = activity == .thinking || activity == .tool
        let rotation: CGFloat
        if !working { rotation = 0 }
        // Reduce Motion: a still, visibly turned spark instead of a spinning one.
        else if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { rotation = 22.5 }
        else { rotation = CGFloat(animationFrame) * 11.25 }
        button.image = Fmt.statusImage(mode: Settings.colorMode, rotation: rotation,
                                       permissionDot: activity == .permission)
```

- [ ] **Step 4: Add the `CLAUDE CODE` section and the update item to `rebuild()`**

In `rebuild()`, directly before `if Settings.notifyThreshold > 0, Notifier.alertsBlocked {`, add:

```swift
        if !sessions.isEmpty {
            menu.addItem(.separator())
            menu.addItem(headingRow(SessionActivity.menuHeading))
            let visible = SessionPanel.visible(sessions)
            for session in visible.shown {
                menu.addItem(sessionRow(for: session))
            }
            if visible.hidden > 0 {
                let label = SessionActivity.moreLabel(visible.hidden)
                menu.addItem(textRow { label })
            }
        }
```

Replace:

```swift
        menu.addItem(.separator())
        menu.addItem(refreshRow())
```

with:

```swift
        menu.addItem(.separator())
        if let release = availableRelease {
            let item = action(UpdateCheck.menuTitle(release), key: "", selector: #selector(openRelease))
            menu.addItem(item)
        }
        menu.addItem(refreshRow())
```

- [ ] **Step 5: Add the settings toggles**

In `settingsItem()`, directly before the comment `// A status line and a way in.`, add:

```swift
        submenu.addItem(.separator())
        submenu.addItem(header(SessionActivity.settingsHeading))
        let track = action(SessionActivity.trackMenuTitle, key: "", selector: #selector(toggleTrackSessions))
        track.state = Settings.trackSessions ? .on : .off
        submenu.addItem(track)
        let hookStatus = NSMenuItem(
            title: HookInstaller.statusLabel(hookOutcome, enabled: Settings.trackSessions,
                                             sessionCount: sessions.count),
            action: nil, keyEquivalent: "")
        hookStatus.isEnabled = false
        submenu.addItem(hookStatus)
```

Directly after `submenu.addItem(launch)`, add:

```swift
        let updates = action(UpdateCheck.settingsTitle, key: "", selector: #selector(toggleCheckForUpdates))
        updates.state = Settings.checkForUpdates ? .on : .off
        submenu.addItem(updates)
```

Below `@objc private func toggleLaunchAtLogin()`, add:

```swift
    /// Not `onSettingsChanged`: neither toggle has anything to do with polling usage.
    @objc private func toggleTrackSessions() {
        Settings.trackSessions.toggle()
        onTrackSessionsChanged?()
    }

    @objc private func toggleCheckForUpdates() {
        Settings.checkForUpdates.toggle()
        onCheckForUpdatesChanged?()
    }

    @objc private func openRelease() {
        guard let url = availableRelease?.url else { return }
        NSWorkspace.shared.open(url)
    }
```

- [ ] **Step 6: Add the row builders**

In `// MARK: - Live rows`, after `textRow`, add:

```swift
    /// A session, kept current while the menu is open. Closes over the session's **id** and looks
    /// it up each time — the same lesson as `window(id:)`. A session that ended while the menu is
    /// open says so rather than vanishing, because an open menu can't lose rows.
    private func sessionRow(for session: Session) -> NSMenuItem {
        let id = session.id
        var row = SessionRow(session, now: Date())
        let hosted = HostedRow(SessionRowView(row: row, mode: Settings.colorMode), title: row.spoken)
        liveRows.append(LiveRow { [weak self] in
            guard let self else { return }
            if let current = self.sessions.first(where: { $0.id == id }) {
                row = SessionRow(current, now: Date())
            } else {
                row = row.ended
            }
            hosted.update(SessionRowView(row: row, mode: Settings.colorMode), title: row.spoken)
        })
        return hosted.item
    }

    private func headingRow(_ text: String) -> NSMenuItem {
        HostedRow(PanelHeadingView(text: text), title: text).item
    }
```

- [ ] **Step 7: Wire `AppDelegate`**

Add `import HeadroomShared` at the top. Add properties below `private lazy var menuController`:

```swift
    private let sessionActivity = SessionActivity.default
    private let hookInstaller = HookInstaller.default
    private var sessionWatcher: DirectoryWatcher?
    /// Runs only while a session is working or waiting. Drives the spinning spark and, once a
    /// second, a re-read — elapsed times in an open menu, and interrupts, which write no hook.
    private var animationTimer: Timer?
    private var animationTicks = 0
    private var updateTimer: Timer?
```

In `applicationDidFinishLaunching`, after `menuController.onSettingsChanged = …`, add:

```swift
        menuController.onTrackSessionsChanged = { [weak self] in self?.startSessionTracking() }
        menuController.onCheckForUpdatesChanged = { [weak self] in self?.startUpdateChecks() }
```

After `reschedulePoll()` in the same method, add:

```swift
        startSessionTracking()
        startUpdateChecks()
```

Inside the 60-second tick closure, before `self.menuController.tick()`, add:

```swift
            // Catches a killed terminal even when nothing is writing session files.
            self.refreshSessions()
```

Replace `@objc private func didWake() { refresh() }` with:

```swift
    @objc private func didWake() {
        refresh()
        refreshSessions()
        checkForUpdatesIfDue()
    }
```

Add these methods above `schedule(every:_:)`:

```swift
    // MARK: - Claude Code sessions

    /// Installs or removes hooks to match the setting, and starts or stops watching for sessions.
    /// Runs at every launch, which is also what repairs the hook path after the app has moved.
    private func startSessionTracking() {
        menuController.hookOutcome = hookInstaller.apply(enabled: Settings.trackSessions)
        if Settings.trackSessions {
            if sessionWatcher == nil {
                sessionWatcher = DirectoryWatcher(directory: sessionActivity.directory) { [weak self] in
                    self?.refreshSessions()
                }
            }
        } else {
            sessionWatcher = nil
        }
        refreshSessions()
    }

    private func refreshSessions() {
        let sessions = Settings.trackSessions ? sessionActivity.sessions() : []
        menuController.update(sessions: sessions)
        let active = sessions.contains { $0.state != .idle }
        if active, animationTimer == nil {
            animationTimer = schedule(every: 0.25) { [weak self] in self?.animationTick() }
        } else if !active, let timer = animationTimer {
            timer.invalidate()
            animationTimer = nil
            menuController.advanceAnimation()  // Re-render the title at rest.
        }
    }

    private func animationTick() {
        menuController.advanceAnimation()
        animationTicks += 1
        if animationTicks % 4 == 0 { refreshSessions() }
    }

    // MARK: - Update checks

    private func startUpdateChecks() {
        updateTimer?.invalidate()
        updateTimer = nil
        menuController.update(release: Settings.checkForUpdates
            ? UpdateCheck.pending(known: Settings.knownRelease, currentVersion: Self.appVersion) : nil)
        guard Settings.checkForUpdates else { return }
        let first = Timer(timeInterval: UpdateCheck.launchDelay, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.checkForUpdatesIfDue()
            // Hourly *look*; `isDue` keeps the actual request to once a day.
            self.updateTimer = self.schedule(every: 3600) { [weak self] in self?.checkForUpdatesIfDue() }
        }
        RunLoop.main.add(first, forMode: .common)
        updateTimer = first
    }

    private func checkForUpdatesIfDue() {
        guard Settings.checkForUpdates,
              UpdateCheck.isDue(lastAttempt: Settings.lastUpdateCheck, now: Date()) else { return }
        Settings.lastUpdateCheck = Date()
        UpdateCheck.fetch(currentVersion: Self.appVersion) { [weak self] release in
            DispatchQueue.main.async {
                guard let self, Settings.checkForUpdates else { return }
                if let release { Settings.knownRelease = release }
                self.menuController.update(release: UpdateCheck.pending(
                    known: Settings.knownRelease, currentVersion: Self.appVersion))
            }
        }
    }

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }
```

- [ ] **Step 8: Build and run the tests**

Run: `swift build 2>&1 | grep -E "error|warning: unused" ; swift test --disable-xctest 2>&1 | tail -2`
Expected: no errors; all tests pass.

- [ ] **Step 9: Commit**

```bash
git add Sources/HeadroomCore/DirectoryWatcher.swift Sources/HeadroomCore/MenuController.swift Sources/HeadroomCore/AppDelegate.swift
git commit -m "feat: show Claude Code sessions in the menu bar and dropdown, and offer updates

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 9: Build, CI, and release procedure

**Files:**
- Modify: `build.sh`, `.github/workflows/build.yml`, `docs/RELEASING.md`

- [ ] **Step 1: Build and place the helper in `build.sh`**

Change `mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"` to:

```bash
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers"
```

Below `BIN="$APP/Contents/MacOS/$APP_NAME"`, add:

```bash
# The Claude Code hook helper. Contents/Helpers is Apple's documented home for helper tools.
HOOK_NAME="headroom-hook"
HOOK="$APP/Contents/Helpers/$HOOK_NAME"
```

Replace the slice loop and `lipo` line:

```bash
SLICES=()
HOOK_SLICES=()
for TRIPLE in arm64-apple-macosx x86_64-apple-macosx; do
  swift build "${SPM_FLAGS[@]}" --triple "$TRIPLE"
  # Ask SwiftPM where it put things rather than hardcoding a path. Note .build/release is a
  # compatibility symlink pointing at whichever triple built last — using it would lipo one slice
  # with itself. The flags must match the build exactly, hence the shared array.
  BIN_PATH="$(swift build "${SPM_FLAGS[@]}" --triple "$TRIPLE" --show-bin-path)"
  SLICES+=("$BIN_PATH/$APP_NAME")
  HOOK_SLICES+=("$BIN_PATH/$HOOK_NAME")
done
lipo -create "${SLICES[@]}" -output "$BIN"
lipo -create "${HOOK_SLICES[@]}" -output "$HOOK"
```

- [ ] **Step 2: Sign inside-out in `build.sh`**

Replace the signing `if` block with:

```bash
# Inside-out: the helper is signed before the app that contains it, because signing the app seals
# its contents. Never --deep, which Apple names as the most common cause of notarization failures.
xattr -cr "$APP"
if [[ -n "${HEADROOM_SIGN_ID:-}" ]]; then
  echo "Signing with: $HEADROOM_SIGN_ID"
  codesign --force --options runtime --timestamp --sign "$HEADROOM_SIGN_ID" "$HOOK"
  codesign --force --options runtime --timestamp --sign "$HEADROOM_SIGN_ID" "$APP"
else
  codesign --force --sign - "$HOOK"
  codesign --force --sign - "$APP"
fi
```

- [ ] **Step 3: Verify the build locally**

```bash
./build.sh
codesign --verify --strict --verbose build/Headroom.app
lipo -info build/Headroom.app/Contents/Helpers/headroom-hook
otool -l build/Headroom.app/Contents/Helpers/headroom-hook | grep -c 'minos 13.0'
nm -a build/Headroom.app/Contents/Helpers/headroom-hook | grep -c OSO
time (echo '{}' | build/Headroom.app/Contents/Helpers/headroom-hook stop)
```
Expected: `valid on disk` and `satisfies its Designated Requirement`; `Architectures in the fat file: … x86_64 arm64`; `2`; `0`; well under 0.1s.

- [ ] **Step 4: Verify the helper in CI**

In `.github/workflows/build.yml`, step "Verify the app bundle", replace the lines from `BIN="build/Headroom.app/Contents/MacOS/Headroom"` through `test "$(nm -a "$BIN" | grep -c OSO)" -eq 0` with:

```yaml
          test -f "build/Headroom.app/Contents/Info.plist"
          # The app and the Claude Code hook helper get the same checks: the helper is run by Claude
          # Code on every tool call, so a single-arch or 10.13 helper breaks sessions, not just Headroom.
          for BIN in build/Headroom.app/Contents/MacOS/Headroom \
                     build/Headroom.app/Contents/Helpers/headroom-hook; do
            test -x "$BIN"
            # Must be a universal binary — a single-arch slice means the lipo step silently regressed.
            lipo -info "$BIN" | tee /dev/stderr | grep -q "arm64"
            lipo -info "$BIN" | grep -q "x86_64"
            # `platforms:` in Package.swift is the only thing pinning the deployment target now, and a
            # typo there ships a macOS 10.13 binary that would pass every check above.
            test "$(otool -l "$BIN" | grep -c 'minos 13.0')" -eq 2
            # `swift build -c release` compiles with -g by default; without -debug-info-format none the
            # binary carries a debug map full of absolute paths from the build machine.
            test "$(nm -a "$BIN" | grep -c OSO)" -eq 0
          done
```

(Keep the `codesign --verify` lines that follow; change `--verbose` to `--strict --verbose`.)

In step "Check tests touch nothing they shouldn't", extend the pattern — replace `|StatuslineFeed\.default'` with:

```
|StatuslineFeed\.default|HookInstaller\.default|SessionActivity\.default|SessionFiles\.defaultDirectory|UpdateCheck\.fetch'
```

and extend the preceding comment with: `# HookInstaller.default edits the real ~/.claude/settings.json; SessionActivity.default and SessionFiles.defaultDirectory are the running app's sessions; UpdateCheck.fetch is the network.`

- [ ] **Step 5: Confirm the grep still passes locally**

```bash
grep -rnE 'MenuController\(|AppDelegate\(|accessToken\(|launchAtLogin|UNUserNotificationCenter|ClaudeProvider\(\)\.fetch|UsageHistory\.default|StatuslineFeed\.default|HookInstaller\.default|SessionActivity\.default|SessionFiles\.defaultDirectory|UpdateCheck\.fetch' Tests/ | grep -vE '^[^:]+:[0-9]+:[[:space:]]*(//|\*|///)' || echo "OK — tests stay in bounds."
```
Expected: `OK — tests stay in bounds.`

- [ ] **Step 6: Sign the helper in `docs/RELEASING.md`**

Replace:

```bash
# Sign and notarize the .app first, so a copy dragged out of the DMG carries its own ticket.
xattr -cr build/Headroom.app
codesign --force --options runtime --timestamp --sign "$SIGN_ID" build/Headroom.app
```

with:

```bash
# Sign and notarize the .app first, so a copy dragged out of the DMG carries its own ticket.
# Inside-out: the Claude Code hook helper before the app. The notary service requires the hardened
# runtime on every executable in the bundle, helpers included, and rejects the app otherwise.
xattr -cr build/Headroom.app
codesign --force --options runtime --timestamp --sign "$SIGN_ID" build/Headroom.app/Contents/Helpers/headroom-hook
codesign --force --options runtime --timestamp --sign "$SIGN_ID" build/Headroom.app
```

(Equivalent: `HEADROOM_SIGN_ID="$SIGN_ID" ./build.sh --dmg` now signs both correctly; the manual lines stay for the existing procedure.)

- [ ] **Step 7: Commit**

```bash
git add build.sh .github/workflows/build.yml docs/RELEASING.md
git commit -m "build: bundle, sign and verify the headroom-hook helper

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 10: Documentation and rule changes

**Files:**
- Modify: `CLAUDE.md`, `README.md`, `SECURITY.md`, `CHANGELOG.md`, `Sources/HeadroomCore/StatuslineFeed.swift:11-13`

- [ ] **Step 1: Correct the `StatuslineFeed` comment**

Replace the paragraph starting `/// **Headroom never edits `~/.claude/settings.json`.**` with:

```swift
/// **Headroom never edits the user's statusline.** It is theirs — this one already renders their
/// directory, branch, model and context — and silently replacing it to install a helper would be a
/// poor trade for a menu bar app. Opting in is a line they paste and can delete. (Headroom does add
/// its own *hooks* to `~/.claude/settings.json` for session tracking — see `HookInstaller` — and
/// never touches the `statusLine` key.)
```

- [ ] **Step 2: `CLAUDE.md`**

1. Build section: add `ls build/Headroom.app/Contents/Helpers/   # headroom-hook, the Claude Code hook helper` below `open build/Headroom.app`.
2. Architecture table: change the `main.swift` row to mention both executables, and add rows:

```markdown
| `Sources/headroom-hook/main.swift` | The Claude Code hook helper. Top-level code only; reads the hook payload, writes one session file, exits 0. Bundled at `Contents/Helpers/` |
| `Sources/HeadroomShared/` | Foundation-only code shared by the app and the helper: `SessionRecord` and its files, `HookEvent` (the hook → state machine), `SessionOwner`, `isJSONBoolean`. Must never import AppKit — the helper runs on every tool call |
| `Sources/HeadroomCore/HookInstaller.swift` | Adds/removes Headroom's hooks in `~/.claude/settings.json` and nothing else |
| `Sources/HeadroomCore/SessionActivity.swift` | Reads session files: liveness, the no-owner age limit, interrupt detection, ordering. Owns the session menu copy |
| `Sources/HeadroomCore/TranscriptTail.swift` | Esc-interrupt detection from the end of a transcript |
| `Sources/HeadroomCore/GitBranch.swift` | Branch from `.git/HEAD`, following worktree `gitdir:` files |
| `Sources/HeadroomCore/SessionPanel.swift` | The `CLAUDE CODE` dropdown rows and their pure `SessionRow` view model |
| `Sources/HeadroomCore/DirectoryWatcher.swift` | Debounced `DispatchSource` on the sessions folder |
| `Sources/HeadroomCore/UpdateCheck.swift` | Once-a-day GitHub Releases check; version comparison and release parsing |
```

3. Hard rules: replace rule 5 with:

```markdown
5. **Two network destinations:** `api.anthropic.com` for usage, and `api.github.com` for a
   once-a-day update check the user can turn off. No analytics, no identifiers, no downloads.
6. **Headroom edits `~/.claude/settings.json` only to add or remove its own hooks** — entries whose
   command contains `headroom-hook`. Never another key, never another tool's hook, never
   `statusLine`. It never writes a file it could not parse, never replaces a symlink, writes only
   when something changed, and backs the original up once to `settings.json.bak-headroom`.
```

4. Add a section after "## Credentials":

```markdown
## Claude Code sessions

`HookInstaller` registers `headroom-hook` for eight events; the helper writes
`~/Library/Application Support/com.vickipetrova.headroom/sessions/<id>.json`; `SessionActivity`
reads the folder. Traps, each measured and each with a test:

- **The hook command must be one bare command.** With `'<path>' <event>`, the helper's parent process
  *is* Claude Code (verified on 2.1.273), which is what the liveness check keys on. A wrapper like
  `PATH=… cmd` or `a && b` can put a short-lived shell in between, and every session would look dead
  a second later. `SessionOwner` therefore skips shells. It cannot match on the name `claude`: a
  native install's executable is named after its version (`…/claude/versions/2.1.273`), and an npm
  install runs as `node`.
- **`Stop` does not fire on Esc.** An interrupted turn is detected from the transcript, where it is
  a `user` entry starting `[Request interrupted by user`. That entry is frequently **not the last
  line** — `last-prompt`, `ai-title`, `mode`, `permission-mode`, `attachment` and
  `file-history-snapshot` follow it — so `TranscriptTail` takes the last `user`/`assistant` entry. It
  only trusts a transcript written after the session's last hook event, because a new prompt's hook
  fires before the prompt reaches the transcript.
- **Hooks load when a session starts.** Sessions open at first install don't appear until
  restarted; the Settings status says so.
- **A missing hook command is skipped silently by Claude Code**, so a deleted Headroom leaves
  harmless dead hooks rather than broken sessions.
- **Moving an existing hook to the end would fight other tools.** `HookInstaller.merged` leaves a
  current hook where it is; re-appending it made two tools that both append rewrite the file forever.
```

5. "Never called from a test": add bullets:

```markdown
- `HookInstaller.default` — edits the real `~/.claude/settings.json`. Construct it with a temp
  `claudeDirectory` and a temp helper file.
- `SessionActivity.default` / `SessionFiles.defaultDirectory` — the running app's sessions folder.
- `UpdateCheck.fetch` — real network. `available(data:response:error:currentVersion:)` is the pure part.
```

- [ ] **Step 3: `README.md`**

1. Replace the Security paragraph's `No telemetry, no analytics, no update checks.` sentence with: `It also asks GitHub once a day whether a newer Headroom exists (turn it off under Settings). No telemetry, no analytics, no identifiers.`
2. Add a section before "## Security":

```markdown
## Claude Code sessions

Headroom also shows what Claude Code is doing. The spark in the menu bar spins while a session is
working and gains a dot when one is waiting for your permission, and the dropdown lists each live
session with its project, branch, current step and how long the turn has run.

To do that, Headroom adds a small set of hooks to `~/.claude/settings.json` the first time it runs.
It changes nothing else in that file, keeps a one-time backup at
`~/.claude/settings.json.bak-headroom`, and records only each session's state, folder and tool
*names* — never your prompts or tool input. Sessions already open when the hooks are added appear
once they're restarted.

Turn it off under **Settings › Track Claude Code Sessions**, which removes the hooks. **Turn it off
before deleting Headroom**; if you forget, the leftover hooks do nothing and Claude Code ignores them.

Session tracking was inspired by [claude-status-bar](https://github.com/m1ckc3s/claude-status-bar)
by Mick Cesanek.
```

- [ ] **Step 4: `SECURITY.md`**

Replace `One destination, one request:` … `That's the entire network surface. No telemetry, no analytics, no crash reporting, no update checks, no third-party services.` with:

```markdown
Two destinations:

```
GET https://api.anthropic.com/api/oauth/usage                          (with your token)
GET https://api.github.com/repos/vickipetrova/headroom/releases/latest   (no token, at most once a day)
```

The second is the update check. It carries no token, cookie or identifier beyond a
`User-Agent: Headroom/<version>` header, never downloads anything, and can be turned off under
Settings. No telemetry, no analytics, no crash reporting, no third-party services.
```

Under "## What it stores", add:

```markdown
In `~/Library/Application Support/com.vickipetrova.headroom/sessions/`, one small file per live
Claude Code session: its state, folder, transcript path, the tool *name* in use and the Claude Code
process id. Never prompt text, tool input or output. Deleted when the session ends.

In `~/.claude/settings.json`, Headroom's own hook entries (commands ending in `headroom-hook`), with a
one-time backup of the original at `~/.claude/settings.json.bak-headroom`.
```

- [ ] **Step 5: `CHANGELOG.md`**

Under `## [Unreleased]` → `### Added`, add at the top:

```markdown
- **Claude Code session activity.** The menu bar spark spins while a session is working and shows a
  dot when one is waiting for permission; the dropdown lists live sessions with project, branch,
  current step and elapsed time. Headroom installs its own hooks into `~/.claude/settings.json`
  (nothing else in the file is touched, the original is backed up once) and removes them when the
  setting is turned off. An Esc-interrupted turn is detected from the transcript, since Claude Code
  fires no hook for it. Inspired by claude-status-bar.
- **Update checks.** Once a day Headroom asks GitHub for the latest release and offers a menu item
  when a newer one exists. No identifiers are sent and nothing is downloaded; it can be turned off.
```

- [ ] **Step 6: Check the README/snippet test still passes**

Run: `swift test --disable-xctest 2>&1 | tail -2`
Expected: all pass.

- [ ] **Step 7: Commit**

```bash
git add CLAUDE.md README.md SECURITY.md CHANGELOG.md Sources/HeadroomCore/StatuslineFeed.swift
git commit -m "docs: session tracking, update checks, and the two rule changes behind them

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 11: End-to-end check in the live app, then the PR

This step edits the developer's real `~/.claude/settings.json` through the app. **Confirm with the user before Step 2.**

- [ ] **Step 1: Back up the real settings and note the running app**

```bash
SCRATCH="$(mktemp -d)"
cp -p ~/.claude/settings.json "$SCRATCH/settings.before.json" 2>/dev/null || echo "no settings.json yet"
pgrep -fl "MacOS/Headroom" || echo "Headroom not running"
echo "$SCRATCH"
```

- [ ] **Step 2: Build and launch** *(after the user confirms)*

```bash
pkill -f "MacOS/Headroom"; ./build.sh && open build/Headroom.app && sleep 3
```

- [ ] **Step 3: Confirm the install touched only hooks**

```bash
python3 - "$SCRATCH/settings.before.json" ~/.claude/settings.json <<'EOF'
import json, os, sys
p = sys.argv[1]
before = json.load(open(p)) if os.path.exists(p) and open(p).read().strip() else {}
after = json.load(open(sys.argv[2]))
strip = lambda s: {k: v for k, v in s.items() if k != "hooks"}
assert strip(before) == strip(after), "non-hook keys changed"
ours = [h["command"] for es in after.get("hooks", {}).values() for e in es if isinstance(e, dict)
        for h in e.get("hooks", []) if "headroom-hook" in h.get("command", "")]
print(len(ours), "headroom hooks"); print("\n".join(ours))
EOF
ls -l ~/.claude/settings.json.bak-headroom
```
Expected: `8 headroom hooks`, each `'<repo>/build/Headroom.app/Contents/Helpers/headroom-hook' <event>`; the backup exists.

- [ ] **Step 4: Drive a real session and watch the files**

```bash
cd "$SCRATCH" && claude -p "Run the shell command: sleep 8. Then reply done." "--allowedTools=Bash(sleep:*)" < /dev/null &
sleep 3; cat ~/Library/Application\ Support/com.vickipetrova.headroom/sessions/*.json; echo
osascript -e 'tell application "System Events" to tell process "Headroom" to get name of every menu item of menu 1 of menu bar item 1 of menu bar 1'
wait
```
Expected: a session file with `"state":"tool"` and `"label":"Running command"` while `sleep` runs; the menu item list includes `CLAUDE CODE` and a row like `…, Running command · 3s`. After `claude -p` exits, the file is gone (SessionEnd) and the section disappears on the next open. Check the spark visibly spins during the run (screenshot or eyes).

- [ ] **Step 5: Toggle off and confirm the hooks are removed**

```bash
osascript -e 'tell application "System Events" to tell process "Headroom" to click menu item "Track Claude Code Sessions" of menu 1 of menu item "Settings" of menu 1 of menu bar item 1 of menu bar 1'
sleep 1; grep -c headroom-hook ~/.claude/settings.json
```
Expected: `0`. (If System Events can't click into the closed status menu, toggle it by hand and re-run the `grep`.) Then toggle it back on the same way (or leave it off, per the user), and `diff <(python3 -m json.tool --sort-keys "$SCRATCH/settings.before.json") <(python3 -m json.tool --sort-keys ~/.claude/settings.json)` shows no differences when off.

- [ ] **Step 6: Push and open the PR**

```bash
swift test --disable-xctest 2>&1 | tail -1
git push
gh pr create --base main --head feat/session-activity \
  --title "Claude Code session activity, automatic hooks, and update checks" \
  --body "$(cat <<'EOF'
## What

- The menu bar spark spins while a Claude Code session works and shows a dot when one needs permission; the dropdown lists live sessions (project, branch, step, elapsed).
- Headroom installs its own hooks into `~/.claude/settings.json` (only its own entries; one-time backup; removed when the setting is off). A bundled Foundation-only helper, `Contents/Helpers/headroom-hook`, writes one file per session.
- A once-a-day GitHub Releases update check, with a menu item linking to the release.

## Rule changes (deliberate)

- Hard rule 5 now allows `api.github.com` for the update check.
- New hard rule 6: Headroom edits `~/.claude/settings.json` only to add/remove its own hooks.

## Measured, not assumed

- The helper's parent process is Claude Code when the hook command is bare (2.1.273); its executable is named after its version, so shells are skipped rather than `claude` matched.
- Esc interrupts fire no `Stop`; they're read from the transcript, where the marker is often not the last line.

Design: `docs/superpowers/specs/2026-09-16-session-activity-design.md` · Plan: `docs/superpowers/plans/2026-09-16-session-activity.md`

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

Wait for the `build` check to go green before asking for merge.
