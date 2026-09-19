import Foundation
import Testing

@testable import CashewCore

@Suite struct GitBranchTests {
    private func scratch() throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cashew-git-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    private func write(_ text: String, to path: String) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        try Data(text.utf8).write(to: URL(fileURLWithPath: path))
    }

    @Test func parsesHead() {
        #expect(GitBranch.branch(fromHead: "ref: refs/heads/feat/session-activity\n") == "feat/session-activity")
        #expect(GitBranch.branch(fromHead: "0a1b2c3d4e5f60718293a4b5c6d7e8f901234567\n") == "0a1b2c3")
        #expect(GitBranch.branch(fromHead: "ref: refs/heads/\n") == nil)
        #expect(GitBranch.branch(fromHead: "garbage") == nil)
    }

    @Test func findsHeadFromANestedDirectory() throws {
        let repo = try scratch()
        try write("ref: refs/heads/main\n", to: "\(repo)/.git/HEAD")
        try FileManager.default.createDirectory(atPath: "\(repo)/Sources/App", withIntermediateDirectories: true)
        // Suffix, not equality: `standardizingPath` may rewrite the temp directory's /private prefix.
        #expect(GitBranch.headPath(from: "\(repo)/Sources/App")?.hasSuffix("/.git/HEAD") == true)
        #expect(GitBranch().branch(cwd: "\(repo)/Sources/App") == "main")
    }

    /// A worktree's `.git` is a file pointing at the real git directory.
    @Test func followsWorktreeGitdirFiles() throws {
        let root = try scratch()
        try write("gitdir: \(root)/main/.git/worktrees/wt\n", to: "\(root)/wt/.git")
        try write("ref: refs/heads/feat/x\n", to: "\(root)/main/.git/worktrees/wt/HEAD")
        #expect(GitBranch().branch(cwd: "\(root)/wt") == "feat/x")
    }

    @Test func relativeGitdir() throws {
        let root = try scratch()
        try write("gitdir: ../main/.git/worktrees/wt\n", to: "\(root)/wt/.git")
        try write("ref: refs/heads/rel\n", to: "\(root)/main/.git/worktrees/wt/HEAD")
        #expect(GitBranch().branch(cwd: "\(root)/wt") == "rel")
    }

    @Test func noRepository() throws {
        #expect(GitBranch().branch(cwd: "") == nil)
        #expect(GitBranch().branch(cwd: "/nonexistent/path") == nil)
    }

    @Test func checkoutIsNoticed() throws {
        let repo = try scratch()
        let head = "\(repo)/.git/HEAD"
        try write("ref: refs/heads/one\n", to: head)
        let git = GitBranch()
        #expect(git.branch(cwd: repo) == "one")
        try write("ref: refs/heads/two\n", to: head)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(10)], ofItemAtPath: head)
        #expect(git.branch(cwd: repo) == "two")
    }
}
