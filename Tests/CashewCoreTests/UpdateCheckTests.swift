import Foundation
import Testing

@testable import CashewCore

@Suite struct UpdateCheckTests {
    private func object(_ text: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    private func response(_ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: UpdateCheck.endpoint, statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    private let release = """
        {"tag_name": "v0.2.0", "html_url": "https://github.com/vickipetrova/cashew/releases/tag/v0.2.0",
         "draft": false, "prerelease": false}
        """

    @Test(arguments: [("v0.2.0", [0, 2, 0]), ("0.10.1", [0, 10, 1]), ("V1", [1]), ("1.2.3.4", [1, 2, 3, 4])])
    func versionsParse(_ raw: String, _ expected: [Int]) {
        #expect(UpdateCheck.version(raw) == expected)
    }

    @Test(arguments: ["v0.2.0-beta.1", "", "v", "1..2", "latest", "1.2.3.4.5", "1.x", "１.２"])
    func junkVersionsDoNot(_ raw: String) {
        #expect(UpdateCheck.version(raw) == nil)
    }

    /// Compared numerically — a string compare says 0.9.0 is newer than 0.10.0.
    @Test func comparison() {
        #expect(UpdateCheck.isNewer([0, 10, 0], than: [0, 9, 0]))
        #expect(!UpdateCheck.isNewer([0, 1, 0], than: [0, 1, 0]))
        #expect(!UpdateCheck.isNewer([0, 1], than: [0, 1, 0]))
        #expect(UpdateCheck.isNewer([1], than: [0, 99, 99]))
        #expect(!UpdateCheck.isNewer([0, 1, 0], than: [0, 2, 0]))
    }

    @Test func parsesTheLatestRelease() throws {
        let parsed = try #require(UpdateCheck.release(in: try object(release)))
        #expect(parsed.tag == "v0.2.0")
        #expect(parsed.version == [0, 2, 0])
        #expect(parsed.url.absoluteString == "https://github.com/vickipetrova/cashew/releases/tag/v0.2.0")
    }

    @Test(arguments: [
        #"{"tag_name": "v0.2.0", "html_url": "https://evil.example/cashew"}"#,
        #"{"tag_name": "v0.2.0", "html_url": "http://github.com/vickipetrova/cashew/releases/tag/v0.2.0"}"#,
        #"{"tag_name": "v0.2.0", "html_url": "https://github.com/someone-else/cashew/releases/tag/v0.2.0"}"#,
        #"{"tag_name": 2, "html_url": "https://github.com/vickipetrova/cashew/releases/tag/v0.2.0"}"#,
        #"{"html_url": "https://github.com/vickipetrova/cashew/releases/tag/v0.2.0"}"#,
        #"{"tag_name": "v0.2.0", "html_url": "https://github.com/vickipetrova/cashew/releases/tag/v0.2.0", "draft": true}"#,
        #"{"tag_name": "v0.2.0", "html_url": "https://github.com/vickipetrova/cashew/releases/tag/v0.2.0", "prerelease": true}"#,
    ])
    func untrustworthyReleasesAreIgnored(_ text: String) throws {
        #expect(UpdateCheck.release(in: try object(text)) == nil)
    }

    @Test func availableOnlyWhenNewer() {
        let data = Data(release.utf8)
        #expect(UpdateCheck.available(data: data, response: response(200), error: nil, currentVersion: "0.1.0") != nil)
        #expect(UpdateCheck.available(data: data, response: response(200), error: nil, currentVersion: "0.2.0") == nil)
        #expect(UpdateCheck.available(data: data, response: response(200), error: nil, currentVersion: "0.3.0") == nil)
    }

    /// Before the first release GitHub answers 404. That is the normal state, not an error to show.
    @Test func failuresAreSilent() {
        let data = Data(release.utf8)
        #expect(UpdateCheck.available(data: Data("{}".utf8), response: response(404), error: nil, currentVersion: "0.1.0") == nil)
        #expect(UpdateCheck.available(data: data, response: response(403), error: nil, currentVersion: "0.1.0") == nil)
        #expect(UpdateCheck.available(data: nil, response: nil, error: URLError(.notConnectedToInternet), currentVersion: "0.1.0") == nil)
        #expect(UpdateCheck.available(data: Data("<html>".utf8), response: response(200), error: nil, currentVersion: "0.1.0") == nil)
    }

    @Test func dueOncePerDayMeasuredFromTheLastAttempt() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        #expect(UpdateCheck.isDue(lastAttempt: nil, now: now))
        #expect(!UpdateCheck.isDue(lastAttempt: now.addingTimeInterval(-3600), now: now))
        #expect(UpdateCheck.isDue(lastAttempt: now.addingTimeInterval(-86_400), now: now))
        // The clock moved backwards: don't wait up to a day on a timestamp from the future.
        #expect(UpdateCheck.isDue(lastAttempt: now.addingTimeInterval(3600), now: now))
    }

    /// A release found yesterday must still show after a restart today, and vanish once installed.
    @Test func pendingSurvivesUntilInstalled() throws {
        let known = try #require(UpdateCheck.release(in: try object(release)))
        #expect(UpdateCheck.pending(known: known, currentVersion: "0.1.0") == known)
        #expect(UpdateCheck.pending(known: known, currentVersion: "0.2.0") == nil)
        #expect(UpdateCheck.pending(known: nil, currentVersion: "0.1.0") == nil)
    }

    @Test func menuTitle() throws {
        let known = try #require(UpdateCheck.release(in: try object(release)))
        #expect(UpdateCheck.menuTitle(known) == "Update Available: v0.2.0…")
    }
}
