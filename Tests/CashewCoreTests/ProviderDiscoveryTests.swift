import Foundation
import Testing
@testable import CashewCore

/// Discovery's one rule: it never probes credentials on the thread that asked.
///
/// The rule is here rather than in `AppDelegate` because `AppDelegate` cannot be constructed in a
/// test — CI greps for it — and that is precisely how this shipped green. A credential probe on the
/// main thread takes the same legacy Keychain item lock as the decrypting read in
/// `ClaudeProvider.fetch`, which holds it across a securityd round trip that waits on a modal
/// permission prompt. With one provider the main thread reached the probe microseconds after
/// dispatching the decrypt and won the race; adding a second provider put a few milliseconds of its
/// own work in between and the main thread started losing it, blocking inside
/// `applicationDidFinishLaunching`. AppKit never finished launching, the status item was never
/// placed, and the accessibility API reported zero menu bars for an app that is nothing but a menu
/// bar.
@Suite struct ProviderDiscoveryTests {
    /// A provider that reports where it was asked, and reaches no Keychain, no file and no network.
    private struct SpyProvider: UsageProvider {
        static let host = "example.invalid"

        let id: ProviderID
        let present: Bool
        let onProbe: (Thread) -> Void

        func credentialsExist() -> Bool {
            onProbe(Thread.current)
            return present
        }

        func fetch(completion: @escaping (Result<[LimitWindow], Error>) -> Void) {
            completion(.failure(UsageError.noCredentials))
        }
    }

    /// Collects the probe threads under a lock, because the whole point is that they are not ours.
    private final class ProbeLog {
        private let lock = NSLock()
        private var threads: [Thread] = []

        func record(_ thread: Thread) {
            lock.lock()
            defer { lock.unlock() }
            threads.append(thread)
        }

        var recorded: [Thread] {
            lock.lock()
            defer { lock.unlock() }
            return threads
        }
    }

    /// `answering: nil` hands the result back inline on the probe queue, so nothing here depends on
    /// the main queue being serviced — a test process has no `NSApplication` draining it.
    private func discovery() -> ProviderDiscovery {
        ProviderDiscovery(queue: DispatchQueue(label: "cashew.tests.discovery"), answering: nil)
    }

    private func probe(_ providers: [UsageProvider], with discovery: ProviderDiscovery)
        -> Set<ProviderID> {
        let done = DispatchSemaphore(value: 0)
        var active: Set<ProviderID> = []
        discovery.probe(providers) { result in
            active = result
            done.signal()
        }
        // Generous, because a hang here is the bug: an implementation that answered synchronously
        // would never reach the wait at all, and one that deadlocked should fail rather than stall
        // the suite.
        #expect(done.wait(timeout: .now() + 5) == .success)
        return active
    }

    /// The regression, asserted where it can be: the probe runs somewhere other than the caller.
    @Test func theCredentialProbeNeverRunsOnTheCallingThread() {
        let caller = Thread.current
        let log = ProbeLog()
        let providers: [UsageProvider] = [
            SpyProvider(id: .claude, present: true, onProbe: log.record),
            SpyProvider(id: .codex, present: true, onProbe: log.record),
        ]

        _ = probe(providers, with: discovery())

        let threads = log.recorded
        #expect(threads.count == 2)
        for thread in threads {
            #expect(thread !== caller)
            #expect(!thread.isMainThread)
        }
    }

    /// The second half of the same rule: `probe` is asynchronous, so nothing it does can be on the
    /// caller's stack. A synchronous implementation would have run both providers before this line.
    @Test func theProbeHasNotRunByTheTimeProbeReturns() {
        let log = ProbeLog()
        let gate = DispatchSemaphore(value: 0)
        let providers: [UsageProvider] = [
            SpyProvider(id: .claude, present: true, onProbe: { thread in
                gate.wait()
                log.record(thread)
            }),
        ]

        discovery().probe(providers) { _ in }
        #expect(log.recorded.isEmpty)
        gate.signal()
    }

    @Test func onlyTheProvidersWithCredentialsComeBack() {
        let log = ProbeLog()
        let providers: [UsageProvider] = [
            SpyProvider(id: .claude, present: false, onProbe: log.record),
            SpyProvider(id: .codex, present: true, onProbe: log.record),
        ]

        #expect(probe(providers, with: discovery()) == [.codex])
    }

    /// The state `AppDelegate` sits in between launch and the first answer. It is not an error case
    /// — `PollPlan.providersToPoll` already treats an empty active set as "poll Claude anyway", which
    /// is why the first poll can wait for discovery instead of racing it.
    @Test func noProvidersYetIsAnEmptySetWhichPollPlanAlreadyHandles() {
        #expect(probe([], with: discovery()).isEmpty)
        #expect(PollPlan.providersToPoll(active: [], all: [.claude, .codex]) == [.claude])
    }
}
