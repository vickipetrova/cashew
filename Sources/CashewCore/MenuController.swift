import AppKit
import CashewShared

/// Which limits the menu bar title shows, given what the response reported and what the user picked.
///
/// Pure and separate from `MenuController` so the rules are testable — the controller can't be
/// constructed in a test, and these are exactly the cases that are awkward to reach by hand: a
/// scope that disappears from the response, or every chosen scope disappearing at once.
enum TitleSelection {
    /// Which limits the menu bar title shows, given what each provider reported and what the user
    /// picked. Sections rather than a flat list, because the stored selection is qualified by
    /// provider and a bare `LimitWindow` does not know which provider it came from.
    static func windows(from sections: [(provider: ProviderID, windows: [LimitWindow])],
                        selection: Set<String>)
        -> [(provider: ProviderID, window: LimitWindow)] {
        // Choosing nothing is a real choice, and it has to be told apart from choosing something
        // that has since gone missing — the fallback below must not fire for it, or unchecking the
        // last limit would silently put a number back.
        guard !selection.isEmpty else { return [] }
        // Order comes from the response within a section, and from section order across them.
        let shown = sections.flatMap { section in
            section.windows
                .filter { selection.contains(section.provider.qualify($0.id)) }
                .map { (provider: section.provider, window: $0) }
        }
        guard shown.isEmpty else { return shown }
        // Everything chosen has gone missing. Global, not per-section: a per-section fallback would
        // put an unselected provider's window in the title purely because that provider happened to
        // report something.
        let all = sections.flatMap { s in s.windows.map { (provider: s.provider, window: $0) } }
        return all.first { $0.window.kind == .primary }.map { [$0] } ?? Array(all.prefix(1))
    }
}

/// Whether the menu bar needs to say which provider a percentage belongs to.
///
/// Pure and separate for the same reason `TitleSelection` is: `MenuController` cannot be built in a
/// test, and a rule that lives there is a rule with no coverage.
enum TitleGlyphs {
    static func needed(for providers: [ProviderID]) -> Bool {
        Set(providers).count > 1
    }
}

/// What the menu bar title shows when there is nothing to display: an error glyph, a plain dash for
/// a clean account with no quota to report, or a loading ellipsis.
///
/// Pure and separate for the same reason `TitleGlyphs` and `TitleSelection` are — `MenuController`
/// cannot be built in a test, and this was the fourth place in this feature that read raw snapshots
/// without excluding a hidden provider first: a hidden provider's own failed poll must not be what
/// puts an error glyph in the menu bar for a product the user switched off.
enum TitleFallback {
    /// `hidden` has no production caller — `MenuController` always passes `unhiddenSnapshots`,
    /// already filtered, so filtering again here would do it twice. The parameter stays, defaulted
    /// to empty, as the seam this rule is asserted through; see the same note on
    /// `PanelSections.visible`'s own `hidden` parameter.
    static func chip(for snapshots: [ProviderSnapshot], hidden: Set<ProviderID> = []) -> String {
        let considered = snapshots.filter { !hidden.contains($0.provider) }
        if considered.contains(where: { $0.failure != nil }) { return "!" }
        // A clean fetch that reported nothing isn't an error and isn't still loading —
        // API-key accounts have no plan quota to report.
        if considered.contains(where: { $0.updatedAt != nil }) { return "–" }
        return "…"
    }
}

/// Which provider sections the dropdown draws, and whether they need naming.
///
/// Pure and separate from `MenuController` for the same reason `TitleSelection` is: the controller
/// cannot be constructed in a test, so a rule that lives inside it is a rule with no coverage.
enum PanelSections {
    /// A snapshot worth drawing: it has something to show, or something to say about why it
    /// doesn't — and its provider hasn't been switched off in Settings.
    ///
    /// `hidden` has no production caller: `MenuController` now pre-filters with its own
    /// `unhiddenSnapshots` before calling this, so passing `hidden` again here would filter twice.
    /// The parameter stays anyway, defaulted to empty, because `MenuController` cannot be
    /// constructed in a test — this is the only seam the exclusion rule can be asserted through.
    /// Retained deliberately; a previous PR in this codebase had exactly this shape of parameter
    /// mistaken for dead code and removed.
    static func visible(_ snapshots: [ProviderSnapshot], now: Date = Date(),
                        hidden: Set<ProviderID> = []) -> [ProviderSnapshot] {
        snapshots.filter {
            !hidden.contains($0.provider)
                && (!$0.displayable(now: now).isEmpty || $0.failure != nil)
        }
    }

    /// One row of the dropdown's usage section, named by *what* it is rather than *how* it's drawn
    /// — `rebuild()` is the only place that knows an `NSMenuItem` exists.
    enum Row: Equatable {
        case separator
        case heading(ProviderID)
        case usage(ProviderID, LimitWindow)
        case error(ProviderID)
    }

    /// The row sequence for one dropdown, as a plan rather than as side effects on an `NSMenu`.
    ///
    /// Pure so the ordering rule is assertable — it used to live inline in `rebuild()`, which no
    /// test can reach, and that is exactly how the separator between a section's usage rows and its
    /// error row went missing without a single test failing.
    ///
    /// `sections` and `needHeadings` are derived from one `visible(...)` call, not two independent
    /// ones each defaulting `now` to a fresh `Date()` — two clocks a freshness boundary could fall
    /// between would let the heading count disagree with the sections actually drawn.
    ///
    /// `hidden` is likewise defaulted and has no production caller — see the note on `visible`'s own
    /// `hidden` parameter above; the same reasoning applies here.
    static func rows(for snapshots: [ProviderSnapshot], now: Date = Date(),
                     hidden: Set<ProviderID> = []) -> [Row] {
        let sections = visible(snapshots, now: now, hidden: hidden)
        // Headings appear only once there is more than one section to tell apart, so a single
        // provider gets exactly the menu it had before providers were a concept — which is what
        // makes adding the second one a change the existing user never sees until it applies to
        // them.
        let needHeadings = sections.count > 1
        var rows: [Row] = []
        for (index, section) in sections.enumerated() {
            // A rule between providers, but never between the rows inside one: a line between every
            // usage row made three windows look like three unrelated panels stacked up. Between
            // providers it divides genuinely different things, which is what separators are for.
            if index > 0 { rows.append(.separator) }
            if needHeadings { rows.append(.heading(section.provider)) }
            let windows = section.displayable(now: now)
            for window in windows { rows.append(.usage(section.provider, window)) }
            if section.failure != nil {
                // Divides *kinds* of thing — data from an error — so it only earns its place when
                // there is data above it to divide from. A provider with nothing but a failure has
                // no usage rows here, and its error row is the section's entire content.
                if !windows.isEmpty { rows.append(.separator) }
                rows.append(.error(section.provider))
            }
        }
        return rows
    }
}

/// Owns the status item: the title in the menu bar and the dropdown behind it.
///
/// Knows nothing about where usage comes from — it is handed `[LimitWindow]` and renders it.
final class MenuController: NSObject, NSMenuDelegate {
    /// Called when the user picks Refresh Now.
    var onRefresh: (() -> Void)?

    /// Called when a preference changes, so the poll timer can be rescheduled.
    var onSettingsChanged: (() -> Void)?

    /// Called when Track Claude Code Sessions is toggled, so hooks are installed or removed.
    var onTrackSessionsChanged: (() -> Void)?

    /// Called when automatic update checks are toggled.
    var onCheckForUpdatesChanged: (() -> Void)?

    /// The last result of installing hooks, for the Settings status line.
    var hookOutcome: HookInstaller.Outcome?

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()

    /// The raw reads from each poll. Almost nothing should read this directly — see
    /// `unhiddenSnapshots` below, which is what every renderer actually wants.
    private var snapshots: [ProviderSnapshot] = []

    /// The snapshots anything user-facing may consider, with hidden providers removed.
    ///
    /// Everything that renders reads this rather than `snapshots` directly. Four separate call
    /// sites forgot the filter while this feature was being built — the dropdown rows, the display
    /// windows, the title windows and the title's fallback chip — each because raw `snapshots` was
    /// in scope and read naturally. This exists so the question does not have to be asked again at
    /// the next call site.
    private var unhiddenSnapshots: [ProviderSnapshot] {
        snapshots.filter { !Settings.hiddenProviders.contains($0.provider) }
    }

    /// Which providers have credentials, independent of `snapshots` — which only ever holds what's
    /// currently polled, and hiding a provider stops it being polled. Deriving the Settings list
    /// from `snapshots` would make a hidden provider's own switch disappear the moment it's used,
    /// with no way back short of a hand-edited plist. See `AppDelegate.pushDetectedProviders()`.
    private var detected: Set<ProviderID> = []
    private var isMenuOpen = false

    /// Most urgent first (`SessionActivity` sorts them), so the first one decides the title.
    private var sessions: [Session] = []
    private var animationFrame = 0
    /// Rate-limits the status word so a burst of hook events can't strobe the title. See
    /// `TitleWordHold` for why this is deliberate rather than a consequence of how often we poll.
    private var titleWord = TitleWordHold()
    /// Who the word currently speaks for — see `TitleSession`.
    private var titleSessionID: String?
    private var availableRelease: Release?

    /// Read-only here. `AppDelegate` owns recording, because only it knows a fetch actually
    /// succeeded — the menu is handed windows either way.
    private let history: UsageHistory

    /// Read only for its status. `AppDelegate` merges the readings; the menu just says whether they
    /// are arriving, since nothing else would tell a user their setup line isn't working.
    private let statusline: StatuslineFeed

    /// A row that can be rewritten in place while the menu sits open, so a menu held across a tick
    /// or a poll stays honest without being rebuilt underneath the user.
    ///
    /// `apply` reads *current* state each time it runs rather than closing over a value — see
    /// `window(id:)`. A row whose window has vanished from the latest poll leaves itself alone:
    /// one-poll-stale beats blanking the row or writing some other window's number into it.
    ///
    /// It performs the update rather than returning a string because rows are no longer all the same
    /// kind — a view-backed row goes through `HostedRow.update`, which swaps the `rootView` *and*
    /// re-measures the row's height. The spike for this design confirmed SwiftUI repaints while the
    /// menu is tracking; the re-measure is what makes a row that changes height do so honestly.
    private struct LiveRow { let apply: () -> Void }

    /// Rebuilt with the menu, and cleared before it — these closures retain their views.
    private var liveRows: [LiveRow] = []

    init(history: UsageHistory = .default, statusline: StatuslineFeed = .default) {
        self.history = history
        self.statusline = statusline
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        statusItem.button?.title = "✻ …"
    }

    // MARK: - Input

    func update(snapshots: [ProviderSnapshot]) {
        self.snapshots = snapshots
        renderTitle()
        // A poll can land while the dropdown is open, and the open dropdown is not rebuilt. Without
        // this the rows keep rendering the state they were built from — most visibly a countdown
        // running down to the *previous* window's reset and pinning at "now".
        refreshLiveRows()
    }

    /// Refreshes the live rows without rebuilding the menu, for the case where it's held open.
    func tick() { refreshLiveRows() }

    func update(sessions: [Session]) {
        self.sessions = sessions
        renderTitle()
        refreshLiveRows()
    }

    func update(release: Release?) {
        availableRelease = release
        // Shape change (an item appears), so it shows on the next open, like any new row.
    }

    func update(detected: Set<ProviderID>) {
        self.detected = detected
        // Shape change (a Providers section, or a row in it, appears or disappears), so it shows
        // on the next open, like `update(release:)` above.
    }

    /// One step of the working spark. Driven by `AppDelegate`'s fast timer, which only runs while a
    /// session is active.
    func advanceAnimation() {
        animationFrame = (animationFrame + 1) % MenuBarAnimation.globalCycleFrames
        // A word held back during a burst is drawn on the first frame after its window passes —
        // otherwise it would wait for the next session event, which in a quiet moment can be a
        // while. Everything else is only the image: at twelve frames a second, re-running the
        // title's forecasts and attributed-string building would be a lot of work for the same text.
        //
        // `wordWentStale` is the other half, and it is not the same case. `hasPending` means the
        // hooks announced a change and the hold deferred it. A turn crossing into `.starting` →
        // `.thinking` → `.lingering` is announced by nothing — it happens on the clock while Claude
        // Code sits silent, which is precisely when "been here a while" is worth saying — so there
        // was never anything to defer. Asking costs a hash and an array lookup.
        if titleWord.hasPending || wordWentStale() { renderTitle() } else { renderStatusImage() }
    }

    /// Whether the word the sessions would produce right now differs from the one on screen.
    private func wordWentStale() -> Bool {
        guard Settings.showStatusWords else { return false }
        // Read-only: `renderTitle` is what commits the choice to `titleSessionID`.
        let speaking = TitleSession.chosen(from: sessions, sticky: titleSessionID)
        return StatusWords.title(for: speaking) != titleWord.current
    }

    // MARK: - In-place refresh
    //
    // Every live row recomputes together, from all three entry points (tick, poll, poll failure), so
    // the menu can never show a mix of fresh and stale values — a percentage from one poll above a
    // reset time from the one before it is worse than either alone.
    //
    // Accepted limit, and a deliberate one: this rewrites rows, it cannot add or remove them. If a
    // poll changes the menu's *shape* — a `weekly_scoped` model appears or disappears, the first
    // successful poll replaces "Loading…" — the new shape waits for the next open, because the
    // alternative is rebuilding a menu that is on screen (see `rebuild`). The menu bar title, which
    // is what the user reads without clicking, is correct the whole time.

    private func refreshLiveRows() {
        guard isMenuOpen else { return }  // Closed menus rebuild from scratch on the way open.
        // Hazard worth knowing before adding a row kind: on a view-backed item, `title` is not drawn
        // at all, and on a plain item `attributedTitle` silently beats `title`. Either way the
        // compiler says nothing, and the symptom is a row that quietly stops updating. Each row
        // therefore owns the way it refreshes itself, rather than this loop assuming one.
        for row in liveRows { row.apply() }
    }

    // MARK: - Menu bar title

    /// Just the image, which is all that changes between animation frames.
    ///
    /// The image rather than a character in the title so that System mode can hand it to macOS as a
    /// template and have it adapt exactly like a built-in menu bar control — including inverting
    /// when the item is highlighted, which coloured text does not do.
    private func renderStatusImage() {
        guard let button = statusItem.button else { return }
        // Most urgent first, so one session decides both the image and the word — see
        // `SessionActivity`'s ordering. Several sessions' worth of text would not fit a menu bar.
        let activity = sessions.first
        let working = activity?.state == .thinking || activity?.state == .tool
        button.image = Settings.menuBarAnimation.image(
            mode: Settings.colorMode, frame: animationFrame, working: working,
            attention: activity?.state == .permission,
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        button.imagePosition = .imageLeading
    }

    private func renderTitle() {
        guard let button = statusItem.button else { return }

        // The spark is an image rather than a character in the title so that System mode can hand it
        // to macOS as a template and have it adapt exactly like a built-in menu bar control —
        // including inverting when the item is highlighted, which coloured text does not do.
        // Most urgent first, so one session decides both the image and the word — see
        // `SessionActivity`'s ordering. Several sessions' worth of text would not fit a menu bar.
        renderStatusImage()

        guard !displayWindows().isEmpty else {
            button.attributedTitle = NSAttributedString()
            button.title = TitleFallback.chip(for: unhiddenSnapshots)
            return
        }

        let mode = Settings.colorMode
        let title = NSMutableAttributedString()
        // The word goes first, where the eye already is: the image is to its left, and the numbers
        // it prefixes are the thing it is interrupting. Secondary colour so the percentages, which
        // carry the alert colours, stay the loudest thing in the item.
        let speaking = TitleSession.chosen(from: sessions, sticky: titleSessionID)
        titleSessionID = speaking?.id
        let word = Settings.showStatusWords
            ? titleWord.display(StatusWords.title(for: speaking), now: Date())
            : nil
        if let word {
            // Full label colour, and no separator before the numbers. The word is the part you read
            // at a glance while something is running; in secondary grey behind a `·` it read as an
            // aside to the percentages rather than the headline, and the dot made two unrelated
            // things look like one list.
            title.append(NSAttributedString(string: "\(word)  ", attributes: [
                .foregroundColor: NSColor.labelColor,
            ]))
        }
        let shown = titleWindows()
        let glyphed = TitleGlyphs.needed(for: shown.map(\.provider))
        var lastProvider: ProviderID?
        for (index, entry) in shown.enumerated() {
            if index > 0 {
                // A wider gap between providers than between one provider's own windows, so the
                // grouping reads without a second separator character doing the work.
                let gap = entry.provider == lastProvider ? " · " : "  "
                title.append(NSAttributedString(string: gap, attributes: [
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]))
            }
            if glyphed, entry.provider != lastProvider {
                title.append(NSAttributedString(string: "\(entry.provider.titleGlyph) ", attributes: [
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]))
            }
            let tinted = Forecast.tintsTitle(kind: entry.window.kind,
                                             forecast: forecast(for: entry.window,
                                                                provider: entry.provider))
            title.append(percentage(of: entry.window, mode: mode, onPace: tinted))
            lastProvider = entry.provider
        }
        button.attributedTitle = title
    }

    /// What is currently worth putting on screen, which is not always what the last poll returned.
    ///
    /// One place, used by the panel, the menu bar title and the error copy alike — the three used to
    /// be able to disagree, and a title showing percentages over a panel showing none is worse than
    /// either on its own.
    private func displayWindows() -> [LimitWindow] {
        let now = Date()
        return PanelSections.visible(unhiddenSnapshots, now: now).flatMap { $0.displayable(now: now) }
    }

    /// The windows the title shows, across every provider.
    ///
    /// Task 2 bridged this with a hardcoded `.claude`, because a bare `LimitWindow` does not know
    /// its provider while the selection set is stored qualified. Now that snapshots carry the
    /// provider, the bridge is replaced — a hardcoded `.claude` here would make every Codex window
    /// permanently unselectable.
    private func titleWindows() -> [(provider: ProviderID, window: LimitWindow)] {
        let now = Date()
        let sections = PanelSections.visible(unhiddenSnapshots, now: now)
            .map { (provider: $0.provider, windows: $0.displayable(now: now)) }
        return TitleSelection.windows(from: sections, selection: Settings.titleLimitIDs)
    }

    /// Where this window is heading, from the samples recorded so far.
    ///
    /// Recomputed on each render rather than cached with the window: the live rows re-run on every
    /// 60-second tick, and a forecast pinned at build time would keep naming a hit date the newest
    /// samples had already moved — the same trap that made held-open countdowns go stale.
    ///
    /// Takes the provider directly: both providers can name a window `"session"`, and looking the
    /// provider up by id alone would forecast a Codex row from Claude's history the moment the two
    /// collide — the exact cross-provider mixup `ProviderID.qualify` exists to prevent.
    private func forecast(for window: LimitWindow, provider: ProviderID) -> Forecast {
        Forecast.project(samples: history.samples(for: window.id, provider: provider),
                         kind: window.kind, resetsAt: window.resetsAt, now: Date())
    }

    private func percentage(of window: LimitWindow?, mode: Settings.ColorMode,
                            onPace: Bool = false) -> NSAttributedString {
        // Monospaced digits so the title doesn't shuffle sideways as the numbers tick over.
        NSAttributedString(string: Fmt.pct(window?.utilization), attributes: [
            .foregroundColor: window
                .map { Fmt.color($0.utilization, mode: mode, role: .title, onPace: onPace) }
                ?? NSColor.secondaryLabelColor,
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
        ])
    }

    // MARK: - Dropdown

    func menuNeedsUpdate(_ menu: NSMenu) { rebuild() }
    func menuWillOpen(_ menu: NSMenu) { isMenuOpen = true }
    func menuDidClose(_ menu: NSMenu) { isMenuOpen = false }

    private func rebuild() {
        // Never rebuild a menu that is on screen. `menuNeedsUpdate` is not just an "about to open"
        // callback: AppKit also runs it while matching key equivalents, and this menu claims ⌘R and
        // ⌘Q, so it can fire mid-tracking. Rebuilding then would (1) delete the parent item of an
        // open Settings submenu out from under it, (2) re-target a click already in flight — the
        // user presses on "Refresh Now" and releases on whatever now occupies that row, which at the
        // bottom of this menu is "Quit Cashew" — and (3) discard highlight and keyboard-navigation
        // state, dropping the user back to the top of the menu mid-arrow-key. Open menus are updated
        // in place by `refreshLiveRows` instead.
        guard !isMenuOpen else { return }

        // Before the items go, not after: these registrations hold the `NSMenuItem`s strongly, so a
        // stale entry would keep a detached item alive and go on ticking it forever for a menu that
        // no longer contains it.
        liveRows.removeAll()
        menu.removeAllItems()

        // `PanelSections.rows` is empty exactly when no provider has anything to show and none has
        // failed either — `visible(...)`, which it's built from, always keeps a failed snapshot
        // regardless of its windows, so an empty plan can never hide an error.
        let rows = PanelSections.rows(for: unhiddenSnapshots)

        if rows.isEmpty {
            // `unhiddenSnapshots`, not `snapshots`: a hidden provider's own successful poll must not
            // be what tells a Claude-only user they're still loading, or make a genuinely-loading
            // account claim it has none to show.
            if unhiddenSnapshots.contains(where: { $0.updatedAt != nil }) {
                menu.addItem(textRow {
                    """
                    No plan limits reported for this account. Pro and Max plans have session and \
                    weekly windows; metered API-key accounts have no quota to show.
                    """
                })
            } else {
                menu.addItem(textRow { "Loading…" })
            }
        } else {
            for row in rows {
                switch row {
                case .separator: menu.addItem(.separator())
                case .heading(let provider): menu.addItem(headingRow(provider.sectionHeading))
                case .usage(let provider, let window): menu.addItem(usageRow(for: window, provider: provider))
                case .error(let provider): menu.addItem(errorRow(for: provider))
                }
            }
        }

        if !sessions.isEmpty {
            menu.addItem(.separator())
            menu.addItem(headingRow(SessionActivity.menuHeading))
            let visible = SessionPanel.visible(sessions)
            for session in visible.shown {
                menu.addItem(sessionRow(for: session))
            }
            if visible.hidden > 0 {
                let label = SessionActivity.moreLabel(visible.hidden)
                menu.addItem(textRow { label })
            }
        }

        if Settings.notifyThreshold > 0, Notifier.alertsBlocked {
            menu.addItem(.separator())
            let item = action("Alerts blocked — open Notification settings",
                              key: "", selector: #selector(openNotificationSettings))
            menu.addItem(item)
        }

        menu.addItem(.separator())
        if let release = availableRelease {
            let item = action(UpdateCheck.menuTitle(release), key: "", selector: #selector(openRelease))
            menu.addItem(item)
        }
        menu.addItem(refreshRow())
        menu.addItem(settingsItem())
        menu.addItem(action("Quit Cashew", key: "q", selector: #selector(quitClicked)))
    }

    // MARK: - Settings submenu
    //
    // Three levels deep: Settings, one of its sections, and that section's own rows. Flat, it was
    // eight headed groups in one column — every one of them visible whichever one you came for.
    //
    // Rebuilt with the rest of the menu, so every switch and mark is read fresh rather than cached
    // — launch-at-login in particular can be revoked in System Settings behind our back.
    //
    // One rule runs through it, and it is the macOS one: **picking dismisses, switching does not.**
    // A choice among several (an animation, a colour, a threshold) is a command and closes the menu
    // like any other menu command. An on/off is a control you may want two or three of in a visit,
    // so it stays put. That is the whole reason the switches are custom views — see `MenuToggle`.

    private enum Copy {
        static let providersSection = "Providers"
        static let menuBarSection = "Menu Bar"
        static let alertsSection = "Alerts & Refresh"
        static let limitsHeader = "LIMITS SHOWN"
        static let colorHeader = "COLOR"
        static let notifyHeader = "NOTIFY WHEN USAGE PASSES"
        static let refreshHeader = "CHECK USAGE EVERY"
        /// Under `notifyHeader` this reads as an answer; "Off" read as a label for a switch that
        /// wasn't there.
        static let neverNotify = "Never"
        /// What System Settings itself calls this, in General › Login Items. Matching the platform's
        /// own word costs nothing and means one less thing to translate on the way to finding it.
        static let launchTitle = "Open at Login"
    }

    private func settingsItem() -> NSMenuItem {
        let submenu = NSMenu()
        submenu.autoenablesItems = false

        if let providers = providerSettings() {
            submenu.addItem(section(Copy.providersSection, providers))
        }
        submenu.addItem(section(Copy.menuBarSection, menuBarSettings()))
        submenu.addItem(section(Copy.alertsSection, alertSettings()))
        submenu.addItem(section(SessionActivity.settingsHeading, claudeCodeSettings()))
        submenu.addItem(.separator())

        // These two stay at the Settings level rather than going into a section. Neither belongs to
        // any of the three groups above, and they are the two a first-time user goes looking for, so
        // a third hover to reach them would cost more than the two extra rows cost here.
        //
        // `settled` matters on this one specifically: registration legitimately fails when the app
        // runs from a quarantined or temporary location, and `Settings.launchAtLogin` reads the real
        // `SMAppService` status rather than a mirror of it. Without the re-read the switch would
        // slide over and stay there, claiming something macOS had just refused.
        // No subtitles on these two, unlike the switches inside the sections: both are settings
        // every Mac app has, and a line explaining "Start Cashew when you log in" under "Open at
        // Login" is the kind of help that reads as padding. The subtitle is for the ones that are
        // genuinely unguessable — "Status words" — not for every switch on principle.
        submenu.addItem(SettingsRow.toggle(
            Copy.launchTitle,
            isOn: Settings.launchAtLogin, settled: { Settings.launchAtLogin }
        ) { isOn in Settings.launchAtLogin = isOn })

        submenu.addItem(SettingsRow.toggle(
            UpdateCheck.settingsTitle, isOn: Settings.checkForUpdates
        ) { [weak self] isOn in
            Settings.checkForUpdates = isOn
            self?.onCheckForUpdatesChanged?()
        })

        let item = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
        item.isEnabled = true
        item.submenu = submenu
        return item
    }

    private func section(_ title: String, _ contents: NSMenu) -> NSMenuItem {
        contents.autoenablesItems = false
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = true
        item.submenu = contents
        return item
    }

    /// One switch per *detected* provider, or nothing at all.
    ///
    /// Returns nil when fewer than two providers are detected: a section offering a single switch
    /// that turns off the only thing the app can show is a way to break Cashew, not a preference.
    /// A provider with no credentials is not listed — there is nothing to switch.
    ///
    /// Reads `detected`, not `snapshots` — see the note on `detected`'s declaration for why that
    /// distinction is load-bearing rather than cosmetic.
    private func providerSettings() -> NSMenu? {
        guard detected.count > 1 else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false
        let hidden = Settings.hiddenProviders
        for provider in ProviderID.allCases where detected.contains(provider) {
            menu.addItem(SettingsRow.toggle(
                "\(provider.sectionHeading.capitalized) (\(hidden.contains(provider) ? "off" : "on"))",
                isOn: !hidden.contains(provider),
                onToggle: { [weak self] _ in
                    Settings.hiddenProviders = Settings.hiddenProviders(toggling: provider,
                                                                        in: Settings.hiddenProviders)
                    self?.onSettingsChanged?()
                }))
        }
        return menu
    }

    /// What the menu bar item itself shows: which numbers, whether it talks, and how it looks.
    private func menuBarSettings() -> NSMenu {
        let menu = NSMenu()

        // Built from the windows the response actually reported, never from a hardcoded list — the
        // set of model-scoped limits is the vendor's to change, and has already changed once.
        // Omitted entirely when there is nothing to choose between yet.
        let allWindows = snapshots.flatMap(\.windows)
        if !allWindows.isEmpty {
            menu.addItem(SettingsRow.header(Copy.limitsHeader))
            let selected = Settings.titleLimitIDs
            let sections = snapshots.map { (provider: $0.provider, windows: $0.windows) }
            // What the title is *actually* showing, which differs from the selection when a chosen
            // scope has vanished and `TitleSelection` fell back. Marking that row `.mixed` rather
            // than `.off` stops the submenu claiming a limit is hidden while its number is sitting
            // in the menu bar. Unticking everything is not that case: it renders nothing, so every
            // row is plainly `.off`.
            //
            // Qualified by provider, not just by id: two providers can both report a "session"
            // window, and an unqualified set would mark the wrong one `.mixed`.
            let rendered = Set(TitleSelection.windows(from: sections, selection: selected)
                .map { $0.provider.qualify($0.window.id) })
            for snapshot in snapshots {
                for window in snapshot.windows {
                    let item = action(window.optionLabel,
                                      key: "", selector: #selector(toggleTitleLimit(_:)))
                    // The id goes in `representedObject`, not `tag`: tags are Int and these are
                    // strings, and a positional tag would break the moment the response reorders.
                    // Qualified by provider, to match what `Settings.titleLimitIDs` actually stores.
                    let qualifiedID = snapshot.provider.qualify(window.id)
                    item.representedObject = qualifiedID
                    if selected.contains(qualifiedID) { item.state = .on }
                    else if rendered.contains(qualifiedID) { item.state = .mixed }
                    else { item.state = .off }
                    menu.addItem(item)
                }
            }
            menu.addItem(.separator())
        }

        menu.addItem(SettingsRow.toggle(
            SessionActivity.statusWordsMenuTitle, subtitle: SessionActivity.statusWordsMenuSubtitle,
            isOn: Settings.showStatusWords
        ) { [weak self] isOn in
            // Repaints the menu bar and nothing else — deliberately *not* `onSettingsChanged`, which
            // exists so a shortened poll interval feels immediate. This has nothing to do with
            // polling, and calling it would spend a usage request on a preference.
            Settings.showStatusWords = isOn
            self?.renderTitle()
        })

        menu.addItem(.separator())
        menu.addItem(SettingsRow.header(SessionActivity.animationHeading))
        for style in MenuBarAnimation.allCases {
            let item = action(style.label, key: "", selector: #selector(setAnimation(_:)))
            // `representedObject`, not `tag`: tags are Int, and a positional tag would break the
            // moment the list is reordered.
            item.representedObject = style
            item.state = Settings.menuBarAnimation == style ? .on : .off
            menu.addItem(item)
        }

        menu.addItem(.separator())
        menu.addItem(SettingsRow.header(Copy.colorHeader))
        for mode in Settings.ColorMode.allCases {
            let item = action(mode.label, key: "", selector: #selector(setColorMode(_:)))
            item.representedObject = mode
            item.state = Settings.colorMode == mode ? .on : .off
            menu.addItem(item)
        }

        return menu
    }

    /// When Cashew interrupts you, and how often it looks.
    private func alertSettings() -> NSMenu {
        let menu = NSMenu()

        menu.addItem(SettingsRow.header(Copy.notifyHeader))
        for threshold in Settings.thresholdOptions {
            let item = action(threshold == 0 ? Copy.neverNotify : "\(threshold)%",
                              key: "", selector: #selector(setThreshold(_:)))
            item.tag = threshold
            item.state = Settings.notifyThreshold == threshold ? .on : .off
            menu.addItem(item)
        }

        menu.addItem(.separator())
        menu.addItem(SettingsRow.header(Copy.refreshHeader))
        for minutes in Settings.refreshOptions {
            let title = minutes == 1 ? "1 minute" : "\(minutes) minutes"
            let item = action(title, key: "", selector: #selector(setInterval(_:)))
            item.tag = minutes
            item.state = Settings.refreshMinutes == minutes ? .on : .off
            menu.addItem(item)
        }

        return menu
    }

    /// Session tracking and the live feed — the two things that need Claude Code's cooperation, and
    /// the two that therefore have a status to report rather than only a setting to hold.
    private func claudeCodeSettings() -> NSMenu {
        let menu = NSMenu()

        let hookStatus = SettingsRow.note(hookStatusText())
        menu.addItem(SettingsRow.toggle(
            SessionActivity.trackMenuTitle, subtitle: SessionActivity.trackMenuSubtitle,
            isOn: Settings.trackSessions
        ) { [weak self, weak hookStatus] isOn in
            // Not `onSettingsChanged`: this has nothing to do with polling usage.
            Settings.trackSessions = isOn
            self?.onTrackSessionsChanged?()
            // The switch leaves the menu open, so unlike every other row here this status line is
            // read *after* the thing it describes has changed and with nobody about to rebuild it —
            // `rebuild` refuses while the menu is on screen. Installing hooks is synchronous, so by
            // now `hookOutcome` is the new one; without this the line would go on saying "On · 2
            // sessions" underneath a switch the user had just turned off.
            hookStatus?.attributedTitle = SettingsRow.noteTitle(self?.hookStatusText() ?? "")
        })
        menu.addItem(hookStatus)
        // Also refreshed on the 60-second tick: the session count in it goes stale on its own while
        // the menu sits open, which matters more now that a switch no longer closes it.
        liveRows.append(LiveRow { [weak self, weak hookStatus] in
            guard let self else { return }
            hookStatus?.attributedTitle = SettingsRow.noteTitle(self.hookStatusText())
        })

        // A status line and a way in. The opt-in is a line in the user's own statusline script, which
        // Cashew deliberately never edits — so the menu's job is to make it findable and to say
        // whether it's working. Read fresh on every open, like everything else here.
        menu.addItem(.separator())
        menu.addItem(SettingsRow.header(StatuslineFeed.menuHeading))
        let status = statusline.status()
        menu.addItem(SettingsRow.note(status.label()))
        if status.offersSetup {
            menu.addItem(action(StatuslineFeed.setupMenuTitle,
                                key: "", selector: #selector(showLiveSetup)))
        }

        return menu
    }

    private func hookStatusText() -> String {
        HookInstaller.statusLabel(hookOutcome, enabled: Settings.trackSessions,
                                  sessionCount: sessions.count)
    }


    @objc private func setInterval(_ sender: NSMenuItem) {
        Settings.refreshMinutes = sender.tag
        onSettingsChanged?()
    }

    @objc private func setThreshold(_ sender: NSMenuItem) {
        Settings.notifyThreshold = sender.tag
        onSettingsChanged?()
    }

    @objc private func toggleTitleLimit(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        Settings.titleLimitIDs = Settings.titleLimitIDs(toggling: id, in: Settings.titleLimitIDs)
        // Same reasoning as `setColorMode`: which numbers are shown changes nothing about polling.
        renderTitle()
    }

    @objc private func setColorMode(_ sender: NSMenuItem) {
        guard let mode = sender.representedObject as? Settings.ColorMode else { return }
        Settings.colorMode = mode
        // Repaints the menu bar immediately; the dropdown picks it up on its next open, which is
        // after this click dismisses it anyway.
        //
        // Deliberately *not* `onSettingsChanged` — that exists so a shortened poll interval feels
        // immediate and a lowered alert threshold is evaluated against current usage. Neither
        // applies to a colour, and calling it would spend a request on the usage endpoint and reset
        // the poll phase every time someone toggled a swatch.
        renderTitle()
    }

    /// A dialog rather than a bare copy command. Copying silently from a menu gave no sign anything
    /// happened and no hint what the clipboard now held or where it went; the dialog explains, shows
    /// the line itself, and copies only when asked.
    @objc private func showLiveSetup() {
        let alert = NSAlert()
        alert.messageText = StatuslineFeed.setupDialogTitle
        alert.informativeText = StatuslineFeed.setupDialogMessage
        alert.addButton(withTitle: StatuslineFeed.setupCopyButton)
        alert.addButton(withTitle: "Cancel")

        let snippet = NSTextField(wrappingLabelWithString: StatuslineFeed.setupCommand)
        snippet.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        snippet.isSelectable = true
        snippet.preferredMaxLayoutWidth = 460
        snippet.frame.size = snippet.fittingSize
        alert.accessoryView = snippet

        // An accessory app has no window to bring forward, so without this the dialog opens behind
        // whatever app was frontmost when the menu was clicked.
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(StatuslineFeed.setupSnippet, forType: .string)
    }

    @objc private func setAnimation(_ sender: NSMenuItem) {
        guard let style = sender.representedObject as? MenuBarAnimation else { return }
        Settings.menuBarAnimation = style
        renderTitle()
    }

    @objc private func openRelease() {
        guard let url = availableRelease?.url else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Live rows

    /// One usage section: heading with its reset time, the percentage with a countdown, and the bar.
    ///
    /// Registered for in-place refresh, keyed on the window's stable `id` so a poll that reorders or
    /// relabels windows still finds the right one.
    private func usageRow(for window: LimitWindow, provider: ProviderID) -> NSMenuItem {
        let id = window.id
        let row = UsageRow(window, mode: Settings.colorMode, forecast: forecast(for: window, provider: provider))
        let hosted = HostedRow(UsageRowView(row: row), title: row.spoken)
        liveRows.append(LiveRow { [weak self] in
            guard let self, let window = self.window(id: id, provider: provider) else { return }
            let row = UsageRow(window, mode: Settings.colorMode,
                               forecast: self.forecast(for: window, provider: provider))
            // `update` re-measures, which this row now depends on rather than merely tolerating: the
            // pace line appears and disappears, so the row's height is no longer constant.
            hosted.update(UsageRowView(row: row), title: row.spoken)
        })
        return hosted.item
    }

    /// A message-only row: the footer, an error, "Loading…".
    private func textRow(_ text: @escaping () -> String?) -> NSMenuItem {
        let initial = text() ?? ""
        let hosted = HostedRow(PanelTextView(text: initial), title: initial)
        liveRows.append(LiveRow {
            guard let latest = text() else { return }
            // The row this fix exists for. "Loading…" becoming the three-line Keychain message is a
            // height change, and until `update` re-measured, the row kept its one-line height and
            // clipped the rest away.
            hosted.update(PanelTextView(text: latest), title: latest)
        })
        return hosted.item
    }

    /// A session, kept current while the menu is open. Closes over the session's **id** and looks
    /// it up each time — the same lesson as `window(id:)`. A session that ended while the menu is
    /// open says so rather than vanishing, because an open menu can't lose rows.
    private func sessionRow(for session: Session) -> NSMenuItem {
        let id = session.id
        var row = SessionRow(session, now: Date())
        let hosted = HostedRow(SessionRowView(row: row, mode: Settings.colorMode), title: row.spoken)
        liveRows.append(LiveRow { [weak self] in
            guard let self else { return }
            if let current = self.sessions.first(where: { $0.id == id }) {
                row = SessionRow(current, now: Date())
            } else {
                row = row.ended
            }
            hosted.update(SessionRowView(row: row, mode: Settings.colorMode), title: row.spoken)
        })
        return hosted.item
    }

    private func headingRow(_ text: String) -> NSMenuItem {
        HostedRow(PanelHeadingView(text: text), title: text).item
    }

    /// Errors only. How fresh the numbers are is shown on the Refresh Now row instead, where it sits
    /// next to the thing that acts on it — and the error copy already carries its own timestamp
    /// ("Showing data from 14:02"), so a separate Updated line would have said it twice.
    private func errorRow(for provider: ProviderID) -> NSMenuItem {
        textRow { [weak self] in
            guard let self,
                  let section = self.snapshots.first(where: { $0.provider == provider }),
                  let error = section.failure else { return nil }
            return self.message(for: error, in: section)
        }
    }

    /// Refresh Now, carrying how old the numbers are.
    ///
    /// A plain `NSMenuItem`, deliberately, even though a view-backed one could draw a nicer badge.
    /// Two things measured on a view-backed version decided it: a hosting view swallows the mouse
    /// event, so `NSMenuItem.action` never fires and the row has to reimplement its own selection;
    /// and `keyEquivalent` stops working entirely — ⌘Q on a plain item kept working while ⌘R on the
    /// view-backed row did nothing, and `NSMenuDelegate.menuHasKeyEquivalent`, the documented hook
    /// for reclaiming it, is not consulted for status-item menus. Plain text costs a rounded badge;
    /// a custom view costs the shortcut, the native highlight, and AppKit's click routing.
    ///
    /// Registered as a live row so the age keeps counting up while the menu is held open.
    private func refreshRow() -> NSMenuItem {
        let title = { [weak self] in
            "Refresh Now (\(Fmt.age(of: self?.unhiddenSnapshots.compactMap(\.updatedAt).max())))"
        }
        let item = action(title(), key: "r", selector: #selector(refreshClicked))
        liveRows.append(LiveRow { item.title = title() })
        return item
    }

    /// The window this row was built for, as it stands in the *latest* poll of its own provider.
    ///
    /// Looking it up beats closing over the `LimitWindow`: a captured value made a held-open menu go
    /// on counting down to the reset of a window the poll had already replaced, reach "now", and
    /// stay pinned there until the menu was closed and reopened.
    ///
    /// Keyed on provider *and* id, because the id alone is only unique within a provider.
    private func window(id: String, provider: ProviderID) -> LimitWindow? {
        snapshots.first { $0.provider == provider }?.windows.first { $0.id == id }
    }

    /// A provider's error copy, plus the "you're looking at old numbers" note that only makes sense
    /// when that provider still has numbers on screen to be old.
    private func message(for error: Error, in snapshot: ProviderSnapshot) -> String {
        let description = (error as? UsageError)?.errorDescription ?? error.localizedDescription
        // Keyed on what is actually on screen *for this provider*: once `Freshness` drops its rows,
        // promising "showing data from…" would point at numbers that aren't there any more.
        guard !snapshot.displayable().isEmpty, let updatedAt = snapshot.updatedAt else {
            return description
        }
        // `Fmt.stamp`, never `Fmt.clock` — clock renders a bare time for any past date, so this line
        // once claimed a fifteen-day-old reading was from "4:44 AM".
        return "\(description) Showing data from \(Fmt.stamp(updatedAt))."
    }

    // MARK: - Item builders

    private func action(_ title: String, key: String, selector: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = self
        item.isEnabled = true
        return item
    }

    @objc private func openNotificationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")
        else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func refreshClicked() {
        // Asking for a refresh is consent to be asked for Keychain access again, if a previous Deny
        // latched it off. Otherwise the error row's advice is unreachable without relaunching.
        Credentials.allowKeychainRetry()
        onRefresh?()
    }
    @objc private func quitClicked() { NSApp.terminate(nil) }
}
