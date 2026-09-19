import Foundation
import CashewShared

/// Which session the menu bar's word speaks for.
///
/// `SessionActivity` orders sessions by urgency and then by how recently they changed, and taking
/// the first of those is right for the image — permission beats working, always. For the *word* it
/// is not enough: two sessions working at once take turns being the most recently changed, so the
/// title alternated between one session's word and the other's for as long as both kept working.
/// Neither word was wrong; the flipping was, and no amount of rate-limiting fixes it, because the
/// two sources keep disagreeing.
///
/// So the choice is sticky within a rank: whoever the title is already speaking for keeps it while
/// they are still doing something of the same urgency. Anything more urgent — a session waiting for
/// approval — takes it immediately, which is the one case where interrupting is the point.
enum TitleSession {
    static func chosen(from sessions: [Session], sticky: String?) -> Session? {
        guard let best = sessions.first else { return nil }
        guard let sticky, let held = sessions.first(where: { $0.id == sticky }),
              // Idle says nothing, so holding the title with it would only mute a working session.
              held.state != .idle,
              rank(held.state) == rank(best.state) else { return best }
        return held
    }

    /// Only whether one state outranks another, not the full ordering: within a rank the sticky
    /// session wins, so thinking and running a tool have to count as the same thing — otherwise the
    /// title would still jump every time one session started a tool call.
    private static func rank(_ state: SessionState) -> Int {
        switch state {
        case .permission: return 0
        case .tool, .thinking: return 1
        case .idle: return 2
        }
    }
}
