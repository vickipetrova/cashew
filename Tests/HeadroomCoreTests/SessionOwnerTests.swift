import Foundation
import Testing

@testable import HeadroomShared

@Suite struct SessionOwnerTests {
    private func find(_ start: Int32, names: [Int32: String], parents: [Int32: Int32]) -> Int32? {
        SessionOwner.find(start: start, parent: { parents[$0] }, name: { names[$0] })
    }

    /// Verified on Claude Code 2.1.273: a bare hook command's parent is Claude Code itself, whose
    /// executable is named after its version.
    @Test func directParentIsTheOwner() {
        #expect(find(90, names: [90: "2.1.273", 80: "zsh"], parents: [90: 80]) == 90)
    }

    @Test func npmInstallRunsUnderNode() {
        #expect(find(90, names: [90: "node"], parents: [:]) == 90)
    }

    /// A wrapped command (`PATH=… cmd`, `a && b`) interposes a shell that exits with the hook.
    @Test func shellsAreSkipped() {
        #expect(find(100, names: [100: "sh", 90: "2.1.273"], parents: [100: 90]) == 90)
    }

    @Test func onlyShellsMeansNoOwner() {
        #expect(find(100, names: [100: "sh", 90: "zsh", 80: "bash"], parents: [100: 90, 90: 80]) == nil)
    }

    @Test func depthIsBounded() {
        var names: [Int32: String] = [:]
        var parents: [Int32: Int32] = [:]
        for pid in Int32(10)...Int32(30) { names[pid] = "sh"; parents[pid] = pid - 1 }
        names[9] = "2.1.273"
        #expect(find(30, names: names, parents: parents) == nil)
    }

    @Test func unknownProcessOrLaunchdIsNoOwner() {
        #expect(find(90, names: [:], parents: [:]) == nil)
        #expect(find(1, names: [1: "launchd"], parents: [:]) == nil)
    }

    @Test func payloadParsing() {
        #expect(HookInput.payload(from: Data(#"{"session_id": "a"}"#.utf8))["session_id"] as? String == "a")
        #expect(HookInput.payload(from: Data("not json".utf8)).isEmpty)
        #expect(HookInput.payload(from: Data("[1, 2]".utf8)).isEmpty)
        #expect(HookInput.payload(from: Data(count: HookInput.maxBytes + 1)).isEmpty)
    }

    /// The real lookups, against this test process — no fixtures, just "does the syscall work".
    @Test func realLookupsWork() {
        #expect(SessionOwner.parentPID(of: getpid()) == getppid())
        #expect(SessionOwner.executableName(of: getpid()) != nil)
    }
}
