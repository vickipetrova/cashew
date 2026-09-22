import Foundation

/// The rolling record of what each limit has read, so `Forecast` has a rate to work from.
///
/// This is the first thing Cashew writes to disk, which is why the location is a parameter rather
/// than a constant: tests get a temp directory, and the CI grep that keeps tests off real user state
/// stays enforceable. `SECURITY.md` documents the real path and its contents.
final class UsageHistory {
    /// Anything older than this is dropped on every write. Well past the 24-hour trailing window the
    /// longest forecast uses — the extra cashew is so a Mac that was asleep for a weekend still has
    /// something to work from, not because anything reads back that far.
    static let retention: TimeInterval = 7 * 24 * 60 * 60

    /// The last successful reading, kept whole rather than as samples.
    ///
    /// Samples carry a percentage and nothing else, which is all a rate needs — but a *row* needs the
    /// heading, the kind and the reset time too. Keeping the last good windows verbatim is what lets
    /// a cold start that can't reach the API still show the numbers it had, instead of an error and
    /// a blank panel.
    ///
    /// **Sections, not a flat `[LimitWindow]`, and that is the whole point of the type.** The flat
    /// shape was everything a one-provider app ever needed and became wrong the moment there were
    /// two: `save` wrote every provider's rows into one list and the restore had no way to tell
    /// them apart, so it handed all of them to Claude. On a real cold start that put
    /// `CODEX · 30-DAY` under the `CLAUDE` heading — and, because one section is one section, took
    /// the headings and the separator away entirely. A provider-less window is now unrepresentable,
    /// so the two cannot drift again by convention.
    ///
    /// The on-disk format changed with it, deliberately and without a migration. `read` is
    /// `try?`-guarded, so a `snapshot.json` in the old shape simply fails to decode and that one
    /// cold start goes without its last good reading — the same trade this codebase already makes
    /// whenever the encoded form moves.
    struct Snapshot: Codable, Equatable {
        /// One provider's rows, inseparable from the provider they came from.
        struct Section: Codable, Equatable {
            let provider: ProviderID
            let windows: [LimitWindow]
        }

        let sections: [Section]
        let at: Date

        /// The rows saved for one provider, or none. Named rather than spelled as a `first(where:)`
        /// at each call site, because "whose rows are these" is the question this type exists to
        /// answer.
        func windows(for provider: ProviderID) -> [LimitWindow] {
            sections.first { $0.provider == provider }?.windows ?? []
        }
    }

    private let fileURL: URL
    private let snapshotURL: URL
    private var samples: [Sample]

    /// `~/Library/Application Support/com.vickipetrova.cashew/`.
    static let `default` = UsageHistory(directory: FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("com.vickipetrova.cashew", isDirectory: true))

    /// Two files, one type: it already owns this directory and the fail-soft plumbing around it, and
    /// splitting them would duplicate all of that to save one small struct.
    init(directory: URL) {
        fileURL = directory.appendingPathComponent("history.json")
        snapshotURL = directory.appendingPathComponent("snapshot.json")
        samples = Self.read(fileURL)
    }

    /// Every sample recorded for one limit, oldest first.
    func samples(for limitID: String, provider: ProviderID) -> [Sample] {
        let qualified = provider.qualify(limitID)
        return samples.filter { $0.limitID == qualified }
    }

    /// One sample per window, then prune, then write.
    ///
    /// Called from the success branch of a poll only. A failed poll must not record anything: the
    /// numbers on screen are deliberately kept from the last good fetch, and re-recording them would
    /// invent a flat stretch that never happened and drag every rate towards zero.
    func record(_ windows: [LimitWindow], provider: ProviderID, at now: Date = Date()) {
        samples.append(contentsOf: windows.compactMap { window in
            // A window whose utilization couldn't be read is not a zero — it is nothing. Writing it
            // as 0 would look like a reset and throw the trailing window away.
            guard window.utilization.isFinite else { return nil }
            return Sample(at: now, limitID: provider.qualify(window.id),
                          utilization: window.utilization)
        })
        samples.removeAll { now.timeIntervalSince($0.at) > Self.retention }
        write()
    }

    // MARK: - Last good reading

    /// Overwrite the remembered reading. Success only, same as `record`.
    ///
    /// Takes sections rather than windows so the caller cannot hand over rows without saying whose
    /// they are. `save` and `restorableSnapshot` used to agree by convention and stopped agreeing
    /// the first time there were two providers; now they agree by construction.
    func save(snapshot sections: [Snapshot.Section], at now: Date = Date()) {
        write(Snapshot(sections: sections, at: now), to: snapshotURL)
    }

    /// What's worth showing from the last good reading, or nil if there's nothing honest left.
    ///
    /// Deliberately *not* everything that was saved, and filtered by the same `Freshness` rule the
    /// running app applies to what's on screen — one definition, so a reading can't be too stale to
    /// keep displaying yet fresh enough to restore.
    ///
    /// Applied per section, and a section left with nothing is dropped rather than restored empty:
    /// a provider whose every row has expired has nothing to say, and an empty section would still
    /// count towards the "more than one section" rule that decides whether headings are drawn.
    func restorableSnapshot(now: Date = Date()) -> Snapshot? {
        guard let snapshot: Snapshot = Self.read(snapshotURL) else { return nil }
        let live = snapshot.sections.compactMap { section -> Snapshot.Section? in
            let windows = Freshness.displayable(section.windows, updatedAt: snapshot.at, now: now)
            return windows.isEmpty
                ? nil
                : Snapshot.Section(provider: section.provider, windows: windows)
        }
        guard !live.isEmpty else { return nil }
        return Snapshot(sections: live, at: snapshot.at)
    }

    // MARK: - Disk
    //
    // Every path here fails soft. A forecast is a nicety on top of the number the user actually came
    // for, so a corrupt file, a full disk, or a directory someone chmod'd must cost the forecast and
    // nothing else — never a crash, and never a menu that won't open. Same rule as parsing the
    // endpoint (hard rule 3 in CLAUDE.md), for the same reason.

    private static func read<T: Decodable>(_ url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private static func read(_ url: URL) -> [Sample] {
        read(url) ?? []
    }

    private func write() { write(samples, to: fileURL) }

    private func write<T: Encodable>(_ value: T, to url: URL) {
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
