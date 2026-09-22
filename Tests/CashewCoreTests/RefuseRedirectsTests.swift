import Foundation
import Testing

@testable import CashewCore

/// Both of Cashew's sessions refuse redirects, and SECURITY.md states that as one rule rather than
/// two. These hold the rule.
///
/// The usage session is the one that matters most — it carries the bearer token, and a cross-host
/// hop is exactly how a token leaks. The update check carries no token, but it does send a
/// `User-Agent`, and a GitHub 301 on a repo rename would forward it; refusing there too means the
/// document needs no caveat.
@Suite struct RefuseRedirectsTests {
    private func redirect() -> (HTTPURLResponse, URLRequest) {
        let response = HTTPURLResponse(
            url: URL(string: "https://api.github.com/repos/vickipetrova/cashew/releases/latest")!,
            statusCode: 301, httpVersion: nil,
            headerFields: ["Location": "https://example.invalid/moved"])!
        return (response, URLRequest(url: URL(string: "https://example.invalid/moved")!))
    }

    /// The whole contract: hand the completion handler nil and the hop never happens.
    @Test func handsBackNoRequest() async {
        let (response, request) = redirect()
        let followed: URLRequest? = await withCheckedContinuation { continuation in
            RefuseRedirects().urlSession(
                URLSession.shared, task: URLSession.shared.dataTask(with: request),
                willPerformHTTPRedirection: response, newRequest: request,
                completionHandler: { continuation.resume(returning: $0) })
        }
        #expect(followed == nil)
    }

    /// Wiring, not behaviour — but the behaviour above is worthless if a session forgets the
    /// delegate, which is precisely how the update check came to differ from the usage request.
    @Test func bothSessionsInstallThePolicy() {
        #expect(ClaudeProvider.session.delegate is RefuseRedirects)
        #expect(UpdateCheck.session.delegate is RefuseRedirects)
    }

    @Test func theClaudeEndpointOnlyTalksToItsDeclaredHost() {
        // Hard rule 5 is per-provider now: each provider names the one host it may contact, and
        // this is what keeps the declaration honest rather than decorative.
        #expect(ClaudeProvider.host == "api.anthropic.com")
        #expect(ClaudeProvider.endpointHost == ClaudeProvider.host)
    }

    @Test func theCodexEndpointOnlyTalksToItsDeclaredHost() {
        #expect(CodexProvider.host == "chatgpt.com")
        #expect(CodexProvider.endpointHost == CodexProvider.host)
    }

    @Test func theCodexSessionRefusesRedirects() {
        // Same reason as the other two: a redirect off the declared host would silently break the
        // one-host-per-provider promise in hard rule 5.
        #expect(CodexProvider.session.delegate is RefuseRedirects)
    }
}
