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
