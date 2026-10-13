import CoreServices
import Foundation

/// Owns the index and keeps it current: loads the snapshot (or scans), applies FSEvents,
/// tracks external volumes and saves periodically.
public final class IndexManager {
    public struct Configuration: Codable, Equatable {
        public var excludedPaths: [String] = []
        public var includeExternalVolumes = false
        /// Replaces the default root "/" (used by the CLI and tests).
        public var customRoots: [String]?

        public init() {}

        var key: String {
            "ex=\(excludedPaths.map(IndexManager.normalizeUserPath).sorted().joined(separator: "\u{1}"))|ext=\(includeExternalVolumes)|roots=\(customRoots?.joined(separator: "\u{1}") ?? "/")"
        }
    }

    public enum Phase: Equatable {
        case starting, loading, scanning, ready
    }

    public struct Status: Equatable {
        public var phase: Phase
        public var count: Int
        public var detail: String
    }

    public let index = FileIndex()
    public let storeURL: URL
    private var _configuration: Configuration
    public var configuration: Configuration { stateLock.withLock { _configuration } }
    /// Called on `statusQueue` whenever the phase or progress changes.
    public var onStatus: ((Status) -> Void)?
    public var statusQueue = DispatchQueue.main
    public var log: ((String) -> Void)?

    private let work = DispatchQueue(label: "QuickFind.index", qos: .userInitiated)
    private let stateLock = Mutex()
    private let saveLock = Mutex()
    private var _status = Status(phase: .starting, count: 0, detail: "")
    private var _ready = false
    private var _processedEventID: FSEventStreamEventId = 0
    private var _savedGeneration: UInt64 = .max
    private var _scanner: ParallelScanner?
    private var _fullScanRequested = false
    private var lastProgress = DispatchTime(uptimeNanoseconds: 0)

    // Only touched on `work`.
    private var watcher: FSWatcher?
    private var nameOrderItem: DispatchWorkItem?
    private var saveTimer: DispatchSourceTimer?
    private let lister = BulkLister()
    private let listing = DirListing()
    /// Last time a subtree was fully reconciled, and requests postponed by the cool-down.
    private var lastDeepSync: [String: Date] = [:]
    private var deferredDeep = Set<String>()
    private var deferredScheduled = false
    private static let deepSyncCooldown: TimeInterval = 120

    // Event intake: FSEvents callbacks only collect paths here (never blocked by scans), so macOS
    // does not drop events and ask for full rescans just because a scan is running.
    private let eventQueue = DispatchQueue(label: "QuickFind.fsevents", qos: .utility)
    private let eventsLock = Mutex()
    private var pendingEvents: [String: FSWatcher.Event] = [:]
    private var pendingSpecial: [FSWatcher.Event] = []
    private var processingScheduled = false
    private var excluded: Set<String> = []

    public static var defaultStoreURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("QuickFind/index.qfi")
    }

    public init(configuration: Configuration = Configuration(), storeURL: URL = IndexManager.defaultStoreURL) {
        _configuration = configuration
        self.storeURL = storeURL
        excluded = Set(configuration.excludedPaths.map(Self.normalizeUserPath).filter { !$0.isEmpty })
    }

    public var status: Status { stateLock.withLock { _status } }
    public var isReady: Bool { stateLock.withLock { _ready } }

    // MARK: Public control

    /// Loads the saved index (replaying FSEvents since the last run) or performs a full scan.
    /// `rescan` forces a full scan, e.g. after permissions changed.
    public func start(rescan: Bool = false) {
        work.async { [self] in
            if rescan { fullScan() } else { startOnQueue() }
            startSaveTimer()
        }
    }

    /// Blocks until the index is loaded/scanned (CLI use).
    public func startSynchronously() { work.sync { startOnQueue() } }

    public func rebuild() {
        stateLock.withLock { _fullScanRequested = true; return _scanner }?.cancel()
        work.async { [self] in fullScan() }
    }

    public func updateConfiguration(_ c: Configuration) {
        stateLock.withLock { _fullScanRequested = true; return _scanner }?.cancel()
        stateLock.withLock { _configuration = c }
        work.async { [self] in
            excluded = Set(c.excludedPaths.map(Self.normalizeUserPath).filter { !$0.isEmpty })
            fullScan()
        }
    }

    /// Test hook: reconciles `path` as if FSEvents had reported lost events for it (blocking).
    public func reconcileForTesting(_ path: String) {
        work.sync {
            lastDeepSync[path] = nil
            deepSync(Self.normalizeUserPath(path))
        }
    }

    /// Call when volumes were mounted or unmounted.
    public func volumesDidChange() {
        work.async { [self] in
            guard stateLock.withLock({ _ready }) else { return }
            reconcileRoots()
        }
    }

    /// Writes the snapshot if anything changed since the last save. Safe from any thread.
    public func save() {
        saveLock.withLock {
            // Never write a snapshot while a scanner is filling in a subtree: it would be incomplete.
            let (ready, eventID, saved, scanning) = stateLock.withLock {
                (_ready, _processedEventID, _savedGeneration, _scanner != nil)
            }
            guard ready, !scanning else { return }
            let generation = index.stats.generation
            guard generation != saved else { return }
            let t0 = DispatchTime.now()
            do {
                try index.save(to: storeURL, lastEventID: eventID, configKey: configuration.key,
                               volumeUUIDs: Self.currentVolumeUUIDs())
                stateLock.withLock { _savedGeneration = generation }
                log?("Index gespeichert (\(Self.ms(since: t0)) ms)")
            } catch {
                log?("Speichern fehlgeschlagen: \(error)")
            }
        }
    }

    // MARK: Startup / scanning (on `work`)

    /// Exists while a scan runs; if the app quits mid-scan, the next start rebuilds the index.
    private var scanMarkerURL: URL { storeURL.appendingPathExtension("scanning") }

    private func startOnQueue() {
        setStatus(.loading, 0, "Lade Index …")
        let t0 = DispatchTime.now()
        if FileManager.default.fileExists(atPath: scanMarkerURL.path) {
            log?("Letzter Scan wurde unterbrochen – Index wird neu aufgebaut")
            fullScan()
            return
        }
        if let meta = try? index.load(from: storeURL), meta.configKey == configuration.key,
           Self.uuidsMatch(meta.volumeUUIDs) {
            let count = index.stats.count
            stateLock.withLock {
                _ready = true
                _processedEventID = meta.lastEventID
                _savedGeneration = index.stats.generation
            }
            log?("Index geladen: \(count) Einträge in \(Self.ms(since: t0)) ms")
            setStatus(.ready, count, "Index geladen")
            reconcileRoots()
            index.compactStorage()
            startWatcher(since: meta.lastEventID)
            scheduleNameOrder(delay: 0)
        } else {
            fullScan()
        }
    }

    private func roots() -> [String] {
        if let r = configuration.customRoots {
            return r.map(Self.normalizeUserPath)
        }
        var r = ["/"]
        if configuration.includeExternalVolumes { r += Self.externalVolumes() }
        return r
    }

    private func fullScan() {
        stateLock.withLock { _fullScanRequested = false }
        watcher?.stop()
        watcher = nil
        stateLock.withLock { _ready = false }
        let startID = FSEventsGetCurrentEventId()
        let t0 = DispatchTime.now()
        setStatus(.scanning, 0, "Indiziere …")
        var jobs: [ParallelScanner.Job] = []
        index.lock.write {
            index.reset()
            for r in roots() {
                jobs.append(.init(id: index.addRoot(r), path: r))
            }
        }
        guard runScanner(jobs) else { return }   // cancelled – a new scan is queued
        let count = index.stats.count
        let secs = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1e9
        stateLock.withLock {
            _ready = true
            _processedEventID = startID
            _savedGeneration = .max
        }
        log?("Vollscan: \(count) Einträge in \(String(format: "%.2f", secs)) s")
        setStatus(.ready, count, String(format: "Indiziert in %.1f s", secs))
        index.compactStorage()
        index.rebuildNameOrder()
        save()
        startWatcher(since: startID)
    }

    @discardableResult
    private func runScanner(_ jobs: [ParallelScanner.Job]) -> Bool {
        let scanner = ParallelScanner(index: index, isExcluded: { [unowned self] in isExcluded($0) },
                                      progress: { [weak self] n in self?.scanProgress(n) })
        stateLock.withLock { _scanner = scanner }
        FileManager.default.createFile(atPath: scanMarkerURL.path, contents: nil)
        scanner.run(jobs)
        let cancelled = scanner.isCancelled
        stateLock.withLock { _scanner = nil }
        // A cancelled scan is always followed by a full scan, which keeps the marker until it finishes.
        if !cancelled { try? FileManager.default.removeItem(at: scanMarkerURL) }
        return !cancelled
    }

    private func scanProgress(_ count: Int) {
        let now = DispatchTime.now()
        let report = stateLock.withLock { () -> Bool in
            guard _status.phase == .scanning, now.uptimeNanoseconds - lastProgress.uptimeNanoseconds > 150_000_000 else {
                return false
            }
            lastProgress = now
            return true
        }
        if report { setStatus(.scanning, count, "Indiziere …") }
    }

    private func setStatus(_ phase: Phase, _ count: Int, _ detail: String) {
        let s = Status(phase: phase, count: count, detail: detail)
        stateLock.withLock { _status = s }
        if let cb = onStatus { statusQueue.async { cb(s) } }
    }

    private func startSaveTimer() {
        let t = DispatchSource.makeTimerSource(queue: work)
        t.schedule(deadline: .now() + 120, repeating: 120)
        t.setEventHandler { [weak self] in self?.save() }
        t.resume()
        saveTimer = t
    }

    private func scheduleNameOrder(delay: Double) {
        nameOrderItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.index.rebuildNameOrder() }
        nameOrderItem = item
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay, execute: item)
    }

    // MARK: Live updates (on `work`)

    private func startWatcher(since: FSEventStreamEventId) {
        watcher?.stop()
        let paths = index.lock.read { index.rootPaths.map(\.path) }
        watcher = FSWatcher(paths: paths, since: since, queue: eventQueue) { [weak self] events in
            self?.enqueue(events)
        }
        if watcher == nil { log?("FSEvents-Stream konnte nicht gestartet werden") }
    }

    /// Collects events (merged per path) and schedules one processing pass on the work queue.
    private func enqueue(_ events: [FSWatcher.Event]) {
        eventsLock.withLock {
            for e in events {
                let special = e.flags.has(kFSEventStreamEventFlagRootChanged) || e.flags.has(kFSEventStreamEventFlagEventIdsWrapped)
                    || e.flags.has(kFSEventStreamEventFlagMount) || e.flags.has(kFSEventStreamEventFlagUnmount)
                    || e.flags.has(kFSEventStreamEventFlagHistoryDone)
                if special {
                    pendingSpecial.append(e)
                } else if let old = pendingEvents[e.path] {
                    pendingEvents[e.path] = FSWatcher.Event(path: e.path, flags: old.flags | e.flags, id: max(old.id, e.id))
                } else {
                    pendingEvents[e.path] = e
                }
            }
            guard !processingScheduled else { return }
            processingScheduled = true
            work.async { [weak self] in self?.processPending() }
        }
    }

    private func processPending() {
        let batch: [FSWatcher.Event] = eventsLock.withLock {
            let b = pendingSpecial + Array(pendingEvents.values)
            pendingEvents.removeAll(keepingCapacity: true)
            pendingSpecial.removeAll()
            processingScheduled = false
            return b
        }
        if !batch.isEmpty { handle(batch) }
    }

    private func handle(_ events: [FSWatcher.Event]) {
        var dirs = Set<String>()
        var deep = Set<String>()
        var maxID = stateLock.withLock { _processedEventID }
        var full = false
        var volumes = false
        for e in events {
            let f = e.flags
            if f.has(kFSEventStreamEventFlagHistoryDone) { continue }
            maxID = max(maxID, e.id)
            if f.has(kFSEventStreamEventFlagRootChanged) || f.has(kFSEventStreamEventFlagEventIdsWrapped) {
                full = true
                continue
            }
            if f.has(kFSEventStreamEventFlagMount) || f.has(kFSEventStreamEventFlagUnmount) {
                volumes = true
                continue
            }
            let p = Self.normalizeEventPath(e.path)
            if isExcluded(p) { continue }
            if f.has(kFSEventStreamEventFlagMustScanSubDirs) { deep.insert(p) } else { dirs.insert(p) }
        }
        if full {
            log?("FSEvents verlangt vollständigen Neuscan")
            fullScan()
            return
        }
        func covered(_ p: String, by set: Set<String>) -> Bool {
            set.contains { d in d != p && (d == "/" || p.hasPrefix(d + "/")) }
        }
        let gen0 = index.stats.generation
        for p in deep.sorted() where !covered(p, by: deep) { deepSync(p) }
        for p in dirs where !deep.contains(p) && !covered(p, by: deep) { refreshDirectory(p) }
        if volumes && configuration.includeExternalVolumes { reconcileRoots() }
        stateLock.withLock { _processedEventID = maxID }
        if index.stats.generation != gen0 {
            let count = index.stats.count
            setStatus(.ready, count, "Aktuell")
            scheduleNameOrder(delay: 10)
        }
    }

    private func refreshDirectory(_ path: String, depth: Int = 0) {
        guard depth < 128 else { return }
        let found = index.lock.read { () -> (Int32, UInt8)? in
            guard let id = index.lookup(path) else { return nil }
            return (id, index.flags[Int(id)])
        }
        guard let (id, f) = found else {
            // Unknown path: refresh the parent so the new item gets added.
            let parent = (path as NSString).deletingLastPathComponent
            if !parent.isEmpty && parent != path { refreshDirectory(parent, depth: depth + 1) }
            return
        }
        let isRoot = f & EntryFlag.root != 0
        guard f & EntryFlag.directory != 0, isRoot || f & (EntryFlag.mountPoint | EntryFlag.symlink) == 0 else { return }

        let jobs = sync(id, path, isRoot: isRoot)
        if !jobs.isEmpty { runScanner(jobs) }
    }

    /// Lists `path` and brings the children of `id` in line with it (adds, removes, updates).
    /// Returns scan jobs for new subfolders; `subfolders` receives the existing ones.
    private func sync(_ id: Int32, _ path: String, isRoot: Bool,
                      subfolders: ((Int32, String) -> Void)? = nil) -> [ParallelScanner.Job] {
        let err = lister.list(path, into: listing)
        if err == ENOENT || err == ENOTDIR {
            if !isRoot { index.lock.write { index.removeSubtree(id) } }
            return []
        }
        guard err == 0 else { return [] }

        var jobs: [ParallelScanner.Job] = []
        var keep: [(Int32, ListedEntry)] = []
        index.lock.write {
            guard index.isLive(id) else { return }
            var existing: [[UInt8]: Int32] = [:]
            for c in index.children(of: id) { existing[index.nameBytes(c)] = c }
            var added: [ListedEntry] = []
            let typeMask = EntryFlag.directory | EntryFlag.symlink | EntryFlag.mountPoint
            for e in listing.entries {
                if let c = existing.removeValue(forKey: listing.name(e)) {
                    if index.flags[Int(c)] & typeMask != e.flags & typeMask {
                        index.removeSubtree(c)
                        added.append(e)
                    } else {
                        index.update(c, size: e.size, allocated: e.alloc, mtime: e.mtime, ctime: e.ctime, flags: e.flags)
                        if subfolders != nil && e.descendable { keep.append((c, e)) }
                    }
                } else {
                    added.append(e)
                }
            }
            for (_, c) in existing { index.removeSubtree(c) }
            if !added.isEmpty {
                jobs = index.appendListing(listing, only: added, parent: id,
                                           plans: listing.prepare(parentPath: path, isExcluded: isExcluded, only: added))
            }
        }
        if let subfolders {
            for (c, e) in keep { subfolders(c, joinPath(path, listing.nameString(e))) }
        }
        return jobs
    }

    /// FSEvents lost track of a subtree ("MustScanSubDirs"): compare the whole subtree with the
    /// disk instead of emptying and rescanning it, so the index stays complete meanwhile. The same
    /// path is reconciled at most every two minutes; further requests are postponed, not lost.
    private func deepSync(_ path: String) {
        if let last = lastDeepSync[path], Date().timeIntervalSince(last) < Self.deepSyncCooldown {
            deferredDeep.insert(path)
            if !deferredScheduled {
                deferredScheduled = true
                work.asyncAfter(deadline: .now() + Self.deepSyncCooldown) { [weak self] in
                    guard let self else { return }
                    deferredScheduled = false
                    let paths = deferredDeep
                    deferredDeep.removeAll()
                    for p in paths.sorted() { deepSync(p) }
                }
            }
            return
        }
        lastDeepSync[path] = Date()
        guard let rootID = index.lock.read({ index.lookup(path) }) else {
            refreshDirectory(path)
            return
        }
        let t0 = DispatchTime.now()
        var stack: [(Int32, String)] = [(rootID, path)]
        var jobs: [ParallelScanner.Job] = []
        var folders = 0
        while let (id, p) = stack.popLast() {
            if stateLock.withLock({ _fullScanRequested }) { break }   // a full scan is queued anyway
            let isRoot = index.lock.read { index.flags[Int(id)] & EntryFlag.root != 0 }
            jobs += sync(id, p, isRoot: isRoot) { stack.append(($0, $1)) }
            folders += 1
            if jobs.count >= 512 {
                runScanner(jobs)
                jobs.removeAll()
            }
        }
        if !jobs.isEmpty { runScanner(jobs) }
        log?("Abgleich \(path): \(folders) Ordner in \(Self.ms(since: t0)) ms")
    }

    /// Adds newly mounted volumes as roots and drops unmounted ones.
    private func reconcileRoots() {
        guard configuration.customRoots == nil else { return }
        let wanted = Set(roots())
        let existing = index.lock.read { index.rootPaths }
        var changed = false
        for (id, path) in existing where !wanted.contains(path) {
            index.lock.write { index.removeSubtree(id) }
            log?("Volume entfernt: \(path)")
            changed = true
        }
        let have = Set(existing.map(\.path))
        var jobs: [ParallelScanner.Job] = []
        for r in wanted.subtracting(have).sorted() {
            index.lock.write { jobs.append(.init(id: index.addRoot(r), path: r)) }
            log?("Volume hinzugefügt: \(r)")
        }
        if !jobs.isEmpty {
            runScanner(jobs)
            changed = true
        }
        if changed {
            startWatcher(since: stateLock.withLock { _processedEventID })
            scheduleNameOrder(delay: 1)
            setStatus(.ready, index.stats.count, "Aktuell")
        }
    }

    // MARK: Helpers

    private func isExcluded(_ path: String) -> Bool {
        if excluded.isEmpty { return false }
        if excluded.contains(path) { return true }
        for e in excluded where path.hasPrefix(e) && path.utf8.count > e.utf8.count {
            if path.utf8[path.utf8.index(path.utf8.startIndex, offsetBy: e.utf8.count)] == UInt8(ascii: "/") { return true }
        }
        return false
    }

    public static func normalizeUserPath(_ p: String) -> String {
        var s = (p.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
        if let c = realpath(s, nil) {
            s = String(cString: c)
            free(c)
        }
        while s.count > 1 && s.hasSuffix("/") { s.removeLast() }
        return s
    }

    static func normalizeEventPath(_ path: String) -> String {
        var p = path
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        let data = "/System/Volumes/Data"
        if p == data { return "/" }
        if p.hasPrefix(data + "/") { p = String(p.dropFirst(data.count)) }
        return p
    }

    public static func externalVolumes() -> [String] {
        let keys: [URLResourceKey] = [.volumeIsLocalKey, .volumeIsRootFileSystemKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { url -> String? in
            guard url.path.hasPrefix("/Volumes/"),
                  let v = try? url.resourceValues(forKeys: Set(keys)),
                  v.volumeIsLocal == true, v.volumeIsRootFileSystem != true else { return nil }
            var isLink: ObjCBool = false
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil { isLink = true }
            return isLink.boolValue ? nil : url.path
        }
    }

    static func currentVolumeUUIDs() -> [String: String] {
        var out: [String: String] = [:]
        for p in ["/", "/System/Volumes/Data"] {
            var st = stat()
            guard stat(p, &st) == 0, let uuid = FSEventsCopyUUIDForDevice(st.st_dev) else { continue }
            out[p] = CFUUIDCreateString(nil, uuid) as String
        }
        return out
    }

    static func uuidsMatch(_ stored: [String: String]) -> Bool {
        let now = currentVolumeUUIDs()
        for (k, v) in stored where now[k] != nil && now[k] != v { return false }
        return true
    }

    static func ms(since t: DispatchTime) -> Int {
        Int((DispatchTime.now().uptimeNanoseconds - t.uptimeNanoseconds) / 1_000_000)
    }
}
