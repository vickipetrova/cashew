import Foundation
import Testing

@testable import HeadroomCore
@testable import HeadroomShared

/// Headroom edits the user's own Claude Code settings. Every test here guards a way that goes wrong
/// for someone who didn't ask for it: losing another tool's hook, rewriting the file on every launch,
/// replacing a dotfiles symlink, or touching a file it couldn't parse.
@Suite struct HookInstallerTests {
    private let helper = "/Applications/Headroom.app/Contents/Helpers/headroom-hook"

    private func object(_ text: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    private func entries(_ settings: [String: Any], _ event: String) -> [Any] {
        ((settings["hooks"] as? [String: Any])?[event] as? [Any]) ?? []
    }

    private func commands(_ settings: [String: Any], _ event: String) -> [String] {
        entries(settings, event).flatMap { entry -> [String] in
            (((entry as? [String: Any])?["hooks"] as? [Any]) ?? [])
                .compactMap { ($0 as? [String: Any])?["command"] as? String }
        }
    }

    private func same(_ a: [String: Any], _ b: [String: Any]) -> Bool {
        NSDictionary(dictionary: a).isEqual(to: b)
    }

    // MARK: Merge

    @Test func installsEveryEventIntoEmptySettings() {
        let merged = HookInstaller.merged([:], helperPath: helper)
        for event in HookEvent.allCases {
            #expect(commands(merged, event.hookName)
                    == ["[ -x '\(helper)' ] || exit 0; exec '\(helper)' \(event.rawValue)"])
            let entry = entries(merged, event.hookName).first as? [String: Any]
            #expect((entry?["matcher"] as? String) == (event.needsMatcher ? "*" : nil))
        }
    }

    @Test func preservesUnrelatedKeysAndOtherHooks() throws {
        let settings = try object("""
            {"model": "opus", "statusLine": {"type": "command", "command": "~/.claude/statusline.sh"},
             "hooks": {"Stop": [{"hooks": [{"type": "command", "command": "afplay done.aiff"}]}]}}
            """)
        let merged = HookInstaller.merged(settings, helperPath: helper)
        #expect(merged["model"] as? String == "opus")
        #expect(same(try #require(merged["statusLine"] as? [String: Any]),
                     try #require(settings["statusLine"] as? [String: Any])))
        #expect(commands(merged, "Stop") == ["afplay done.aiff", HookInstaller.command(helperPath: helper, event: .stop)])
    }

    @Test func replacesAStalePath() throws {
        let settings = try object("""
            {"hooks": {"Stop": [{"hooks": [{"type": "command",
              "command": "'/Volumes/Headroom/Headroom.app/Contents/Helpers/headroom-hook' stop"}]}]}}
            """)
        #expect(commands(HookInstaller.merged(settings, helperPath: helper), "Stop")
                == [HookInstaller.command(helperPath: helper, event: .stop)])
    }

    /// A later tool appending its own hook after ours must not make Headroom move itself to the end
    /// on every launch — two tools doing that to each other rewrite the file forever.
    @Test func leavesItsHookInPlaceWhenOthersFollowIt() {
        var settings = HookInstaller.merged([:], helperPath: helper)
        var hooks = settings["hooks"] as! [String: Any]
        var stop = hooks["Stop"] as! [Any]
        stop.append(["hooks": [["type": "command", "command": "afplay done.aiff"]]])
        hooks["Stop"] = stop
        settings["hooks"] = hooks
        #expect(same(HookInstaller.merged(settings, helperPath: helper), settings))
    }

    @Test func mergeIsIdempotent() throws {
        let settings = try object(#"{"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "x"}]}]}}"#)
        let once = HookInstaller.merged(settings, helperPath: helper)
        #expect(same(HookInstaller.merged(once, helperPath: helper), once))
    }

    @Test func removalRestoresTheOriginal() throws {
        let original = try object("""
            {"model": "opus", "hooks": {"Stop": [{"hooks": [{"type": "command", "command": "afplay done.aiff"}]}]}}
            """)
        let installed = HookInstaller.merged(original, helperPath: helper)
        #expect(same(HookInstaller.merged(installed, helperPath: nil), original))
        #expect(same(HookInstaller.merged(HookInstaller.merged([:], helperPath: helper), helperPath: nil), [:]))
    }

    @Test func sharedEntryKeepsTheOtherCommand() throws {
        let settings = try object("""
            {"hooks": {"PreToolUse": [{"matcher": "*", "hooks": [
              {"type": "command", "command": "other-tool pre"},
              {"type": "command", "command": "'/old/headroom-hook' pre"}]}]}}
            """)
        #expect(commands(HookInstaller.merged(settings, helperPath: nil), "PreToolUse") == ["other-tool pre"])
    }

    @Test func oddEntriesSurviveInstallAndRemoval() throws {
        let settings = try object(#"{"hooks": {"Stop": ["weird", 5]}}"#)
        let removed = HookInstaller.merged(HookInstaller.merged(settings, helperPath: helper), helperPath: nil)
        #expect(entries(removed, "Stop").count == 2)
    }

    /// Removing when nothing of ours is there must not tidy away an empty array the user wrote.
    @Test func userWrittenEmptyArrayIsKeptByRemoval() throws {
        let settings = try object(#"{"hooks": {"SessionEnd": []}}"#)
        #expect(same(HookInstaller.merged(settings, helperPath: nil), settings))
    }

    @Test func pathsAreShellQuoted() {
        #expect(HookInstaller.command(helperPath: "/Users/o'neil/Headroom.app/Contents/Helpers/headroom-hook",
                                      event: .stop)
                == #"[ -x '/Users/o'\''neil/Headroom.app/Contents/Helpers/headroom-hook' ] || exit 0; "#
                    + #"exec '/Users/o'\''neil/Headroom.app/Contents/Helpers/headroom-hook' stop"#)
    }

    /// Claude Code shows a hook error notice for a command that isn't there, so a deleted or moved
    /// Headroom must make its leftover hooks exit 0 quietly. Runs the real shell, never ~/.claude.
    @Test func missingHelperIsAQuietNoOp() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("headroom-missing-\(UUID().uuidString)/it's gone/headroom-hook").path
        process.arguments = ["-c", HookInstaller.command(helperPath: missing, event: .stop)]
        let stderr = Pipe()
        process.standardError = stderr
        process.standardOutput = Pipe()
        try process.run()
        process.waitUntilExit()
        let errors = stderr.fileHandleForReading.readDataToEndOfFile()
        #expect(process.terminationStatus == 0)
        #expect(errors.isEmpty)
    }

    @Test func translocatedAndMountedLocationsAreRefused() {
        #expect(!HookInstaller.isRunnableLocation(
            "/private/var/folders/x/T/AppTranslocation/ABC/d/Headroom.app/Contents/Helpers/headroom-hook"))
        #expect(!HookInstaller.isRunnableLocation("/Volumes/Headroom/Headroom.app/Contents/Helpers/headroom-hook"))
        #expect(HookInstaller.isRunnableLocation(helper))
    }

    // MARK: Files

    private struct Sandbox {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("headroom-installer-\(UUID().uuidString)", isDirectory: true)
        var claude: URL { root.appendingPathComponent(".claude", isDirectory: true) }
        var settings: URL { claude.appendingPathComponent("settings.json") }
        var backup: URL { claude.appendingPathComponent("settings.json.bak-headroom") }
        var helper: URL { root.appendingPathComponent("headroom-hook") }

        func make(claudeDirectory: Bool = true, helper makeHelper: Bool = true) throws -> HookInstaller {
            if claudeDirectory {
                try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
            } else {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            }
            if makeHelper {
                try Data().write(to: helper)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
            }
            return HookInstaller(claudeDirectory: claude, helperPath: helper.path)
        }
    }

    @Test func noClaudeDirectoryDoesNothing() throws {
        let sandbox = Sandbox()
        #expect(try sandbox.make(claudeDirectory: false).apply(enabled: true) == .claudeNotFound)
    }

    @Test func missingHelperRefusesToInstallButStillRemoves() throws {
        let sandbox = Sandbox()
        let installer = try sandbox.make(helper: false)
        #expect(installer.apply(enabled: true) == .helperMissing)
        #expect(!FileManager.default.fileExists(atPath: sandbox.settings.path))
        #expect(installer.apply(enabled: false) == .upToDate)
    }

    @Test func writesOnceThenLeavesTheFileAlone() throws {
        let sandbox = Sandbox()
        let installer = try sandbox.make()
        #expect(installer.apply(enabled: true) == .wrote)
        let first = try Data(contentsOf: sandbox.settings)
        #expect(installer.apply(enabled: true) == .upToDate)
        #expect(try Data(contentsOf: sandbox.settings) == first)
        // No original existed, so there is nothing to back up.
        #expect(!FileManager.default.fileExists(atPath: sandbox.backup.path))
    }

    @Test func backupIsTakenOnceAndNeverOverwritten() throws {
        let sandbox = Sandbox()
        let installer = try sandbox.make()
        let original = Data(#"{"model": "opus"}"#.utf8)
        try original.write(to: sandbox.settings)
        #expect(installer.apply(enabled: true) == .wrote)
        #expect(installer.apply(enabled: false) == .wrote)
        #expect(try Data(contentsOf: sandbox.backup) == original)
    }

    @Test(arguments: [#"{ not json"#, #"{"hooks": []}"#, #"[1, 2]"#])
    func unparseableSettingsAreNeverTouched(_ text: String) throws {
        let sandbox = Sandbox()
        let installer = try sandbox.make()
        try Data(text.utf8).write(to: sandbox.settings)
        #expect(installer.apply(enabled: true) == .unreadableSettings)
        #expect(try Data(contentsOf: sandbox.settings) == Data(text.utf8))
        #expect(!FileManager.default.fileExists(atPath: sandbox.backup.path))
    }

    /// Dotfile managers symlink `settings.json`. An atomic write to the link's path would replace the
    /// link with a plain file and silently detach it from the user's repo.
    @Test func symlinkedSettingsStayASymlink() throws {
        let sandbox = Sandbox()
        let installer = try sandbox.make()
        let real = sandbox.root.appendingPathComponent("dotfiles-settings.json")
        try Data(#"{"model": "opus"}"#.utf8).write(to: real)
        try FileManager.default.createSymbolicLink(at: sandbox.settings, withDestinationURL: real)
        #expect(installer.apply(enabled: true) == .wrote)
        let attributes = try FileManager.default.attributesOfItem(atPath: sandbox.settings.path)
        #expect(attributes[.type] as? FileAttributeType == .typeSymbolicLink)
        let written = try object(String(decoding: try Data(contentsOf: real), as: UTF8.self))
        #expect(!commands(written, "Stop").isEmpty)
    }

    /// If Claude Code (or another tool) rewrites settings.json in the window between our read and our
    /// write, we must not clobber that write with one based on stale contents.
    @Test func concurrentChangeIsNotOverwritten() throws {
        let sandbox = Sandbox()
        var installer = try sandbox.make()
        let originalDate = Date(timeIntervalSince1970: 1_790_000_000)
        try Data(#"{"model": "opus"}"#.utf8).write(to: sandbox.settings)
        try FileManager.default.setAttributes([.modificationDate: originalDate], ofItemAtPath: sandbox.settings.path)
        installer.beforeWrite = {
            try? Data(#"{"model": "sonnet"}"#.utf8).write(to: sandbox.settings)
            try? FileManager.default.setAttributes(
                [.modificationDate: originalDate.addingTimeInterval(60)], ofItemAtPath: sandbox.settings.path)
        }
        #expect(installer.apply(enabled: true) == .changedMeanwhile)
        #expect(try Data(contentsOf: sandbox.settings) == Data(#"{"model": "sonnet"}"#.utf8))
        #expect(!FileManager.default.fileExists(atPath: sandbox.backup.path))
    }

    // MARK: Status

    @Test func statusLabels() {
        #expect(HookInstaller.statusLabel(.upToDate, enabled: false, sessionCount: 3) == "Off")
        #expect(HookInstaller.statusLabel(.wrote, enabled: true, sessionCount: 0)
                == "On · new Claude Code sessions will appear")
        #expect(HookInstaller.statusLabel(.upToDate, enabled: true, sessionCount: 0) == "On · no active sessions")
        #expect(HookInstaller.statusLabel(.upToDate, enabled: true, sessionCount: 1) == "On · 1 session")
        #expect(HookInstaller.statusLabel(.wrote, enabled: true, sessionCount: 2) == "On · 2 sessions")
        #expect(HookInstaller.statusLabel(.notInApplications, enabled: true, sessionCount: 0)
                == "Move Headroom to Applications to turn this on")
        #expect(HookInstaller.statusLabel(.unreadableSettings, enabled: false, sessionCount: 0)
                == "Off · couldn't remove hooks from settings.json")
    }
}
