import Foundation
import UserNotifications

/// Threshold alerts: at most one per window per reset period.
///
/// "Per reset period" is the important part. Polling every minute at 85% with an 80% threshold
/// must not produce an alert every minute, and quitting and relaunching must not restart the
/// count — so the marker is the window's own reset timestamp, persisted.
enum Notifier {
    /// Where the "already told them" markers live. Reassigned only by tests, which point it at a
    /// scratch suite so they neither read nor clobber the real preferences.
    static var defaults = UserDefaults.standard

    /// How an alert actually reaches the user.
    ///
    /// Injectable because `UNUserNotificationCenter.current()` raises an Objective-C exception in a
    /// process with no app bundle — which is every `swift test` run — and an ObjC exception reaching
    /// Swift is an abort, not a catchable error. Without this seam one test would take down the whole
    /// run with no indication of which.
    static var deliver: (LimitWindow, Int) -> Void = { post($0, threshold: $1) }

    /// True when alerts are switched on but macOS won't deliver them — the user denied the
    /// prompt, or the build isn't eligible to register for notifications at all (an ad-hoc
    /// signed build from source is refused outright on recent macOS).
    ///
    /// Worth surfacing: without it the app looks like it's watching your usage and simply never
    /// says anything. Read and written on the main thread only.
    private(set) static var alertsBlocked = false

    /// Asked once, at launch. macOS remembers the answer, so calling again just returns it.
    static func requestAuthorizationIfNeeded() {
        guard Settings.notifyThreshold > 0 else {
            alertsBlocked = false
            return
        }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            DispatchQueue.main.async { alertsBlocked = !granted }
        }
    }

    static func evaluate(_ windows: [LimitWindow], now: Date = Date()) {
        let threshold = Settings.notifyThreshold
        guard threshold > 0 else { return }

        for window in windows {
            // Compared on the rounded value so the alert agrees with the menu bar. At 79.6% the
            // title reads "80%", and an 80% alert that stayed silent would look broken.
            guard window.utilization.rounded() >= Double(threshold) else { continue }

            let key = markerKey(for: window)
            let period = periodID(for: window, now: now)
            let previous = defaults.string(forKey: key).flatMap(Marker.init(raw:))
            let announced = previous?.period == period

            // Speak up for a period we haven't covered yet, or when the threshold has been *lowered*
            // since we did — that's a crossing the user just asked to hear about. Remembering the
            // lowest threshold already announced is what stops raising it back from re-alerting: a
            // plain inequality check meant idle clicks in the Settings submenu produced a fresh alert
            // each time, because changing a setting re-polls and re-evaluates.
            if announced, let previous, threshold >= previous.threshold { continue }

            let lowest = announced ? min(threshold, previous?.threshold ?? threshold) : threshold
            defaults.set(Marker(period: period, threshold: lowest).raw, forKey: key)
            deliver(window, threshold)
        }
    }

    // MARK: - Markers

    /// Keyed on `LimitWindow.id`, never on the display label. Keying on display copy meant restyling
    /// a heading silently reset which alerts counted as already-sent.
    private static func markerKey(for window: LimitWindow) -> String {
        "notified.\(window.id)"
    }

    /// Identifies the reset period currently in effect.
    ///
    /// Quantized to the minute, and that is the whole point: the endpoint re-stamps `resets_at` on
    /// every request. Three polls twenty seconds apart returned the same reset instant with
    /// fractional seconds .516073, .880178 and .202674. Keyed on the raw timestamp, every poll looked
    /// like a fresh period and anyone above their threshold was alerted on every single poll.
    ///
    /// Rounded rather than truncated so a reset that drifts across a boundary (observed: 16:39:59
    /// creeping to 16:40:00 over two hours) doesn't flip buckets. Distinct periods are at least five
    /// hours apart — the shortest window Claude reports — so a minute-wide bucket cannot merge two.
    ///
    /// Falls back to the UTC day when the endpoint omits `resets_at`: a constant there meant such a
    /// window was announced once and then stayed silent forever, across relaunches.
    private static func periodID(for window: LimitWindow, now: Date) -> String {
        guard let resetsAt = window.resetsAt else {
            return "day-\(Int((now.timeIntervalSince1970 / 86_400).rounded(.down)))"
        }
        return "m\(Int((resetsAt.timeIntervalSince1970 / 60).rounded()))"
    }

    private struct Marker {
        let period: String
        /// The lowest threshold already announced for this period.
        let threshold: Int

        var raw: String { "\(period)|\(threshold)" }

        init(period: String, threshold: Int) {
            self.period = period
            self.threshold = threshold
        }

        init?(raw: String) {
            // Split on the last separator: the period component never contains one today, but being
            // strict about the trailing field keeps this correct if that changes.
            guard let separator = raw.lastIndex(of: "|"),
                  let threshold = Int(raw[raw.index(after: separator)...])
            else { return nil }
            self.period = String(raw[..<separator])
            self.threshold = threshold
        }
    }

    // MARK: - Delivery

    /// Never called from a test — see `deliver`.
    static func post(_ window: LimitWindow, threshold: Int) {
        let content = UNMutableNotificationContent()
        content.title = "\(window.shortLabel) at \(Fmt.pct(window.utilization))"
        content.body = window.resetsAt == nil
            ? "Past your \(threshold)% alert."
            : Fmt.resetLine(for: window.resetsAt)
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
