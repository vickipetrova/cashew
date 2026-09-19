import Foundation
import CashewShared

/// What the menu bar *says* a session is doing, next to the usage numbers.
///
/// The words are the point of the feature: the animation tells you something is happening, and the
/// word tells you what, without opening the menu. Only the most urgent session gets one — several
/// sessions' worth of text in the menu bar would be unreadable at any width.
///
/// Cashew's own list. Claude Code has playful words of its own; copying them would tie this menu
/// to one vendor's copy, and this app is going to track more than one tool.
enum StatusWords {
    /// The menu bar is shared with every other app's item, so the text is capped rather than trusted.
    /// Tool names arrive from a payload Cashew doesn't own.
    static let maxLength = 18

    static let thinkingWords = [
        "Thinking…", "Percolating…", "Pondering…", "Noodling…", "Mulling…",
        "Brewing…", "Tinkering…", "Untangling…", "Puzzling…", "Cogitating…",
    ]

    /// Nil when there is nothing worth saying — no session, or one that is idle.
    static func title(for session: Session?) -> String? {
        guard let session else { return nil }
        switch session.state {
        case .idle:
            return nil
        case .permission:
            return capped(session.label.isEmpty ? SessionLabels.permission : session.label)
        case .tool, .thinking:
            guard session.state == .tool else {
                return capped(thinkingWord(id: session.id, turnStartedAt: session.turnStartedAt))
            }
            let label = session.label.isEmpty ? SessionActivity.workingLabel : session.label
            return capped(label + "…")
        }
    }

    /// The word for one turn of one session.
    ///
    /// Keyed on the session and the turn's start so it holds still for the whole turn — re-picking
    /// on every 0.25 s frame would make the menu bar flicker through the list — while two sessions
    /// thinking side by side, and two consecutive turns, get different words.
    static func thinkingWord(id: String, turnStartedAt: Date?) -> String {
        let turn = turnStartedAt.map { String(Int($0.timeIntervalSince1970)) } ?? ""
        return thinkingWords[index(of: id + "@" + turn, count: thinkingWords.count)]
    }

    /// FNV-1a, not `hashValue`: Swift seeds its hasher per process, so a word chosen with it would
    /// change every time the app restarted — including in the middle of the turn it describes.
    static func index(of text: String, count: Int) -> Int {
        guard count > 0 else { return 0 }
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01b3
        }
        return Int(hash % UInt64(count))
    }

    private static func capped(_ text: String) -> String {
        text.count <= maxLength ? text : String(text.prefix(maxLength))
    }
}
