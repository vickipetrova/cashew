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
        tickTimer = schedule(every: 60) { [weak self] in self?.menuController.tick() }

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
        pollTimer?.invalidate()
        pollTimer = schedule(every: Settings.refreshInterval) { [weak self] in self?.refresh() }
    }

    /// Bumped for every fetch, captured by that fetch's completion, and compared when it lands.
    ///
    /// Without it a slow poll can finish *after* a later one and overwrite fresh numbers with older
    /// ones — stamped `updatedAt: Date()`, so they'd claim to be current. Mashing Refresh Now stacks
    /// requests the same way.
    private var fetchGeneration = 0

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
                    self.history.record(windows)
                    // Kept whole as well as sampled, so the next cold start has rows to draw even if
                    // its first poll fails.
                    self.history.save(snapshot: windows)
                    self.menuController.update(windows: windows, updatedAt: Date())
                    Notifier.evaluate(windows)
                case .failure(let error):
                    self.menuController.update(error: error)
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
