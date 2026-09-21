import Foundation
import CashewShared
import Security

/// Finds the OAuth token Claude Code already holds, so Cashew needs no setup of its own.
///
/// Nothing in this file logs, prints, caches, or persists the token. It is read on demand,
/// handed to a single request, and dropped. Keep it that way — see the guardrails in CLAUDE.md.
enum Credentials {
    /// Note the ordering: the Keychain outranks the file on a tie, matching Claude Code's own
    /// precedence (it reads the Keychain first and treats the file as a fallback).
    enum Source: Int {
        case file = 0
        case keychain = 1
    }

    struct Candidate: Equatable {
        let token: String

        /// MILLISECONDS since 1970, exactly as Claude Code writes it — its own code is
        /// `expiresAt: Date.now() + expires_in * 1000`, and a real value here has 13 digits.
        /// Deliberately never converted to a `Date`: the unit belongs to a vendor we don't control,
        /// and ordering two of them is the only thing we ever do with it. Read as seconds it would
        /// land in the year 58,000.
        let expiresAtMillis: Double?

        /// The bare-token form. Claude Code always writes the `claudeAiOauth` envelope, so a naked
        /// token in the file is a human deliberately pointing Cashew somewhere — it outranks
        /// everything rather than silently losing for having no expiry.
        let isOverride: Bool

        let source: Source
    }

    enum Outcome: Equatable {
        /// Nothing usable here — no file, no Keychain item, or contents we can't make sense of.
        case absent
        /// Something is here and macOS refused to hand it over.
        case accessDenied
        case found(Candidate)

        var candidate: Candidate? {
            if case .found(let candidate) = self { return candidate }
            return nil
        }
    }

    enum Failure: Error, Equatable {
        case notFound
        case accessDenied
    }

    private static let credentialsPath = "~/.claude/.credentials.json"

    /// Claude Code writes the same JSON blob under this service name in the login Keychain.
    ///
    /// Both this and the path above change when `CLAUDE_CONFIG_DIR` is set — the file moves with the
    /// config dir and the service name gains a hash suffix — so those users will see "no Claude Code
    /// login found". Not chased: an app launched from Finder can't see Claude Code's environment
    /// anyway. It is called out in `docs/TROUBLESHOOTING.md`.
    private static let keychainService = "Claude Code-credentials"

    /// The current access token.
    ///
    /// Read fresh on every call rather than cached: Claude Code rotates this token during active
    /// sessions, and a cached copy would go stale and start 401ing.
    static func accessToken() -> Result<String, Failure> {
        resolve(file: readFile(), keychain: readKeychain())
    }

    /// Picks between the two stores. Pure, so the whole matrix is testable without touching a real
    /// login — this and `candidate(in:source:)` are the only parts of this file a test may call.
    ///
    /// Choosing on *presence* rather than validity was a real bug: a stale
    /// `~/.claude/.credentials.json` left behind by an older Claude Code (its migration only deletes
    /// that file when the Keychain was previously empty) shadowed the live Keychain token forever.
    /// Every poll 401'd and the menu advised opening a Claude Code session, which could never help,
    /// because the copy Claude Code refreshes was the one we weren't reading.
    static func resolve(file: Outcome, keychain: Outcome) -> Result<String, Failure> {
        let candidates = [file, keychain].compactMap(\.candidate)
        if let best = candidates.max(by: { rank(of: $0) < rank(of: $1) }) {
            return .success(best.token)
        }
        let denied = [file, keychain].contains { $0 == .accessDenied }
        return .failure(denied ? .accessDenied : .notFound)
    }

    /// Explicit override first, then whichever credential lives longest, then the Keychain. Spelled
    /// as a sort key rather than a comparator so ties are impossible and the ordering reads in
    /// one line. (`Bool` isn't `Comparable`, hence the Int.)
    private static func rank(of candidate: Candidate) -> (Int, Double, Int) {
        (candidate.isOverride ? 1 : 0,
         candidate.expiresAtMillis ?? -.infinity,
         candidate.source.rawValue)
    }

    // MARK: - Sources

    private static func readFile() -> Outcome {
        let path = (credentialsPath as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: path) else { return .absent }
        guard let data = FileManager.default.contents(atPath: path) else { return .accessDenied }
        // Present but unparseable is `.absent`, not `.accessDenied`: there's nothing usable here,
        // and telling the user to grant access would be the wrong advice.
        return candidate(in: data, source: .file).map(Outcome.found) ?? .absent
    }

    /// Set once macOS refuses the Keychain, and never unset.
    ///
    /// Claude Code creates its Keychain item without `-A`/`-T`, so its ACL trusts only the binary
    /// that made it and Cashew is prompted for access. Without this latch, a user who clicks Deny
    /// would be re-prompted on every poll — a modal dialog every five minutes, forever. Only ever
    /// touched from the serial queue in `ClaudeProvider.fetch`.
    private static var keychainAccessDenied = false

    /// Clears the latch so the next read may prompt again.
    ///
    /// Called only from Refresh Now: picking it is the user asking to be asked. Without this the
    /// latch is a dead end — after one Deny, macOS never asks again for the life of the process, so
    /// the menu's own advice ("allow Cashew access when macOS asks") can never come true, and this
    /// app is designed to run for weeks between launches.
    static func allowKeychainRetry() {
        keychainAccessDenied = false
    }

    private static func readKeychain() -> Outcome {
        if keychainAccessDenied { return .accessDenied }

        // No `kSecAttrAccount` predicate on purpose. Claude Code sets the account to `$USER`, but
        // falls back to a literal when that fails its own sanity check — matching on it could miss
        // the item entirely, which is worse than the unlikely case of duplicate items under one
        // service name.
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?

        // Deliberately not enumerating errSecAuthFailed / errSecUserCanceled / errSecInteractionNotAllowed
        // and friends: which one you get for a denial varies across macOS versions. Anything that
        // isn't "found" or "definitely not there" is treated as refused.
        switch SecItemCopyMatching(query as CFDictionary, &result) {
        case errSecSuccess:
            guard let data = result as? Data else { return .absent }
            return candidate(in: data, source: .keychain).map(Outcome.found) ?? .absent
        case errSecItemNotFound:
            return .absent
        default:
            keychainAccessDenied = true
            return .accessDenied
        }
    }

    // MARK: - Parsing

    /// The Keychain item and the file both hold `{"claudeAiOauth": {"accessToken": "..."}}`.
    /// Older and hand-made setups sometimes store the bare token instead, so fall back to
    /// treating the payload as the token itself.
    static func candidate(in data: Data, source: Source) -> Candidate? {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let oauth = object["claudeAiOauth"] as? [String: Any],
           let token = oauth["accessToken"] as? String,
           !token.isEmpty {
            return Candidate(token: token,
                             expiresAtMillis: millis(oauth["expiresAt"]),
                             isOverride: false,
                             source: source)
        }
        guard let raw = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty, !raw.hasPrefix("{")
        else { return nil }
        return Candidate(token: raw, expiresAtMillis: nil, isOverride: true, source: source)
    }

    // MARK: - Presence

    /// Whether there is a Claude Code login here at all, without reading it.
    ///
    /// Pure, like `resolve`, so discovery is testable without touching a real login — the impure
    /// half is `keychainItemExists()` below, which CI keeps out of tests.
    ///
    /// `.accessDenied` counts as present. Something is there and macOS refused it, which is the
    /// opposite of absent: reporting it as absent would hide the provider entirely and with it the
    /// one message that tells the user how to fix it.
    static func exists(file: Outcome, keychain: Outcome) -> Bool {
        [file, keychain].contains { $0 != .absent }
    }

    /// The presence probe's query, lifted out of the call below so a test can read it.
    ///
    /// `kSecReturnAttributes` without `kSecReturnData` asks securityd for metadata only, which does
    /// not evaluate the item's decrypt ACL and therefore cannot raise the permission prompt. That
    /// matters more than it looks: discovery runs on every launch, on the main thread, for the one
    /// item every Keychain-only user has, and a discovery check that prompted would be worse than
    /// having no discovery at all.
    ///
    /// The property exists because the guarantee was unenforced: the code was right and nothing
    /// failed if a later edit added `kSecReturnData` to it. CI keeps tests away from the probe
    /// itself, which stops a test reaching a real login — a different promise, and not this one.
    static var keychainPresenceQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
    }

    /// Does the Keychain item exist, without decrypting it? See `keychainPresenceQuery` for why the
    /// query is shaped the way it is.
    ///
    /// Never called from a test — it reads the real login Keychain. CI greps for it.
    static func keychainItemExists() -> Bool {
        var result: CFTypeRef?
        switch SecItemCopyMatching(keychainPresenceQuery as CFDictionary, &result) {
        case errSecSuccess: return true
        case errSecItemNotFound: return false
        // Anything else — including a denial — means something is there that we could not read.
        default: return true
        }
    }

    /// Does the credentials file exist? Cheap, and no prompt is possible.
    static func fileExists() -> Bool {
        FileManager.default.fileExists(atPath: (credentialsPath as NSString).expandingTildeInPath)
    }

    /// Is there a Claude Code login on this machine at all?
    ///
    /// The impure composition of the two probes above, kept as one named function so
    /// `ClaudeProvider`'s default argument stays readable and there is a single symbol for CI to
    /// grep. Never called from a test.
    static func loginExists() -> Bool {
        exists(file: fileExists() ? .accessDenied : .absent,
               keychain: keychainItemExists() ? .accessDenied : .absent)
    }

    private static func millis(_ any: Any?) -> Double? {
        // Same trap as the usage parser: JSON booleans bridge to NSNumber, so `as? Double` turns
        // `true` into 1.0 — which would rank as an expiry rather than as no expiry at all.
        guard let any, !isJSONBoolean(any) else { return nil }
        let value: Double
        if let double = any as? Double { value = double }
        else if let int = any as? Int { value = Double(int) }
        else { return nil }
        // Claude Code writes 0 for a token it considers dead.
        guard value.isFinite, value > 0 else { return nil }
        return value
    }
}
