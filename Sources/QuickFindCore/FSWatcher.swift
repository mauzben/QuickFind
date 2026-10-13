import CoreServices
import Foundation

/// Thin wrapper around an FSEvents stream (directory-level events).
/// Passing a stored event ID as `since` replays every change made while the app was not
/// running – the macOS counterpart of reading the NTFS USN journal.
final class FSWatcher {
    struct Event {
        let path: String
        let flags: FSEventStreamEventFlags
        let id: FSEventStreamEventId
    }

    private var stream: FSEventStreamRef?
    private let handler: ([Event]) -> Void

    init?(paths: [String], since: FSEventStreamEventId, queue: DispatchQueue, latency: Double = 0.3,
          handler: @escaping ([Event]) -> Void) {
        self.handler = handler
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                       retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, ids in
            guard let info else { return }
            let watcher = Unmanaged<FSWatcher>.fromOpaque(info).takeUnretainedValue()
            let cPaths = paths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
            var events: [Event] = []
            events.reserveCapacity(count)
            for i in 0..<count {
                events.append(Event(path: String(cString: cPaths[i]), flags: flags[i], id: ids[i]))
            }
            watcher.handler(events)
        }
        let createFlags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagWatchRoot)
        let sinceWhen = since == 0 ? FSEventStreamEventId(kFSEventStreamEventIdSinceNow) : since
        guard let s = FSEventStreamCreate(kCFAllocatorDefault, callback, &ctx, paths as CFArray,
                                          sinceWhen, latency, createFlags) else { return nil }
        stream = s
        FSEventStreamSetDispatchQueue(s, queue)
        guard FSEventStreamStart(s) else {
            stop()
            return nil
        }
    }

    func stop() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
    }

    deinit { stop() }
}

extension FSEventStreamEventFlags {
    func has(_ flag: Int) -> Bool { self & FSEventStreamEventFlags(flag) != 0 }
}
