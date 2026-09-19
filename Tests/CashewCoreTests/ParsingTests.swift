import Foundation
import Testing

@testable import CashewCore

/// Parsing of the usage endpoint. This is the highest-value suite in the project: the endpoint is
/// undocumented, has already grown a second response shape alongside the original, and every field
/// here is a guess that Anthropic can change without warning.
///
/// Fixtures are JSON text rather than Swift dictionaries so values arrive as the `NSNumber`s
/// `JSONSerialization` actually produces — the same door the real response comes through.
@Suite struct ParsingTests {
    /// Parses through the identical path `ClaudeProvider.fetch` uses.
    private func windows(_ json: String) throws -> [LimitWindow] {
        let data = try #require(json.data(using: .utf8))
        let object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return ClaudeProvider.windows(in: object)
    }

    // MARK: - The current shape

    /// The response as it looks today: a `limits` array carrying all three windows, with the legacy
    /// keys still present alongside and `seven_day_opus` explicitly null.
    static let current = #"""
    {
      "five_hour":      {"utilization": 3.0, "resets_at": "2026-08-02T16:39:59.408408+00:00"},
      "seven_day":      {"utilization": 13.0, "resets_at": "2026-08-04T13:59:59.408434+00:00"},
      "seven_day_opus": null,
      "tangelo": null,
      "limits": [
        {"kind": "session",       "percent": 42,   "resets_at": "2026-08-02T16:39:59.408408+00:00", "scope": null},
        {"kind": "weekly_all",    "percent": 57.3, "resets_at": "2026-08-04T13:59:59.408434+00:00", "scope": null},
        {"kind": "weekly_scoped", "percent": 61,   "resets_at": "2026-08-04T14:00:00.408749+00:00",
         "scope": {"model": {"id": null, "display_name": "Fable"}, "surface": null}}
      ],
      "member_dashboard_available": false
    }
    """#

    @Test func currentShapeYieldsThreeWindows() throws {
        let result = try windows(Self.current)
        #expect(result.count == 3)
        #expect(result.map(\.kind) == [.session, .weekly, .weeklyScoped])
        #expect(result.map(\.utilization) == [42, 57.3, 61])
    }

    @Test func labelsComeFromTheProvider() throws {
        let result = try windows(Self.current)
        #expect(result[0].label == "SESSION · 5-HOUR")
        #expect(result[0].shortLabel == "Session")
        #expect(result[1].label == "WEEKLY · ALL MODELS")
        #expect(result[1].shortLabel == "Weekly")
    }

    /// The reason for reading `limits[]` at all: the scoped window names its own model, so the app
    /// doesn't hardcode "Opus" and silently mislabel a different one.
    @Test func scopedLabelUsesTheReportedModelName() throws {
        let result = try windows(Self.current)
        #expect(result[2].label == "WEEKLY · FABLE")
        #expect(result[2].shortLabel == "Weekly (Fable)")
        // The Show in Menu Bar row is the provider's copy too, so a model is offered by its own
        // name. Mutating this to a constant otherwise passes every test while every scoped row in
        // that submenu silently reads the same.
        #expect(result[2].optionLabel == "Fable")
        #expect(result[0].optionLabel == "Session (5h)")
        #expect(result[1].optionLabel == "Weekly (all models)")
    }

    /// Integer and fractional `percent` take different branches of `number(_:)`.
    @Test func acceptsIntegerAndFractionalPercent() throws {
        let result = try windows(Self.current)
        #expect(result[0].utilization == 42)    // JSON integer
        #expect(result[1].utilization == 57.3)  // JSON fraction
    }

    @Test func parsesFractionalSecondsAndOffsetTimestamps() throws {
        let result = try windows(Self.current)
        let resetsAt = try #require(result[0].resetsAt)
        // ISO8601DateFormatter truncates to milliseconds, so compare with tolerance.
        #expect(abs(resetsAt.timeIntervalSince1970 - 1_785_688_799.408408) < 0.001)
    }

    @Test func parsesTimestampsWithoutFractionalSeconds() throws {
        let result = try windows(#"""
        {"limits": [{"kind": "session", "percent": 10, "resets_at": "2026-08-02T16:39:59Z"}]}
        """#)
        #expect(try #require(result.first?.resetsAt).timeIntervalSince1970 == 1_785_688_799)
    }

    @Test func acceptsNumericEpochTimestamps() throws {
        let result = try windows(#"""
        {"limits": [{"kind": "session", "percent": 10, "resets_at": 1785688799}]}
        """#)
        #expect(try #require(result.first?.resetsAt).timeIntervalSince1970 == 1_785_688_799)
    }

    @Test func multipleScopedWindowsAllSurviveInOrder() throws {
        let result = try windows(#"""
        {"limits": [
          {"kind": "weekly_scoped", "percent": 20, "scope": {"model": {"display_name": "Opus"}}},
          {"kind": "weekly_scoped", "percent": 30, "scope": {"model": {"display_name": "Sonnet"}}}
        ]}
        """#)
        #expect(result.map(\.id) == ["scoped:Opus", "scoped:Sonnet"])
    }

    /// `id` is what the menu matches rows on and what alert markers key off, and it is derived from
    /// a server-controlled name. Two scoped entries sharing a display name must not collapse into
    /// one identity — both rows would otherwise render the first window's numbers.
    @Test func duplicateModelNamesStillGetDistinctIdentities() throws {
        let result = try windows(#"""
        {"limits": [
          {"kind": "weekly_scoped", "percent": 20, "scope": {"model": {"display_name": "Opus"}}},
          {"kind": "weekly_scoped", "percent": 30, "scope": {"model": {"display_name": "Opus"}}}
        ]}
        """#)
        #expect(result.count == 2)
        #expect(Set(result.map(\.id)).count == 2)
        #expect(result.map(\.utilization) == [20, 30])
    }

    /// The nastier version: a model genuinely named "Opus#2" collides with the id the uniquifier
    /// would *generate* for a second "Opus". Counting occurrences isn't enough — the suffix has to be
    /// checked against what has actually been emitted, or the pass produces the duplicate it exists
    /// to prevent, and two rows share a title checkbox, an alert marker and a set of numbers.
    @Test func aGeneratedIdCannotCollideWithARealModelName() throws {
        let result = try windows(#"""
        {"limits": [
          {"kind": "weekly_scoped", "percent": 20, "scope": {"model": {"display_name": "Opus"}}},
          {"kind": "weekly_scoped", "percent": 30, "scope": {"model": {"display_name": "Opus"}}},
          {"kind": "weekly_scoped", "percent": 40, "scope": {"model": {"display_name": "Opus#2"}}}
        ]}
        """#)
        #expect(result.count == 3)
        #expect(Set(result.map(\.id)).count == 3)
        #expect(result.map(\.utilization) == [20, 30, 40])
    }

    /// The dropdown renders in array order, so scoped windows must always trail the two headline
    /// ones even when the endpoint lists them first.
    @Test func returnOrderIsSessionThenWeeklyThenScoped() throws {
        let result = try windows(#"""
        {"limits": [
          {"kind": "weekly_scoped", "percent": 30, "scope": {"model": {"display_name": "Opus"}}},
          {"kind": "weekly_all", "percent": 20},
          {"kind": "session", "percent": 10}
        ]}
        """#)
        #expect(result.map(\.kind) == [.session, .weekly, .weeklyScoped])
    }

    @Test func weeklyLeadsWhenSessionIsAbsent() throws {
        let result = try windows(#"""
        {"limits": [{"kind": "weekly_all", "percent": 20}]}
        """#)
        #expect(result.map(\.kind) == [.weekly])
    }

    // MARK: - The legacy shape

    static let legacy = #"""
    {
      "five_hour":      {"utilization": 42, "resets_at": "2026-08-02T16:39:59Z"},
      "seven_day":      {"utilization": 67.5, "resets_at": "2026-08-05T09:00:00Z"},
      "seven_day_opus": {"utilization": 91, "resets_at": "2026-08-05T09:00:00Z"}
    }
    """#

    @Test func legacyOnlyResponseStillWorks() throws {
        let result = try windows(Self.legacy)
        #expect(result.count == 3)
        #expect(result.map(\.kind) == [.session, .weekly, .weeklyScoped])
        #expect(result.map(\.utilization) == [42, 67.5, 91])
        #expect(result[2].id == "scoped:Opus")
    }

    /// Three ways `limits` can be useless. Each must fall through to the legacy keys rather than
    /// producing an empty menu.
    @Test(arguments: ["[]", "null", #"{"kind": "session"}"#, #""nope""#])
    func unusableLimitsFallsBackToLegacy(_ limits: String) throws {
        let result = try windows(#"""
        {
          "limits": \#(limits),
          "five_hour": {"utilization": 5},
          "seven_day": {"utilization": 6},
          "seven_day_opus": {"utilization": 7}
        }
        """#)
        #expect(result.map(\.utilization) == [5, 6, 7])
    }

    // MARK: - Both shapes present

    @Test func arrayWinsOverLegacyAndRowsAreNotDuplicated() throws {
        let result = try windows(#"""
        {
          "five_hour": {"utilization": 1},
          "seven_day": {"utilization": 2},
          "seven_day_opus": {"utilization": 3},
          "limits": [
            {"kind": "session", "percent": 10},
            {"kind": "weekly_all", "percent": 20},
            {"kind": "weekly_scoped", "percent": 30, "scope": {"model": {"display_name": "Fable"}}}
          ]
        }
        """#)
        #expect(result.count == 3)
        #expect(result.map(\.utilization) == [10, 20, 30])
    }

    /// The fallback is per field, not all-or-nothing — this is the contract, and the mixed case is
    /// the one a refactor flattens.
    @Test func fallbackFillsOnlyWhatTheArrayOmitted() throws {
        let result = try windows(#"""
        {
          "five_hour": {"utilization": 1},
          "seven_day": {"utilization": 2},
          "seven_day_opus": {"utilization": 3},
          "limits": [{"kind": "session", "percent": 10}]
        }
        """#)
        #expect(result.map(\.utilization) == [10, 2, 3])
        #expect(result[2].id == "scoped:Opus")
    }

    /// Scoped fallback is all-or-nothing by design: one scoped entry from the array suppresses the
    /// legacy Opus row rather than showing both.
    @Test func oneScopedEntrySuppressesTheLegacyOpusRow() throws {
        let result = try windows(#"""
        {
          "seven_day_opus": {"utilization": 3},
          "limits": [{"kind": "weekly_scoped", "percent": 30, "scope": {"model": {"display_name": "Fable"}}}]
        }
        """#)
        #expect(result.count == 1)
        #expect(result[0].id == "scoped:Fable")
    }

    /// A scoped entry the array *dropped* leaves `scoped` empty, so the legacy row reappears.
    @Test func droppedScopedEntryLetsTheLegacyOpusRowThrough() throws {
        let result = try windows(#"""
        {
          "seven_day_opus": {"utilization": 3},
          "limits": [{"kind": "weekly_scoped", "percent": null, "scope": {"model": {"display_name": "Fable"}}}]
        }
        """#)
        #expect(result.map(\.id) == ["scoped:Opus"])
    }

    // MARK: - Drift and malformed payloads

    /// Regression for the bug where a single unrecognized element discarded the entire array.
    /// Adding one new entry shape is the most likely way this endpoint drifts next, and it must
    /// cost that one row rather than every row.
    @Test func oneJunkArrayElementDoesNotDiscardTheRest() throws {
        let result = try windows(#"""
        {"limits": [
          {"kind": "session", "percent": 42},
          "garbage",
          {"kind": "weekly_all", "percent": 13}
        ]}
        """#)
        #expect(result.map(\.utilization) == [42, 13])
    }

    @Test func unknownKindIsIgnoredWithoutAffectingOthers() throws {
        let result = try windows(#"""
        {"limits": [
          {"kind": "monthly_all", "percent": 99},
          {"kind": "session", "percent": 42}
        ]}
        """#)
        #expect(result.map(\.kind) == [.session])
    }

    /// Kinds are matched case-sensitively. Documented so the choice is deliberate.
    @Test func kindMatchingIsCaseSensitive() throws {
        #expect(try windows(#"{"limits": [{"kind": "Session", "percent": 42}]}"#).isEmpty)
    }

    /// An unusable `percent` drops the row: showing a window without its number would be worse than
    /// not showing it.
    @Test(arguments: ["null", #""85""#, "true", "{}"])
    func unusablePercentDropsTheRow(_ percent: String) throws {
        let result = try windows(#"""
        {"limits": [{"kind": "session", "percent": \#(percent)}]}
        """#)
        #expect(result.isEmpty)
    }

    @Test func missingPercentDropsTheRow() throws {
        #expect(try windows(#"{"limits": [{"kind": "session"}]}"#).isEmpty)
    }

    /// The asymmetry that matters: an unusable *timestamp* keeps the row. The percentage is the
    /// point of the app; the reset time degrades to "Reset time unknown".
    @Test(arguments: ["null", #""not-a-date""#, #""2026-08-02T16:39:59""#, "false"])
    func unusableTimestampKeepsTheRow(_ resetsAt: String) throws {
        let result = try windows(#"""
        {"limits": [{"kind": "session", "percent": 42, "resets_at": \#(resetsAt)}]}
        """#)
        #expect(result.count == 1)
        #expect(result[0].utilization == 42)
        #expect(result[0].resetsAt == nil)
    }

    /// Every link of the `scope.model.display_name` chain can be missing independently — and an
    /// empty or blank name is as unusable as a missing one. It used to render "THIS WEEK ()".
    @Test(arguments: ["", #", "scope": null"#, #", "scope": {}"#,
                      #", "scope": {"model": null}"#, #", "scope": {"model": {}}"#,
                      #", "scope": {"model": {"display_name": null}}"#,
                      #", "scope": {"model": {"display_name": ""}}"#,
                      #", "scope": {"model": {"display_name": "   "}}"#,
                      #", "scope": {"model": {"display_name": 42}}"#])
    func unusableScopeFallsBackToAGenericLabel(_ scope: String) throws {
        let result = try windows(#"""
        {"limits": [{"kind": "weekly_scoped", "percent": 30\#(scope)}]}
        """#)
        #expect(result.map(\.id) == ["scoped:scoped"])
    }

    /// The model name is server-controlled and ends up in a menu label, a notification title, and a
    /// `UserDefaults` key, so it is bounded rather than trusted.
    @Test func aRidiculousModelNameIsBounded() throws {
        let huge = String(repeating: "A", count: 5_000)
        let result = try windows(#"""
        {"limits": [{"kind": "weekly_scoped", "percent": 30,
                     "scope": {"model": {"display_name": "\#(huge)"}}}]}
        """#)
        #expect(try #require(result.first).label.count < 100)
    }

    @Test func aModelNameWithNewlinesIsFlattened() throws {
        let result = try windows(#"""
        {"limits": [{"kind": "weekly_scoped", "percent": 30,
                     "scope": {"model": {"display_name": "Opus\n4.5"}}}]}
        """#)
        #expect(result.map(\.id) == ["scoped:Opus 4.5"])
    }

    /// Regression: `Fmt.pct` converts to Int, and converting a Double to Int traps on a value past
    /// Int's range. A hostile or garbled percentage must not crash the menu bar.
    @Test(arguments: [("1e30", 100.0), ("-5", 0.0), ("150", 100.0), ("99.4", 99.4)])
    func outOfRangePercentIsClampedNotTrapped(_ input: String, _ expected: Double) throws {
        let result = try windows(#"""
        {"limits": [{"kind": "session", "percent": \#(input)}]}
        """#)
        #expect(result.first?.utilization == expected)
        _ = Fmt.pct(result.first?.utilization)  // Would trap before the clamp.
    }

    @Test func absurdEpochTimestampIsRejected() throws {
        let result = try windows(#"""
        {"limits": [{"kind": "session", "percent": 42, "resets_at": 1e30}]}
        """#)
        #expect(result.count == 1)
        #expect(result[0].resetsAt == nil)
    }

    // MARK: - Nothing at all

    /// An API-key account has no plan quota. Empty is a legitimate answer, not an error.
    @Test(arguments: ["{}", #"{"limits": []}"#, #"{"five_hour": null, "seven_day": null}"#])
    func nothingToReportYieldsNoWindows(_ json: String) throws {
        #expect(try windows(json).isEmpty)
    }

    @Test func unknownTopLevelKeysAreIgnored() throws {
        let result = try windows(#"""
        {
          "brand_new_feature": {"nested": [1, 2, 3]},
          "limits": [{"kind": "session", "percent": 42, "future_field": "ignored"}]
        }
        """#)
        #expect(result.map(\.utilization) == [42])
    }

    /// Later entries win. Pinned deliberately so the behaviour is a decision, not an accident.
    @Test func duplicateKindKeepsTheLastEntry() throws {
        let result = try windows(#"""
        {"limits": [
          {"kind": "session", "percent": 10},
          {"kind": "session", "percent": 20}
        ]}
        """#)
        #expect(result.map(\.utilization) == [20])
    }
}
