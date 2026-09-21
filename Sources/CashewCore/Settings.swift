import Foundation
import ServiceManagement

/// Preferences, backed by UserDefaults. There is no settings window in v0.1 — everything here is
/// driven from the Settings submenu in the dropdown.
enum Settings {
    /// Minutes between polls. The endpoint is cheap, but there's no reason to hammer it.
    static let refreshOptions = [1, 5, 15]

    /// Utilization percentage that triggers an alert. 0 means never.
    static let thresholdOptions = [0, 50, 80, 90]

    /// How much colour the menu bar and the panel use.
    enum ColorMode: String, CaseIterable {
        /// Colour means "pay attention": ordinary label colour and the brand orange until usage is
        /// worth noticing, then yellow, then red. The default, because a permanent green at 3% used
        /// is noise — it says "fine" in the state you are in almost always.
        case alertsOnly
        /// No colour at all. Everything takes a system label colour and the spark becomes a template
        /// image, so the whole item adapts like a built-in menu bar control.
        case system

        /// Read under the word COLOR, which is what lets both of these be this short — and what
        /// makes them parallel answers to one question instead of two jargon terms. "Alerts only"
        /// and "System" named the *modes*; these name what you'd see.
        var label: String {
            switch self {
            case .alertsOnly: return "Only when usage is high"
            case .system: return "Never"
            }
        }
    }

    /// Reassigned only by tests, which point it at a scratch suite rather than the real preferences.
    static var defaults = UserDefaults.standard

    private enum Key {
        static let refreshMinutes = "refreshMinutes"
        static let notifyThreshold = "notifyThreshold"
        static let colorMode = "colorMode"
        static let titleLimitIDs = "titleLimitIDs"
        static let trackSessions = "trackSessions"
        static let menuBarAnimation = "menuBarAnimation"
        static let showStatusWords = "showStatusWords"
        static let checkForUpdates = "checkForUpdates"
        static let allowHooksOutsideApplications = "allowHooksOutsideApplications"
        static let lastUpdateCheck = "lastUpdateCheck"
        static let knownRelease = "knownRelease"
    }

    /// Which limits appear in the menu bar title, by `LimitWindow.id`.
    ///
    /// Stored by identifier rather than by display name so that restyling a heading — or the vendor
    /// renaming a model — doesn't quietly lose the choice. The one caveat worth knowing: a scoped
    /// window's id is derived from the model's display name, because the endpoint's own
    /// `scope.model.id` is null in every response we have seen. So a *genuine* model rename does
    /// lose that one entry; nothing better is on offer from the API.
    ///
    /// Ids that no longer appear in the response are kept here on purpose. A scope that vanishes for
    /// a week and comes back should come back selected.
    ///
    /// Empty is a legitimate choice — a menu bar item with no numbers in it, just the spark and
    /// whatever the sessions are saying. The `guard` is what keeps that distinct from never having
    /// chosen: `array(forKey:)` returns nil for a key that was never written and `[]` for one the
    /// user emptied, so the defaults apply to the first and not the second.
    static var titleLimitIDs: Set<String> {
        get {
            guard let stored = defaults.array(forKey: Key.titleLimitIDs) as? [String] else {
                return defaultTitleLimitIDs
            }
            return Set(stored)
        }
        set { defaults.set(Array(newValue), forKey: Key.titleLimitIDs) }
    }

    /// The two headline windows — what the title showed before this was configurable.
    ///
    /// Qualified, because the stored set is shared across providers: an unqualified `"session"`
    /// would select both Claude's and Codex's short window with one entry and give no way to
    /// choose between them.
    static let defaultTitleLimitIDs: Set<String> = [
        ProviderID.claude.qualify(LimitWindow.sessionID),
        ProviderID.claude.qualify(LimitWindow.weeklyID),
    ]

    /// Pure, so the rule is testable without a menu.
    ///
    /// Unchecking the last limit leaves the set empty, and that is allowed. It used to fall back to
    /// the session window on the grounds that a bare spark "looks broken and offers no way back" —
    /// but the spark is drawn whether or not any limit is selected, so the item stays clickable and
    /// this setting stays two hovers away. The fallback was guarding a state that was never
    /// unreachable, at the cost of making a deliberate choice impossible to express.
    static func titleLimitIDs(toggling id: String, in current: Set<String>) -> Set<String> {
        var next = current
        if next.contains(id) { next.remove(id) } else { next.insert(id) }
        return next
    }

    /// Same shape as the two above: a stored value we don't recognise falls back to the default
    /// rather than leaving the app in a mode that doesn't exist.
    static var colorMode: ColorMode {
        get {
            defaults.string(forKey: Key.colorMode).flatMap(ColorMode.init(rawValue:)) ?? .alertsOnly
        }
        set { defaults.set(newValue.rawValue, forKey: Key.colorMode) }
    }

    /// Values outside the offered set fall back to the default, so a hand-edited plist can't
    /// leave the app polling every 0 seconds.
    static var refreshMinutes: Int {
        get {
            let stored = defaults.integer(forKey: Key.refreshMinutes)
            return refreshOptions.contains(stored) ? stored : 5
        }
        set { defaults.set(newValue, forKey: Key.refreshMinutes) }
    }

    static var refreshInterval: TimeInterval { TimeInterval(refreshMinutes * 60) }

    static var notifyThreshold: Int {
        get {
            guard defaults.object(forKey: Key.notifyThreshold) != nil else { return 80 }
            let stored = defaults.integer(forKey: Key.notifyThreshold)
            return thresholdOptions.contains(stored) ? stored : 80
        }
        set { defaults.set(newValue, forKey: Key.notifyThreshold) }
    }

    /// Which of the menu bar's working animations is drawn. A stored value we don't recognise falls
    /// back to the default rather than leaving the item blank.
    static var menuBarAnimation: MenuBarAnimation {
        get {
            defaults.string(forKey: Key.menuBarAnimation).flatMap(MenuBarAnimation.init(rawValue:))
                ?? .sparkSpin
        }
        set { defaults.set(newValue.rawValue, forKey: Key.menuBarAnimation) }
    }

    /// Whether the menu bar says what a session is doing ("Percolating…", "Awaiting approval") next
    /// to the numbers. On by default; off leaves the animation to say it, and the animation turns
    /// yellow when a session is waiting.
    static var showStatusWords: Bool {
        get {
            defaults.object(forKey: Key.showStatusWords) == nil
                ? true : defaults.bool(forKey: Key.showStatusWords)
        }
        set { defaults.set(newValue, forKey: Key.showStatusWords) }
    }

    /// On by default. Probed for existence first, because `bool(forKey:)` returns false for a missing
    /// key and "off" has to survive a relaunch.
    static var trackSessions: Bool {
        get { defaults.object(forKey: Key.trackSessions) == nil ? true : defaults.bool(forKey: Key.trackSessions) }
        set { defaults.set(newValue, forKey: Key.trackSessions) }
    }

    static var checkForUpdates: Bool {
        get { defaults.object(forKey: Key.checkForUpdates) == nil ? true : defaults.bool(forKey: Key.checkForUpdates) }
        set { defaults.set(newValue, forKey: Key.checkForUpdates) }
    }

    /// A developer switch, with no menu item: lets a bundle outside `/Applications` and
    /// `~/Applications` install its hooks. Off by default, because doing so points the real
    /// `~/.claude/settings.json` at that bundle — a build folder that gets cleaned. Set it with
    /// `defaults write com.vickipetrova.cashew allowHooksOutsideApplications -bool true`.
    static var allowHooksOutsideApplications: Bool {
        get { defaults.bool(forKey: Key.allowHooksOutsideApplications) }
        set { defaults.set(newValue, forKey: Key.allowHooksOutsideApplications) }
    }

    /// When the update check last *tried*, successful or not — so a network that is down doesn't turn
    /// once a day into once an hour.
    static var lastUpdateCheck: Date? {
        get { defaults.object(forKey: Key.lastUpdateCheck) as? Date }
        set { defaults.set(newValue, forKey: Key.lastUpdateCheck) }
    }

    /// The newest release seen, kept so an update found yesterday still shows after a restart today.
    /// Stored in the API's own shape and re-read through `UpdateCheck.release(in:)`, so a hand-edited
    /// plist gets the same URL checks as the network does.
    static var knownRelease: Release? {
        get { defaults.dictionary(forKey: Key.knownRelease).flatMap(UpdateCheck.release(in:)) }
        set {
            guard let newValue else { return defaults.removeObject(forKey: Key.knownRelease) }
            defaults.set(["tag_name": newValue.tag, "html_url": newValue.url.absoluteString],
                         forKey: Key.knownRelease)
        }
    }

    /// Deliberately not mirrored into UserDefaults: macOS owns this state (the user can revoke it
    /// in System Settings › General › Login Items), so a local copy would go stale and lie.
    static var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                // Registration legitimately fails when the app runs from a temporary or
                // quarantined location. Since the getter reads the real status, the checkmark
                // simply doesn't move — which is the honest result, not a silent lie.
            }
        }
    }
}
