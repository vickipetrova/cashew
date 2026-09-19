import Foundation
import CashewShared

// Claude Code runs this on every prompt and every tool call, so three rules hold everywhere below:
// it is fast, it prints nothing, and it exits 0 whatever happens — a hook that fails or talks can
// disturb the session it is observing.
//
// Privacy: only the tool *name*, cwd and transcript path are kept. Prompt text, tool input and tool
// output are in the payload and are never written anywhere.

guard CommandLine.arguments.count > 1,
      let event = HookEvent(rawValue: CommandLine.arguments[1]) else { exit(0) }

/// Read on a separate thread so a stdin that never closes can't hold up the session.
final class Collected: @unchecked Sendable { var data = Data() }
let collected = Collected()
let finished = DispatchSemaphore(value: 0)
Thread.detachNewThread {
    var data = Data()
    while data.count <= HookInput.maxBytes {
        let chunk = FileHandle.standardInput.availableData
        if chunk.isEmpty { break }
        data.append(chunk)
    }
    collected.data = data
    finished.signal()
}
// Only read `collected` after the signal: on timeout the reader may still be writing to it.
let payload = finished.wait(timeout: .now() + 2) == .success ? HookInput.payload(from: collected.data) : [:]

guard let url = SessionFiles.url(for: payload["session_id"] as? String ?? "",
                                 in: SessionFiles.defaultDirectory) else { exit(0) }

let owner = SessionOwner.find(start: getppid(),
                              parent: SessionOwner.parentPID(of:),
                              name: SessionOwner.executableName(of:))

switch event.outcome(payload: payload, previous: SessionFiles.read(url), pid: owner, now: Date()) {
case .write(let record): try? SessionFiles.write(record, to: url)
case .delete: try? FileManager.default.removeItem(at: url)
case .ignore: break
}
exit(0)
