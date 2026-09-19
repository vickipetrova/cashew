import Foundation
import Testing

@testable import CashewCore

/// Carrying a Headroom install over to Cashew.
///
/// The rename changed the bundle identifier, and macOS keys almost everything to that: the
/// Application Support folder, the preferences domain, the hooks written into Claude Code's
/// settings. Without this the app would look freshly installed to someone who had been using it for
/// months — no usage history, no forecast, no settings, and a dead hook per event left behind in
/// `~/.claude/settings.json` pointing at an app that no longer exists.
@Suite struct LegacyMigrationTests {
    private func scratch() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cashew-migration-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    // MARK: Application Support

    @Test func theOldFolderIsMovedWholesale() throws {
        let root = scratch()
        let old = root.appendingPathComponent("com.vickipetrova.headroom", isDirectory: true)
        let new = root.appendingPathComponent("com.vickipetrova.cashew", isDirectory: true)
        try write(#"{"samples":[]}"#, to: old.appendingPathComponent("history.json"))
        try write(#"{"state":"idle"}"#, to: old.appendingPathComponent("sessions/a.json"))

        #expect(LegacyMigration.moveSupportFolder(from: old, to: new))
        #expect(FileManager.default.fileExists(atPath: new.appendingPathComponent("history.json").path))
        #expect(FileManager.default.fileExists(atPath: new.appendingPathComponent("sessions/a.json").path))
        // The old folder is left behind deliberately — see the note on `moveSupportFolder`.
        #expect(FileManager.default.fileExists(atPath: old.path))
    }

    @Test func aFolderThatAlreadyExistsIsNeverOverwritten() throws {
        let root = scratch()
        let old = root.appendingPathComponent("com.vickipetrova.headroom", isDirectory: true)
        let new = root.appendingPathComponent("com.vickipetrova.cashew", isDirectory: true)
        try write("old", to: old.appendingPathComponent("history.json"))
        try write("new", to: new.appendingPathComponent("history.json"))

        #expect(!LegacyMigration.moveSupportFolder(from: old, to: new))
        #expect(try String(contentsOf: new.appendingPathComponent("history.json"), encoding: .utf8) == "new")
    }

    @Test func nothingToMoveIsNotAFailureToReport() {
        let root = scratch()
        #expect(!LegacyMigration.moveSupportFolder(
            from: root.appendingPathComponent("com.vickipetrova.headroom", isDirectory: true),
            to: root.appendingPathComponent("com.vickipetrova.cashew", isDirectory: true)))
    }

    // MARK: Preferences

    @Test func preferencesAreCopiedWithoutClobberingAnythingAlreadySet() throws {
        let oldSuite = "com.vickipetrova.cashew.tests.legacy-\(UUID().uuidString)"
        let newSuite = "com.vickipetrova.cashew.tests.current-\(UUID().uuidString)"
        let old = try #require(UserDefaults(suiteName: oldSuite))
        let new = try #require(UserDefaults(suiteName: newSuite))
        defer {
            old.removePersistentDomain(forName: oldSuite)
            new.removePersistentDomain(forName: newSuite)
        }
        old.set(15, forKey: "refreshMinutes")
        old.set(false, forKey: "checkForUpdates")
        new.set(1, forKey: "refreshMinutes")   // the user already chose something here

        LegacyMigration.copyPreferences(from: old, to: new)

        #expect(new.integer(forKey: "refreshMinutes") == 1)     // untouched
        #expect(new.object(forKey: "checkForUpdates") as? Bool == false)  // carried over
    }

    // MARK: Hooks

    /// The installer recognises its own hooks by the helper's path. After the rename that path is
    /// `cashew-hook`, so a settings file full of `headroom-hook` entries would keep every one of
    /// them: eight dead hooks, one per event, each firing a command that no longer exists.
    @Test func theOldHooksAreRecognisedAndRemoved() throws {
        let settings = try #require(try JSONSerialization.jsonObject(with: Data("""
            {"hooks": {"Stop": [
              {"hooks": [{"type": "command", "command": "afplay done.aiff"}]},
              {"hooks": [{"type": "command",
                "command": "[ -x '/Applications/Headroom.app/Contents/Helpers/headroom-hook' ] || exit 0; exec '/Applications/Headroom.app/Contents/Helpers/headroom-hook' stop"}]}
            ]}}
            """.utf8)) as? [String: Any])

        let merged = HookInstaller.merged(settings, helperPath: nil)
        let commands = (((merged["hooks"] as? [String: Any])?["Stop"] as? [Any]) ?? [])
            .flatMap { entry -> [String] in
                (((entry as? [String: Any])?["hooks"] as? [Any]) ?? [])
                    .compactMap { ($0 as? [String: Any])?["command"] as? String }
            }
        #expect(commands == ["afplay done.aiff"])
    }

    @Test func installingReplacesTheOldHooksRatherThanAddingToThem() throws {
        let helper = "/Applications/Cashew.app/Contents/Helpers/cashew-hook"
        let settings = try #require(try JSONSerialization.jsonObject(with: Data("""
            {"hooks": {"Stop": [{"hooks": [{"type": "command",
              "command": "'/Applications/Headroom.app/Contents/Helpers/headroom-hook' stop"}]}]}}
            """.utf8)) as? [String: Any])

        let merged = HookInstaller.merged(settings, helperPath: helper)
        let commands = (((merged["hooks"] as? [String: Any])?["Stop"] as? [Any]) ?? [])
            .flatMap { entry -> [String] in
                (((entry as? [String: Any])?["hooks"] as? [Any]) ?? [])
                    .compactMap { ($0 as? [String: Any])?["command"] as? String }
            }
        #expect(commands.count == 1)
        #expect(commands.first?.contains("cashew-hook") == true)
        #expect(commands.first?.contains("headroom-hook") == false)
    }

    // MARK: Statusline

    /// Someone who pasted the old snippet keeps writing to the old folder, and their statusline
    /// script is theirs — Cashew has never edited it and is not about to start. So it reads both
    /// locations and Settings tells them, once, where the new line lives.
    @Test func theOldStatuslineFileIsStillRead() throws {
        let root = scratch()
        let old = root.appendingPathComponent("com.vickipetrova.headroom", isDirectory: true)
        let new = root.appendingPathComponent("com.vickipetrova.cashew", isDirectory: true)
        let payload = #"{"rate_limits":{"five_hour":{"used_percentage":16}}}"#
        try write(payload, to: old.appendingPathComponent("statusline.json"))
        try FileManager.default.createDirectory(at: new, withIntermediateDirectories: true)

        let feed = StatuslineFeed(directory: new, legacyDirectory: old)
        let windows = try #require(feed.read(now: Date()))
        #expect(windows.first?.utilization == 16)
        if case .live(_, let legacy) = feed.status(now: Date()) { #expect(legacy) }
        else { Issue.record("expected a live reading from the legacy file") }
    }

    /// The new location wins: someone who has updated their snippet should not be shown an older
    /// reading left behind by the one they replaced.
    @Test func theNewStatuslineFileWins() throws {
        let root = scratch()
        let old = root.appendingPathComponent("com.vickipetrova.headroom", isDirectory: true)
        let new = root.appendingPathComponent("com.vickipetrova.cashew", isDirectory: true)
        try write(#"{"rate_limits":{"five_hour":{"used_percentage":16}}}"#,
                  to: old.appendingPathComponent("statusline.json"))
        try write(#"{"rate_limits":{"five_hour":{"used_percentage":42}}}"#,
                  to: new.appendingPathComponent("statusline.json"))

        let feed = StatuslineFeed(directory: new, legacyDirectory: old)
        #expect(try #require(feed.read(now: Date())).first?.utilization == 42)
        if case .live(_, let legacy) = feed.status(now: Date()) { #expect(!legacy) }
        else { Issue.record("expected a live reading from the current file") }
    }
}
