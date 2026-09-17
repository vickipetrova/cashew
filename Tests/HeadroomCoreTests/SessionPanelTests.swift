import Foundation
import Testing

@testable import HeadroomCore
@testable import HeadroomShared

@Suite struct SessionPanelTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func session(_ state: SessionState, label: String = "", branch: String? = "main",
                         id: String = "a", started: TimeInterval? = 65) -> Session {
        Session(id: id, state: state, label: label, project: "headroom", branch: branch,
                turnStartedAt: started.map { now.addingTimeInterval(-$0) }, updatedAt: now)
    }

    @Test func toolRowShowsLabelAndElapsed() {
        let row = SessionRow(session(.tool, label: "Editing"), now: now)
        #expect(row.title == "headroom · main")
        #expect(row.status == "Editing · 1m 05s")
        #expect(!row.needsAttention)
        #expect(row.spoken == "headroom · main, Editing · 1m 05s")
    }

    @Test func thinkingWithoutALabelOrStart() {
        #expect(SessionRow(session(.thinking, started: nil), now: now).status == "Working")
    }

    @Test func permissionNeedsAttention() {
        let row = SessionRow(session(.permission, label: "Awaiting approval"), now: now)
        #expect(row.status == "Awaiting approval")
        #expect(row.needsAttention)
    }

    @Test func idleAndNoBranch() {
        let row = SessionRow(session(.idle, branch: nil), now: now)
        #expect(row.title == "headroom")
        #expect(row.status == "Idle")
    }

    @Test func endedKeepsTheTitle() {
        let ended = SessionRow(session(.permission, label: "Awaiting approval"), now: now).ended
        #expect(ended.title == "headroom · main")
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
