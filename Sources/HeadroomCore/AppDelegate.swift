import AppKit

/// Wiring: a provider, a menu, and two timers.
///
/// The only public symbol in HeadroomCore. `Sources/Headroom/main.swift` holds nothing but the
/// top-level code that constructs this and starts the run loop — top-level code can't live in a
/// library target, and keeping everything else `internal` means the test target reaches it with
/// `@testable` instead of the module needing a public API.
public final class AppDelegate: NSObject, NSApplicationDelegate {
    // A synthesized initializer on a public class is internal, so this has to be spelled out for
    // `AppDelegate()` to compile from the executable target.
    public override init() { super.init() }

    private let provider: UsageProvider = ClaudeProvider()
    private let history = UsageHistory.default
    private let statusline = StatuslineFeed.default
    private lazy var menuController = MenuController(history: history)

    private var pollTimer: Timer?
    private var tickTimer: Timer?

    public func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)  // Menu bar only, no dock icon, no window.

        menuController.onRefresh = { [weak self] in self?.refresh() }
        menuController.onSettingsChanged = { [weak self] in self?.settingsChanged() }
        Notifier.requestAuthorizationIfNeeded()

        refresh()
        reschedulePoll()
        tickTimer = schedule(every: 60) { [weak self] in
            guard let self else { return }
            // The countdown tick is also where a live reading gets picked up: the statusline file is
            // rewritten every time Claude Code renders, which is far more often than the poll, so
            // this is what makes the numbers live rather than up to fifteen minutes stale.
            if !self.polled.isEmpty || self.statusline.read() != nil {
                self.publishMergingLiveReadings(at: Date())
            }
            self.menuController.tick()
        }

        // Timers are unreliable across sleep — the Mac can wake hours later with a window that
        // has already reset. Ask again the moment it wakes.
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(didWake),
            name: NSWorkspace.didWakeNotification, object: nil)
    }

    @objc private func didWake() { refresh() }

    /// Any preference change re-polls: a shorter interval should feel immediate, and a lowered
    /// alert threshold should be evaluated against current usage rather than at the next tick.
    private func settingsChanged() {
        Notifier.requestAuthorizationIfNeeded()
        reschedulePoll()
        refresh()
    }

    private func reschedulePoll() {
        rateLimitStreak = 0
        pollTimer?.invalidate()
        pollTimer = schedule(every: Settings.refreshInterval) { [weak self] in self?.refresh() }
    }

    /// Consecutive rate-limited replies. Reset by any success, and by any settings change, since that
    /// is the user explicitly asking for a different cadence.
    private var rateLimitStreak = 0

    /// Replace the repeating poll with a single delayed one after being told to slow down.
    ///
    /// This is the fix for a fifteen-day outage: the app was rate-limited, kept asking every five
    /// minutes regardless, and had no way back except being noticed and restarted. `Retry-After` was
    /// parsed by nobody and discarded with the rest of the response.
    ///
    /// One-shot rather than repeating, so each further refusal gets its own longer wait and the first
    /// success restores the normal interval through `reschedulePoll`.
    private func backOff(retryAfter: TimeInterval?) {
        rateLimitStreak += 1
        let delay = Backoff.delay(attempt: rateLimitStreak, retryAfter: retryAfter,
                                  base: Settings.refreshInterval)
        pollTimer?.invalidate()
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    /// Bumped for every fetch, captured by that fetch's completion, and compared when it lands.
    ///
    /// Without it a slow poll can finish *after* a later one and overwrite fresh numbers with older
    /// ones — stamped `updatedAt: Date()`, so they'd claim to be current. Mashing Refresh Now stacks
    /// requests the same way.
    private var fetchGeneration = 0

    /// The last full reading from the API, before any live overlay.
    ///
    /// Kept apart from what's on screen because the two sources report different things: the API is
    /// the only one that knows about per-model limits, so its answer has to survive being partly
    /// overwritten by a fresher one.
    private var polled: [LimitWindow] = []

    /// Overlay whatever Claude Code currently reports onto the last poll, and publish the result.
    ///
    /// The statusline is a *supplement*, not a replacement. Using it alone was tried and was worse
    /// than either source on its own: its payload has no per-model limits, so a `WEEKLY · FABLE` row
    /// blinked in and out depending on whether a Claude Code session happened to be open.
    private func publishMergingLiveReadings(at updatedAt: Date) {
        let merged = SourceMerge.merge(polled: polled, live: statusline.read() ?? [])
        guard !merged.isEmpty else { return }
        history.record(merged, at: updatedAt)
        history.save(snapshot: merged, at: updatedAt)
        menuController.update(windows: merged, updatedAt: updatedAt)
        Notifier.evaluate(merged)
    }

    private func refresh() {
        fetchGeneration += 1
        let generation = fetchGeneration
        provider.fetch { [weak self] result in
            DispatchQueue.main.async {
                guard let self, generation == self.fetchGeneration else { return }
                switch result {
                case .success(let windows):
                    // Recorded before the menu renders, so the row being built can already see this
                    // poll's sample. Only on success: a failed poll leaves the last good numbers on
                    // screen, and re-recording them would invent a flat stretch that never happened
                    // and drag every rate towards idle.
                    //
                    // Published through the merge so a poll can't undo a fresher statusline reading
                    // — the API answer can be up to fifteen minutes older than what Claude Code
                    // reported thirty seconds ago.
                    self.polled = windows
                    self.publishMergingLiveReadings(at: Date())
                    // Back to the normal cadence. Only a success clears a backoff — a manual Refresh
                    // Now that also gets refused must not reset the streak, or mashing it defeats the
                    // whole mechanism.
                    if self.rateLimitStreak > 0 { self.reschedulePoll() }
                case .failure(let error):
                    self.menuController.update(error: error)
                    if case UsageError.rateLimited(let retryAfter) = error {
                        self.backOff(retryAfter: retryAfter)
                    }
                }
            }
        }
    }

    /// `.common` mode matters: a timer in the default mode stops firing while a menu is open,
    /// which is exactly when the countdown refresh needs to run.
    private func schedule(every interval: TimeInterval, _ block: @escaping () -> Void) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: true) { _ in block() }
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }
}
