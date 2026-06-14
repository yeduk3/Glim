import Foundation
import CoreServices

/// Watches a directory tree via FSEvents and fires `onChange` (coalesced) whenever
/// anything under it is created, deleted, renamed, or modified — including changes
/// made by *other* tabs or external apps (Finder). This is what keeps every tab's
/// sidebar synced to the filesystem rather than to whichever tab made the edit.
final class DirectoryWatcher {
    private var stream: FSEventStreamRef?
    private var watchedPath: String?
    private let onChange: () -> Void

    init(onChange: @escaping () -> Void) { self.onChange = onChange }

    /// (Re)starts watching `url`. No-op if already watching that exact path, so it's
    /// safe to call on every view update.
    func start(url: URL) {
        if stream != nil, watchedPath == url.path { return }
        stop()
        watchedPath = url.path

        // FSEvents hands the C callback our `self` via the context info pointer.
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue()
            watcher.onChange()
        }
        var ctx = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)

        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &ctx,
            [url.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.2,              // latency (s): coalesces a rename's create+delete burst into one fire
            flags) else { return }

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, .main)   // callback (and thus onChange) runs on main
        FSEventStreamStart(stream)
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        watchedPath = nil
    }

    deinit { stop() }
}
