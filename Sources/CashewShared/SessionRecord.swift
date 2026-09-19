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
    public static let permission = "Awaiting approval"
}

/// One session's file: written by `cashew-hook`, read by `SessionActivity`.
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
    /// Alongside Cashew's other state. Never call from a test — tests pass a temp directory.
    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.vickipetrova.cashew", isDirectory: true)
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
