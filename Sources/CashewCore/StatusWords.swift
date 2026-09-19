import Foundation
import CashewShared

/// What Cashew *says* a session is doing — in the menu bar next to the usage numbers, and in the
/// dropdown's session rows.
///
/// The words are the point of the feature: the animation tells you something is happening, and the
/// word tells you what, without opening the menu. Only the most urgent session gets one in the menu
/// bar — several sessions' worth of text up there would be unreadable at any width.
///
/// Every pool leads with the plain wording Cashew used before it had a voice, and the rest is the
/// voice. Nothing was replaced: `Editing…` and `Awaiting approval` still turn up, they just have
/// company now. Leading with the plain one is load-bearing twice over — it is what the menu bar
/// falls back to when a pick doesn't fit, and it is the wording `HookEvent` writes into the session
/// file, so the two can't drift apart without a test noticing.
///
/// Cashew's own list. Claude Code has playful words of its own; copying them would tie this menu
/// to one vendor's copy, and this app is going to track more than one tool.
enum StatusWords {
    /// The menu bar is shared with every other app's item, so the text is capped rather than
    /// trusted. Tool names arrive from a payload Cashew doesn't own.
    static let maxLength = 18

    /// `NSMenu` sizes itself to its widest item, so a long phrase widens the *whole* dropdown
    /// rather than just its own row — and the row appends `· 12m 30s` after it.
    static let rowMaxLength = 30

    /// A turn younger than this is still getting going; one older than `longTurn` has been at it a
    /// while. Both are read off `turnStartedAt`, so they cost nothing but a comparison.
    static let freshTurn: TimeInterval = 20
    static let longTurn: TimeInterval = 600

    /// What a session is in the middle of. Not `SessionState`: that is written to disk by the
    /// helper and says nothing about how long a turn has been running, which is most of what makes
    /// one phrase apt and another silly.
    enum Moment: Equatable {
        case starting
        case thinking
        case lingering
        case permission
        case finished
        /// Carries the plain label out of the session file, because that is the pool's key.
        case tool(String)
    }

    static let startingPhrases = [
        SessionLabels.thinking + "…", "On it.", "Oh, a job!", "Right then.", "Here we go.",
    ]

    static let thinkingPhrases = [
        SessionLabels.thinking + "…", "Percolating…", "Pondering…", "Noodling…", "Mulling…",
        "Brewing…", "Tinkering…", "Untangling…", "Puzzling…", "Cogitating…", "Crunching…",
        // The app's own. It turns up as often as any other word, which is the joke.
        "Cashewing…",
    ]

    /// The only pool that doesn't lead with `Thinking…`. It doesn't need the fallback — every
    /// phrase here but one already fits the menu bar — and having it meant a twelve-minute turn
    /// said "Thinking…" a fifth of the time, which is the one thing this moment exists not to say.
    static let lingeringPhrases = [
        "Still going.", "Not bored yet.", "Still here. Been a while.", "Long one, this.",
        "Still at it.",
    ]

    static let permissionPhrases = [
        SessionLabels.permission, "Need a nod from you.", "Tap me — I've got a question.",
        "Your call, this one.",
    ]

    static let finishedPhrases = [
        "Done.", "Done. That one was tidy.", "Didn't even break a sweat.", "Finished. Next?",
    ]

    /// Keyed by the plain label `HookEvent` writes, which is also each pool's first entry.
    /// `HookEventTests` holds these keys against `HookEvent.toolLabels`; they live apart because
    /// the helper must not link anything but Foundation.
    static let toolPhrases: [String: [String]] = [
        "Reading": ["Reading…", "Skimming…", "Having a read…"],
        "Editing": ["Editing…", "Tweaking…", "Rearranging…"],
        "Writing": ["Writing…", "Scribbling…", "Putting it down…"],
        "Running command": ["Running command…", "Poking the shell…", "Typing at the terminal…"],
        "Searching": ["Searching…", "Rummaging…", "Digging around…"],
        "Searching web": ["Searching web…", "Asking the internet…"],
        "Browsing web": ["Browsing web…", "Off reading the web…"],
        "Delegating": ["Delegating…", "Passing the buck…", "Getting a hand…"],
        "Planning": ["Planning…", "Making a list…", "Plotting…"],
        "Using tool": ["Using tool…", "Poking at it…", "Fiddling with something…"],
    ]

    /// Every pool there is, for the tests that hold all of them to the same two caps.
    static var allPools: [[String]] {
        [startingPhrases, thinkingPhrases, lingeringPhrases, permissionPhrases, finishedPhrases]
            + toolPhrases.values
    }

    static func phrases(for moment: Moment) -> [String] {
        switch moment {
        case .starting: return startingPhrases
        case .thinking: return thinkingPhrases
        case .lingering: return lingeringPhrases
        case .permission: return permissionPhrases
        case .finished: return finishedPhrases
        case .tool(let label):
            let plain = label.isEmpty ? SessionActivity.workingLabel : label
            // An unrecognised label is shown as it arrived rather than swapped for something
            // invented: it may be a newer Claude Code's tool, and guessing at it would be worse
            // than repeating it.
            return toolPhrases[plain] ?? [plain + "…"]
        }
    }

    /// Nil when there is nothing worth saying — a session sitting idle that didn't just finish.
    static func moment(for session: Session, now: Date) -> Moment? {
        switch session.state {
        case .permission:
            return .permission
        case .idle:
            return session.justFinished ? .finished : nil
        case .tool:
            return .tool(session.label)
        case .thinking:
            // No start means no claim about how long this has taken, so: the middle one.
            guard let age = session.turnStartedAt.map({ now.timeIntervalSince($0) }) else {
                return .thinking
            }
            if age < freshTurn { return .starting }
            return age >= longTurn ? .lingering : .thinking
        }
    }

    /// The phrase for one session at one moment, unabridged.
    ///
    /// Keyed on the session, the turn's start *and* the moment so it holds still for as long as the
    /// moment lasts — re-picking on every 0.25 s frame would make the menu bar flicker through the
    /// list — while a turn that runs on visibly moves along, and two sessions thinking side by side
    /// say different things.
    static func phrase(for session: Session, now: Date) -> String? {
        guard let moment = moment(for: session, now: now) else { return nil }
        let pool = phrases(for: moment)
        guard !pool.isEmpty else { return nil }
        let turn = session.turnStartedAt.map { String(Int($0.timeIntervalSince1970)) } ?? ""
        return pool[index(of: "\(session.id)@\(turn)@\(key(moment))", count: pool.count)]
    }

    /// The menu bar's version: the pick when it fits, and otherwise the pool's plain wording rather
    /// than the pick with its last words sawn off. The two surfaces then still agree about what is
    /// happening — the bar just says it plainly.
    ///
    /// Idle says nothing at all, finished included: the dropdown is rebuilt every time it opens,
    /// but nothing re-renders the menu bar once every session has gone quiet, so "Done." up there
    /// would outstay its sixty seconds with no one to clear it.
    static func title(for session: Session?, now: Date = Date()) -> String? {
        guard let session, session.state != .idle,
              let moment = moment(for: session, now: now),
              let plain = phrases(for: moment).first,
              let pick = phrase(for: session, now: now)
        else { return nil }
        return capped(pick.count <= maxLength ? pick : plain, to: maxLength)
    }

    /// The dropdown's version: the pick in full, or `Idle` when there is nothing to say.
    static func rowStatus(for session: Session, now: Date) -> String {
        guard let phrase = phrase(for: session, now: now) else { return SessionActivity.idleLabel }
        return capped(phrase, to: rowMaxLength)
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

    /// Distinct per moment, so the three stages of one long turn don't land on the same index.
    private static func key(_ moment: Moment) -> String {
        switch moment {
        case .starting: return "starting"
        case .thinking: return "thinking"
        case .lingering: return "lingering"
        case .permission: return "permission"
        case .finished: return "finished"
        case .tool(let label): return "tool:" + label
        }
    }

    private static func capped(_ text: String, to limit: Int) -> String {
        text.count <= limit ? text : String(text.prefix(limit))
    }
}
