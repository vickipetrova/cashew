import Foundation
import Testing

@testable import CashewCore
@testable import CashewShared

@Suite struct SessionPanelTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func session(_ state: SessionState, label: String = "", branch: String? = "main",
                         id: String = "a", started: TimeInterval? = 65,
                         justFinished: Bool = false) -> Session {
        Session(id: id, state: state, label: label, project: "cashew", branch: branch,
                turnStartedAt: started.map { now.addingTimeInterval(-$0) }, updatedAt: now,
                justFinished: justFinished)
    }

    /// The row draws from the same phrase book as the menu bar, so the two can't describe the same
    /// session differently. Only the length differs — see `StatusWords.rowMaxLength`.
    @Test func toolRowShowsAPhraseAndElapsed() {
        let row = SessionRow(session(.tool, label: "Editing"), now: now)
        let phrase = StatusWords.rowStatus(for: session(.tool, label: "Editing"), now: now)
        #expect(StatusWords.toolPhrases["Editing"]?.contains(phrase) == true)
        #expect(row.title == "cashew · main")
        #expect(row.status == "\(phrase) · 1m 05s")
        #expect(!row.needsAttention)
        #expect(row.spoken == "cashew · main, \(phrase) · 1m 05s")
    }

    @Test func thinkingWithoutALabelOrStartStillSaysSomething() {
        let row = SessionRow(session(.thinking, started: nil), now: now)
        #expect(StatusWords.thinkingPhrases.contains(row.status))
    }

    @Test func permissionNeedsAttention() {
        let row = SessionRow(session(.permission, label: "Awaiting approval"), now: now)
        #expect(StatusWords.permissionPhrases.contains(row.status))
        #expect(row.needsAttention)
    }

    /// No elapsed time: a turn waiting on you, or one that has ended, isn't measuring anything.
    @Test func permissionAndFinishedRowsCarryNoClock() {
        #expect(!SessionRow(session(.permission), now: now).status.contains("·"))
        #expect(!SessionRow(session(.idle, justFinished: true), now: now).status.contains("·"))
    }

    @Test func aFinishedTurnTakesABow() {
        let row = SessionRow(session(.idle, justFinished: true), now: now)
        #expect(StatusWords.finishedPhrases.contains(row.status))
        #expect(!row.needsAttention)
    }

    @Test func idleAndNoBranch() {
        let row = SessionRow(session(.idle, branch: nil), now: now)
        #expect(row.title == "cashew")
        #expect(row.status == "Idle")
    }

    @Test func endedKeepsTheTitle() {
        let ended = SessionRow(session(.permission, label: "Awaiting approval"), now: now).ended
        #expect(ended.title == "cashew · main")
        #expect(ended.status == "Ended")
        #expect(!ended.needsAttention)
    }

    @Test func rowCap() {
        let sessions = (0..<8).map { session(.idle, id: "s\($0)") }
        let visible = SessionPanel.visible(sessions)
        #expect(visible.shown.count == 6)
        #expect(visible.hidden == 2)
        #expect(SessionPanel.visible(Array(sessions.prefix(6))).hidden == 0)
    }
}
