import Foundation
import Testing

@testable import CashewCore
@testable import CashewShared

/// The word the menu bar shows for whatever Claude Code is doing.
@Suite struct StatusWordsTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func session(_ state: SessionState, label: String = "", id: String = "a",
                         started: TimeInterval? = 65) -> Session {
        Session(id: id, state: state, label: label, project: "cashew", branch: "main",
                turnStartedAt: started.map { now.addingTimeInterval(-$0) }, updatedAt: now)
    }

    @Test func idleAndNoSessionSayNothing() {
        #expect(StatusWords.title(for: nil) == nil)
        #expect(StatusWords.title(for: session(.idle)) == nil)
    }

    @Test func permissionIsTheOneWordThatMatters() {
        #expect(StatusWords.title(for: session(.permission, label: SessionLabels.permission))
                == SessionLabels.permission)
    }

    @Test func toolWorkKeepsItsOwnLabel() {
        #expect(StatusWords.title(for: session(.tool, label: "Editing")) == "Editing…")
        // A file written by an older helper, or an event that never carried one.
        #expect(StatusWords.title(for: session(.tool)) == "Working…")
    }

    @Test func thinkingGetsAPlayfulWord() throws {
        let word = try #require(StatusWords.title(for: session(.thinking)))
        #expect(StatusWords.thinkingWords.contains(word))
    }

    /// The word must hold still for the turn it describes. Re-picking it on every 0.25 s frame
    /// would make the menu bar unreadable.
    @Test func thewordIsStableWithinATurnAndChangesBetweenTurns() {
        let turn = session(.thinking, started: 65)
        #expect(StatusWords.title(for: turn) == StatusWords.title(for: turn))

        let laterTurn = session(.thinking, started: 5)
        let words = Set([turn, laterTurn].compactMap(StatusWords.title(for:)))
        // Two turns *may* land on the same word by chance; across a run of turns they must not.
        let manyTurns = (0..<40).map { session(.thinking, started: TimeInterval($0) * 37) }
        #expect(Set(manyTurns.compactMap(StatusWords.title(for:))).count > 1)
        #expect(words.count >= 1)
    }

    /// Two sessions thinking at once shouldn't both say "Percolating…" — they're different work.
    @Test func differentSessionsGetDifferentWords() {
        let words = (0..<40).map { session(.thinking, id: "session-\($0)") }
            .compactMap(StatusWords.title(for:))
        #expect(Set(words).count > 1)
    }

    /// Deterministic across launches: `hashValue` is seeded per process, so a word picked with it
    /// would change every time the app restarts, mid-turn.
    @Test func wordChoiceSurvivesARestart() {
        #expect(StatusWords.index(of: "abc", count: 10) == StatusWords.index(of: "abc", count: 10))
        #expect(StatusWords.index(of: "abc", count: 10) != StatusWords.index(of: "abd", count: 10)
                || StatusWords.index(of: "abc", count: 3) != StatusWords.index(of: "abd", count: 3))
        #expect((0..<10).contains(StatusWords.index(of: "anything", count: 10)))
        #expect(StatusWords.index(of: "anything", count: 0) == 0)
    }

    /// The title sits next to the numbers in a menu bar shared with every other app's item.
    @Test func everyWordFitsTheCap() {
        #expect(StatusWords.thinkingWords.allSatisfy { $0.count <= StatusWords.maxLength })
        #expect(StatusWords.title(for: session(.tool, label: String(repeating: "x", count: 60)))?.count
                == StatusWords.maxLength)
        #expect(SessionLabels.permission.count <= StatusWords.maxLength)
    }
}
