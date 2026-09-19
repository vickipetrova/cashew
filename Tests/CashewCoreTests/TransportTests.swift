import Foundation
import Testing

@testable import CashewCore

/// Everything between the socket and the parser. No network: `ClaudeProvider.result` is pure, and
/// `fetch` is never called from a test — it would use the developer's real token.
@Suite struct TransportTests {
    private let url = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    private func response(_ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
    }

    private func data(_ json: String) throws -> Data {
        try #require(json.data(using: .utf8))
    }

    private func error(from result: Result<[LimitWindow], Error>) -> UsageError? {
        guard case .failure(let failure) = result else { return nil }
        return failure as? UsageError
    }

    @Test func aGoodResponseParsesToWindows() throws {
        let body = try data(#"{"limits": [{"kind": "session", "percent": 42}]}"#)
        let result = ClaudeProvider.result(data: body, response: response(200), error: nil)
        #expect(try result.get().map(\.utilization) == [42])
    }

    /// 401 is the one status with bespoke advice, because it's the one the user can act on.
    @Test func unauthorizedGetsItsOwnMessage() throws {
        let result = ClaudeProvider.result(data: try data("{}"), response: response(401), error: nil)
        #expect(error(from: result) == .unauthorized)
        #expect(error(from: result)?.errorDescription?.contains("Token expired") == true)
    }

    /// Every other non-200 reports its code rather than guessing at a cause. A redirect lands here
    /// too, since the session refuses to follow them.
    ///
    /// 429 is deliberately absent: it now has its own case, because it is the only status that says
    /// what to do about it.
    @Test(arguments: [301, 302, 307, 400, 403, 500, 503])
    func otherStatusesSurfaceTheirCode(_ status: Int) throws {
        let result = ClaudeProvider.result(data: try data("{}"), response: response(status), error: nil)
        #expect(error(from: result) == .http(status))
        #expect(error(from: result)?.errorDescription?.contains("\(status)") == true)
    }

    // MARK: - Rate limiting

    private func response(_ status: Int, retryAfter: String) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                        headerFields: ["Retry-After": retryAfter])!
    }

    /// The status that cost fifteen days of a dead menu bar. It is not "HTTP 429" to the user, and it
    /// is not `.http` to the scheduler — the whole point is that it carries an instruction.
    @Test func rateLimitingIsItsOwnErrorRatherThanAStatusCode() throws {
        let result = ClaudeProvider.result(data: try data("{}"), response: response(429), error: nil)
        #expect(error(from: result) == .rateLimited(retryAfter: nil))
        let message = try #require(error(from: result)?.errorDescription)
        #expect(message.contains("Too many requests"))
        // The old copy read as a fault to be fixed rather than a wait to be sat out.
        #expect(!message.contains("429"))
    }

    @Test func retryAfterInSecondsIsHonoured() throws {
        let result = ClaudeProvider.result(data: try data("{}"),
                                           response: response(429, retryAfter: "120"), error: nil)
        #expect(error(from: result) == .rateLimited(retryAfter: 120))
    }

    /// RFC 9110 allows an HTTP date as well as a delta, and servers use both.
    @Test func retryAfterAsAnHTTPDateIsConvertedToADelay() throws {
        let future = Date().addingTimeInterval(600)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"

        let result = ClaudeProvider.result(
            data: try data("{}"),
            response: response(429, retryAfter: formatter.string(from: future)), error: nil)

        guard case .rateLimited(let retryAfter) = try #require(error(from: result)) else {
            Issue.record("expected .rateLimited"); return
        }
        let seconds = try #require(retryAfter)
        #expect(abs(seconds - 600) < 5)
    }

    /// A date already in the past would otherwise become a negative delay, scheduling the retry
    /// immediately and defeating the backoff at exactly the moment it is needed.
    @Test(arguments: ["Wed, 01 Jan 2020 00:00:00 GMT", "0", "-30", "soon", ""])
    func anUnusableRetryAfterFallsBackToNoAdvice(_ header: String) throws {
        let result = ClaudeProvider.result(data: try data("{}"),
                                           response: response(429, retryAfter: header), error: nil)
        #expect(error(from: result) == .rateLimited(retryAfter: nil))
    }

    @Test func aTransportFailureIsReportedAsNetwork() {
        let dropped = URLError(.notConnectedToInternet)
        let result = ClaudeProvider.result(data: nil, response: nil, error: dropped)
        #expect(error(from: result) == .network(dropped))
        #expect(error(from: result)?.errorDescription?.contains("api.anthropic.com") == true)
    }

    /// A transport error wins even if a partial response came back with it.
    @Test func aTransportFailureOutranksAnyResponse() throws {
        let result = ClaudeProvider.result(data: try data("{}"), response: response(200),
                                           error: URLError(.timedOut))
        #expect(error(from: result) == .network(URLError(.timedOut)))
    }

    @Test func aMissingBodyIsABadResponse() {
        #expect(error(from: ClaudeProvider.result(data: nil, response: response(200), error: nil))
            == .badResponse)
    }

    @Test func aNonHTTPResponseIsABadResponse() throws {
        let plain = URLResponse(url: url, mimeType: nil,
                                expectedContentLength: 0, textEncodingName: nil)
        #expect(error(from: ClaudeProvider.result(data: try data("{}"), response: plain, error: nil))
            == .badResponse)
    }

    /// A JSON *array* root, an error envelope that isn't an object, or plain HTML from a proxy.
    @Test(arguments: ["[]", #"["nope"]"#, "null", "42", "<html>maintenance</html>", ""])
    func aRootThatIsNotAnObjectIsABadResponse(_ body: String) throws {
        #expect(error(from: ClaudeProvider.result(data: try data(body),
                                                  response: response(200), error: nil))
            == .badResponse)
    }

    /// 200 with a well-formed object that simply has no limits is success with nothing to show —
    /// the API-key-account case — not an error.
    @Test func anEmptyObjectIsSuccessWithNoWindows() throws {
        let result = ClaudeProvider.result(data: try data("{}"), response: response(200), error: nil)
        #expect(try result.get().isEmpty)
    }
}

extension UsageError: @retroactive Equatable {
    /// Test-only, and deliberately compares `network` by URLError code rather than by identity —
    /// `Error` isn't `Equatable`, and the code is the part these tests care about.
    public static func == (lhs: UsageError, rhs: UsageError) -> Bool {
        switch (lhs, rhs) {
        case (.noCredentials, .noCredentials),
             (.credentialsAccessDenied, .credentialsAccessDenied),
             (.unauthorized, .unauthorized),
             (.badResponse, .badResponse):
            return true
        case (.http(let a), .http(let b)):
            return a == b
        case (.rateLimited(let a), .rateLimited(let b)):
            return a == b
        case (.network(let a), .network(let b)):
            return (a as? URLError)?.code == (b as? URLError)?.code
        default:
            return false
        }
    }
}
