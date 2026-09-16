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
