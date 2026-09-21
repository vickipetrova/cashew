import Foundation
import CashewShared

/// Finds the token `codex login` already wrote, so Cashew needs no setup of its own.
///
/// The Codex half of the promise `Credentials` makes for Claude Code, and much smaller for one
/// reason: there is exactly one store. Codex keeps nothing in the login Keychain — checked, and
/// nothing matching "codex" exists there — so there is no ranking between stores, no access-denied
/// latch, and no serial queue guarding a modal permission prompt.
///
/// Nothing here logs, prints, caches or persists the token. Cashew never writes this file, never
/// runs `codex`, never holds the refresh token and never authenticates. See the guardrails in
/// CLAUDE.md.
enum CodexCredentials {
    struct Token: Equatable {
        let accessToken: String
        let accountID: String
    }

    private static let path = "~/.codex/auth.json"

    private static var expandedPath: String { (path as NSString).expandingTildeInPath }

    /// Cheap, no network, no prompt — this runs on every launch as part of provider discovery.
    static func fileExists() -> Bool {
        FileManager.default.fileExists(atPath: expandedPath)
    }

    static func read() -> Token? {
        guard let data = FileManager.default.contents(atPath: expandedPath) else { return nil }
        return parse(data)
    }

    /// Pure, so the whole matrix is testable without a real login — this is the only part of this
    /// file a test may call.
    ///
    /// The `id_token` and `refresh_token` are ignored on purpose, and the access token's JWT claims
    /// are not decoded: `exp` would only invent a staleness rule Cashew would then have to keep in
    /// step with OpenAI's, and an expired token returns 401, which says it plainly. `plan_type`
    /// arrives in the usage response anyway.
    static func parse(_ data: Data) -> Token? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = object["tokens"] as? [String: Any]
        else { return nil }
        // `as? String` on an NSNumber correctly fails, and `isJSONBoolean` is not needed here —
        // a bridged boolean is an NSNumber, which is not a String either.
        guard let accessToken = tokens["access_token"] as? String, !accessToken.isEmpty,
              let accountID = tokens["account_id"] as? String, !accountID.isEmpty
        else { return nil }
        return Token(accessToken: accessToken, accountID: accountID)
    }
}
