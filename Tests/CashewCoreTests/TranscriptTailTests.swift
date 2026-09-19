import Foundation
import Testing

@testable import CashewCore

/// `Stop` does not fire when a turn is interrupted with Esc (Claude Code docs), so without this an
/// interrupted session shows "working" forever. The fixtures are shaped on real transcripts: the
/// interrupt marker is frequently *not* the last line.
@Suite struct TranscriptTailTests {
    private func lines(_ entries: String...) -> Data { Data(entries.joined(separator: "\n").utf8) }

    private let assistant = #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"ok"}]}}"#
    private let interrupt = #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]}}"#
    private let toolInterrupt = #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user for tool use]"}]}}"#

    @Test func markerFollowedByBookkeepingEntries() {
        #expect(TranscriptTail.endsInInterrupt(lines(assistant, interrupt,
            #"{"type":"last-prompt"}"#, #"{"type":"ai-title"}"#, #"{"type":"mode"}"#,
            #"{"type":"permission-mode"}"#, #"{"type":"attachment"}"#, #"{"type":"file-history-snapshot"}"#)))
    }

    @Test func toolUseInterrupt() {
        #expect(TranscriptTail.endsInInterrupt(lines(assistant, toolInterrupt)))
    }

    @Test func stringContentForm() {
        #expect(TranscriptTail.endsInInterrupt(lines(
            #"{"type":"user","message":{"role":"user","content":"[Request interrupted by user]"}}"#)))
    }

    @Test func aNewPromptAfterTheMarkerIsNotAnInterrupt() {
        #expect(!TranscriptTail.endsInInterrupt(lines(interrupt,
            #"{"type":"user","message":{"role":"user","content":"try again please"}}"#, #"{"type":"attachment"}"#)))
    }

    @Test func assistantOrToolResultLastIsNotAnInterrupt() {
        #expect(!TranscriptTail.endsInInterrupt(lines(interrupt, assistant)))
        #expect(!TranscriptTail.endsInInterrupt(lines(interrupt,
            #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"ok"}]}}"#)))
    }

    /// The tail starts mid-file, so its first line is usually a fragment.
    /// The fragment has to be the line the scan actually reaches, or this proves nothing: after it
    /// come only non-conversational entries (or nothing), so the loop gets to it and must move past.
    @Test func partialFirstLineIsSkipped() {
        // A fragment of an interrupt entry: it must not count as one just because it contains the text.
        let fragment = #"t":[{"type":"text","text":"[Request interrupted by user]"}]}}"#
        #expect(!TranscriptTail.endsInInterrupt(lines(fragment, #"{"type":"attachment"}"#, #"{"type":"mode"}"#)))
        #expect(!TranscriptTail.endsInInterrupt(lines(fragment)))
        #expect(TranscriptTail.endsInInterrupt(lines(fragment, interrupt, #"{"type":"attachment"}"#)))
        #expect(!TranscriptTail.endsInInterrupt(Data()))
    }

    /// The marker only counts if the transcript was written after the session's last hook event —
    /// otherwise a new turn right after an interrupted one reads as interrupted until Claude replies.
    @Test func olderTranscriptIsNotTrusted() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("t-\(UUID().uuidString).jsonl")
        try lines(assistant, interrupt).write(to: url)
        let written = Date(timeIntervalSince1970: 1_790_000_000)
        try FileManager.default.setAttributes([.modificationDate: written], ofItemAtPath: url.path)
        let tail = TranscriptTail()
        #expect(tail.wasInterrupted(transcript: url.path, after: written.addingTimeInterval(-5)))
        #expect(!tail.wasInterrupted(transcript: url.path, after: written.addingTimeInterval(5)))
        #expect(!tail.wasInterrupted(transcript: "/nonexistent/t.jsonl", after: .distantPast))
    }
}
