import Foundation
import Testing

@testable import CashewCore
@testable import CashewShared

/// The words Cashew uses for whatever Claude Code is doing — in the menu bar and in the dropdown.
@Suite struct StatusWordsTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func session(_ state: SessionState, label: String = "", id: String = "a",
                         started: TimeInterval? = 65, justFinished: Bool = false) -> Session {
        Session(id: id, state: state, label: label, project: "cashew", branch: "main",
                turnStartedAt: started.map { now.addingTimeInterval(-$0) }, updatedAt: now,
                justFinished: justFinished)
    }

    // MARK: The phrase book

    /// Every pool leads with the plain wording Cashew used before it had a voice, so the menu bar
    /// always has something short and unremarkable to fall back to.
    @Test func everyPoolLeadsWithSomethingThatFitsTheMenuBar() {
        for pool in StatusWords.allPools {
            #expect(!pool.isEmpty)
            #expect(pool.first!.count <= StatusWords.maxLength, "too long for the menu bar: \(pool)")
        }
    }

    /// `NSMenu` sizes itself to its widest item, so a long phrase widens the whole dropdown rather
    /// than just its own row.
    @Test func everyPhraseFitsADropdownRow() {
        for phrase in StatusWords.allPools.flatMap({ $0 }) {
            #expect(phrase.count <= StatusWords.rowMaxLength, "would widen the dropdown: \(phrase)")
        }
    }

    @Test func noPhraseIsRepeatedWithinItsPool() {
        for pool in StatusWords.allPools {
            #expect(Set(pool).count == pool.count, "duplicate in \(pool)")
        }
    }

    /// The plain wording is the contract with the rest of the app: `HookEvent` writes these labels
    /// into the session file, and the menu falls back to them.
    @Test func plainWordingIsStillThere() {
        #expect(StatusWords.phrases(for: .permission).first == SessionLabels.permission)
        #expect(StatusWords.phrases(for: .thinking).first == SessionLabels.thinking + "…")
        #expect(StatusWords.toolPhrases["Editing"]?.first == "Editing…")
    }

    /// The two lists live apart — the helper must not link anything but Foundation — so nothing but
    /// this holds them together. A tool label with no pool would still render, but plainly, and the
    /// silence about it would be the bug.
    @Test func everyLabelTheHookCanWriteHasAPool() {
        for label in Set(HookEvent.toolLabels.values) {
            #expect(StatusWords.toolPhrases[label] != nil, "no pool for \(label)")
            #expect(StatusWords.toolPhrases[label]?.first == label + "…")
        }
        let fallback = HookEvent.label(forTool: "SomeToolCashewHasNeverHeardOf")
        #expect(StatusWords.toolPhrases[fallback]?.first == fallback + "…")
    }

    // MARK: Which moment a session is in

    @Test func aTurnMovesThroughThreeMomentsAsItRunsOn() {
        #expect(StatusWords.moment(for: session(.thinking, started: 5), now: now) == .starting)
        #expect(StatusWords.moment(for: session(.thinking, started: 65), now: now) == .thinking)
        #expect(StatusWords.moment(for: session(.thinking, started: 601), now: now) == .lingering)
    }

    @Test func momentBoundariesAreClosedAtTheTop() {
        #expect(StatusWords.moment(for: session(.thinking, started: 19.9), now: now) == .starting)
        #expect(StatusWords.moment(for: session(.thinking, started: 20), now: now) == .thinking)
        #expect(StatusWords.moment(for: session(.thinking, started: 599.9), now: now) == .thinking)
        #expect(StatusWords.moment(for: session(.thinking, started: 600), now: now) == .lingering)
    }

    /// Nothing says when the turn began — an older helper, or a state that never carried one. The
    /// middle moment is the one that claims nothing about how long this has been going.
    @Test func aTurnWithNoStartIsSimplyThinking() {
        #expect(StatusWords.moment(for: session(.thinking, started: nil), now: now) == .thinking)
    }

    /// A long tool call keeps saying which tool. The row already shows `· 12m 30s`, so "still
    /// running a command" is the more useful half of the fact than "still".
    @Test func toolWorkStaysOnItsToolHoweverLongItTakes() {
        #expect(StatusWords.moment(for: session(.tool, label: "Editing", started: 5), now: now)
                == .tool("Editing"))
        #expect(StatusWords.moment(for: session(.tool, label: "Editing", started: 3600), now: now)
                == .tool("Editing"))
    }

    @Test func permissionAndIdleAndDone() {
        #expect(StatusWords.moment(for: session(.permission), now: now) == .permission)
        #expect(StatusWords.moment(for: session(.idle), now: now) == nil)
        #expect(StatusWords.moment(for: session(.idle, justFinished: true), now: now) == .finished)
    }

    // MARK: Picking one

    @Test func aSessionDrawsFromItsMomentsPool() throws {
        let phrase = try #require(StatusWords.phrase(for: session(.thinking), now: now))
        #expect(StatusWords.phrases(for: .thinking).contains(phrase))

        let lingering = try #require(StatusWords.phrase(for: session(.thinking, started: 700), now: now))
        #expect(StatusWords.phrases(for: .lingering).contains(lingering))
    }

    /// An older helper's label, or one Cashew doesn't recognise, is shown as it arrived rather than
    /// swapped for something invented.
    @Test func anUnknownToolLabelIsUsedAsItIs() {
        #expect(StatusWords.phrase(for: session(.tool, label: "Frobnicating"), now: now)
                == "Frobnicating…")
        #expect(StatusWords.phrase(for: session(.tool), now: now)
                == SessionActivity.workingLabel + "…")
    }

    @Test func anIdleSessionSaysNothing() {
        #expect(StatusWords.phrase(for: session(.idle), now: now) == nil)
    }

    /// The phrase must hold still for as long as the moment lasts. Re-picking it on every 0.25 s
    /// frame would make the menu bar unreadable.
    @Test func thePhraseHoldsStillWithinAMoment() {
        let turn = session(.thinking, started: 30)
        let asTheClockTicks = [0.0, 1.0, 60.0, 500.0]
            .map { StatusWords.phrase(for: turn, now: now.addingTimeInterval($0)) }
        #expect(Set(asTheClockTicks.compactMap { $0 }).count == 1)
    }

    /// …and changes when the moment does, so one turn running on visibly moves along: the same
    /// session, the same turn, read at three points on the clock.
    @Test func thePhraseChangesWhenTheMomentDoes() {
        let turn = session(.thinking, started: 5)
        let alongTheTurn = [0.0, 60.0, 700.0]
            .map { StatusWords.phrase(for: turn, now: now.addingTimeInterval($0)) }
        #expect(Set(alongTheTurn.compactMap { $0 }).count == 3)
    }

    @Test func consecutiveTurnsGetDifferentPhrases() {
        let turns = (0..<40).map { session(.thinking, started: TimeInterval($0) * 37 + 30) }
        #expect(Set(turns.compactMap { StatusWords.phrase(for: $0, now: now) }).count > 1)
    }

    /// Two sessions thinking at once shouldn't both say "Percolating…" — that's different work.
    @Test func differentSessionsGetDifferentPhrases() {
        let sessions = (0..<40).map { session(.thinking, id: "session-\($0)") }
        #expect(Set(sessions.compactMap { StatusWords.phrase(for: $0, now: now) }).count > 1)
    }

    /// Deterministic across launches: `hashValue` is seeded per process, so a phrase picked with it
    /// would change every time the app restarts, mid-turn.
    @Test func phraseChoiceSurvivesARestart() {
        #expect(StatusWords.index(of: "abc", count: 10) == StatusWords.index(of: "abc", count: 10))
        #expect(StatusWords.index(of: "abc", count: 10) != StatusWords.index(of: "abd", count: 10)
                || StatusWords.index(of: "abc", count: 3) != StatusWords.index(of: "abd", count: 3))
        #expect((0..<10).contains(StatusWords.index(of: "anything", count: 10)))
        #expect(StatusWords.index(of: "anything", count: 0) == 0)
    }

    // MARK: The menu bar

    @Test func idleAndNoSessionSayNothing() {
        #expect(StatusWords.title(for: nil, now: now) == nil)
        #expect(StatusWords.title(for: session(.idle), now: now) == nil)
    }

    /// "Done." belongs in the dropdown, which is rebuilt every time it opens. Nothing re-renders
    /// the menu bar once every session has gone quiet, so a finished phrase up there would outstay
    /// its sixty seconds.
    @Test func theMenuBarStaysQuietWhenATurnFinishes() {
        #expect(StatusWords.title(for: session(.idle, justFinished: true), now: now) == nil)
    }

    /// A phrase too long for the menu bar isn't cut in half — the bar shows the plain wording and
    /// the dropdown still shows the pick. They agree about what is happening either way.
    @Test func aPhraseTooLongForTheMenuBarFallsBackToThePlainWording() {
        let long = StatusWords.phrases(for: .permission).first(where: { $0.count > StatusWords.maxLength })
        #expect(long != nil, "the permission pool should have a phrase longer than the menu bar")

        for id in (0..<40).map({ "session-\($0)" }) {
            let title = StatusWords.title(for: session(.permission, id: id), now: now)
            #expect(title == nil || title!.count <= StatusWords.maxLength)
            #expect(title == StatusWords.phrases(for: .permission).first
                    || title == StatusWords.phrase(for: session(.permission, id: id), now: now))
        }
    }

    /// The title sits next to the numbers in a menu bar shared with every other app's item, and a
    /// label out of a session file is not Cashew's to trust.
    @Test func anOverlongLabelIsStillCapped() {
        #expect(StatusWords.title(for: session(.tool, label: String(repeating: "x", count: 60)),
                                  now: now)?.count == StatusWords.maxLength)
    }

    // MARK: The dropdown

    @Test func aRowSaysIdleWhenThereIsNothingToSay() {
        #expect(StatusWords.rowStatus(for: session(.idle), now: now) == SessionActivity.idleLabel)
    }

    @Test func aRowShowsTheFullPhrase() throws {
        let finished = session(.idle, justFinished: true)
        let phrase = try #require(StatusWords.phrase(for: finished, now: now))
        #expect(StatusWords.rowStatus(for: finished, now: now) == phrase)
    }

    @Test func aRowCapsAnOverlongLabelToo() {
        #expect(StatusWords.rowStatus(for: session(.tool, label: String(repeating: "x", count: 60)),
                                      now: now).count == StatusWords.rowMaxLength)
    }
}
