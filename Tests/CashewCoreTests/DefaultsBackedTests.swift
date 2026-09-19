import Foundation
import Testing

@testable import CashewCore

/// `Notifier` and `Settings` both read a `UserDefaults` that these tests reassign, so they must not
/// run concurrently with each other. `.serialized` is inherited by nested suites — marking each
/// inner suite instead would still let the two of them race.
///
/// Setup happens in `init` and there is deliberately no `deinit`: swift-testing releases the previous
/// suite instance while constructing the next one, so a `deinit` that restored these statics would
/// overlap the next `init` writing them and trip Swift's exclusivity checking. Wiping the scratch
/// domain on the way *in* gives the same isolation without the hazard, and makes a crashed run
/// self-healing rather than leaving poisoned state for the next one.
@Suite(.serialized)
struct DefaultsBacked {
    /// Never the app's real domain (`com.vickipetrova.cashew`): pointing tests at that would
    /// clobber the developer's own refresh interval, threshold, and live alert markers.
    static let suiteName = "com.vickipetrova.cashew.tests"

    /// A named suite is not in-memory — it is flushed to ~/Library/Preferences/<name>.plist. Without
    /// the wipe, markers would survive the run and a "first alert fires" test would pass once and
    /// fail every time after.
    static func scratchDefaults(clearing: Bool = true) throws -> UserDefaults {
        _ = removeScratchPlistAtExit
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        if clearing { defaults.removePersistentDomain(forName: suiteName) }
        return defaults
    }

    /// Registered once, the first time a scratch suite is opened, so a run doesn't leave its markers
    /// sitting in the developer's preferences afterwards. (cfprefsd still recreates an empty
    /// ~/Library/Preferences/<suiteName>.plist skeleton; the point is that it holds nothing.)
    /// `atexit` rather than a `deinit`: see the note on the suite above.
    private static let removeScratchPlistAtExit: Void = {
        atexit { UserDefaults().removePersistentDomain(forName: DefaultsBacked.suiteName) }
    }()

    /// Collects what `evaluate` decided to send, standing in for `UNUserNotificationCenter` — which
    /// aborts the process when there is no app bundle, as in every `swift test` run.
    final class Recorder: @unchecked Sendable {
        private(set) var alerts: [(label: String, threshold: Int)] = []
        func record(_ window: LimitWindow, _ threshold: Int) {
            alerts.append((window.label, threshold))
        }
        func reset() { alerts.removeAll() }
        var count: Int { alerts.count }
        var labels: [String] { alerts.map(\.label) }
    }

    // MARK: - Notifier

    /// Alert de-duplication. The promise is "at most one per window per reset period", and both
    /// failure modes are invisible: either the user is spammed, or they are silently never told.
    @Suite struct NotifierTests {
        private let defaults: UserDefaults
        private let recorder = Recorder()

        init() throws {
            defaults = try DefaultsBacked.scratchDefaults()
            Settings.defaults = defaults
            Notifier.defaults = defaults
            let recorder = self.recorder
            Notifier.deliver = { recorder.record($0, $1) }
        }

        private let reset = Date(timeIntervalSince1970: 1_785_688_799)
        private let now = Date(timeIntervalSince1970: 1_785_600_000)
        // Keyed on the window's stable id, not its display label — restyling a heading must not
        // reset which alerts count as already-sent.
        private let sessionKey = "notified.session"

        private func window(_ utilization: Double, id: String = "session",
                            resetsAt: Date?) -> LimitWindow {
            LimitWindow(kind: .session, id: id, label: "SESSION · 5-HOUR", shortLabel: "Session", optionLabel: "opt",
                        utilization: utilization, resetsAt: resetsAt)
        }

        @Test func crossingTheThresholdAlertsOnce() {
            Settings.notifyThreshold = 80
            Notifier.evaluate([window(85, resetsAt: reset)], now: now)
            #expect(recorder.count == 1)
            #expect(recorder.alerts.first?.threshold == 80)
            #expect(defaults.string(forKey: sessionKey) != nil)
        }

        @Test func pollingAgainWithTheSameDataStaysQuiet() {
            Settings.notifyThreshold = 80
            let windows = [window(85, resetsAt: reset)]
            Notifier.evaluate(windows, now: now)
            Notifier.evaluate(windows, now: now)
            Notifier.evaluate(windows, now: now)
            #expect(recorder.count == 1)
        }

        /// The entire reason the marker is persisted rather than held in memory.
        @Test func markerSurvivesARelaunch() throws {
            Settings.notifyThreshold = 80
            Notifier.evaluate([window(85, resetsAt: reset)], now: now)
            recorder.reset()

            // A fresh process reading what the previous one stored.
            Notifier.defaults = try DefaultsBacked.scratchDefaults(clearing: false)
            Notifier.evaluate([window(87, resetsAt: reset)], now: now)
            #expect(recorder.count == 0)
        }

        @Test func aNewResetPeriodAlertsAgain() {
            Settings.notifyThreshold = 80
            Notifier.evaluate([window(85, resetsAt: reset)], now: now)
            Notifier.evaluate([window(85, resetsAt: reset.addingTimeInterval(18_000))], now: now)
            #expect(recorder.count == 2)
        }

        @Test func belowThresholdSaysNothingAndRecordsNothing() {
            Settings.notifyThreshold = 80
            Notifier.evaluate([window(42, resetsAt: reset)], now: now)
            #expect(recorder.count == 0)
            #expect(defaults.string(forKey: sessionKey) == nil)
        }

        @Test func thresholdOffSaysNothing() {
            Settings.notifyThreshold = 0
            Notifier.evaluate([window(99, resetsAt: reset)], now: now)
            #expect(recorder.count == 0)
        }

        @Test func exactlyAtTheThresholdAlerts() {
            Settings.notifyThreshold = 80
            Notifier.evaluate([window(80, resetsAt: reset)], now: now)
            #expect(recorder.count == 1)
        }

        /// Regression: the menu bar rounds, so 79.6% displays as "80%". An 80% alert that stayed
        /// silent while the title read 80% looks broken.
        @Test func alertMatchesTheDisplayedPercentage() {
            Settings.notifyThreshold = 80
            Notifier.evaluate([window(79.6, resetsAt: reset)], now: now)
            #expect(Fmt.pct(79.6) == "80%")
            #expect(recorder.count == 1)
        }

        @Test func windowsAreTrackedIndependently() {
            Settings.notifyThreshold = 80
            Notifier.evaluate([
                window(85, id: "session", resetsAt: reset),
                window(90, id: "weekly", resetsAt: reset),
                window(10, id: "scoped:Opus", resetsAt: reset),
            ], now: now)
            #expect(recorder.count == 2)
            #expect(defaults.string(forKey: "notified.session") != nil)
            #expect(defaults.string(forKey: "notified.weekly") != nil)
            #expect(defaults.string(forKey: "notified.scoped:Opus") == nil)
        }

        /// Restyling a heading must not look like a new window and re-announce a crossing already
        /// sent — the reason identity moved off the display label.
        @Test func relabellingAWindowDoesNotReAlert() {
            Settings.notifyThreshold = 80
            Notifier.evaluate([window(85, resetsAt: reset)], now: now)
            let restyled = LimitWindow(kind: .session, id: "session",
                                       label: "COMPLETELY DIFFERENT HEADING", shortLabel: "Session", optionLabel: "opt",
                                       utilization: 85, resetsAt: reset)
            Notifier.evaluate([restyled], now: now)
            #expect(recorder.count == 1)
        }

        /// Lowering the threshold is a crossing the user just asked to hear about.
        @Test func loweringTheThresholdAlertsAgain() {
            Settings.notifyThreshold = 80
            Notifier.evaluate([window(85, resetsAt: reset)], now: now)
            Settings.notifyThreshold = 50
            Notifier.evaluate([window(85, resetsAt: reset)], now: now)
            #expect(recorder.count == 2)
        }

        /// Regression: raising it back is not a new crossing. Changing any setting re-polls and
        /// re-evaluates, so comparing thresholds by inequality meant idle clicks in the Settings
        /// submenu produced a fresh alert every time.
        @Test func raisingTheThresholdBackDoesNotAlertAgain() {
            Settings.notifyThreshold = 80
            Notifier.evaluate([window(85, resetsAt: reset)], now: now)
            Settings.notifyThreshold = 50
            Notifier.evaluate([window(85, resetsAt: reset)], now: now)
            recorder.reset()

            Settings.notifyThreshold = 80
            Notifier.evaluate([window(85, resetsAt: reset)], now: now)
            Settings.notifyThreshold = 90
            Notifier.evaluate([window(95, resetsAt: reset)], now: now)
            #expect(recorder.count == 0)
        }

        /// Regression, and the one that matters most: the endpoint re-stamps `resets_at` on every
        /// request. Three real polls 20 seconds apart came back with fractional seconds .516073,
        /// .880178, .202674 — the same reset instant, restamped. Keying the period on the raw
        /// timestamp made every poll look like a new period, so anyone over the threshold was
        /// alerted on *every poll*: twelve an hour at the default interval.
        ///
        /// Every other test in this suite passed throughout, because each one builds a single `Date`
        /// and reuses it — self-consistent, and wrong about the server.
        @Test func restampedResetTimeIsStillTheSamePeriod() {
            Settings.notifyThreshold = 80
            for fraction in [0.516073, 0.880178, 0.202674] {
                let restamped = Date(timeIntervalSince1970: 1_785_688_800 + fraction)
                Notifier.evaluate([window(85, resetsAt: restamped)], now: now)
            }
            #expect(recorder.count == 1)
        }

        /// The flip side: a genuinely different period must still get through. Windows are at least
        /// five hours apart, so quantizing the period can never merge two real ones.
        @Test func quantizingDoesNotSwallowARealNewPeriod() {
            Settings.notifyThreshold = 80
            Notifier.evaluate([window(85, resetsAt: reset)], now: now)
            Notifier.evaluate([window(85, resetsAt: reset.addingTimeInterval(300))], now: now)
            #expect(recorder.count == 2)
        }

        /// Regression: with no reset time the marker used to be a constant, so a window was
        /// announced once and then stayed silent forever, across relaunches. It should still be once
        /// per period — falling back to the day when the endpoint won't say.
        @Test func windowWithNoResetTimeAlertsOncePerDay() {
            Settings.notifyThreshold = 80
            Notifier.evaluate([window(85, resetsAt: nil)], now: now)
            Notifier.evaluate([window(85, resetsAt: nil)], now: now)
            #expect(recorder.count == 1)

            Notifier.evaluate([window(85, resetsAt: nil)], now: now.addingTimeInterval(86_400 * 2))
            #expect(recorder.count == 2)
        }
    }

    // MARK: - Settings

    @Suite struct SettingsTests {
        private let defaults: UserDefaults

        init() throws {
            defaults = try DefaultsBacked.scratchDefaults()
            Settings.defaults = defaults
        }

        @Test func unsetPreferencesUseTheDocumentedDefaults() {
            #expect(Settings.refreshMinutes == 5)
            #expect(Settings.notifyThreshold == 80)
            #expect(Settings.refreshInterval == 300)
        }

        /// A hand-edited plist must not be able to leave the app polling every zero seconds.
        @Test(arguments: [0, 3, -1, 999])
        func outOfRangeRefreshFallsBackToTheDefault(_ stored: Int) {
            defaults.set(stored, forKey: "refreshMinutes")
            #expect(Settings.refreshMinutes == 5)
        }

        @Test(arguments: [1, 5, 15])
        func offeredRefreshValuesAreKept(_ stored: Int) {
            Settings.refreshMinutes = stored
            #expect(Settings.refreshMinutes == stored)
            #expect(Settings.refreshInterval == TimeInterval(stored * 60))
        }

        /// The highest-value assertion in this file. "Off" is stored as 0, which is also what
        /// `UserDefaults.integer(forKey:)` returns for a missing key — so the getter has to probe for
        /// the key's existence separately. Collapse that and alerts silently switch back on for
        /// everyone who turned them off.
        @Test func offIsPersistedAndNotMistakenForUnset() {
            Settings.notifyThreshold = 0
            #expect(Settings.notifyThreshold == 0)
        }

        @Test(arguments: [50, 80, 90])
        func offeredThresholdsAreKept(_ stored: Int) {
            Settings.notifyThreshold = stored
            #expect(Settings.notifyThreshold == stored)
        }

        @Test(arguments: [42, -1, 100])
        func outOfRangeThresholdFallsBackToTheDefault(_ stored: Int) {
            defaults.set(stored, forKey: "notifyThreshold")
            #expect(Settings.notifyThreshold == 80)
        }

        @Test func colourModeDefaultsToAlertsOnly() {
            #expect(Settings.colorMode == .alertsOnly)
        }

        @Test(arguments: Settings.ColorMode.allCases)
        func offeredColourModesAreKept(_ mode: Settings.ColorMode) {
            Settings.colorMode = mode
            #expect(Settings.colorMode == mode)
        }

        /// Same rule as the two settings above: a value we don't recognise — a hand-edited plist, or
        /// a mode removed in a later version — falls back rather than leaving the app in a mode that
        /// no longer exists.
        @Test(arguments: ["", "rainbow", "System", "alertsonly"])
        func anUnknownStoredColourModeFallsBack(_ stored: String) {
            defaults.set(stored, forKey: "colorMode")
            #expect(Settings.colorMode == .alertsOnly)
        }

        // MARK: - Which limits show in the menu bar

        @Test func titleShowsSessionAndWeeklyByDefault() {
            #expect(Settings.titleLimitIDs == [LimitWindow.sessionID, LimitWindow.weeklyID])
        }

        @Test func titleSelectionRoundTrips() {
            Settings.titleLimitIDs = [LimitWindow.sessionID, "scoped:Fable"]
            #expect(Settings.titleLimitIDs == [LimitWindow.sessionID, "scoped:Fable"])
        }

        /// Keyed by identifier, not display name — a heading restyle must not silently deselect a
        /// limit the user chose.
        @Test func titleSelectionIsKeyedByIdentifier() {
            Settings.titleLimitIDs = ["scoped:Fable"]
            let stored = defaults.array(forKey: "titleLimitIDs") as? [String]
            #expect(stored == ["scoped:Fable"])
            #expect(stored?.contains(where: { $0.contains("THIS WEEK") }) != true)
        }

        @Test func togglingAddsAndRemoves() {
            let base: Set<String> = [LimitWindow.sessionID, LimitWindow.weeklyID]
            #expect(Settings.titleLimitIDs(toggling: "scoped:Fable", in: base)
                == [LimitWindow.sessionID, LimitWindow.weeklyID, "scoped:Fable"])
            #expect(Settings.titleLimitIDs(toggling: LimitWindow.weeklyID, in: base)
                == [LimitWindow.sessionID])
        }

        /// Unchecking everything is allowed, and means what it says: no numbers in the menu bar.
        /// The item still draws its spark, so it stays clickable and this setting stays two hovers
        /// away — which is why the old "always keep one" fallback was protecting nothing.
        @Test func unCheckingTheLastOneLeavesNothingSelected() {
            #expect(Settings.titleLimitIDs(toggling: LimitWindow.weeklyID, in: [LimitWindow.weeklyID])
                == [])
            #expect(Settings.titleLimitIDs(toggling: "scoped:Fable", in: ["scoped:Fable"]) == [])
            // Including unchecking session itself.
            #expect(Settings.titleLimitIDs(toggling: LimitWindow.sessionID, in: [LimitWindow.sessionID])
                == [])
        }

        /// The distinction the getter turns on: *never set* means "give me the defaults", and an
        /// empty array means "the user unchecked them all". `UserDefaults` keeps the two apart —
        /// `array(forKey:)` returns nil for the first and `[]` for the second — so an emptied
        /// selection has to survive a relaunch rather than springing back to the defaults.
        @Test func anEmptySelectionRoundTrips() {
            Settings.titleLimitIDs = []
            #expect(defaults.array(forKey: "titleLimitIDs") as? [String] == [])
            #expect(Settings.titleLimitIDs == [])
        }

        /// A stored value of the wrong shape entirely — a hand-edited plist, or a format change in a
        /// later version — falls back rather than crashing on the cast.
        @Test func aWronglyTypedStoredSelectionFallsBack() {
            defaults.set("session", forKey: "titleLimitIDs")
            #expect(Settings.titleLimitIDs == Settings.defaultTitleLimitIDs)
            defaults.set([1, 2], forKey: "titleLimitIDs")
            #expect(Settings.titleLimitIDs == Settings.defaultTitleLimitIDs)
        }

        // `Settings.launchAtLogin` is deliberately never touched: its setter registers a real login
        // item with macOS, which from a test process would point at the test binary.

        @Test func sessionTrackingAndUpdateChecksDefaultOn() {
            #expect(Settings.trackSessions)
            #expect(Settings.checkForUpdates)
            #expect(Settings.lastUpdateCheck == nil)
            #expect(Settings.knownRelease == nil)
        }

        /// A developer switch: a dev bundle installing hooks rewrites the real settings.json to point
        /// into a build folder, so it has to be asked for.
        @Test func hooksOutsideApplicationsDefaultOff() {
            #expect(!Settings.allowHooksOutsideApplications)
            defaults.set(true, forKey: "allowHooksOutsideApplications")
            #expect(Settings.allowHooksOutsideApplications)
        }

        /// Same trap as the threshold: `bool(forKey:)` is false for a missing key, so "off" has to be
        /// told apart from "never set" or turning it off would not survive a relaunch.
        @Test func turningThemOffIsPersisted() {
            Settings.trackSessions = false
            Settings.checkForUpdates = false
            #expect(!Settings.trackSessions)
            #expect(!Settings.checkForUpdates)
        }

        @Test func knownReleaseRoundTripsAndIsRevalidated() throws {
            let release = try #require(UpdateCheck.release(in: [
                "tag_name": "v0.2.0",
                "html_url": "https://github.com/vickipetrova/cashew/releases/tag/v0.2.0",
            ]))
            Settings.knownRelease = release
            #expect(Settings.knownRelease == release)
            // A hand-edited plist can't smuggle in a link to somewhere else.
            defaults.set(["tag_name": "v9.9.9", "html_url": "https://evil.example/"], forKey: "knownRelease")
            #expect(Settings.knownRelease == nil)
            Settings.knownRelease = nil
            #expect(defaults.object(forKey: "knownRelease") == nil)
        }
    }
}
