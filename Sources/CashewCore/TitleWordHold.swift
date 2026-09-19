import Foundation

/// A floor on how often the menu bar's status word is allowed to change.
///
/// The word is driven by Claude Code's hooks, and those fire on *every* state change: a turn that
/// reads three files produces thinking → Reading → thinking → Reading → thinking → Editing inside a
/// second or two, each one true, each one rendered the moment the session file is written. The
/// result is a title that flickers through words faster than the eye can settle on any of them, and
/// the information it is trying to convey — what this session is doing — is lost in the strobing.
///
/// The reference project looks steadier for an incidental reason rather than a considered one: it
/// polls its state files every 0.4s, so most of the churn happens between two of its frames and is
/// never drawn. Holding the title deliberately is the same smoothing without depending on how often
/// anything is polled, and it keeps the honest part: what lands after the wait is what is true *at
/// that moment*, never a replay of the changes that were skipped.
struct TitleWordHold {
    /// Long enough that a burst of tool calls collapses to one or two words; short enough that a
    /// change you are waiting for — a session asking for approval — still feels immediate.
    static let minimumInterval: TimeInterval = 1.5

    private var shown: String??
    private var changedAt: Date?
    private var pending = false

    /// The word to draw now, given what the sessions currently say.
    ///
    /// Called from every title render, which is as often as twelve times a second while a session
    /// works, so it must be cheap and must not treat a repeat as a change.
    mutating func display(_ word: String?, now: Date) -> String? {
        guard let current = shown else {          // nothing drawn yet: no reason to wait
            shown = .some(word)
            changedAt = now
            pending = false
            return word
        }
        guard current != word else {              // already on screen, including "still nothing"
            pending = false
            return current
        }
        guard let changedAt, now.timeIntervalSince(changedAt) < Self.minimumInterval else {
            shown = .some(word)
            self.changedAt = now
            pending = false
            return word
        }
        // Too soon. Keep what is there and remember that a render is owed once the window passes.
        pending = true
        return current
    }

    /// Whether a change is waiting for the window to pass.
    ///
    /// `MenuController` uses this to re-render the title on an animation frame it would otherwise
    /// spend on the image alone — without it, a word held back during a burst would sit there until
    /// the next session event, which in a quiet moment can be a while.
    var hasPending: Bool { pending }

    /// What is on screen now, as far as the hold knows — nil before anything has been drawn, and
    /// nil again once the word goes away.
    ///
    /// `hasPending` catches a change the *hooks* announced and the hold deferred. Some moments have
    /// no announcement behind them at all: a turn crossing into "been a while" happens on the clock,
    /// with Claude Code silent throughout, so nothing was ever offered to `display` to defer.
    /// `MenuController` compares the prospective word against this to catch those.
    var current: String? { shown ?? nil }
}
