import Foundation

/// The branch a session is on, from `.git/HEAD` directly — no `git` process per poll.
///
/// Main thread only.
final class GitBranch {
    static let shared = GitBranch()

    private var cache: [String: (head: String, modified: Date?, branch: String?)] = [:]

    func branch(cwd: String) -> String? {
        guard !cwd.isEmpty, let head = Self.headPath(from: cwd) else { return nil }
        // Keyed on HEAD's mtime: git rewrites the file on checkout, so a switch is picked up.
        let modified = (try? FileManager.default.attributesOfItem(atPath: head))?[.modificationDate] as? Date
        if let hit = cache[cwd], hit.head == head, hit.modified == modified { return hit.branch }
        let branch = (try? String(contentsOfFile: head, encoding: .utf8)).flatMap(Self.branch(fromHead:))
        cache[cwd] = (head, modified, branch)
        return branch
    }

    /// Walks up to the nearest `.git`. A directory holds `HEAD`; a file (a worktree or submodule)
    /// names the real git directory with `gitdir:`, absolute or relative.
    static func headPath(from directory: String) -> String? {
        let fileManager = FileManager.default
        var current = (directory as NSString).standardizingPath
        for _ in 0..<64 {
            let dotGit = (current as NSString).appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: dotGit, isDirectory: &isDirectory) {
                if isDirectory.boolValue { return (dotGit as NSString).appendingPathComponent("HEAD") }
                guard let text = try? String(contentsOfFile: dotGit, encoding: .utf8),
                      let line = text.split(whereSeparator: \.isNewline).first,
                      line.hasPrefix("gitdir:") else { return nil }
                let raw = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
                let gitDirectory = raw.hasPrefix("/") ? raw : (current as NSString).appendingPathComponent(raw)
                return ((gitDirectory as NSString).standardizingPath as NSString).appendingPathComponent("HEAD")
            }
            guard current != "/" else { return nil }
            current = (current as NSString).deletingLastPathComponent
        }
        return nil
    }

    /// `ref: refs/heads/<name>` → name; a detached SHA → its first 7 characters.
    static func branch(fromHead text: String) -> String? {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "ref: refs/heads/"
        if line.hasPrefix(prefix) {
            let name = line.dropFirst(prefix.count)
            return name.isEmpty ? nil : String(name.prefix(64))
        }
        if line.count >= 7, line.allSatisfy(\.isHexDigit) { return String(line.prefix(7)) }
        return nil
    }
}
