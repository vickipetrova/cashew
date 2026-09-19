import AppKit
import CashewShared
import SwiftUI

/// One row of the dropdown's `CLAUDE CODE` section. Pure, for the same reason as `UsageRow`:
/// `MenuController` can't be constructed in a test.
struct SessionRow: Equatable {
    /// "cashew · feat/session-activity"
    let title: String
    /// "Editing · 1m 05s", "Awaiting approval", "Idle"
    let status: String
    let needsAttention: Bool

    var spoken: String { "\(title), \(status)" }

    init(title: String, status: String, needsAttention: Bool) {
        self.title = title
        self.status = status
        self.needsAttention = needsAttention
    }

    init(_ session: Session, now: Date) {
        title = session.branch.map { "\(session.project) · \($0)" } ?? session.project
        needsAttention = session.state == .permission
        // One phrase book for both surfaces, so the row and the menu bar can't describe the same
        // session differently. The row gets the pick in full; the menu bar has less room.
        let phrase = StatusWords.rowStatus(for: session, now: now)
        switch session.state {
        case .permission, .idle:
            // Nothing is being measured: one turn is waiting on you, the other has ended.
            status = phrase
        case .thinking, .tool:
            let elapsed = Fmt.elapsed(since: session.turnStartedAt, now: now)
            status = elapsed.isEmpty ? phrase : "\(phrase) · \(elapsed)"
        }
    }

    /// What a held-open row shows once its session has gone. Rows can't be removed from an open menu.
    var ended: SessionRow {
        SessionRow(title: title, status: SessionActivity.endedLabel, needsAttention: false)
    }
}

enum SessionPanel {
    static let rowLimit = 6

    static func visible(_ sessions: [Session], limit: Int = rowLimit) -> (shown: [Session], hidden: Int) {
        (Array(sessions.prefix(limit)), max(0, sessions.count - limit))
    }
}

struct SessionRowView: View {
    let row: SessionRow
    let mode: Settings.ColorMode

    var body: some View {
        HStack(spacing: 8) {
            Text(row.title)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            if row.needsAttention {
                Circle()
                    .fill(Color(nsColor: mode == .system ? .labelColor : .systemYellow))
                    .frame(width: 6, height: 6)
            }
            Text(row.status)
                .font(.callout)
                .foregroundStyle(.secondary)
                // The elapsed time ticks every second; it must not shuffle the row sideways.
                .monospacedDigit()
                .lineLimit(1)
        }
        .padding(.horizontal, PanelMetrics.horizontalPadding)
        .padding(.vertical, 3)
        .frame(minWidth: PanelMetrics.minimumWidth, maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.spoken)
    }
}

/// A section heading in the main dropdown, matching the weight of `UsageRowView`'s headings.
struct PanelHeadingView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.callout.weight(.semibold))
            .padding(.horizontal, PanelMetrics.horizontalPadding)
            .padding(.top, 5)
            .padding(.bottom, 1)
            .frame(minWidth: PanelMetrics.minimumWidth, maxWidth: .infinity, alignment: .leading)
    }
}
