import Foundation

/// Which process owns this session, for the app's liveness check.
///
/// The helper's parent is Claude Code when the hook command runs it directly or `exec`s it — verified
/// on 2.1.273 for a direct command, stable across events in one session; `exec` replaces the shell,
/// so the parent is the same. Matching Claude Code by *name* does not work: a
/// native install's executable is `~/.local/share/claude/versions/<version>`, and an npm install
/// runs as `node`. What can be recognised reliably is a shell, which is the one thing that should
/// never be taken as the owner — it exits with the hook, and every session would look dead a second
/// later.
public enum SessionOwner {
    public static let shells: Set<String> = ["sh", "bash", "zsh", "dash", "fish", "ksh", "tcsh", "csh"]

    /// The first non-shell at or above `start`, or nil. Nil makes the app fall back to an age limit.
    public static func find(start: Int32, parent: (Int32) -> Int32?, name: (Int32) -> String?,
                            maxDepth: Int = 5) -> Int32? {
        var pid = start
        for _ in 0..<maxDepth {
            guard pid > 1, let executable = name(pid) else { return nil }
            if !shells.contains(executable) { return pid }
            guard let next = parent(pid) else { return nil }
            pid = next
        }
        return nil
    }

    public static func parentPID(of pid: Int32) -> Int32? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }

    public static func executableName(of pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return URL(fileURLWithPath: String(cString: buffer)).lastPathComponent
    }
}

/// The hook's stdin.
public enum HookInput {
    /// Hook payloads are a few hundred bytes. Anything this big is not one.
    public static let maxBytes = 1_000_000

    public static func payload(from data: Data) -> [String: Any] {
        guard data.count <= maxBytes,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return object
    }
}
