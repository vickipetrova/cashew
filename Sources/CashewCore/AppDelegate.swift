import AppKit
import CashewShared

/// Wiring: a provider, a menu, and two timers.
///
/// The only public symbol in CashewCore. `Sources/Cashew/main.swift` holds nothing but the
/// top-level code that constructs this and starts the run loop — top-level code can't live in a
/// library target, and keeping everything else `internal` means the test target reaches it with
/// `@testable` instead of the module needing a public API.
public final class AppDelegate: NSObject, NSApplicationDelegate {
    // A synthesized initializer on a public class is internal, so this has to be spelled out for
    // `AppDelegate()` to compile from the executable target.
    public override init() { super.init() }

    private let providers: [UsageProvider] = [ClaudeProvider(), CodexProvider()]
    private let history = UsageHistory.default
    private let statusline = StatuslineFeed.default
    private lazy var menuController = MenuController(history: history, statusline: statusline)
    private let sessionActivity = SessionActivity.default
    private let hookInstaller = HookInstaller.default
    private var sessionWatcher: DirectoryWatcher?
    /// Runs only while a session is working or waiting. Drives the spinning spark and, once a
    /// second, a re-read — elapsed times in an open menu, and interrupts, which write no hook.
    private var animationTimer: Timer?
    private var animationTicks = 0
    private var updateTimer: Timer?

    private var tickTimer: Timer?

    public func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)  // Menu bar only, no dock icon, no window.

        menuController.onRefresh = { [weak self] in self?.refresh() }
        menuController.onSettingsChanged = { [weak self] in self?.settingsChanged() }
        menuController.onTrackSessionsChanged = { [weak self] in self?.startSessionTracking() }
        menuController.onCheckForUpdatesChanged = { [weak self] in self?.startUpdateChecks() }
        Notifier.requestAuthorizationIfNeeded()

        restoreLastGoodReading()
        pushDetectedProviders()
        refresh()
        reschedulePoll()
        startSessionTracking()
        startUpdateChecks()
        tickTimer = schedule(every: 60) { [weak self] in
            guard let self else { return }
            // The countdown tick is also where a live reading gets picked up: the statusline file is
            // rewritten every time Claude Code renders, which is far more often than the poll, so
            // this is what makes the numbers live rather than up to fifteen minutes stale.
            if !self.snapshots.isEmpty || self.statusline.read() != nil {
                self.publish(at: Date())
            }
            // Catches a killed terminal even when nothing is writing session files.
            self.refreshSessions()
            self.menuController.tick()
        }

        // Timers are unreliable across sleep — the Mac can wake hours later with a window that
        // has already reset. Ask again the moment it wakes.
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(didWake),
            name: NSWorkspace.didWakeNotification, object: nil)
    }

    @objc private func didWake() {
        refresh()
        refreshSessions()
        checkForUpdatesIfDue()
    }

    /// Any preference change re-polls: a shorter interval should feel immediate, and a lowered
    /// alert threshold should be evaluated against current usage rather than at the next tick.
    private func settingsChanged() {
        Notifier.requestAuthorizationIfNeeded()
        pushDetectedProviders()
        reschedulePoll()
        refresh()
    }

    /// Put every provider back on the normal cadence. For the two callers that legitimately mean
    /// "everyone" — launch, and a settings change the user made on purpose — not for a single
    /// provider's own recovery; see the scoped overload below for that.
    private func reschedulePoll() {
        rateLimitStreak.removeAll()
        let toPoll = providersToPoll()
        let ids = Set(toPoll.map(\.id))
        // A provider that lost its credentials (or was never active) keeps no timer running.
        for (id, timer) in pollTimers where !ids.contains(id) {
            timer.invalidate()
            pollTimers[id] = nil
        }
        for provider in toPoll {
            pollTimers[provider.id]?.invalidate()
            pollTimers[provider.id] = schedule(every: Settings.refreshInterval) { [weak self] in
                self?.refresh(provider)
            }
        }
    }

    /// Put one provider back on the normal cadence. Scoped deliberately: clearing every streak
    /// here would let one provider's recovery cancel another's backoff timer and restore full
    /// cadence against a server still refusing it.
    private func reschedulePoll(_ id: ProviderID) {
        rateLimitStreak[id] = nil
        pollTimers[id]?.invalidate()
        pollTimers[id] = schedule(every: Settings.refreshInterval) { [weak self] in
            self?.refresh(id)
        }
    }

    /// The providers worth polling right now, by the pure rule in `PollPlan`.
    private func providersToPoll() -> [UsageProvider] {
        let activeIDs = activeProviders.map(\.id)
        let allIDs = providers.map(\.id)
        let ids = PollPlan.providersToPoll(active: activeIDs, all: allIDs,
                                           hidden: Settings.hiddenProviders)
        return ids.compactMap { id in providers.first(where: { $0.id == id }) }
    }

    /// Tells the menu which providers are worth a Settings switch — credential presence alone,
    /// never filtered by `hiddenProviders`. Hiding a provider stops it being polled, which would
    /// otherwise make it vanish from `providersToPoll()`'s output; if the Settings list were built
    /// from that instead of this, the switch that turns a hidden provider back on would disappear
    /// along with it. Pushed wherever discovery could have changed, not on every poll — it costs a
    /// credentials check per provider (a file read for Codex, a non-decrypting Keychain probe for
    /// Claude), and nothing here needs it done more often than that.
    private func pushDetectedProviders() {
        menuController.update(detected: PollPlan.detectedProviders(active: activeProviders.map(\.id)))
    }

    /// Consecutive rate-limited replies, **per provider**. Reset by that provider's next success,
    /// and by any settings change, since that is the user explicitly asking for a different cadence.
    private var rateLimitStreak: [ProviderID: Int] = [:]

    /// One poll timer per provider, so a provider being told to slow down cannot slow the others.
    private var pollTimers: [ProviderID: Timer] = [:]

    /// Bumped for every fetch and compared when it lands, **per provider**.
    ///
    /// Per provider and not global, which is the whole point: a single counter meant any provider's
    /// fetch invalidated every other provider's in-flight reply, so a second provider would silently
    /// drop the first one's results. Within one provider it still does its original job — stopping a
    /// slow poll from overwriting fresher numbers stamped `updatedAt: Date()`.
    private var fetchGeneration: [ProviderID: Int] = [:]

    /// The last full reading from each provider, before any live overlay.
    private var snapshots: [ProviderID: ProviderSnapshot] = [:]

    /// Start from the last good reading on disk rather than from nothing.
    ///
    /// A launch whose first poll fails — an expired token, no network, a 429, or no credentials at
    /// all — otherwise shows an error over an empty panel, even though the numbers from an hour ago
    /// were both known and still roughly true. That is the entire case the saved reading exists for.
    ///
    /// It is seeded **here and nowhere else**, and that is the fix rather than a tidy-up.
    /// `MenuController` used to restore it for itself, which looked equivalent and was not: the
    /// failure path rebuilds a provider's state from `snapshots[id]`, so a seed the delegate did not
    /// have became `existing.failed(error)` over empty windows, and `update(snapshots:)` — a
    /// wholesale replacement — then wiped the very rows the controller had restored. The menu bar
    /// fell to "!" and the dropdown showed the error alone, on exactly the launch the restore is
    /// for. One seed, in the one place both the panel and the failure path read from.
    ///
    /// Attributed to Claude because the saved reading is a flat `[LimitWindow]` carrying no provider
    /// — all a one-provider app ever wrote.
    ///
    /// Published straight away so the panel has rows before the first poll lands. `restored: true`
    /// is what stops that publish being mistaken for one — see `ProviderSnapshot.observed(live:)` —
    /// and `publish` re-stamps `updatedAt` only when a live overlay is merged in, so with no live
    /// feed the dropdown goes on saying "Showing data from" the hour it was really read.
    private func restoreLastGoodReading() {
        guard let restored = history.restorableSnapshot() else { return }
        snapshots[.claude] = ProviderSnapshot(provider: .claude, windows: restored.windows,
                                              updatedAt: restored.at, failure: nil, restored: true)
        publish(at: Date())
    }

    /// Replace one provider's repeating poll with a single delayed one after being told to slow down.
    ///
    /// This is the fix for a fifteen-day outage: the app was rate-limited, kept asking every five
    /// minutes regardless, and had no way back except being noticed and restarted.
    ///
    /// Scoped to the provider that was refused. A shared timer would mean Codex being throttled also
    /// throttling Claude, which is the original bug wearing a different hat.
    private func backOff(_ provider: ProviderID, retryAfter: TimeInterval?) {
        let streak = (rateLimitStreak[provider] ?? 0) + 1
        rateLimitStreak[provider] = streak
        let delay = Backoff.delay(attempt: streak, retryAfter: retryAfter,
                                  base: Settings.refreshInterval)
        pollTimers[provider]?.invalidate()
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            self?.refresh(provider)
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimers[provider] = timer
    }

    /// Only providers the user actually has. A provider with no credentials is not polled, does not
    /// appear, and costs no network — see the discovery rule in the design.
    private var activeProviders: [UsageProvider] {
        providers.filter { $0.credentialsExist() }
    }

    private func refresh(_ id: ProviderID) {
        guard let provider = providers.first(where: { $0.id == id }) else { return }
        refresh(provider)
    }

    /// Poll every active provider. Called at launch, on wake, and from Refresh Now.
    private func refresh() {
        for provider in providersToPoll() { refresh(provider) }
    }

    /// Assemble every provider's snapshot and publish them.
    ///
    /// The statusline overlay is applied to **Claude's** snapshot and nothing else. `StatuslineFeed`
    /// reads what Claude Code hands its own statusline; it is Claude's live feed, not the app's, and
    /// merging it into a combined list could overwrite another provider's window that happens to
    /// share an unqualified id.
    ///
    /// - Parameter recording: The caller's own statement that this publish carries a reading worth
    ///   keeping, not a guess inferred from a provider's (possibly latched) failure state. A failed
    ///   poll passes `false`: it must not record or save, because that would invent a flat stretch
    ///   that never happened and drag every burn rate toward idle. Everything else — a real success,
    ///   and the 60-second tick's re-merge of the live statusline onto the last good reading — must
    ///   keep recording on the default, or the live feed stops reaching the forecast and the
    ///   threshold alerts for as long as a failure lasts, which is exactly the silent-alert bug
    ///   `Notifier` exists to prevent.
    private func publish(at updatedAt: Date, recording: Bool = true) {
        var assembled: [ProviderSnapshot] = []
        var observed: [LimitWindow] = []
        for provider in providers {
            guard var snapshot = snapshots[provider.id] else { continue }
            var live: [LimitWindow] = []
            if provider.id == .claude, let reading = statusline.read(), !reading.isEmpty {
                live = reading
                let merged = SourceMerge.merge(polled: snapshot.windows, live: live)
                snapshot = ProviderSnapshot(provider: .claude, windows: merged,
                                            updatedAt: updatedAt, failure: snapshot.failure,
                                            restored: snapshot.restored)
            }
            guard !snapshot.windows.isEmpty || snapshot.failure != nil else { continue }
            // `observed`, not `windows`: a restored snapshot's own rows came off disk with their
            // samples already recorded, and re-recording them once a minute would invent a flat
            // stretch that never happened. What the live overlay just contributed is new, and still
            // counts.
            let fresh = snapshot.observed(live: live)
            if recording, !fresh.isEmpty {
                history.record(fresh, provider: snapshot.provider, at: updatedAt)
                Notifier.evaluate(fresh, provider: snapshot.provider)
            }
            observed.append(contentsOf: fresh)
            assembled.append(snapshot)
        }
        guard !assembled.isEmpty else { return }
        // Nothing observed, nothing to save. Writing here regardless would overwrite the last good
        // reading with whatever is on screen — an empty list while a provider is failing, which
        // destroys the file this launch was restored from, or the restored rows themselves re-dated
        // to now, which keeps a stale reading alive past the age bound that is supposed to retire it.
        if recording, !observed.isEmpty {
            history.save(snapshot: observed, at: updatedAt)
        }
        menuController.update(snapshots: assembled)
    }

    private func refresh(_ provider: UsageProvider) {
        let id = provider.id
        let generation = (fetchGeneration[id] ?? 0) + 1
        fetchGeneration[id] = generation
        provider.fetch { [weak self] result in
            DispatchQueue.main.async {
                guard let self, generation == self.fetchGeneration[id] else { return }
                let existing = self.snapshots[id]
                    ?? ProviderSnapshot(provider: id, windows: [], updatedAt: nil, failure: nil)
                switch result {
                case .success(let windows):
                    // Recorded before the menu renders, so the row being built can already see this
                    // poll's sample. Only on success: a failed poll leaves the last good numbers on
                    // screen, and re-recording them would invent a flat stretch that never happened.
                    self.snapshots[id] = existing.succeeded(windows: windows, at: Date())
                    self.publish(at: Date())
                    // Back to the normal cadence, for this provider only. A manual Refresh Now that
                    // is also refused must not reset the streak, or mashing it defeats the mechanism.
                    // Scoped: the all-providers `reschedulePoll()` would cancel another provider's
                    // own backoff timer and put it back on full cadence against a server still
                    // refusing it.
                    if (self.rateLimitStreak[id] ?? 0) > 0 { self.reschedulePoll(id) }
                case .failure(let error):
                    self.snapshots[id] = existing.failed(error)
                    self.publish(at: Date(), recording: false)
                    if case UsageError.rateLimited(let retryAfter) = error {
                        self.backOff(id, retryAfter: retryAfter)
                    }
                }
            }
        }
    }

    // MARK: - Claude Code sessions

    /// Installs or removes hooks to match the setting, and starts or stops watching for sessions.
    /// Runs at every launch, which is also what repairs the hook path after the app has moved.
    private func startSessionTracking() {
        menuController.hookOutcome = hookInstaller.apply(enabled: Settings.trackSessions)
        if Settings.trackSessions {
            if sessionWatcher == nil {
                sessionWatcher = DirectoryWatcher(directory: sessionActivity.directory) { [weak self] in
                    self?.refreshSessions()
                }
            }
        } else {
            sessionWatcher = nil
        }
        refreshSessions()
    }

    private func refreshSessions() {
        let sessions = Settings.trackSessions ? sessionActivity.sessions() : []
        // Also re-renders the title, so when the timer stops below the spark is already drawn at rest.
        menuController.update(sessions: sessions)
        // The fast timer is for the spinning spark, so only a working session runs it. A session
        // waiting on permission draws a still dot and is picked up by the directory watcher and the
        // 60-second tick like an idle one — no reason to wake four times a second for it.
        let working = sessions.contains { $0.state == .thinking || $0.state == .tool }
        if working, animationTimer == nil {
            animationTimer = schedule(every: MenuBarAnimation.tickInterval) { [weak self] in
                self?.animationTick()
            }
        } else if !working, let timer = animationTimer {
            timer.invalidate()
            animationTimer = nil
        }
    }

    private func animationTick() {
        menuController.advanceAnimation()
        animationTicks += 1
        // Once a second, not every frame: re-reading the session files, their transcripts and
        // their branches twelve times a second would be wasteful, and nothing in them moves that
        // fast. The frames in between only redraw one small image.
        if animationTicks % MenuBarAnimation.framesPerSecond == 0 { refreshSessions() }
    }

    // MARK: - Update checks

    private func startUpdateChecks() {
        updateTimer?.invalidate()
        updateTimer = nil
        menuController.update(release: Settings.checkForUpdates
            ? UpdateCheck.pending(known: Settings.knownRelease, currentVersion: Self.appVersion) : nil)
        guard Settings.checkForUpdates else { return }
        let first = Timer(timeInterval: UpdateCheck.launchDelay, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.checkForUpdatesIfDue()
            // Hourly *look*; `isDue` keeps the actual request to once a day.
            self.updateTimer = self.schedule(every: 3600) { [weak self] in self?.checkForUpdatesIfDue() }
        }
        RunLoop.main.add(first, forMode: .common)
        updateTimer = first
    }

    private func checkForUpdatesIfDue() {
        guard Settings.checkForUpdates,
              UpdateCheck.isDue(lastAttempt: Settings.lastUpdateCheck, now: Date()) else { return }
        Settings.lastUpdateCheck = Date()
        UpdateCheck.fetch(currentVersion: Self.appVersion) { [weak self] release in
            DispatchQueue.main.async {
                guard let self, Settings.checkForUpdates else { return }
                if let release { Settings.knownRelease = release }
                self.menuController.update(release: UpdateCheck.pending(
                    known: Settings.knownRelease, currentVersion: Self.appVersion))
            }
        }
    }

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// `.common` mode matters: a timer in the default mode stops firing while a menu is open,
    /// which is exactly when the countdown refresh needs to run.
    private func schedule(every interval: TimeInterval, _ block: @escaping () -> Void) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: true) { _ in block() }
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }
}
