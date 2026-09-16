import AppKit
import Foundation

/// Percentages, countdowns, clock times, and the colour modes. Pure formatting — no state.
///
/// `now`, `locale`, and `timeZone` are parameters with live defaults rather than reads of global
/// state, so every function here is a pure function of its arguments and can be checked without
/// waiting for a clock or guessing at the machine's region.
enum Fmt {
    /// Anthropic's orange: the spark glyph, and the calm state of the bars in Alerts-only mode.
    ///
    /// Not a severity colour — `color(_:mode:role:)` owns that. This is the brand, shown while there
    /// is nothing to report; once usage crosses a threshold both the number and the bar move to
    /// yellow and then red, and in System mode this colour is not used at all.
    static let spark = NSColor(srgbRed: 0xD9 / 255, green: 0x77 / 255, blue: 0x57 / 255, alpha: 1)

    /// Beyond this, a reset time needs a weekday to be unambiguous, and the countdown switches to
    /// days. Both must use the same comparison or the two rows contradict each other — at exactly
    /// 24h the menu used to read "Resets 9:00 AM — in 1d 0h".
    private static let dayThreshold: TimeInterval = 86_400

    static func pct(_ utilization: Double?) -> String {
        guard let utilization, utilization.isFinite else { return "–" }
        return "\(Int(utilization.rounded()))%"
    }

    /// "2h 13m" until the window resets. Days collapse to "2d 1h" — minute precision is noise
    /// at that distance.
    static func countdown(to date: Date?, from now: Date = Date()) -> String {
        guard let date else { return "unknown" }
        let interval = date.timeIntervalSince(now)
        // `Int(_: Double)` traps on a non-finite or out-of-range value, and the reset timestamp
        // comes from an endpoint we don't control.
        guard interval.isFinite, interval < Double(Int.max) else { return "unknown" }
        let seconds = Int(interval)
        if seconds <= 0 { return "now" }
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    /// Local wall-clock time, in the user's 12- or 24-hour preference. Resets a day or more out get a
    /// weekday, because "09:00" alone is ambiguous by then.
    static func clock(_ date: Date?, from now: Date = Date(),
                      locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        guard let date else { return "?" }
        let formatter = DateFormatter()
        // `setLocalizedDateFormatFromTemplate` resolves the pattern against whatever locale the
        // formatter holds when it is called, so these two assignments must stay above it.
        formatter.locale = locale
        formatter.timeZone = timeZone
        // Built per call rather than cached in a static: a menu bar app runs for weeks, and a cached
        // formatter keeps showing 12-hour time after the user switches the system to 24-hour. The
        // cost is a handful of allocations per menu open.
        formatter.setLocalizedDateFormatFromTemplate(
            date.timeIntervalSince(now) >= dayThreshold ? "EEE jmm" : "jmm")
        return formatter.string(from: date)
    }

    /// How long ago the numbers on screen were fetched: "just now", "5m ago", "2h ago".
    ///
    /// Deliberately vaguer than a clock time. Next to a Refresh command the useful question is "are
    /// these stale?", and "4m ago" answers it without the reader having to subtract.
    /// A timestamp in the *past*, for "Showing data from …".
    ///
    /// `clock` cannot be used for this and the bug it caused was on screen for fifteen days: its
    /// weekday branch tests `date.timeIntervalSince(now) >= dayThreshold`, which is only ever true
    /// looking forward. For a past date the interval is negative, so it always rendered a bare time —
    /// a reading from fifteen days earlier read "Showing data from 4:44 AM", directly above a
    /// correctly-rendered "Refresh Now (15d ago)".
    ///
    /// Today's readings keep the wall-clock time, which is precise and unambiguous. Anything older
    /// switches to elapsed time, because the useful fact then is *how stale*, not what the clock said.
    static func stamp(_ date: Date?, from now: Date = Date(),
                      locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        guard let date else { return "?" }
        guard now.timeIntervalSince(date) >= dayThreshold else {
            return clock(date, from: now, locale: locale, timeZone: timeZone)
        }
        return age(of: date, from: now)
    }

    static func age(of date: Date?, from now: Date = Date()) -> String {
        guard let date else { return "never" }
        let seconds = Int(now.timeIntervalSince(date))
        if seconds < 45 { return "just now" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(max(minutes, 1))m ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }
        return "\(hours / 24)d ago"
    }

    /// The one place this sentence is written. It used to exist separately in the dropdown and in
    /// notification bodies, and the two had already drifted — one carried a trailing full stop.
    static func resetLine(for date: Date?, from now: Date = Date()) -> String {
        guard date != nil else { return "Reset time unknown" }
        return "Resets \(clock(date, from: now)) — in \(countdown(to: date, from: now))"
    }

    /// How long a turn has been running: `12s`, `1m 05s`, `1h 02m`. Empty without a start.
    static func elapsed(since start: Date?, now: Date = Date()) -> String {
        guard let start else { return "" }
        let interval = now.timeIntervalSince(start)
        // Bounded before the Int conversion, which traps on anything non-finite or out of range.
        guard interval.isFinite, interval < 1_000_000_000 else { return "" }
        let seconds = max(0, Int(interval))
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return String(format: "%dm %02ds", minutes, seconds % 60) }
        return String(format: "%dh %02dm", minutes / 60, minutes % 60)
    }

    /// The spark for the menu bar, drawn as an image rather than set as a character in the title.
    ///
    /// In `.system` mode the image is a *template*: macOS then draws it in whatever colour a
    /// built-in menu bar control would use, which means it inverts correctly when the item is
    /// highlighted and follows the menu bar between light and dark. Coloured text does none of that.
    /// In `.alertsOnly` the glyph is baked in the brand orange and is not a template, so it keeps its
    /// colour — the same `isTemplate = (color == nil)` split the reference project uses.
    ///
    /// Rebuilt per render rather than cached: it is one small glyph a few times a minute, and a
    /// cache would have to be invalidated on both mode changes and appearance changes.
    ///
    /// `rotation` spins the glyph while a Claude Code session is working. ✻ has eight spokes, so
    /// four frames of 11.25° read as continuous motion, and rotating about the centre within the
    /// unrotated canvas keeps the image the same size — the title must not jitter sideways.
    /// `permissionDot` draws a dot after the spark when a session is waiting on the user: yellow in
    /// Alerts-only, and part of the template (so monochrome) in System.
    static func statusImage(mode: Settings.ColorMode, rotation: CGFloat = 0,
                            permissionDot: Bool = false) -> NSImage {
        let glyph = "✻" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13),
            // Opaque black for the template, not `labelColor`. A template's shape is its *alpha*
            // channel and the colour is discarded — and `labelColor` is only 0.847 alpha, so drawing
            // with it produced a spark rendered at 85% strength, visibly lighter than the built-in
            // template items either side of it. Which is the one thing System mode exists to avoid.
            .foregroundColor: mode == .system ? NSColor.black : spark,
        ]
        let glyphSize = glyph.size(withAttributes: attributes)
        let sparkWidth = ceil(glyphSize.width)
        let height = ceil(glyphSize.height)
        let dotDiameter: CGFloat = 6
        let dotGap: CGFloat = 2
        let width = sparkWidth + (permissionDot ? dotGap + dotDiameter : 0)

        // `NSImage(size:flipped:drawingHandler:)` rather than lockFocus/unlockFocus: the handler is
        // re-run per destination scale, so the glyph stays sharp on a second display with a different
        // backing scale instead of being rasterized once at whatever the main screen happened to be.
        // (lockFocus is also deprecated as of macOS 14; the 13.0 deployment target is the only reason
        // it wasn't warning.)
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            if rotation != 0, let context = NSGraphicsContext.current?.cgContext {
                context.saveGState()
                context.translateBy(x: sparkWidth / 2, y: height / 2)
                context.rotate(by: -rotation * .pi / 180)
                context.translateBy(x: -sparkWidth / 2, y: -height / 2)
                glyph.draw(at: .zero, withAttributes: attributes)
                context.restoreGState()
            } else {
                glyph.draw(at: .zero, withAttributes: attributes)
            }
            if permissionDot {
                (mode == .system ? NSColor.black : NSColor.systemYellow).setFill()
                NSBezierPath(ovalIn: NSRect(x: sparkWidth + dotGap, y: (height - dotDiameter) / 2,
                                            width: dotDiameter, height: dotDiameter)).fill()
            }
            return true
        }
        image.isTemplate = mode == .system
        return image
    }

    /// Which surface is being coloured. The two differ only in the calm state, where the number
    /// takes the ordinary label colour and the bar takes the brand orange — one function can't serve
    /// both without being told which it is colouring.
    enum ColorRole {
        case title
        case bar
    }

    /// The single place utilization becomes a colour, for the menu bar title and the panel's bars
    /// alike, so the two can never disagree about what 80% looks like.
    /// `onPace` promotes an otherwise-calm title percentage to yellow.
    ///
    /// The point of the ramp is "pay attention", and a weekly limit you will hit on Thursday deserves
    /// that at 30% just as much as at 60% — the number alone can't say so. It only ever promotes:
    /// 80%+ stays red, because a forecast is a weaker signal than already being there.
    ///
    /// Titles only. The bar keeps tracking utilization so the panel still reads as a measurement, and
    /// the pace line underneath is where the forecast says its piece in words.
    static func color(_ utilization: Double,
                      mode: Settings.ColorMode,
                      role: ColorRole,
                      onPace: Bool = false) -> NSColor {
        // `.system` ignores utilization entirely. That is not a missing branch — "fully monochrome"
        // means the thresholds don't apply, so the menu bar item looks like every other one up there.
        // A forecast doesn't reopen that: choosing System is choosing no colour at all.
        guard mode == .alertsOnly else {
            return role == .title ? .labelColor : .secondaryLabelColor
        }
        // Every comparison against NaN is false, so without this it falls through both bands into
        // `default` and a NaN renders as *red* — an alarm raised by a number we couldn't even read.
        // `ClaudeProvider` clamps before this point; the guard is for the next provider.
        guard utilization.isFinite else { return role == .title ? .labelColor : spark }
        switch utilization {
        case ..<50:
            if role == .title { return onPace ? .systemYellow : .labelColor }
            return spark
        case ..<80: return .systemYellow
        default: return .systemRed
        }
    }
}
