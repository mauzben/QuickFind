import Foundation

struct ListedEntry {
    var nameStart: Int
    var nameLen: Int
    var foldStart: Int
    var foldLen: Int
    var flags: UInt8
    var size: Int64
    var alloc: Int64
    var mtime: Int64
    var ctime: Int64

    var isDirectory: Bool { flags & EntryFlag.directory != 0 }
    var descendable: Bool { isDirectory && flags & (EntryFlag.mountPoint | EntryFlag.symlink) == 0 }
}

/// Result of listing one directory (reused between calls to avoid allocations).
final class DirListing {
    var names: [UInt8] = []
    var folds: [UInt8] = []
    var entries: [ListedEntry] = []

    func reset() {
        names.removeAll(keepingCapacity: true)
        folds.removeAll(keepingCapacity: true)
        entries.removeAll(keepingCapacity: true)
    }

    func name(_ e: ListedEntry) -> [UInt8] { Array(names[e.nameStart..<e.nameStart + e.nameLen]) }

    func nameString(_ e: ListedEntry) -> String {
        names.withUnsafeBufferPointer {
            String(decoding: UnsafeBufferPointer(rebasing: $0[e.nameStart..<e.nameStart + e.nameLen]), as: UTF8.self)
        }
    }
}

@inline(__always) private func ag<T: BinaryInteger>(_ v: T) -> attrgroup_t { attrgroup_t(truncatingIfNeeded: v) }

/// Lists directories with getattrlistbulk(2): name, type, mtime, size and mount status of all
/// entries in a handful of syscalls – the fastest public way to enumerate APFS/HFS+.
final class BulkLister {
    private let bufferSize = 256 * 1024
    private let buffer: UnsafeMutableRawPointer
    private var attrs = attrlist()

    private let cmnName = ag(ATTR_CMN_NAME)
    private let cmnError = ag(ATTR_CMN_ERROR)
    private let cmnObjType = ag(ATTR_CMN_OBJTYPE)
    private let cmnCrTime = ag(ATTR_CMN_CRTIME)
    private let cmnModTime = ag(ATTR_CMN_MODTIME)
    private let dirMount = ag(ATTR_DIR_MOUNTSTATUS)
    private let cmnFlags = ag(ATTR_CMN_FLAGS)
    private let fileAlloc = ag(ATTR_FILE_ALLOCSIZE)
    private let fileLength = ag(ATTR_FILE_DATALENGTH)

    init() {
        buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 16)
        attrs.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        attrs.commonattr = ag(ATTR_CMN_RETURNED_ATTRS) | cmnName | cmnError | cmnObjType | cmnCrTime | cmnModTime | cmnFlags
        attrs.dirattr = dirMount
        attrs.fileattr = fileAlloc | fileLength
    }

    deinit { buffer.deallocate() }

    /// Returns 0 on success or an errno value.
    func list(_ path: String, into out: DirListing) -> Int32 {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else {
            out.reset()
            return errno
        }
        defer { close(fd) }
        return list(fd: fd, into: out)
    }

    /// Lists an already opened directory (the descriptor stays open).
    func list(fd: Int32, into out: DirListing) -> Int32 {
        out.reset()
        while true {
            let n = getattrlistbulk(fd, &attrs, buffer, bufferSize, 0)
            if n < 0 { return errno }
            if n == 0 { break }
            var entry = buffer
            for _ in 0..<Int(n) {
                let length = Int(entry.loadUnaligned(as: UInt32.self))
                var field = entry + 4
                let returned = field.loadUnaligned(as: attribute_set_t.self)
                field += MemoryLayout<attribute_set_t>.size
                if returned.commonattr & cmnError != 0 { field += 4 }
                var namePtr: UnsafeRawPointer?
                var nameLen = 0
                if returned.commonattr & cmnName != 0 {
                    let ref = field.loadUnaligned(as: attrreference_t.self)
                    namePtr = UnsafeRawPointer(field + Int(ref.attr_dataoffset))
                    nameLen = max(0, Int(ref.attr_length) - 1)
                    field += MemoryLayout<attrreference_t>.size
                }
                var objType: UInt32 = 0
                if returned.commonattr & cmnObjType != 0 {
                    objType = field.loadUnaligned(as: UInt32.self)
                    field += 4
                }
                // Common attributes come in bit order: CRTIME (0x200) before MODTIME (0x400).
                var ctime: Int64 = 0
                if returned.commonattr & cmnCrTime != 0 {
                    ctime = Int64(field.loadUnaligned(as: timespec.self).tv_sec)
                    field += MemoryLayout<timespec>.size
                }
                var mtime: Int64 = 0
                if returned.commonattr & cmnModTime != 0 {
                    mtime = Int64(field.loadUnaligned(as: timespec.self).tv_sec)
                    field += MemoryLayout<timespec>.size
                }
                var bsdFlags: UInt32 = 0
                if returned.commonattr & cmnFlags != 0 {
                    bsdFlags = field.loadUnaligned(as: UInt32.self)
                    field += 4
                }
                var isMount = false
                if returned.dirattr & dirMount != 0 {
                    isMount = field.loadUnaligned(as: UInt32.self) & UInt32(DIR_MNTSTATUS_MNTPOINT) != 0
                    field += 4
                }
                // File attributes come in bit order: ALLOCSIZE (0x4) before DATALENGTH (0x200).
                var alloc: Int64 = 0
                if returned.fileattr & fileAlloc != 0 {
                    alloc = field.loadUnaligned(as: Int64.self)
                    field += 8
                }
                var size: Int64 = 0
                if returned.fileattr & fileLength != 0 {
                    size = field.loadUnaligned(as: Int64.self)
                    field += 8
                }
                entry += length

                guard let np = namePtr, nameLen > 0 else { continue }
                let bytes = UnsafeBufferPointer(start: np.assumingMemoryBound(to: UInt8.self), count: nameLen)
                var f: UInt8 = 0
                if objType == 2 { f |= EntryFlag.directory }       // VDIR
                if objType == 5 { f |= EntryFlag.symlink }         // VLNK
                if isMount { f |= EntryFlag.mountPoint }
                if bytes[0] == UInt8(ascii: ".") { f |= EntryFlag.hidden }
                if bsdFlags & UInt32(SF_DATALESS) != 0 { f |= EntryFlag.dataless }
                let ns = out.names.count
                out.names.append(contentsOf: bytes)
                let fs = out.folds.count
                Fold.append(bytes, to: &out.folds)
                out.entries.append(ListedEntry(nameStart: ns, nameLen: nameLen, foldStart: fs,
                                               foldLen: out.folds.count - fs, flags: f,
                                               size: f & EntryFlag.directory != 0 ? 0 : size,
                                               alloc: f & EntryFlag.directory != 0 ? 0 : alloc, mtime: mtime, ctime: ctime))
            }
        }
        return 0
    }
}

func joinPath(_ dir: String, _ name: String) -> String {
    dir.hasSuffix("/") ? dir + name : dir + "/" + name
}

/// What to do with one listed entry: nil = excluded; otherwise its path/name for directories.
struct ChildPlan {
    let path: String
    let descend: Bool
}

extension DirListing {
    /// Computes child paths and exclusions *outside* the index lock.
    func prepare(parentPath: String, isExcluded: (String) -> Bool, only subset: [ListedEntry]? = nil) -> [ChildPlan?] {
        (subset ?? entries).map { e in
            guard e.isDirectory else { return ChildPlan(path: "", descend: false) }
            let p = joinPath(parentPath, nameString(e))
            if isExcluded(p) { return nil }
            return ChildPlan(path: p, descend: e.descendable)
        }
    }
}

extension FileIndex {
    /// Appends entries of `listing` as children of `parent` (write lock held). `paths` comes from
    /// `DirListing.prepare`. Returns the subdirectories to descend into.
    func appendListing(_ listing: DirListing, only subset: [ListedEntry]? = nil, parent: Int32,
                       plans: [ChildPlan?]) -> [ParallelScanner.Job] {
        var jobs: [ParallelScanner.Job] = []
        let list = subset ?? listing.entries
        names.reserve(names.count + listing.names.count + list.count)
        folds.reserve(folds.count + listing.folds.count + list.count)
        listing.names.withUnsafeBufferPointer { nb in
            listing.folds.withUnsafeBufferPointer { fb in
                for (k, e) in list.enumerated() {
                    guard let plan = plans[k] else { continue }
                    let id = append(name: UnsafeBufferPointer(rebasing: nb[e.nameStart..<e.nameStart + e.nameLen]),
                                    fold: UnsafeBufferPointer(rebasing: fb[e.foldStart..<e.foldStart + e.foldLen]),
                                    parent: parent, flags: e.flags, size: e.size, allocated: e.alloc, mtime: e.mtime, ctime: e.ctime)
                    if plan.descend { jobs.append(.init(id: id, path: plan.path)) }
                }
            }
        }
        return jobs
    }
}

/// Multi-threaded tree walker. Workers pop directories from a shared LIFO queue, list them with
/// getattrlistbulk and append the results to the index in one write-locked batch per directory.
final class ParallelScanner {
    struct Job {
        let id: Int32
        let path: String
    }

    static var defaultThreads: Int {
        if let s = ProcessInfo.processInfo.environment["QF_THREADS"], let n = Int(s), n > 0 { return n }
        return max(4, ProcessInfo.processInfo.activeProcessorCount * 2)
    }

    private let index: FileIndex
    private let isExcluded: (String) -> Bool
    private let progress: ((Int) -> Void)?
    private let cond = NSCondition()
    private var queue: [Job] = []
    private var active = 0
    private var stopped = false
    private(set) var directoriesScanned = 0

    init(index: FileIndex, isExcluded: @escaping (String) -> Bool, progress: ((Int) -> Void)? = nil) {
        self.index = index
        self.isExcluded = isExcluded
        self.progress = progress
    }

    func cancel() {
        cond.lock()
        stopped = true
        cond.broadcast()
        cond.unlock()
    }

    var isCancelled: Bool {
        cond.lock()
        defer { cond.unlock() }
        return stopped
    }

    /// Scans the given directories (already present in the index) recursively. Blocks until done.
    func run(_ jobs: [Job], threads: Int = ParallelScanner.defaultThreads) {
        guard !jobs.isEmpty else { return }
        cond.lock()
        queue.append(contentsOf: jobs)
        cond.unlock()
        let group = DispatchGroup()
        for _ in 0..<threads {
            group.enter()
            let t = Thread { [self] in
                worker()
                group.leave()
            }
            t.qualityOfService = .userInitiated
            t.stackSize = 1 << 20
            t.start()
        }
        group.wait()
    }

    private struct Pending {
        let job: Job
        let listing: DirListing
        let plans: [ChildPlan?]
    }

    /// Each worker lists directories into a local batch and commits the batch to the index under
    /// one write lock (instead of one lock round-trip per directory). `active` counts jobs taken
    /// but not yet committed, so idle workers wait rather than exit while batches are pending.
    private func worker() {
        let lister = BulkLister()
        var pending: [Pending] = []
        var pendingEntries = 0
        var pool: [DirListing] = []

        func commit() {
            var newJobs: [Job] = []
            var total = 0
            index.lock.write {
                for p in pending where index.isLive(p.job.id) {
                    newJobs += index.appendListing(p.listing, parent: p.job.id, plans: p.plans)
                }
                total = index.liveCount
            }
            let n = pending.count
            for p in pending { pool.append(p.listing) }
            pending.removeAll(keepingCapacity: true)
            pendingEntries = 0
            cond.lock()
            queue.append(contentsOf: newJobs)
            active -= n
            directoriesScanned += n
            if !newJobs.isEmpty || active == 0 { cond.broadcast() }
            cond.unlock()
            if total > 0 { progress?(total) }
        }

        while true {
            cond.lock()
            while queue.isEmpty && active > 0 && !stopped && pending.isEmpty { cond.wait() }
            if stopped {
                cond.broadcast()
                cond.unlock()
                return
            }
            if queue.isEmpty {
                cond.unlock()
                if pending.isEmpty { return }   // active == 0: all work done
                commit()
                continue
            }
            let job = queue.removeLast()
            active += 1
            let queueLow = queue.count < 4
            cond.unlock()

            let listing = pool.popLast() ?? DirListing()
            _ = lister.list(job.path, into: listing)
            let plans = listing.prepare(parentPath: job.path, isExcluded: isExcluded)
            pending.append(Pending(job: job, listing: listing, plans: plans))
            pendingEntries += listing.entries.count
            if pendingEntries >= 4096 || pending.count >= 256 || queueLow { commit() }
        }
    }
}
