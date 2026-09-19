import Foundation
import ServiceManagement

/// Carrying a Headroom install across to Cashew.
///
/// The app was called Headroom until the rename, and macOS keys almost everything to the bundle
/// identifier rather than to the name: `~/Library/Application Support/com.vickipetrova.headroom`,
/// the preferences domain of the same name, the login item, the Keychain's record of which binary
/// was allowed to read Claude Code's token. A new identifier means a fresh-looking install — no
/// usage history, so no forecast for days; no settings; and, in Claude Code's own settings file,
/// one dead hook per event still pointing at an app that no longer exists.
///
/// So this runs once, at launch, before anything reads either location. It is deliberately small
/// and deliberately non-destructive: it copies rather than deletes, it never overwrites anything
/// Cashew has already written, and every step is independently safe to skip.
///
/// **Two things it cannot carry, both documented in the changelog rather than papered over.** Launch
/// at Login was registered by macOS against the old identifier and there is no API to read another
/// bundle's registration, so it has to be re-ticked. And the Keychain trusts a *binary*, so the
/// first read of the token prompts once more.
enum LegacyMigration {
    static let legacyBundleID = "com.vickipetrova.headroom"
    static let bundleID = "com.vickipetrova.cashew"

    /// Run every launch; each step decides for itself whether there is anything to do.
    ///
    /// Cheap enough to be unconditional — two `fileExists` checks and a defaults read on the common
    /// path — which is better than a "migrated" flag that would itself live in the new domain and
    /// be lost by the very thing it is meant to guard against.
    static func run() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        _ = moveSupportFolder(from: support.appendingPathComponent(legacyBundleID, isDirectory: true),
                              to: support.appendingPathComponent(bundleID, isDirectory: true))
        if let legacy = UserDefaults(suiteName: legacyBundleID) {
            copyPreferences(from: legacy, to: Settings.defaults)
        }
    }

    /// Copies the old folder — history, the last good reading, session files, the statusline file —
    /// to the new one. True when it did something.
    ///
    /// Copy, not move, and the original is left in place: a user who decides the rename was a
    /// mistake and reinstalls the old build finds their data where it was, and the cost is a few
    /// hundred kilobytes. It refuses outright if the new folder already exists, because then Cashew
    /// has already been running and its data is the newer of the two.
    @discardableResult
    static func moveSupportFolder(from legacy: URL, to current: URL) -> Bool {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: legacy.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              !fileManager.fileExists(atPath: current.path) else { return false }
        do {
            try fileManager.copyItem(at: legacy, to: current)
            return true
        } catch {
            // A failed migration must never stop the app launching: the cost is an empty history,
            // which the app already handles — it is what every first run looks like.
            return false
        }
    }

    /// Carries preferences across, without touching any key the user has already set on this side.
    ///
    /// Only keys Cashew knows about, so a stale key from an old build doesn't come back from the
    /// dead, and `allowHooksOutsideApplications` is deliberately not among them: a developer switch
    /// should be set deliberately on the app it applies to.
    static func copyPreferences(from legacy: UserDefaults, to current: UserDefaults) {
        let carried = [
            "refreshMinutes", "notifyThreshold", "colorMode", "titleLimitIDs",
            "trackSessions", "checkForUpdates", "lastUpdateCheck", "knownRelease",
            "menuBarAnimation", "showStatusWords",
        ]
        for key in carried where current.object(forKey: key) == nil {
            guard let value = legacy.object(forKey: key) else { continue }
            current.set(value, forKey: key)
        }
        // And the alert markers, whose names are built from window ids rather than written down
        // here. Without them every window looks un-alerted, so the first poll after the rename
        // re-fires a threshold alert the user was already told about this period.
        for (key, value) in legacy.dictionaryRepresentation()
        where key.hasPrefix(Notifier.markerPrefix) && current.object(forKey: key) == nil {
            current.set(value, forKey: key)
        }
    }
}
