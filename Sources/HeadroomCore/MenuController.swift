import AppKit
import HeadroomShared

/// Which limits the menu bar title shows, given what the response reported and what the user picked.
///
/// Pure and separate from `MenuController` so the rules are testable — the controller can't be
/// constructed in a test, and these are exactly the cases that are awkward to reach by hand: a
/// scope that disappears from the response, or every chosen scope disappearing at once.
enum TitleSelection {
    static func windows(from windows: [LimitWindow], selection: Set<String>) -> [LimitWindow] {
        // Filtering rather than looking each selected id up: order comes from the response, which
        // `ClaudeProvider.windows(in:)` already fixes as session, then weekly, then scoped. A
        // selection whose scope has vanished simply doesn't match, and the stored preference is
        // untouched, so it renders again if the scope returns.
        let shown = windows.filter { selection.contains($0.id) }
        guard shown.isEmpty else { return shown }
        // Everything chosen has gone missing. One number beats a bare spark, which reads as broken
        // and offers no route back to the setting.
        return windows.first { $0.kind == .session }.map { [$0] } ?? Array(windows.prefix(1))
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

    private var windows: [LimitWindow] = []
    private var lastUpdated: Date?
    private var lastError: Error?
    private var isMenuOpen = false

    /// Most urgent first (`SessionActivity` sorts them), so the first one decides the title.
    private var sessions: [Session] = []
    private var animationFrame = 0
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
        // Start from the last good reading rather than from nothing. A launch whose first poll fails
        // — an expired token, no network, or the endpoint rate-limiting us — otherwise shows an error
        // over an empty panel, even though the numbers from an hour ago were both known and still
        // roughly true. Once seeded, everything downstream already behaves: `rebuild` takes its
        // non-empty branch, so the rows render with the error beneath them, and `message(for:)`
        // appends "Showing data from 14:02" because `lastUpdated` is set.
        //
        // Nothing here is treated as a fresh poll. `Notifier.evaluate` and `history.record` run only
        // on a real success, so restored numbers can't fire an alert or invent a sample.
        if let restored = history.restorableSnapshot() {
            windows = restored.windows
            lastUpdated = restored.at
        }
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        statusItem.button?.title = "✻ …"
    }

    // MARK: - Input

    func update(windows: [LimitWindow], updatedAt: Date) {
        self.windows = windows
        self.lastUpdated = updatedAt
        self.lastError = nil
        renderTitle()
        // A poll can land while the dropdown is open, and the open dropdown is not rebuilt. Without
        // this the rows keep rendering the state they were built from — most visibly a countdown
        // running down to the *previous* window's reset and pinning at "now".
        refreshLiveRows()
    }

    /// Keeps whatever was last shown. A dead network or an expired token shouldn't blank out
    /// numbers that were true a few minutes ago; the menu says so instead.
    func update(error: Error) {
        self.lastError = error
        renderTitle()
        // Same reason as above, and it is the footer that changes: "Updated 14:02" has to become
        // the error line while the menu is on screen, or the menu claims a refresh that failed.
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

    /// One step of the working spark. Driven by `AppDelegate`'s fast timer, which only runs while a
    /// session is active.
    func advanceAnimation() {
        animationFrame = (animationFrame + 1) % MenuBarAnimation.maxCycleFrames
        // Only the image, not the whole title: at twelve frames a second, re-running the title's
        // forecasts and attributed-string building for every frame would be a lot of work to
        // produce the same text.
        renderStatusImage()
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
            if lastError != nil { button.title = "!" }
            // A clean fetch that reported nothing isn't an error and isn't still loading —
            // API-key accounts have no plan quota to report.
            else if lastUpdated != nil { button.title = "–" }
            else { button.title = "…" }
            return
        }

        let mode = Settings.colorMode
        let title = NSMutableAttributedString()
        // The word goes first, where the eye already is: the image is to its left, and the numbers
        // it prefixes are the thing it is interrupting. Secondary colour so the percentages, which
        // carry the alert colours, stay the loudest thing in the item.
        if Settings.showStatusWords, let word = StatusWords.title(for: sessions.first) {
            title.append(NSAttributedString(string: "\(word) · ", attributes: [
                .foregroundColor: NSColor.secondaryLabelColor,
            ]))
        }
        for (index, window) in titleWindows().enumerated() {
            if index > 0 {
                title.append(NSAttributedString(string: " · ", attributes: [
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]))
            }
            let tinted = Forecast.tintsTitle(kind: window.kind, forecast: forecast(for: window))
            title.append(percentage(of: window, mode: mode, onPace: tinted))
        }
        button.attributedTitle = title
    }

    /// What is currently worth putting on screen, which is not always what the last poll returned.
    ///
    /// One place, used by the panel, the menu bar title and the error copy alike — the three used to
    /// be able to disagree, and a title showing percentages over a panel showing none is worse than
    /// either on its own.
    private func displayWindows() -> [LimitWindow] {
        Freshness.displayable(windows, updatedAt: lastUpdated, now: Date())
    }

    private func titleWindows() -> [LimitWindow] {
        TitleSelection.windows(from: displayWindows(), selection: Settings.titleLimitIDs)
    }

    /// Where this window is heading, from the samples recorded so far.
    ///
    /// Recomputed on each render rather than cached with the window: the live rows re-run on every
    /// 60-second tick, and a forecast pinned at build time would keep naming a hit date the newest
    /// samples had already moved — the same trap that made held-open countdowns go stale.
    private func forecast(for window: LimitWindow) -> Forecast {
        Forecast.project(samples: history.samples(for: window.id),
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
        // bottom of this menu is "Quit Headroom" — and (3) discard highlight and keyboard-navigation
        // state, dropping the user back to the top of the menu mid-arrow-key. Open menus are updated
        // in place by `refreshLiveRows` instead.
        guard !isMenuOpen else { return }

        // Before the items go, not after: these registrations hold the `NSMenuItem`s strongly, so a
        // stale entry would keep a detached item alive and go on ticking it forever for a menu that
        // no longer contains it.
        liveRows.removeAll()
        menu.removeAllItems()

        // Not `windows`: a reading too old to describe anything is dropped here, so a long outage
        // ends up in the message-only branch below instead of leaving stale percentages on screen.
        let shown = displayWindows()

        if shown.isEmpty {
            if lastError != nil {
                // Reads current state rather than the error bound here, so a later failure while the
                // menu is open rewrites this row instead of freezing the first one.
                menu.addItem(textRow { [weak self] in
                    guard let self, let error = self.lastError else { return nil }
                    return self.message(for: error)
                })
            } else if lastUpdated != nil {
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
            // No rules between the usage rows. Each row already reads as a unit — a semibold heading
            // over a large percentage over a bar — so whitespace is enough to group them, and a line
            // between every one made three sections look like three unrelated panels stacked up.
            // Separators still earn their place below, where they divide *kinds* of thing: data from
            // an error, data from the commands.
            for window in shown {
                menu.addItem(usageRow(for: window))
            }
            if lastError != nil {
                menu.addItem(.separator())
                menu.addItem(errorRow())
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
        menu.addItem(action("Quit Headroom", key: "q", selector: #selector(quitClicked)))
    }

    // MARK: - Settings submenu
    //
    // Rebuilt with the rest of the menu, so every checkmark is read fresh rather than cached —
    // launch-at-login in particular can be revoked in System Settings behind our back.

    private func settingsItem() -> NSMenuItem {
        let submenu = NSMenu()
        submenu.autoenablesItems = false

        submenu.addItem(header("REFRESH EVERY"))
        for minutes in Settings.refreshOptions {
            let title = minutes == 1 ? "1 minute" : "\(minutes) minutes"
            let item = action(title, key: "", selector: #selector(setInterval(_:)))
            item.tag = minutes
            item.state = Settings.refreshMinutes == minutes ? .on : .off
            submenu.addItem(item)
        }

        submenu.addItem(.separator())
        submenu.addItem(header("NOTIFY ABOVE"))
        for threshold in Settings.thresholdOptions {
            let item = action(threshold == 0 ? "Off" : "\(threshold)%",
                              key: "", selector: #selector(setThreshold(_:)))
            item.tag = threshold
            item.state = Settings.notifyThreshold == threshold ? .on : .off
            submenu.addItem(item)
        }

        // Built from the windows the response actually reported, never from a hardcoded list — the
        // set of model-scoped limits is the vendor's to change, and has already changed once.
        // Omitted entirely when there is nothing to choose between yet.
        if !windows.isEmpty {
            submenu.addItem(.separator())
            submenu.addItem(header("SHOW IN MENU BAR"))
            let selected = Settings.titleLimitIDs
            // What the title is *actually* showing, which differs from the selection when every
            // chosen scope has vanished and `TitleSelection` fell back. Marking that row `.mixed`
            // rather than `.off` stops the submenu claiming a limit is hidden while its number is
            // sitting in the menu bar.
            let rendered = Set(TitleSelection.windows(from: windows, selection: selected).map(\.id))
            for window in windows {
                let item = action(window.optionLabel,
                                  key: "", selector: #selector(toggleTitleLimit(_:)))
                // The id goes in `representedObject`, not `tag`: tags are Int and these are strings,
                // and a positional tag would break the moment the response reorders.
                item.representedObject = window.id
                if selected.contains(window.id) { item.state = .on }
                else if rendered.contains(window.id) { item.state = .mixed }
                else { item.state = .off }
                submenu.addItem(item)
            }
        }

        submenu.addItem(.separator())
        submenu.addItem(header("COLORS"))
        for mode in Settings.ColorMode.allCases {
            let item = action(mode.label, key: "", selector: #selector(setColorMode(_:)))
            item.representedObject = mode
            item.state = Settings.colorMode == mode ? .on : .off
            submenu.addItem(item)
        }

        submenu.addItem(.separator())
        submenu.addItem(header(SessionActivity.settingsHeading))
        let track = action(SessionActivity.trackMenuTitle, key: "", selector: #selector(toggleTrackSessions))
        track.state = Settings.trackSessions ? .on : .off
        submenu.addItem(track)
        let hookStatus = NSMenuItem(
            title: HookInstaller.statusLabel(hookOutcome, enabled: Settings.trackSessions,
                                             sessionCount: sessions.count),
            action: nil, keyEquivalent: "")
        hookStatus.isEnabled = false
        submenu.addItem(hookStatus)

        let words = action(SessionActivity.statusWordsMenuTitle,
                           key: "", selector: #selector(toggleStatusWords))
        words.state = Settings.showStatusWords ? .on : .off
        submenu.addItem(words)

        submenu.addItem(.separator())
        submenu.addItem(header(SessionActivity.animationHeading))
        for style in MenuBarAnimation.allCases {
            let item = action(style.label, key: "", selector: #selector(setAnimation(_:)))
            // `representedObject`, not `tag`: tags are Int, and a positional tag would break the
            // moment the list is reordered.
            item.representedObject = style
            item.state = Settings.menuBarAnimation == style ? .on : .off
            submenu.addItem(item)
        }

        // A status line and a way in. The opt-in is a line in the user's own statusline script, which
        // Headroom deliberately never edits — so the menu's job is to make it findable and to say
        // whether it's working. Read fresh on every open, like the checkmarks above.
        submenu.addItem(.separator())
        submenu.addItem(header(StatuslineFeed.menuHeading))
        let status = statusline.status()
        let statusItem = NSMenuItem(title: status.label(), action: nil, keyEquivalent: "")
        statusItem.isEnabled = false
        submenu.addItem(statusItem)
        if status.offersSetup {
            submenu.addItem(action(StatuslineFeed.setupMenuTitle,
                                   key: "", selector: #selector(showLiveSetup)))
        }

        submenu.addItem(.separator())
        let launch = action("Launch at Login", key: "", selector: #selector(toggleLaunchAtLogin))
        launch.state = Settings.launchAtLogin ? .on : .off
        submenu.addItem(launch)

        let updates = action(UpdateCheck.settingsTitle, key: "", selector: #selector(toggleCheckForUpdates))
        updates.state = Settings.checkForUpdates ? .on : .off
        submenu.addItem(updates)

        let item = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
        item.isEnabled = true
        item.submenu = submenu
        return item
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

    @objc private func toggleLaunchAtLogin() {
        Settings.launchAtLogin.toggle()
    }

    /// Not `onSettingsChanged`: neither toggle has anything to do with polling usage.
    @objc private func toggleTrackSessions() {
        Settings.trackSessions.toggle()
        onTrackSessionsChanged?()
    }

    /// Both of these repaint the menu bar immediately and nothing else — deliberately *not*
    /// `onSettingsChanged`, which exists so a shortened poll interval feels immediate. Neither has
    /// anything to do with polling, and calling it would spend a usage request on a preference.
    @objc private func toggleStatusWords() {
        Settings.showStatusWords.toggle()
        renderTitle()
    }

    @objc private func setAnimation(_ sender: NSMenuItem) {
        guard let style = sender.representedObject as? MenuBarAnimation else { return }
        Settings.menuBarAnimation = style
        renderTitle()
    }

    @objc private func toggleCheckForUpdates() {
        Settings.checkForUpdates.toggle()
        onCheckForUpdatesChanged?()
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
    private func usageRow(for window: LimitWindow) -> NSMenuItem {
        let id = window.id
        let row = UsageRow(window, mode: Settings.colorMode, forecast: forecast(for: window))
        let hosted = HostedRow(UsageRowView(row: row), title: row.spoken)
        liveRows.append(LiveRow { [weak self] in
            guard let self, let window = self.window(id: id) else { return }
            let row = UsageRow(window, mode: Settings.colorMode, forecast: self.forecast(for: window))
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
    private func errorRow() -> NSMenuItem {
        textRow { [weak self] in
            guard let self, let lastError = self.lastError else { return nil }
            return self.message(for: lastError)
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
        let title = { [weak self] in "Refresh Now (\(Fmt.age(of: self?.lastUpdated)))" }
        let item = action(title(), key: "r", selector: #selector(refreshClicked))
        liveRows.append(LiveRow { item.title = title() })
        return item
    }

    /// The window this row was built for, as it stands in the *latest* poll.
    ///
    /// Looking it up beats closing over the `LimitWindow`: a captured value made a held-open menu go
    /// on counting down to the reset of a window the poll had already replaced, reach "now", and
    /// stay pinned there until the menu was closed and reopened.
    ///
    /// Matched on `id`, the same key `Notifier.markerKey(for:)` uses — not on the display label,
    /// which is free to be restyled.
    private func window(id: String) -> LimitWindow? {
        windows.first { $0.id == id }
    }

    /// The plan's error copy, plus the "you're looking at old numbers" note that only makes sense
    /// when there are numbers on screen to be old.
    private func message(for error: Error) -> String {
        let description = (error as? UsageError)?.errorDescription
            ?? error.localizedDescription
        // Keyed on what is actually *on screen*, not on what is in memory: once `Freshness` drops the
        // rows, promising "showing data from…" would point at numbers that aren't there any more.
        guard !displayWindows().isEmpty, let lastUpdated else { return description }
        // `Fmt.stamp`, never `Fmt.clock` — see the note there. Clock renders a bare time for any past
        // date, so this line claimed a fifteen-day-old reading was from "4:44 AM".
        return "\(description) Showing data from \(Fmt.stamp(lastUpdated))."
    }

    // MARK: - Item builders

    /// Section headings for the Settings submenu only. The main panel's headings are drawn by
    /// `UsageRowView`; inside a submenu a dimmed heading is the conventional macOS look, and the
    /// rows it labels are real commands rather than data.
    private func header(_ text: String) -> NSMenuItem {
        let item = NSMenuItem()
        item.attributedTitle = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        item.isEnabled = false
        return item
    }

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
