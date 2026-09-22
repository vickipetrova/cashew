import Foundation

/// Which providers have credentials — answered off the main thread, always.
///
/// This type exists because of a deadlock, not for tidiness. `ClaudeProvider.credentialsExist()`
/// reaches `SecItemCopyMatching`, and so does the decrypting read in `ClaudeProvider.fetch`. Both
/// resolve to the *same* legacy `SecKeychain` item, and legacy Keychain calls serialize on that
/// item's own lock — so a presence probe waits behind whatever the decrypting read is doing. The
/// decrypting read is waiting on securityd, which is waiting on the modal ACL permission prompt
/// Claude Code's Keychain item raises for anything that is not Claude Code, and that wait has no
/// upper bound.
///
/// Running the decrypt on a background queue — which Cashew already did, and documents — is only
/// half the rule. The probe has to be off the main thread too, or the main thread simply blocks on
/// the item lock instead of on the prompt. It blocked inside `applicationDidFinishLaunching`, which
/// therefore never returned: AppKit never finished launching, the status item was never placed, and
/// an `LSUIElement` app whose entire UI is a status item had no UI at all. The accessibility API
/// reported zero menu bars for a process that was otherwise alive, unpanicked, and mid-poll.
///
/// The rule is one line and the whole point of the type: **nothing here may run on the main
/// thread.** `AppDelegate` cannot be built in a test, so a rule that lived there would be a rule
/// with no coverage — the same reason `PollPlan` and `TitleSelection` were lifted out.
final class ProviderDiscovery {
    /// Serial, and shared by every probe: two concurrent probes would contend for the same Keychain
    /// item lock, which is exactly the contention this type exists to keep away from anything that
    /// matters. Waiting here costs nothing — nobody is looking at this thread.
    private let queue: DispatchQueue

    /// Where the answer is handed back. `.main` in production, because everything that reads it is
    /// main-thread state. Nil delivers inline on `queue`, which is what a test uses so it never has
    /// to depend on the main queue being serviced.
    private let answering: DispatchQueue?

    init(queue: DispatchQueue = DispatchQueue(label: "com.vickipetrova.cashew.discovery"),
         answering: DispatchQueue? = .main) {
        self.queue = queue
        self.answering = answering
    }

    /// Ask every provider whether it has credentials, and report which ones said yes.
    ///
    /// Asynchronous rather than returning a value, and that is the fix rather than a style choice:
    /// a synchronous answer is a Keychain call on the caller's thread, and the only caller is the
    /// main thread. A caller that needs the answer before it can act passes a continuation.
    func probe(_ providers: [UsageProvider], completion: @escaping (Set<ProviderID>) -> Void) {
        queue.async {
            let active = Set(providers.filter { $0.credentialsExist() }.map(\.id))
            guard let answering = self.answering else { return completion(active) }
            answering.async { completion(active) }
        }
    }
}
