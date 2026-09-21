import AppKit
import Foundation
import Testing

@testable import CashewCore

/// The dropdown's view model. `UsageRow` is a pure function of a `LimitWindow` and a clock, which is
/// what makes the panel testable at all — the views themselves need a running app, and
/// `MenuController` can't be constructed in a test (it creates a real status item).
@Suite struct UsagePanelTests {
    private let now = Date(timeIntervalSince1970: 1_785_600_000)

    private func window(_ utilization: Double, resetsIn seconds: TimeInterval?) -> LimitWindow {
        LimitWindow(kind: .primary, id: "session", label: "SESSION · 5-HOUR", shortLabel: "Session", optionLabel: "opt",
                    utilization: utilization,
                    resetsAt: seconds.map { now.addingTimeInterval($0) })
    }

    @Test func splitsTheResetTimeBetweenHeadingAndValueLine() {
        let row = UsageRow(window(5, resetsIn: 15_300), now: now, mode: .alertsOnly)
        #expect(row.header == "SESSION · 5-HOUR")
        #expect(row.value == "5%")
        #expect(row.trailing == "resets in 4h 15m")
        // The wall-clock time sits on the heading line; only its presence is asserted here, since
        // its formatting is the locale-dependent part and `FormatTests` covers that.
        #expect(!row.headerTrailing.isEmpty)
    }

    /// A window whose reset time the endpoint didn't give still renders — it just says so.
    @Test func aMissingResetTimeDegradesInBothPlaces() {
        let row = UsageRow(window(42, resetsIn: nil), now: now, mode: .alertsOnly)
        #expect(row.headerTrailing.isEmpty)
        #expect(row.trailing == "reset time unknown")
        #expect(row.value == "42%")
    }

    @Test(arguments: [(0.0, 0.0), (12.5, 0.125), (50.0, 0.5), (99.9, 0.999), (100.0, 1.0)])
    func fractionTracksUtilization(_ utilization: Double, _ expected: Double) {
        #expect(abs(UsageRow(window(utilization, resetsIn: 60), now: now, mode: .alertsOnly).fraction - expected) < 0.0001)
    }

    /// `Capsule` happily draws past its frame, so the bar clamps rather than trusting its input —
    /// the parser bounds utilization to 0–100, but a bar that can overflow its track is a rendering
    /// bug waiting for the one payload that gets through.
    @Test(arguments: [(-40.0, 0.0), (150.0, 1.0), (100.0001, 1.0)])
    func fractionIsClampedToTheTrack(_ utilization: Double, _ expected: Double) {
        #expect(UsageRow(window(utilization, resetsIn: 60), now: now, mode: .alertsOnly).fraction == expected)
    }

    /// `min`/`max` propagate NaN, so clamping alone doesn't catch it — a NaN would reach SwiftUI as
    /// an invalid frame width and the bar would silently vanish. `ClaudeProvider` can't produce one,
    /// but this is the view model for any future provider.
    @Test(arguments: [Double.nan, .infinity, -.infinity])
    func fractionSurvivesNonFiniteUtilization(_ utilization: Double) {
        let fraction = UsageRow(window(utilization, resetsIn: 60), now: now, mode: .alertsOnly).fraction
        #expect(fraction.isFinite)
        #expect((0...1).contains(fraction))
    }

    /// The percentage in the panel must agree with the one in the menu bar title, which rounds.
    @Test func percentageMatchesTheMenuBarTitle() {
        let row = UsageRow(window(79.6, resetsIn: 60), now: now, mode: .alertsOnly)
        #expect(row.value == "80%")
        #expect(row.value == Fmt.pct(79.6))
    }

    @Test func headingComesStraightFromTheWindowLabel() {
        let scoped = LimitWindow(kind: .secondaryScoped, id: "scoped:Fable",
                                 label: "WEEKLY · FABLE", shortLabel: "Weekly (Fable)", optionLabel: "opt",
                                 utilization: 16, resetsAt: now.addingTimeInterval(3_600))
        #expect(UsageRow(scoped, now: now, mode: .alertsOnly).header == "WEEKLY · FABLE")
    }

    /// The bar's colour is resolved in the view model, so it is covered by the same tests as the
    /// menu bar title rather than only being visible on screen.
    @Test func barColourFollowsTheMode() {
        #expect(UsageRow(window(20, resetsIn: 60), now: now, mode: .alertsOnly).barColor == Fmt.spark)
        #expect(UsageRow(window(85, resetsIn: 60), now: now, mode: .alertsOnly).barColor == .systemRed)
        // System mode is monochrome at every level, including one that would be red otherwise.
        #expect(UsageRow(window(20, resetsIn: 60), now: now, mode: .system).barColor
            == .secondaryLabelColor)
        #expect(UsageRow(window(85, resetsIn: 60), now: now, mode: .system).barColor
            == .secondaryLabelColor)
    }

    /// One sentence, used both as the VoiceOver label and as the menu item's `title` — the latter
    /// being what AppleScript reports, since a view-backed item draws no title of its own. Derived
    /// in one place so the two can't describe the same row differently.
    @Test func theSpokenFormCarriesTheWholeRow() {
        let spoken = UsageRow(window(5, resetsIn: 15_300), now: now, mode: .alertsOnly).spoken
        #expect(spoken.contains("SESSION · 5-HOUR"))
        #expect(spoken.contains("5%"))
        #expect(spoken.contains("resets in 4h 15m"))
    }

    /// Calm by design: the pace line exists only when you are actually on pace. A row that says
    /// something reassuring every ordinary day teaches you to stop reading it, and then it goes
    /// unread on the day it matters.
    @Test(arguments: [Forecast.underPace, .unknown])
    func onlyBeingOnPaceProducesAPaceLine(_ forecast: Forecast) {
        #expect(UsageRow(window(20, resetsIn: 3_600), now: now, mode: .alertsOnly,
                         forecast: forecast).pace == nil)
    }

    @Test func theDefaultRowHasNoPaceLine() {
        #expect(UsageRow(window(20, resetsIn: 3_600), now: now, mode: .alertsOnly).pace == nil)
    }

    @Test func beingOnPaceNamesTheProjectedTime() {
        let hit = now.addingTimeInterval(2 * 60 * 60)
        let row = UsageRow(window(20, resetsIn: 3_600), now: now, mode: .alertsOnly,
                           forecast: .onPace(hit))
        let pace = try? #require(row.pace)
        #expect(pace?.hasPrefix("On pace to hit the limit ~") == true)
        // The time itself comes from `Fmt.clock`, which `FormatTests` covers for locale and for the
        // weekday it adds past a day out — asserted by identity rather than by re-formatting here.
        #expect(pace?.hasSuffix(Fmt.clock(hit, from: now)) == true)
    }

    /// VoiceOver and AppleScript read `spoken`; a line that only exists visually would be invisible
    /// to exactly the users who most need the menu described to them.
    @Test func thePaceLineIsSpokenToo() {
        let row = UsageRow(window(20, resetsIn: 3_600), now: now, mode: .alertsOnly,
                           forecast: .onPace(now.addingTimeInterval(7_200)))
        #expect(row.spoken.contains("On pace to hit the limit"))
    }
}

/// A view-backed row has to re-measure when its content changes, and `HostedRow` is the only piece
/// of the menu that can be built in a test — it makes no status item and touches no window server.
///
/// Everything here is a *height* assertion at a fixed width. Absolute values are deliberately not
/// asserted: they move with the system font and the macOS version. What must hold is the relation —
/// a longer string at the same width needs more height, and the row has to actually take it.
///
/// `@MainActor` is load-bearing, not decoration. swift-testing runs suites concurrently, and the
/// first run of this one aborted every test with *"modifying the autolayout engine from a background
/// thread"* — building an `NSHostingController` reaches AppKit's layout engine, which is main-thread
/// only. The failure is a crash, not a test failure, so it takes the whole run down with it.
@Suite @MainActor struct HostedRowTests {
    /// The width the menu settles at, so the wrap matches what ships.
    private let width = PanelMetrics.textWrapWidth + PanelMetrics.horizontalPadding * 2

    private let oneLine = "Loading…"

    /// The real Keychain-denied copy, which is the string that exposed this.
    private let manyLines = """
        Keychain access was denied. Cashew needs permission to read the token Claude Code stored, \
        and macOS only asks once. Open Keychain Access, find "Claude Code-credentials", and allow it.
        """

    private func row(_ text: String) -> HostedRow<PanelTextView> {
        let hosted = HostedRow(PanelTextView(text: text), title: text)
        hosted.item.view?.frame.size.width = width
        hosted.fitHeight()
        return hosted
    }

    private func height(of hosted: HostedRow<PanelTextView>) -> CGFloat {
        hosted.item.view?.frame.height ?? 0
    }

    /// The bug: a row built around a short string, then handed a long one, kept its original height
    /// and clipped the rest away. Asserted against a row *built* with the long string rather than a
    /// hardcoded number, so this keeps meaning the same thing when the font or the copy changes.
    @Test func swappingInLongerTextGrowsTheRow() {
        let short = row(oneLine)
        let wanted = height(of: row(manyLines))

        #expect(wanted > height(of: short))  // guard: the two strings must differ in height at all

        short.update(PanelTextView(text: manyLines), title: manyLines)
        #expect(height(of: short) >= wanted)
    }

    /// And back down, or a row that once showed an error keeps a band of dead space under one line
    /// of "Loading…" forever.
    @Test func swappingBackToShorterTextShrinksIt() {
        let hosted = row(manyLines)
        let tall = height(of: hosted)
        hosted.update(PanelTextView(text: oneLine), title: oneLine)
        #expect(height(of: hosted) < tall)
    }

    /// `fittingSize` — what this used to size with — reports one line for the long string no matter
    /// how wide the row is, so a row *created* with the error was clipped before any swap happened.
    ///
    /// Deliberately does not go through `row(_:)`: that helper calls `fitHeight()` itself, which
    /// masks whether the initializer ever measured. Mutation-testing caught exactly that — deleting
    /// the `fitHeight()` call from `init` left the first version of this test passing.
    @Test func aRowCreatedWithLongTextIsNotBornClipped() {
        let short = HostedRow(PanelTextView(text: oneLine), title: oneLine)
        let long = HostedRow(PanelTextView(text: manyLines), title: manyLines)
        #expect((long.item.view?.frame.height ?? 0) > (short.item.view?.frame.height ?? 0))
    }

    /// Height must be measured at the width the menu gave the row, not at the row's natural width.
    /// Narrower wraps to more lines, so if this came back equal the measurement is ignoring width.
    @Test func heightIsMeasuredAtTheGivenWidth() {
        let narrow = HostedRow(PanelTextView(text: manyLines), title: manyLines)
        narrow.item.view?.frame.size.width = PanelMetrics.minimumWidth
        narrow.fitHeight()

        #expect(height(of: narrow) > height(of: row(manyLines)))
    }

    /// The usage rows go through the same path. Their height is constant today, so this asserts the
    /// path is wired rather than that anything grows — the point is that it can't silently stop being.
    @Test func usageRowsAreMeasuredToo() {
        let window = LimitWindow(kind: .primary, id: "session", label: "SESSION · 5-HOUR",
                                 shortLabel: "Session", optionLabel: "opt", utilization: 42,
                                 resetsAt: Date(timeIntervalSince1970: 1_785_600_000))
        let view = UsageRowView(row: UsageRow(window, now: Date(timeIntervalSince1970: 1_785_500_000),
                                              mode: .alertsOnly))
        let hosted = HostedRow(view, title: "row")
        #expect(hosted.item.view?.frame.height ?? 0 > 0)
    }
}

/// Which limits the menu bar title renders. Separate suite because these are the rules that are
/// awkward to reach by hand — a scope vanishing from the response, or all of them vanishing at once.
@Suite struct TitleSelectionTests {
    private func window(_ kind: LimitWindow.Kind, _ id: String) -> LimitWindow {
        LimitWindow(kind: kind, id: id, label: id, shortLabel: id, optionLabel: "opt",
                    utilization: 10, resetsAt: nil)
    }

    private var all: [LimitWindow] {
        [window(.primary, LimitWindow.sessionID),
         window(.secondary, LimitWindow.weeklyID),
         window(.secondaryScoped, "scoped:Fable")]
    }

    private func sections(_ windows: [LimitWindow]) -> [(provider: ProviderID, windows: [LimitWindow])] {
        [(provider: .claude, windows: windows)]
    }

    @Test func rendersOnlyTheSelectedLimits() {
        let shown = TitleSelection.windows(
            from: sections(all), selection: [ProviderID.claude.qualify(LimitWindow.sessionID)])
        #expect(shown.map(\.window.id) == [LimitWindow.sessionID])
    }

    /// Order comes from the response, not from the order the user ticked boxes in.
    @Test func keepsResponseOrderRegardlessOfSelection() {
        let shown = TitleSelection.windows(
            from: sections(all), selection: [ProviderID.claude.qualify("scoped:Fable"),
                                             ProviderID.claude.qualify(LimitWindow.sessionID),
                                             ProviderID.claude.qualify(LimitWindow.weeklyID)])
        #expect(shown.map(\.window.id) == [LimitWindow.sessionID, LimitWindow.weeklyID, "scoped:Fable"])
    }

    /// A scope the user picked that the response no longer reports is simply not rendered — no gap,
    /// no placeholder, and the stored preference is left alone elsewhere so it returns if it does.
    @Test func aVanishedScopeIsDroppedFromTheTitle() {
        let shown = TitleSelection.windows(
            from: sections(all), selection: [ProviderID.claude.qualify(LimitWindow.sessionID),
                                             ProviderID.claude.qualify("scoped:GoneAway")])
        #expect(shown.map(\.window.id) == [LimitWindow.sessionID])
    }

    /// Choosing nothing is not the same as choosing something that went missing, and this is the
    /// test that holds the two apart. An empty selection is a deliberate "no numbers, thanks" and
    /// is rendered literally; the fallback below exists for a selection that *was* made and can no
    /// longer be honoured. Collapsing them would make unchecking the last limit silently re-tick it.
    @Test func selectingNothingRendersNothing() {
        #expect(TitleSelection.windows(from: sections(all), selection: []).isEmpty)
    }

    /// Every selection missing must not render an empty title — the user asked for numbers and a
    /// stale scope list is no reason to show none of them.
    @Test func everySelectionMissingFallsBackToSession() {
        let shown = TitleSelection.windows(
            from: sections(all), selection: [ProviderID.claude.qualify("scoped:GoneAway"),
                                             ProviderID.claude.qualify("alsoGone")])
        #expect(shown.map(\.window.id) == [LimitWindow.sessionID])
    }

    /// …and if even the session window is absent, show whatever came first rather than nothing.
    @Test func withoutASessionWindowItFallsBackToTheFirstReported() {
        let weeklyOnly = [window(.secondary, LimitWindow.weeklyID)]
        #expect(TitleSelection.windows(from: sections(weeklyOnly),
                                       selection: [ProviderID.claude.qualify("nothing")]).map(\.window.id)
            == [LimitWindow.weeklyID])
    }

    @Test func nothingReportedRendersNothing() {
        #expect(TitleSelection.windows(
            from: sections([]), selection: [ProviderID.claude.qualify(LimitWindow.sessionID)]).isEmpty)
    }

    @Test func theDefaultSelectionSelectsBothHeadlineWindows() {
        // The integration nothing covered: Settings stores qualified ids, TitleSelection
        // receives unqualified windows. When these disagree the default silently collapses to
        // one window through the "everything chosen has gone missing" fallback, which looks
        // like a rendering choice rather than a bug.
        let all = [window(.primary, LimitWindow.sessionID),
                   window(.secondary, LimitWindow.weeklyID),
                   window(.secondaryScoped, "scoped:Fable")]
        let shown = TitleSelection.windows(from: sections(all),
                                           selection: Settings.defaultTitleLimitIDs)
        #expect(shown.map(\.window.id) == [LimitWindow.sessionID, LimitWindow.weeklyID])
    }

    /// The per-section-fallback trap. Claude's window is selected and present, so nothing is
    /// "missing" — Codex must contribute nothing, not its primary window. The two windows carry
    /// distinguishable labels rather than sharing every field, so the assertion can tell *whose*
    /// window came back rather than merely counting how many did — a count alone can't catch a
    /// per-section fallback that swaps Claude's window for Codex's same-shaped one.
    @Test func aSelectionFromOneProviderDoesNotPullInAnothersFallback() {
        let claudeWindow = LimitWindow(kind: .primary, id: LimitWindow.sessionID, label: "claude",
                                       shortLabel: "claude", optionLabel: "claude", utilization: 11,
                                       resetsAt: nil)
        let codexWindow = LimitWindow(kind: .primary, id: "session", label: "codex",
                                      shortLabel: "codex", optionLabel: "codex", utilization: 22,
                                      resetsAt: nil)
        let sections = [(provider: ProviderID.claude, windows: [claudeWindow]),
                        (provider: ProviderID.codex, windows: [codexWindow])]
        let shown = TitleSelection.windows(
            from: sections, selection: [ProviderID.claude.qualify(LimitWindow.sessionID)])
        #expect(shown.map(\.window.label) == ["claude"])
    }

    @Test func selectionCarriesEachWindowsProvider() {
        // A bare LimitWindow cannot say which product it came from, so the title could not mark it
        // and LIMITS SHOWN had to guess by value equality.
        let sections = [(provider: ProviderID.claude, windows: [window(.primary, "session")]),
                        (provider: ProviderID.codex, windows: [window(.primary, "primary")])]
        let shown = TitleSelection.windows(
            from: sections,
            selection: [ProviderID.claude.qualify("session"), ProviderID.codex.qualify("primary")])
        #expect(shown.map(\.provider) == [.claude, .codex])
        #expect(shown.map(\.window.id) == ["session", "primary"])
    }

    @Test func theGlyphAppearsOnlyWhenMoreThanOneProviderIsShown() {
        // The rule the user picked: a single-provider title is exactly today's title.
        #expect(TitleGlyphs.needed(for: [.claude]) == false)
        #expect(TitleGlyphs.needed(for: [.claude, .claude]) == false)
        #expect(TitleGlyphs.needed(for: [.claude, .codex]))
    }

    @Test func everyProviderHasADistinctGlyph() {
        // Two providers sharing a glyph would be worse than none — it would look like one product.
        let glyphs = ProviderID.allCases.map(\.titleGlyph)
        #expect(Set(glyphs).count == glyphs.count)
        #expect(glyphs.allSatisfy { !$0.isEmpty })
    }
}

/// Which provider sections the dropdown draws, and whether they need naming. Separate suite because
/// `MenuController` can't be constructed in a test, so this rule — free-standing on purpose — is the
/// only place these cases are reachable.
@Suite struct ProviderSectionTests {
    // Fixed, and matched to `snapshot`'s `updatedAt` below: `PanelSections.rows` defaults `now` to
    // the real `Date()`, and `Freshness.maxAge` is 24 hours, so calling it with the real clock
    // against a fixture stamped at a fixed instant would filter every snapshot as stale no matter
    // which real day the suite runs on — making these pass (or fail) for the wrong reason.
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func snapshot(_ provider: ProviderID, _ ids: [String]) -> ProviderSnapshot {
        ProviderSnapshot(
            provider: provider,
            windows: ids.map {
                LimitWindow(kind: .primary, id: $0, label: $0.uppercased(), shortLabel: $0,
                            optionLabel: $0, utilization: 10, resetsAt: nil)
            },
            updatedAt: now, failure: nil)
    }

    // These three ask `rows(...)` whether a heading was planned rather than asking a predicate
    // whether one was needed. The predicate existed, agreed with them, and was called by nothing:
    // `rows` had come to compute the same `count > 1` inline, so all three passed no matter what
    // the dropdown actually drew.

    @Test func oneProviderGetsNoHeading() {
        // Today's menu, unchanged. A "CLAUDE" heading above the only section would be a visible
        // change in a refactor that is supposed to have none.
        let rows = PanelSections.rows(for: [snapshot(.claude, ["session"])], now: now)
        #expect(!rows.contains { if case .heading = $0 { return true } else { return false } })
    }

    @Test func twoProvidersGetHeadings() {
        let rows = PanelSections.rows(for: [snapshot(.claude, ["session"]),
                                            snapshot(.codex, ["session"])], now: now)
        #expect(rows.contains(.heading(.claude)))
        #expect(rows.contains(.heading(.codex)))
    }

    @Test func aProviderWithNothingToShowIsNotASection() {
        // An empty snapshot must not count towards "more than one", or a Codex provider that is
        // present but reporting nothing would put a heading above Claude for no reason.
        let empty = ProviderSnapshot(provider: .codex, windows: [], updatedAt: nil, failure: nil)
        let rows = PanelSections.rows(for: [snapshot(.claude, ["session"]), empty], now: now)
        #expect(!rows.contains { if case .heading = $0 { return true } else { return false } })
        #expect(!rows.contains(.separator))
    }

    @Test func headingsNameTheProvider() {
        #expect(ProviderID.claude.sectionHeading == "CLAUDE")
        #expect(ProviderID.codex.sectionHeading == "CODEX")
    }

    // MARK: - Row plan

    /// The baseline: one provider, no failure, today's menu exactly — and all three of its rows.
    ///
    /// Three windows and not one, because one window cannot tell a missing separator from a
    /// spurious one. `SESSION`, `WEEKLY · ALL MODELS` and `WEEKLY · FABLE` run together with
    /// nothing between them, which is the shape this whole refactor exists to leave alone; a
    /// separator inserted between a section's own usage rows would pass every single-window
    /// fixture here and make three windows look like three unrelated panels stacked up.
    @Test func oneProviderWithWindowsProducesNoHeadingAndNoSeparator() {
        let single = snapshot(.claude, ["session", "weekly", "scoped:Fable"])
        let rows = PanelSections.rows(for: [single], now: now)
        #expect(rows == [.usage(.claude, single.windows[0]),
                         .usage(.claude, single.windows[1]),
                         .usage(.claude, single.windows[2])])
        #expect(rows.count == 3)
    }

    /// Pins the regression: a provider whose numbers are still on screen but whose last poll
    /// failed gets a separator before its error row, not the error text butted straight against
    /// the usage rows. Lost once already when the ordering rule lived inline in `rebuild()`.
    @Test func aFailureAfterWindowsGetsASeparatorBeforeTheErrorRow() {
        let failed = ProviderSnapshot(provider: .claude, windows: snapshot(.claude, ["session"]).windows,
                                      updatedAt: now, failure: UsageError.badResponse)
        let rows = PanelSections.rows(for: [failed], now: now)
        #expect(rows == [.usage(.claude, failed.windows[0]), .separator, .error(.claude)])
    }

    @Test func twoProvidersProduceHeadingRowsSeparatorHeadingRows() {
        let claude = snapshot(.claude, ["session"])
        let codex = snapshot(.codex, ["session"])
        let rows = PanelSections.rows(for: [claude, codex], now: now)
        #expect(rows == [.heading(.claude), .usage(.claude, claude.windows[0]),
                         .separator,
                         .heading(.codex), .usage(.codex, codex.windows[0])])
    }

    /// A provider that has nothing but a failure — no windows ever came back, or none survived
    /// `Freshness` — still gets its error row. There is no data above it to separate from, so no
    /// separator precedes it.
    @Test func aFailureWithNoDisplayableWindowsStillProducesItsErrorRow() {
        let failedEmpty = ProviderSnapshot(provider: .codex, windows: [], updatedAt: nil,
                                           failure: UsageError.badResponse)
        let rows = PanelSections.rows(for: [failedEmpty], now: now)
        #expect(rows == [.error(.codex)])
    }
}
