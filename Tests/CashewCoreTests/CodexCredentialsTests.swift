import Foundation
import Testing
@testable import CashewCore

@Suite struct CodexCredentialsTests {
    /// The real file's shape, with the token values replaced. Fed as JSON text, like every other
    /// parsing test here, so values arrive as the types `JSONSerialization` really produces.
    private func json(_ text: String) -> Data { Data(text.utf8) }

    @Test func readsTheTokenAndAccountID() throws {
        let token = try #require(CodexCredentials.parse(json("""
        {"auth_mode":"chatgpt",
         "OPENAI_API_KEY":null,
         "tokens":{"id_token":"a.b.c","access_token":"x.y.z","refresh_token":"r","account_id":"acct-1"},
         "last_refresh":"2026-09-21T17:38:49.613648Z"}
        """)))
        #expect(token.accessToken == "x.y.z")
        #expect(token.accountID == "acct-1")
    }

    @Test func anApiKeyLoginHasNoChatgptTokens() {
        // `codex login --with-api-key` writes this shape. A metered API key has no plan quota to
        // report, so there is nothing for Cashew to show and nothing to parse.
        #expect(CodexCredentials.parse(json("""
        {"auth_mode":"apikey","OPENAI_API_KEY":"sk-test","tokens":null}
        """)) == nil)
    }

    @Test func aMissingOrEmptyFieldIsNotACredential() {
        #expect(CodexCredentials.parse(json(#"{"tokens":{"access_token":"x.y.z"}}"#)) == nil)
        #expect(CodexCredentials.parse(json(#"{"tokens":{"account_id":"acct-1"}}"#)) == nil)
        #expect(CodexCredentials.parse(json(#"{"tokens":{"access_token":"","account_id":"a"}}"#)) == nil)
    }

    @Test func aWrongTypedFieldIsNotACredential() {
        // JSON booleans bridge to NSNumber and numbers are not strings; neither may be coerced.
        #expect(CodexCredentials.parse(json(#"{"tokens":{"access_token":true,"account_id":"a"}}"#)) == nil)
        #expect(CodexCredentials.parse(json(#"{"tokens":{"access_token":"x","account_id":7}}"#)) == nil)
    }

    @Test func rubbishIsNotACredential() {
        #expect(CodexCredentials.parse(json("not json at all")) == nil)
        #expect(CodexCredentials.parse(json("[]")) == nil)
        #expect(CodexCredentials.parse(Data()) == nil)
    }
}
