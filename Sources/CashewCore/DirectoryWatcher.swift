import Foundation

/// Calls back when files in a directory are added, replaced or removed.
///
/// The hook helper writes atomically — a rename into the directory — which changes the directory
/// itself, so watching the directory catches every write without watching each file. Debounced,
/// because one tool call produces a PreToolUse and a PostToolUse within milliseconds.
final class DirectoryWatcher {
    private let source: DispatchSourceFileSystemObject
    private var pending: DispatchWorkItem?

    init?(directory: URL, debounce: TimeInterval = 0.1, onChange: @escaping () -> Void) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let descriptor = open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .delete, .rename], queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.pending?.cancel()
            let work = DispatchWorkItem(block: onChange)
            self.pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + debounce, execute: work)
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
    }

    deinit {
        pending?.cancel()
        source.cancel()
    }
}
