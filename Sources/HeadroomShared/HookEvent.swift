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
