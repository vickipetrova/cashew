import Foundation
import HeadroomShared

/// Keeps Headroom's hooks in `~/.claude/settings.json`.
///
/// **The only thing Headroom ever changes in that file is its own hooks** — entries whose command
/// runs its bundled `Contents/Helpers/headroom-hook`. Every other key, and every other tool's hook, is carried through.
///
/// Claude Code has no drop-in directory for another app's hooks (a plugin would need the user to run
/// `/plugin install`), so editing the user's settings is the only automatic route. Three things
/// about it were checked against the docs: hooks added this way are not flagged or refused; they are
/// read when a session *starts*, so already-open sessions don't see them; and a hook whose command no
/// longer exists is skipped silently, so a deleted Headroom leaves harmless leftovers.
struct HookInstaller {
    /// What makes a hook Headroom's. The bundle path, not just the helper's name, so a user's own
    /// `my-headroom-hook-script.sh` is never mistaken for one and removed.
    static let marker = "/Contents/Helpers/headroom-hook"

    let claudeDirectory: URL
    let helperPath: String
    /// `Settings.allowHooksOutsideApplications`: lets a dev build install hooks. See `isRunnableLocation`.
    let allowOutsideApplications: Bool

    /// Test seam: runs between reading and the modification-date re-check, so a test can change the
    /// file in the window a real concurrent write would.
    var beforeWrite: () -> Void = {}

    /// Never call from a test — it is the real `~/.claude`.
    static let `default` = HookInstaller(
        claudeDirectory: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true),
        helperPath: Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/headroom-hook").path,
        allowOutsideApplications: Settings.allowHooksOutsideApplications)

    var settingsURL: URL { claudeDirectory.appendingPathComponent("settings.json") }
    var backupURL: URL { claudeDirectory.appendingPathComponent("settings.json.bak-headroom") }

    enum Outcome: Equatable {
        case claudeNotFound
        /// Running from anywhere but `/Applications` or `~/Applications` — a DMG, a translocated
        /// copy, a Downloads folder, a build folder. Those paths go away, and hooks would point at
        /// nothing.
        case notInApplications
        case helperMissing
        /// Not JSON, or `hooks` isn't an object. Never written to.
        case unreadableSettings
        case upToDate
        case wrote
        /// The file changed between reading and writing — most likely Claude Code saving it. Retried
        /// on the next launch rather than risking overwriting that change.
        case changedMeanwhile
        case writeFailed
    }

    func apply(enabled: Bool) -> Outcome {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: claudeDirectory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return .claudeNotFound }
        if enabled {
            guard Self.isRunnableLocation(helperPath, home: fileManager.homeDirectoryForCurrentUser.path,
                                          allowAnywhere: allowOutsideApplications)
            else { return .notInApplications }
            guard fileManager.isExecutableFile(atPath: helperPath) else { return .helperMissing }
        }

        // Resolved, so a dotfiles symlink is written *through* rather than replaced.
        let target = settingsURL.resolvingSymlinksInPath()
        guard let loaded = Self.load(target) else { return .unreadableSettings }
        let next = Self.merged(loaded.settings, helperPath: enabled ? helperPath : nil)
        guard !NSDictionary(dictionary: loaded.settings).isEqual(to: next) else { return .upToDate }
        beforeWrite()
        guard Self.modificationDate(of: target) == loaded.modified else { return .changedMeanwhile }
        // An atomic write replaces the file through its directory, so it would succeed over a file
        // the user locked read-only. Respect the lock instead — and take no backup of a file that
        // isn't going to change.
        if fileManager.fileExists(atPath: target.path), !fileManager.isWritableFile(atPath: target.path) {
            return .writeFailed
        }

        do {
            if loaded.modified != nil, !fileManager.fileExists(atPath: backupURL.path) {
                try fileManager.copyItem(at: target, to: backupURL)
            }
            let permissions = (try? fileManager.attributesOfItem(atPath: target.path))?[.posixPermissions]
            // Sorted keys: `JSONSerialization` can't preserve the user's order, so the first write
            // reorders the file once — and sorting makes every later write stable.
            var data = try JSONSerialization.data(
                withJSONObject: next, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            data.append(0x0A)
            try data.write(to: target, options: .atomic)
            if let permissions {
                try? fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: target.path)
            }
            return .wrote
        } catch {
            return .writeFailed
        }
    }

    // MARK: Pure

    /// The settings with Headroom's hooks installed (a path) or removed (nil).
    static func merged(_ settings: [String: Any], helperPath: String?) -> [String: Any] {
        let originalHooks = settings["hooks"] as? [String: Any]
        var hooks = originalHooks ?? [:]

        for event in HookEvent.allCases {
            let name = event.hookName
            let original = hooks[name]
            // Not an array: not ours to interpret, so not ours to touch.
            if let original, !(original is [Any]) { continue }
            // `[Any]` and filter, never `[[String: Any]]` — a conditional cast to the concrete type
            // fails the whole array over one odd entry (the same trap as the usage `limits` array).
            let before = original as? [Any] ?? []

            if let helperPath {
                let ours = entry(for: event, helperPath: helperPath)
                let alreadyThere = before.contains { existing in
                    guard let existing = existing as? [String: Any] else { return false }
                    return NSDictionary(dictionary: existing).isEqual(to: ours)
                }
                // Present exactly once and current: leave its position alone. Moving it to the end
                // would fight any other tool that also appends, rewriting the file on every launch.
                if alreadyThere, before.reduce(0, { $0 + ourHookCount(in: $1) }) == 1 { continue }
            }

            var entries = before.compactMap(stripOurs)
            if let helperPath { entries.append(entry(for: event, helperPath: helperPath)) }
            if entries.isEmpty {
                // Only remove a key this call emptied. An empty array the user wrote stays.
                if !before.isEmpty { hooks.removeValue(forKey: name) }
            } else {
                hooks[name] = entries
            }
        }

        var result = settings
        if hooks.isEmpty, let originalHooks, !originalHooks.isEmpty {
            result.removeValue(forKey: "hooks")
        } else if !hooks.isEmpty || originalHooks != nil {
            result["hooks"] = hooks
        }
        return result
    }

    /// `[ -x '<helper>' ] || exit 0; exec '<helper>' <event>` — both halves are load-bearing.
    ///
    /// The guard: Claude Code does *not* skip a hook whose command is missing. The shell exits 127
    /// and the session shows a "hook error" notice on every event, so a deleted or moved Headroom
    /// must leave hooks that exit 0 without a word. The `exec`: the helper finds Claude Code as its
    /// parent process, and `exec` replaces the shell rather than running the helper under it, so
    /// the parent is still Claude Code. (`SessionOwner` skips shells anyway, as a backstop.)
    static func command(helperPath: String, event: HookEvent) -> String {
        let quoted = "'\(helperPath.replacingOccurrences(of: "'", with: #"'\''"#))'"
        return "[ -x \(quoted) ] || exit 0; exec \(quoted) \(event.rawValue)"
    }

    /// Only the Applications folders, where an app is expected to stay put. A translocated copy is
    /// refused even with `allowAnywhere`: its path is random and gone after a relaunch.
    static func isRunnableLocation(_ path: String, home: String, allowAnywhere: Bool) -> Bool {
        guard !path.contains("/AppTranslocation/") else { return false }
        return allowAnywhere || path.hasPrefix("/Applications/") || path.hasPrefix("\(home)/Applications/")
    }

    private static func entry(for event: HookEvent, helperPath: String) -> [String: Any] {
        // 5 seconds: the helper finishes in milliseconds and gives up on stdin after 2. The default
        // hook timeout is minutes, which is far too long to hold a session up if something is wrong.
        var entry: [String: Any] = ["hooks": [[
            "type": "command", "command": command(helperPath: helperPath, event: event), "timeout": 5,
        ]]]
        if event.needsMatcher { entry["matcher"] = "*" }
        return entry
    }

    private static func ourHookCount(in entry: Any) -> Int {
        guard let hooks = (entry as? [String: Any])?["hooks"] as? [Any] else { return 0 }
        return hooks.filter { (($0 as? [String: Any])?["command"] as? String)?.contains(marker) == true }.count
    }

    /// The entry with Headroom's hooks taken out; nil when nothing of it remains.
    private static func stripOurs(_ entry: Any) -> Any? {
        guard var dictionary = entry as? [String: Any], let hooks = dictionary["hooks"] as? [Any]
        else { return entry }
        let kept = hooks.filter { (($0 as? [String: Any])?["command"] as? String)?.contains(marker) != true }
        guard kept.count != hooks.count else { return entry }
        guard !kept.isEmpty else { return nil }
        dictionary["hooks"] = kept
        return dictionary
    }

    // MARK: Files

    private static func load(_ url: URL) -> (settings: [String: Any], modified: Date?)? {
        guard FileManager.default.fileExists(atPath: url.path) else { return ([:], nil) }
        let modified = modificationDate(of: url)
        guard let data = try? Data(contentsOf: url) else { return nil }
        if data.allSatisfy({ [0x20, 0x09, 0x0A, 0x0D].contains($0) }) { return ([:], modified) }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let hooks = object["hooks"], !(hooks is [String: Any]) { return nil }
        return (object, modified)
    }

    private static func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    // MARK: Copy

    static func statusLabel(_ outcome: Outcome?, enabled: Bool, sessionCount: Int) -> String {
        guard enabled else {
            switch outcome {
            case .unreadableSettings, .writeFailed, .changedMeanwhile:
                return "Off · couldn't remove hooks from settings.json"
            default:
                return "Off"
            }
        }
        switch outcome {
        case nil: return "Starting…"
        case .claudeNotFound: return "Claude Code not found"
        case .notInApplications: return "Move Headroom to Applications to turn this on"
        case .helperMissing: return "Headroom is incomplete — reinstall it"
        case .unreadableSettings: return "Couldn't read Claude Code's settings.json"
        case .changedMeanwhile, .writeFailed: return "Couldn't update Claude Code's settings.json"
        case .wrote where sessionCount == 0: return "On · new Claude Code sessions will appear"
        case .wrote, .upToDate:
            switch sessionCount {
            case 0: return "On · no active sessions"
            case 1: return "On · 1 session"
            default: return "On · \(sessionCount) sessions"
            }
        }
    }
}
