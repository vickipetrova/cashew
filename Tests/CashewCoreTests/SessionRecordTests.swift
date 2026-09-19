import Foundation
import Testing

@testable import CashewShared

/// The session file is the contract between `cashew-hook` and the app. The helper writes it and
/// the app parses it — defensively, because an old helper, a hand edit or a half-written file must
/// cost that one session and nothing else.
@Suite struct SessionRecordTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func object(_ text: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    @Test func roundTripsThroughJSON() throws {
        let record = SessionRecord(state: .tool, label: "Editing", tool: "Edit",
                                   cwd: "/Users/v/dev/cashew", transcript: "/t/a.jsonl",
                                   pid: 4242, started: true,
                                   turnStartedAt: now.addingTimeInterval(-65), updatedAt: now)
        let data = try JSONSerialization.data(withJSONObject: record.jsonObject)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let parsed = try #require(SessionRecord(jsonObject: object))
        #expect(parsed == record)
    }

    @Test func missingOrUnknownStateIsRejected() throws {
        #expect(SessionRecord(jsonObject: try object(#"{"updatedAt": 1790000000}"#)) == nil)
        #expect(SessionRecord(jsonObject: try object(#"{"state": "dancing", "updatedAt": 1790000000}"#)) == nil)
    }

    /// `true` must not read as 1970-01-01T00:00:01.
    @Test func booleanTimestampIsRejected() throws {
        #expect(SessionRecord(jsonObject: try object(#"{"state": "idle", "updatedAt": true}"#)) == nil)
    }

    @Test func wrongTypedOptionalFieldsFallBackInsteadOfFailing() throws {
        let record = try #require(SessionRecord(jsonObject: try object("""
            {"state": "thinking", "updatedAt": 1790000000, "pid": true, "started": 1,
             "cwd": 5, "label": null, "turnStartedAt": "soon"}
            """)))
        #expect(record.pid == nil)
        #expect(record.started == false)
        #expect(record.cwd == "")
        #expect(record.label == "")
        #expect(record.turnStartedAt == nil)
    }

    @Test(arguments: ["-5", "0", "1", "3000000000", "12.5"])
    func implausiblePIDsAreDropped(_ raw: String) throws {
        let record = try #require(SessionRecord(jsonObject: try object(
            #"{"state": "idle", "updatedAt": 1790000000, "pid": \#(raw)}"#)))
        #expect(record.pid == nil)
    }

    @Test func sanitizedIDKeepsSafeCharactersOnly() {
        #expect(SessionFiles.sanitizedID("3f1c-9a_b.2") == "3f1c-9a_b.2")
        #expect(SessionFiles.sanitizedID("../../etc/passwd") == "....etcpasswd")
        #expect(SessionFiles.sanitizedID(String(repeating: "a", count: 100))?.count == 64)
    }

    /// No id means no file: a phantom "unknown" session in the menu is worse than nothing.
    @Test(arguments: ["", "///", "..", "."])
    func unusableIDsYieldNoFile(_ raw: String) {
        #expect(SessionFiles.sanitizedID(raw) == nil)
        #expect(SessionFiles.url(for: raw, in: URL(fileURLWithPath: "/tmp")) == nil)
    }

    @Test func writeThenReadFromDisk() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cashew-sessions-\(UUID().uuidString)", isDirectory: true)
        let url = try #require(SessionFiles.url(for: "abc", in: directory))
        let record = SessionRecord(state: .idle, updatedAt: now)
        try SessionFiles.write(record, to: url)
        #expect(SessionFiles.read(url) == record)
    }
}
