import Foundation
import Security
import Testing

@testable import CashewCore

/// Only the pure parts: `candidate(in:source:)` and `resolve(file:keychain:)`.
///
/// Every token below is a made-up string. Nothing here reads the credentials file or the Keychain —
/// those paths reach the developer's real login, and `#expect` prints compared values into CI logs
/// on failure, so a test that touched a live token would print it there.
@Suite struct CredentialsTests {
    private let sample = Credentials.Candidate(token: "t", expiresAtMillis: nil,
                                               isOverride: false, source: .file)

    private func candidate(_ string: String,
                           _ source: Credentials.Source = .file) throws -> Credentials.Candidate? {
        Credentials.candidate(in: try #require(string.data(using: .utf8)), source: source)
    }

    // MARK: - Reading one store

    @Test func readsTheTokenFromClaudeCodesJSON() throws {
        let json = #"{"claudeAiOauth": {"accessToken": "fake-token-value", "expiresAt": 1785700579842}}"#
        let parsed = try #require(try candidate(json))
        #expect(parsed.token == "fake-token-value")
        #expect(parsed.isOverride == false)
    }

    /// Milliseconds, kept as a raw number. Claude Code writes `Date.now() + expires_in * 1000`, so a
    /// real value has 13 digits; read as seconds it would land in the year 58,000.
    @Test func keepsExpiryAsRawMilliseconds() throws {
        let json = #"{"claudeAiOauth": {"accessToken": "fake", "expiresAt": 1785700579842}}"#
        #expect(try #require(try candidate(json)).expiresAtMillis == 1_785_700_579_842)
    }

    /// A JSON boolean bridges to NSNumber and satisfies `as? Double`, so without the guard `true`
    /// would rank as an expiry of 1.0 rather than as no expiry at all.
    @Test(arguments: ["true", "false", #""1785700579842""#, "null", "0", "-5"])
    func rejectsUnusableExpiryValues(_ value: String) throws {
        let json = #"{"claudeAiOauth": {"accessToken": "fake", "expiresAt": \#(value)}}"#
        #expect(try #require(try candidate(json)).expiresAtMillis == nil)
    }

    @Test func ignoresTheOtherFieldsAlongsideIt() throws {
        let json = #"""
        {"claudeAiOauth": {"refreshToken": "fake-refresh", "accessToken": "fake-access",
         "scopes": ["user:inference"], "subscriptionType": "max"}, "trustedDeviceToken": "fake-device"}
        """#
        #expect(try #require(try candidate(json)).token == "fake-access")
    }

    /// Claude Code always writes the envelope, so a naked token is a human override.
    @Test func acceptsABareTokenAndMarksItAnOverride() throws {
        let parsed = try #require(try candidate("fake-bare-token"))
        #expect(parsed.token == "fake-bare-token")
        #expect(parsed.isOverride)
        #expect(parsed.expiresAtMillis == nil)
    }

    @Test func trimsSurroundingWhitespace() throws {
        #expect(try #require(try candidate("  fake-bare-token\n")).token == "fake-bare-token")
    }

    /// The `hasPrefix("{")` guard earns its keep here: without it, JSON that failed the structured
    /// parse would be handed back whole and sent as a bearer token.
    @Test(arguments: [
        #"{"claudeAiOauth": {}}"#,
        #"{"claudeAiOauth": {"accessToken": ""}}"#,
        #"{"claudeAiOauth": {"accessToken": 42}}"#,
        #"{"someOtherApp": {"accessToken": "fake"}}"#,
        #"{"claudeAiOauth": "not-an-object"}"#,
        #"{"unclosed": "#,
        "", "   ", "\n\t ",
    ])
    func refusesPayloadsWithNoUsableToken(_ payload: String) throws {
        #expect(try candidate(payload) == nil)
    }

    @Test func refusesBytesThatAreNotText() {
        #expect(Credentials.candidate(in: Data([0xFF, 0xFE, 0x00, 0x80]), source: .file) == nil)
    }

    // MARK: - Choosing between the two stores

    private func envelope(_ token: String, expires: Double?) -> String {
        let expiry = expires.map { "\($0)" } ?? "null"
        return #"{"claudeAiOauth": {"accessToken": "\#(token)", "expiresAt": \#(expiry)}}"#
    }

    private func found(_ token: String, expires: Double?,
                       _ source: Credentials.Source) throws -> Credentials.Outcome {
        .found(try #require(try candidate(envelope(token, expires: expires), source)))
    }

    /// The bug this whole redesign exists for: choosing on *presence* let a stale credentials file
    /// shadow a live Keychain token forever, with the menu advising a fix that could never work.
    @Test func theLongerLivedCredentialWins() throws {
        let stale = try found("stale-file", expires: 1_000_000_000_000, .file)
        let live = try found("live-keychain", expires: 1_785_700_579_842, .keychain)
        #expect(try Credentials.resolve(file: stale, keychain: live).get() == "live-keychain")
        // …and the same regardless of which store happens to hold the fresher one.
        let freshFile = try found("fresh-file", expires: 1_785_700_579_842, .file)
        let oldKeychain = try found("old-keychain", expires: 1_000_000_000_000, .keychain)
        #expect(try Credentials.resolve(file: freshFile, keychain: oldKeychain).get() == "fresh-file")
    }

    /// Matches Claude Code's own precedence, which reads the Keychain first.
    @Test func theKeychainWinsATie() throws {
        let file = try found("file", expires: 1_785_700_579_842, .file)
        let keychain = try found("keychain", expires: 1_785_700_579_842, .keychain)
        #expect(try Credentials.resolve(file: file, keychain: keychain).get() == "keychain")
    }

    @Test func aCredentialWithAnExpiryBeatsOneWithout() throws {
        let noExpiry = try found("no-expiry", expires: nil, .file)
        let dated = try found("dated", expires: 1_785_700_579_842, .keychain)
        #expect(try Credentials.resolve(file: noExpiry, keychain: dated).get() == "dated")
    }

    /// A bare token is something a human deliberately put there, so it outranks even a live login.
    @Test func aBareTokenOverridesEverything() throws {
        let override = Credentials.Outcome.found(try #require(try candidate("fake-override", .file)))
        let live = try found("live-keychain", expires: 1_785_700_579_842, .keychain)
        #expect(try Credentials.resolve(file: override, keychain: live).get() == "fake-override")
    }

    @Test func usesWhicheverStoreHasSomething() throws {
        let only = try found("only", expires: nil, .keychain)
        #expect(try Credentials.resolve(file: .absent, keychain: only).get() == "only")
        let onlyFile = try found("only-file", expires: nil, .file)
        #expect(try Credentials.resolve(file: onlyFile, keychain: .absent).get() == "only-file")
    }

    @Test func nothingAnywhereIsNotFound() {
        #expect(Credentials.resolve(file: .absent, keychain: .absent) == .failure(.notFound))
    }

    /// "Access denied" must never be reported as "you've never signed in" — the advice differs, and
    /// on a Keychain-only Mac denial is the *only* way the read fails.
    @Test func denialIsReportedAsDenialNotAbsence() {
        #expect(Credentials.resolve(file: .absent, keychain: .accessDenied) == .failure(.accessDenied))
        #expect(Credentials.resolve(file: .accessDenied, keychain: .absent) == .failure(.accessDenied))
        #expect(Credentials.resolve(file: .accessDenied, keychain: .accessDenied)
            == .failure(.accessDenied))
    }

    /// A usable credential anywhere beats a denial elsewhere — no reason to bother the user.
    @Test func aUsableCredentialOutranksADenial() throws {
        let usable = try found("usable", expires: nil, .file)
        #expect(try Credentials.resolve(file: usable, keychain: .accessDenied).get() == "usable")
    }

    // MARK: - Presence, without reading either store

    @Test func presenceIsTrueWhenEitherStoreHasSomething() {
        #expect(Credentials.exists(file: .absent, keychain: .absent) == false)
        #expect(Credentials.exists(file: .found(sample), keychain: .absent))
        #expect(Credentials.exists(file: .absent, keychain: .found(sample)))
    }

    @Test func aDeniedKeychainStillCountsAsPresent() {
        // Denial means there is something there we were refused, which is the opposite of absent.
        // Treating it as absent would hide the provider and with it the one error message that
        // tells the user how to fix it.
        #expect(Credentials.exists(file: .absent, keychain: .accessDenied))
    }

    /// The probe's query, read rather than run: asking for the item's *data* would evaluate its
    /// decrypt ACL, and Claude Code creates its item without `-A`/`-T`, so securityd would put a
    /// modal permission prompt on screen — on the main thread, at every launch, for the one item
    /// every Keychain-only user has. A discovery check that prompts is worse than no discovery at
    /// all, and until this test the rule was only ever a comment.
    ///
    /// Reading the dictionary is not calling the probe: nothing here reaches `SecItemCopyMatching`
    /// or any real login.
    @Test func thePresenceProbeAsksForAttributesAndNeverForData() {
        let query = Credentials.keychainPresenceQuery
        #expect(query[kSecReturnData as String] == nil)
        #expect(query[kSecReturnAttributes as String] as? Bool == true)
        // The rest of the shape, so a query that stopped being a presence check — asking for every
        // match, or for the wrong class — is caught by the same test.
        #expect(query[kSecClass as String] as? String == kSecClassGenericPassword as String)
        #expect(query[kSecMatchLimit as String] as? String == kSecMatchLimitOne as String)
        #expect(query[kSecReturnRef as String] == nil)
        #expect(query[kSecReturnPersistentRef as String] == nil)
    }
}
