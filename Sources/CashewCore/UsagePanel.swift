import AppKit
import SwiftUI

// The dropdown's informational rows.
//
// They are SwiftUI views inside `NSMenuItem.view` rather than ordinary menu items because an
// ordinary item that isn't a command has to be disabled, and macOS draws disabled items greyed out —
// which is what made the whole panel look washed out. AppKit does not dim a custom view, so these
// render at full strength while `NSMenu` still provides the material background, the dismissal
// behaviour, and key equivalents for the real commands below them.

/// Everything one usage section displays, derived from a `LimitWindow`.
///
/// Pure, so the formatting and the bar arithmetic are unit-testable without standing up any AppKit
/// object — `MenuController` cannot be constructed in a test (it creates a real status item), and CI
/// enforces that.
struct UsageRow {
    /// "SESSION · 5-HOUR"
    let header: String
    /// The wall-clock reset time, right of the header. Empty when the endpoint didn't give one.
    let headerTrailing: String
    /// "42%"
    let value: String
    /// "resets in 4h 15m"
    let trailing: String
    /// 0...1, for the bar.
    let fraction: Double

    /// Resolved here rather than in the view, so the bar's colour is covered by the same tests as
    /// the menu bar title's and the two can't drift apart.
    let barColor: NSColor

    /// "On pace to hit the limit ~Thu 14:00", and **nil for everything else**.
    ///
    /// Only `.onPace` produces a line. There is no "you're fine" copy on purpose: a row that says
    /// something reassuring on every ordinary day trains you to stop reading it, and then it is
    /// still being ignored on the day it matters.
    let pace: String?

    /// The whole row as one sentence, for VoiceOver and for the menu item's `title` — which is what
    /// AppleScript reports, since a view-backed item draws no title of its own. Derived here so the
    /// two can't drift into describing the same row differently.
    var spoken: String {
        let base = "\(header), \(value) used, \(trailing)"
        return pace.map { "\(base), \($0)" } ?? base
    }

    /// `mode` has no default on purpose. It used to default to `Settings.colorMode`, which made the
    /// type read a global while its own doc claimed purity — and because Swift evaluates default
    /// arguments at the call site, passing it explicitly changed nothing. Callers name it now.
    init(_ window: LimitWindow, now: Date = Date(), mode: Settings.ColorMode,
         forecast: Forecast = .unknown) {
        barColor = Fmt.color(window.utilization, mode: mode, role: .bar)
        // `Fmt.clock` already switches to a weekday-plus-time format past a day out, which is
        // exactly what a pace date needs — a bare "14:00" for something four days away would be
        // read as this afternoon.
        pace = {
            guard case .onPace(let hit) = forecast else { return nil }
            return "On pace to hit the limit ~\(Fmt.clock(hit, from: now))"
        }()
        header = window.label
        headerTrailing = window.resetsAt.map { Fmt.clock($0, from: now) } ?? ""
        value = Fmt.pct(window.utilization)
        trailing = window.resetsAt == nil
            ? "reset time unknown"
            : "resets in \(Fmt.countdown(to: window.resetsAt, from: now))"
        // Clamped rather than trusted. `ClaudeProvider` already bounds utilization to 0–100, but
        // this is the view model for *any* `UsageProvider` — the roadmap invites more — and a bar
        // that can overflow its track is a rendering bug waiting for the one payload that gets
        // through. The finite check is not redundant with the clamp: `min`/`max` propagate NaN, so
        // a NaN would reach SwiftUI as an invalid frame width and the bar would simply vanish.
        fraction = window.utilization.isFinite ? min(max(window.utilization / 100, 0), 1) : 0
    }
}

struct UsageRowView: View {
    let row: UsageRow

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            // `.callout` rather than `.caption` throughout the small text: caption is 10pt on macOS,
            // which is genuinely hard to read for something you glance at. The heading additionally
            // takes semibold and the full label colour — at secondary it read as disabled, which is
            // the exact impression this panel was redesigned to shed.
            HStack(spacing: 8) {
                Text(row.header)
                    .font(.callout.weight(.semibold))
                Spacer(minLength: 8)
                Text(row.headerTrailing)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(row.value)
                    .font(.system(size: 15, weight: .semibold))
                    // Monospaced digits for the same reason the menu bar title uses them: the number
                    // must not shuffle sideways as it ticks over.
                    .monospacedDigit()
                Spacer(minLength: 8)
                Text(row.trailing)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            ProgressBar(fraction: row.fraction, color: row.barColor)

            // Absent on an ordinary day, which is the whole design. Nothing below it reserves space
            // either — the row is re-measured on every content swap (`HostedRow.update`), so it
            // grows when the line appears rather than carrying a gap the rest of the time.
            if let pace = row.pace {
                Text(pace)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: PanelMetrics.textWrapWidth, alignment: .leading)
            }
        }
        .padding(.horizontal, PanelMetrics.horizontalPadding)
        .padding(.vertical, 7)
        .frame(minWidth: PanelMetrics.minimumWidth, maxWidth: .infinity, alignment: .leading)
        // The row is decoration, not a control: it should never be read as an eleven-part list, and
        // the bar has no meaning to announce beyond the percentage already in `value`.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.spoken)
    }
}

private struct ProgressBar: View {
    let fraction: Double
    let color: NSColor

    var body: some View {
        // GeometryReader rather than a fixed inner width, so the fill tracks the panel width if
        // PanelMetrics ever changes.
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color(nsColor: .quaternaryLabelColor))
                Capsule()
                    .fill(Color(nsColor: color))
                    .frame(width: max(0, geometry.size.width * fraction))
            }
        }
        .frame(height: PanelMetrics.barHeight)
    }
}

/// The footer, and every message-only state: an error, "Loading…".
struct PanelTextView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)  // wrap instead of truncating
            // Bounded, or a long error line lays out at its natural width and drags the whole menu
            // wider than the usage rows. Deliberately *not* derived from `minimumWidth`: that is a
            // floor for a menu with nothing in it, and when the two were the same constant, lowering
            // the floor silently wrapped every error message into a narrow column with dead space
            // beside it.
            .frame(maxWidth: PanelMetrics.textWrapWidth, alignment: .leading)
            .padding(.horizontal, PanelMetrics.horizontalPadding)
            .padding(.vertical, 5)
            .frame(minWidth: PanelMetrics.minimumWidth, maxWidth: .infinity, alignment: .leading)
    }
}

enum PanelMetrics {
    /// A floor, not a target — see `HostedRow`. Only wide enough that a menu showing
    /// nothing but "Loading…" isn't a sliver; the usage rows are all wider than this on their own,
    /// so in practice the menu sizes to its content.
    ///
    /// It was 300 for no reason beyond being the number picked while building the panel, and since
    /// AppKit adds a constant 65pt of chrome that made every menu 365pt wide. Measured: the widest
    /// row wants 240pt naturally (the weekly heading plus its reset time), so the menu now settles
    /// at 305pt. Going below that means shortening the copy, not adjusting this.
    static let minimumWidth: CGFloat = 200
    static let horizontalPadding: CGFloat = 14
    static let barHeight: CGFloat = 4

    /// How wide message text is allowed to lay out before wrapping.
    ///
    /// Tracks the *measured* natural width of a usage row rather than `minimumWidth`, so a wrapped
    /// error line ends where the rows end instead of leaving a column of dead space under full-width
    /// separators.
    ///
    /// 258pt is what the widest row (the weekly heading plus its reset time) measures at the current
    /// type sizes — it was 240 before the small text moved from `.caption` to `.callout`. Any change
    /// to the row's fonts or copy moves this number; re-measure rather than guessing.
    static var textWrapWidth: CGFloat { 258 - horizontalPadding * 2 }

    /// The most a session row may *ask* for, which is the only row in the menu that needs a ceiling.
    ///
    /// Every other row's width is bounded by its own content: a usage row measures 259pt at its
    /// widest, a heading 200. A session row is two `lineLimit(1)` texts side by side with nothing
    /// proposing a width, so `fittingSize` returns the sum of both at full length — measured at
    /// 393pt for `headroom · feat/settings-menu` next to `Typing at the terminal… · 42s`, which put
    /// the whole menu at 457. The `truncationMode(.middle)` on the title could never fire, because
    /// the menu simply grew until the title fitted.
    ///
    /// So the ceiling is what makes the truncation reachable, not a cosmetic limit. 300 is chosen to
    /// land the menu at ~365 with AppKit's 65pt of chrome; it is deliberately well above the 259 the
    /// numbers need, because squeezing the row to exactly that leaves almost nothing for the project
    /// name once a phrase and an elapsed time have taken their share.
    static let sessionRowWidth: CGFloat = 300
}

// MARK: - Hosting

/// A view-backed menu row that keeps its own height honest.
///
/// `NSMenuItem.view` is sized by hand once and never again: AppKit stretches the width to whatever
/// the menu settled on, but it never touches the height. That is fine for a row whose content never
/// changes, and wrong for every row here — `MenuController` refreshes rows in place by handing the
/// host a new `rootView`, so a row born around "Loading…" kept the one line it was born with and
/// clipped the multi-line Keychain-denied message to a sliver.
///
/// Swapping content and re-measuring therefore live in one method, `update`, rather than being two
/// things a caller has to remember to do in order.
final class HostedRow<Content: View> {
    let item = NSMenuItem()

    /// An `NSHostingController`, not the bare `NSHostingView` this used to be, for one reason:
    /// `sizeThatFits(in:)` is the only API here that does height-for-width. `fittingSize` does not,
    /// and measurably so — for the Keychain message it returns 25pt (one line) whether the row is
    /// 200pt or 300pt wide, and it still returns 25pt with the view installed in a window and
    /// `layoutSubtreeIfNeeded()` called. `sizingOptions = [.intrinsicContentSize]` reports the same
    /// 25pt. `sizeThatFits(in:)` returns 85pt at 300pt wide and 115pt at 200pt, which is the
    /// narrower-is-taller behaviour that proves it is actually resolving the wrap.
    private let controller: NSHostingController<Content>

    private var view: NSView { controller.view }

    init(_ rootView: Content, title: String) {
        controller = NSHostingController(rootView: rootView)
        // Width still comes from `fittingSize`: it is what the menu measures its own width from, and
        // it is correct for width — it is only height-for-width that it cannot do. Changing this to
        // a proposed width would change how wide the menu sits, which is a separate, tuned decision.
        view.frame.size = view.fittingSize
        // AppKit sizes the menu from the widest item and then adds its own chrome — measured at 65pt
        // beyond a 300pt row — but it lays the view out at x=0 and does not stretch it. Left alone,
        // every one of those points became dead space on the right, so the separators visibly ran
        // past the end of the text. Autoresizing lets the row grow into the width the menu actually
        // chose; the SwiftUI frame's `minWidth` is what the menu measured in the first place.
        view.autoresizingMask = [.width]
        // Not only for later swaps: a row *created* with the long message was clipped too, because
        // the height `fittingSize` just wrote is the one-line one.
        fitHeight()
        // `title` is set even though a view-backed item never draws it: it is what the accessibility
        // API and AppleScript report, which keeps `get name of every menu item` — this project's
        // standing way to verify the menu, documented in CLAUDE.md — working.
        item.title = title
        item.view = view
        // These rows are data, not commands. Left enabled — the default, since the menu sets
        // `autoenablesItems = false` — releasing the mouse over one selects it and dismisses the
        // whole menu, arrow-key navigation stops on rows that draw no highlight, and VoiceOver
        // offers them as actionable. Disabling costs nothing here: it dims an item's *own* drawing,
        // and this item draws none.
        item.isEnabled = false
    }

    /// Replace the content and re-measure, in that order.
    ///
    /// Called from `MenuController`'s live rows, which is to say while the menu may be open.
    func update(_ rootView: Content, title: String) {
        controller.rootView = rootView
        item.title = title
        fitHeight()
    }

    /// Grow or shrink to the height this content needs *at the width the menu actually gave the row*.
    ///
    /// Measuring at the natural width instead would be wrong in the direction that hurts: these rows
    /// are stretched wider than they ask for, and a wider row wraps to fewer lines, so the natural
    /// width over-reports and would leave a band of dead space under the text.
    func fitHeight() {
        // Before the menu has laid the row out there is no given width yet; its own measured width is
        // the best proposal available, and it is what the menu is about to be at least as wide as.
        let width = view.frame.width > 0 ? view.frame.width : PanelMetrics.minimumWidth
        let fitted = controller.sizeThatFits(
            in: NSSize(width: width, height: .greatestFiniteMagnitude))
        // Guarded so an unchanged row doesn't dirty its frame on every 60-second tick.
        guard abs(view.frame.height - fitted.height) > 0.5 else { return }
        view.frame.size.height = fitted.height
    }
}
