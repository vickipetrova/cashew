import Foundation
import Testing

@testable import CashewCore
@testable import CashewShared

/// Keeping the menu bar title readable while Claude Code works.
///
/// A turn that reads three files fires six hook events in about a second, and every one of them is a
/// real state change: thinking, Reading, thinking, Reading… Rendering each faithfully produces a
/// title nobody can read — the words change faster than the eye settles on them.
@Suite struct TitleWordHoldTests {
    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    /// Some moments pass on the clock alone — a turn crossing into "been a while" fires no hook, so
    /// nothing marks a change as pending. `MenuController` compares the prospective word against
    /// this instead, on an animation frame it would otherwise spend on the image.
    @Test func theHoldSaysWhatIsOnScreen() {
        var hold = TitleWordHold()
        #expect(hold.current == nil)
        _ = hold.display("Percolating…", now: start)
        #expect(hold.current == "Percolating…")
        _ = hold.display("Still going.", now: start.addingTimeInterval(0.2))
        #expect(hold.current == "Percolating…", "held back, so the screen still says the old one")
        _ = hold.display("Still going.", now: start.addingTimeInterval(9))
        #expect(hold.current == "Still going.")
        _ = hold.display(nil, now: start.addingTimeInterval(20))
        #expect(hold.current == nil)
    }

    @Test func theFirstWordAppearsImmediately() {
        var hold = TitleWordHold()
        #expect(hold.display("Percolating…", now: start) == "Percolating…")
        #expect(!hold.hasPending)
    }

    @Test func aChangeWithinTheWindowIsHeldBack() {
        var hold = TitleWordHold()
        _ = hold.display("Percolating…", now: start)
        #expect(hold.display("Reading…", now: start.addingTimeInterval(0.2)) == "Percolating…")
        #expect(hold.hasPending)
    }

    @Test func theChangeLandsOnceTheWindowHasPassed() {
        var hold = TitleWordHold()
        _ = hold.display("Percolating…", now: start)
        _ = hold.display("Reading…", now: start.addingTimeInterval(0.2))
        let due = start.addingTimeInterval(TitleWordHold.minimumInterval)
        #expect(hold.display("Reading…", now: due) == "Reading…")
        #expect(!hold.hasPending)
    }

    /// The point of the whole type: what lands after the wait is *current*, not a queue of everything
    /// that happened during it. Six events in a second show one word, the one true when time was up.
    @Test func onlyTheLatestValueSurvivesTheWait() {
        var hold = TitleWordHold()
        _ = hold.display("Percolating…", now: start)
        for (offset, word) in [(0.1, "Reading…"), (0.3, "Noodling…"), (0.6, "Editing…")] {
            #expect(hold.display(word, now: start.addingTimeInterval(offset)) == "Percolating…")
        }
        let due = start.addingTimeInterval(TitleWordHold.minimumInterval)
        #expect(hold.display("Running command…", now: due) == "Running command…")
    }

    /// Flapping back to what is already on screen is not a change at all, and must not leave a
    /// pending update behind that re-renders the title for nothing.
    @Test func aValueThatReturnsToWhatIsShownClearsThePending() {
        var hold = TitleWordHold()
        _ = hold.display("Percolating…", now: start)
        _ = hold.display("Reading…", now: start.addingTimeInterval(0.2))
        #expect(hold.hasPending)
        #expect(hold.display("Percolating…", now: start.addingTimeInterval(0.4)) == "Percolating…")
        #expect(!hold.hasPending)
    }

    /// Idle is a value like any other: a turn ending and another starting half a second later should
    /// not blink the title empty in between.
    @Test func disappearingIsHeldToo() {
        var hold = TitleWordHold()
        _ = hold.display("Percolating…", now: start)
        #expect(hold.display(nil, now: start.addingTimeInterval(0.2)) == "Percolating…")
        let due = start.addingTimeInterval(TitleWordHold.minimumInterval)
        #expect(hold.display(nil, now: due) == nil)
        #expect(!hold.hasPending)
    }

    /// Slow, ordinary changes are not delayed at all: a turn that thinks for a minute and then runs
    /// one command shows the change the moment it happens.
    @Test func changesBeyondTheWindowAreImmediate() {
        var hold = TitleWordHold()
        _ = hold.display("Percolating…", now: start)
        #expect(hold.display("Running command…", now: start.addingTimeInterval(60))
                == "Running command…")
        #expect(!hold.hasPending)
    }

    /// The window is measured from the last *change*, not from the last call — otherwise a title
    /// updated twelve times a second would never be allowed to change at all.
    @Test func theWindowRunsFromTheLastChange() {
        var hold = TitleWordHold()
        _ = hold.display("Percolating…", now: start)
        for tick in 1...10 {
            _ = hold.display("Percolating…", now: start.addingTimeInterval(Double(tick) * 0.08))
        }
        let due = start.addingTimeInterval(TitleWordHold.minimumInterval)
        #expect(hold.display("Reading…", now: due) == "Reading…")
    }
}

/// Which session the menu bar speaks for when several are running.
@Suite struct TitleSessionTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func session(_ id: String, _ state: SessionState, updated: TimeInterval) -> Session {
        Session(id: id, state: state, label: state == .tool ? "Reading" : "", project: id,
                branch: nil, turnStartedAt: now, updatedAt: now.addingTimeInterval(updated))
    }

    /// Two sessions working at once take turns being the most recently updated, and the title was
    /// following that — measured on a real menu bar, it alternated between one session's word and
    /// the other's every 1.5 seconds, for as long as both kept working. Neither word was wrong;
    /// the flipping was.
    @Test func aWorkingSessionKeepsTheTitleWhileItLasts() {
        let mine = session("mine", .tool, updated: 0)
        let theirs = session("theirs", .thinking, updated: 1)
        #expect(TitleSession.chosen(from: [theirs, mine], sticky: "mine")?.id == "mine")
        #expect(TitleSession.chosen(from: [mine, theirs], sticky: "theirs")?.id == "theirs")
    }

    /// Sticky only within the same rank: a session asking for your approval is the whole reason the
    /// menu bar says anything, and must never wait behind one that is merely busy.
    @Test func approvalStillWins() {
        let busy = session("busy", .tool, updated: 1)
        let waiting = session("waiting", .permission, updated: 0)
        #expect(TitleSession.chosen(from: [waiting, busy], sticky: "busy")?.id == "waiting")
    }

    @Test func aSessionThatEndsHandsTheTitleOver() {
        let other = session("other", .thinking, updated: 0)
        #expect(TitleSession.chosen(from: [other], sticky: "gone")?.id == "other")
        #expect(TitleSession.chosen(from: [], sticky: "gone") == nil)
    }

    /// An idle session holds nothing: the title has nothing to say for it, so the next working one
    /// takes over immediately rather than waiting for it to disappear.
    @Test func idleDoesNotHoldTheTitle() {
        let resting = session("resting", .idle, updated: 1)
        let working = session("working", .thinking, updated: 0)
        #expect(TitleSession.chosen(from: [working, resting], sticky: "resting")?.id == "working")
    }

    @Test func withoutAStickyItIsSimplyTheFirst() {
        let first = session("first", .permission, updated: 0)
        let second = session("second", .tool, updated: 1)
        #expect(TitleSession.chosen(from: [first, second], sticky: nil)?.id == "first")
    }
}
