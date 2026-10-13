import Foundation

public enum EntryFlag {
    public static let directory: UInt8 = 1 << 0
    public static let deleted: UInt8 = 1 << 1
    public static let root: UInt8 = 1 << 2
    public static let symlink: UInt8 = 1 << 3
    public static let mountPoint: UInt8 = 1 << 4
    public static let hidden: UInt8 = 1 << 5
    /// Cloud file whose contents are not downloaded (iCloud/OneDrive "online only").
    public static let dataless: UInt8 = 1 << 6
}

public struct EntryInfo {
    public let id: Int32
    public let name: String
    public let parentPath: String
    /// Logical size (like the Finder's "Größe"); for folders the sum of their contents.
    public let size: Int64
    /// Space actually used on disk (sparse files, compression and cloud placeholders use less).
    public let allocated: Int64
    public let mtime: Int64
    /// Creation date (seconds since 1970).
    public let created: Int64
    public let flags: UInt8

    public var isDirectory: Bool { flags & EntryFlag.directory != 0 }
    public var isOnlineOnly: Bool { flags & EntryFlag.dataless != 0 }
    public var isSymlink: Bool { flags & EntryFlag.symlink != 0 }
    public var path: String {
        if parentPath.isEmpty { return name }
        return parentPath.hasSuffix("/") ? parentPath + name : parentPath + "/" + name
    }
}

/// Raw read-only view of the index storage. Only valid while the index lock is held.
public struct IndexView {
    public let count: Int
    let names: UnsafePointer<UInt8>
    let namesEnd: Int
    let folds: UnsafePointer<UInt8>
    let foldsEnd: Int
    let nameOff: UnsafePointer<UInt32>
    let foldOff: UnsafePointer<UInt32>
    let parents: UnsafePointer<Int32>
    let sizes: UnsafePointer<Int64>
    let allocs: UnsafePointer<Int64>
    let mtimes: UnsafePointer<Int64>
    let ctimes: UnsafePointer<Int64>
    let flags: UnsafePointer<UInt8>

    @inline(__always) func name(_ i: Int) -> UnsafeBufferPointer<UInt8> {
        let s = Int(nameOff[i])
        let e = i + 1 < count ? Int(nameOff[i + 1]) - 1 : namesEnd - 1
        return UnsafeBufferPointer(start: names + s, count: e - s)
    }

    @inline(__always) func fold(_ i: Int) -> UnsafeBufferPointer<UInt8> {
        let s = Int(foldOff[i])
        let e = i + 1 < count ? Int(foldOff[i + 1]) - 1 : foldsEnd - 1
        return UnsafeBufferPointer(start: folds + s, count: e - s)
    }

    /// Folded extension (after the last dot) of a file; empty for folders and dot-less names.
    @inline(__always) func ext(_ i: Int) -> UnsafeBufferPointer<UInt8> {
        let f = fold(i)
        guard flags[i] & EntryFlag.directory == 0 else { return UnsafeBufferPointer(start: f.baseAddress, count: 0) }
        var dot = f.count - 1
        while dot > 0 && f[dot] != UInt8(ascii: ".") { dot -= 1 }
        if dot <= 0 { return UnsafeBufferPointer(start: f.baseAddress, count: 0) }
        return UnsafeBufferPointer(rebasing: f[(dot + 1)...])
    }

    /// Appends the full path of `i` (raw or folded bytes) to `out`.
    func appendPath(_ i: Int, folded: Bool, to out: inout [UInt8]) {
        let p = Int(parents[i])
        if p >= 0 {
            appendPath(p, folded: folded, to: &out)
            if out.last != UInt8(ascii: "/") { out.append(UInt8(ascii: "/")) }
        }
        out.append(contentsOf: folded ? fold(i) : name(i))
    }

    @inline(__always) func lessByName(_ a: Int32, _ b: Int32) -> Bool {
        let fa = fold(Int(a)), fb = fold(Int(b))
        let r = memcmp(fa.baseAddress!, fb.baseAddress!, min(fa.count, fb.count))
        if r != 0 { return r < 0 }
        if fa.count != fb.count { return fa.count < fb.count }
        return a < b
    }
}

/// The in-memory file name database.
///
/// Storage is struct-of-arrays: one byte buffer with all names (NUL separated), one with the
/// case-folded names, plus parallel arrays for parent, size, mtime and flags. The tree is kept
/// as firstChild/nextSibling links so path lookups need no hash maps. Entry IDs are stable for
/// the lifetime of the process (deleted entries are tombstoned and dropped when saving).
/// Invariant: parent ID < child ID.
public final class FileIndex {
    public let lock = RWLock()

    let names = Buffer<UInt8>(capacity: 1 << 22)
    let folds = Buffer<UInt8>(capacity: 1 << 22)
    let nameOff = Buffer<UInt32>(capacity: 1 << 18)
    let foldOff = Buffer<UInt32>(capacity: 1 << 18)
    let parents = Buffer<Int32>(capacity: 1 << 18)
    let firstChild = Buffer<Int32>(capacity: 1 << 18)
    let nextSibling = Buffer<Int32>(capacity: 1 << 18)
    let sizes = Buffer<Int64>(capacity: 1 << 18)
    let allocs = Buffer<Int64>(capacity: 1 << 18)
    let mtimes = Buffer<Int64>(capacity: 1 << 18)
    let ctimes = Buffer<Int64>(capacity: 1 << 18)
    let flags = Buffer<UInt8>(capacity: 1 << 18)

    var rootIDs: [Int32] = []
    var liveCount = 0
    var generation: UInt64 = 0

    // Global name order (ranks) used for O(n) sorting by name.
    var nameOrder: [Int32] = []
    var nameRank: [Int32] = []

    public init() {}

    var count: Int { flags.count }

    // MARK: Public, self-locking API

    /// Number of live entries and the mutation counter.
    public var stats: (count: Int, generation: UInt64) { lock.read { (liveCount, generation) } }

    public var memoryBytes: Int {
        lock.read {
            names.bytes + folds.bytes + nameOff.bytes + foldOff.bytes + parents.bytes + firstChild.bytes
                + nextSibling.bytes + sizes.bytes + allocs.bytes + mtimes.bytes + ctimes.bytes + flags.bytes + nameOrder.count * 8
        }
    }

    public func info(_ id: Int32) -> EntryInfo? { lock.read { entryInfo(id) } }

    public func path(of id: Int32) -> String? { lock.read { isLive(id) ? pathString(id) : nil } }

    public func id(forPath path: String) -> Int32? { lock.read { lookup(path) } }

    // MARK: Internal API (caller holds the lock)

    func view() -> IndexView {
        IndexView(count: count, names: names.base, namesEnd: names.count, folds: folds.base,
                  foldsEnd: folds.count, nameOff: nameOff.base, foldOff: foldOff.base,
                  parents: parents.base, sizes: sizes.base, allocs: allocs.base, mtimes: mtimes.base, ctimes: ctimes.base, flags: flags.base)
    }

    @inline(__always) func isLive(_ id: Int32) -> Bool {
        id >= 0 && Int(id) < count && flags[Int(id)] & EntryFlag.deleted == 0
    }

    @inline(__always) func isDirectory(_ id: Int32) -> Bool { flags[Int(id)] & EntryFlag.directory != 0 }

    /// Gives back the growth slack of the buffers after a load or full scan (≈ 20 % of the index).
    public func compactStorage() {
        lock.write {
            let extra = max(4096, count / 50)          // ~2 % headroom for live updates
            names.shrinkToFit(headroom: extra * 24)
            folds.shrinkToFit(headroom: extra * 24)
            for b in [nameOff, foldOff] { b.shrinkToFit(headroom: extra) }
            for b in [parents, firstChild, nextSibling] { b.shrinkToFit(headroom: extra) }
            for b in [sizes, allocs, mtimes, ctimes] { b.shrinkToFit(headroom: extra) }
            flags.shrinkToFit(headroom: extra)
        }
        malloc_zone_pressure_relief(nil, 0)
    }

    func reset() {
        for b in [names, folds] { b.removeAll() }
        for b in [nameOff, foldOff] { b.removeAll() }
        for b in [parents, firstChild, nextSibling] { b.removeAll() }
        sizes.removeAll()
        allocs.removeAll()
        mtimes.removeAll()
        ctimes.removeAll()
        flags.removeAll()
        rootIDs = []
        liveCount = 0
        nameOrder = []
        nameRank = []
        generation &+= 1
    }

    @discardableResult
    func append(name: UnsafeBufferPointer<UInt8>, fold: UnsafeBufferPointer<UInt8>, parent: Int32,
                flags f: UInt8, size: Int64, allocated: Int64, mtime: Int64, ctime: Int64 = 0) -> Int32 {
        let id = Int32(count)
        nameOff.append(UInt32(names.count))
        if let b = name.baseAddress { names.append(b, count: name.count) }
        names.append(0)
        foldOff.append(UInt32(folds.count))
        if let b = fold.baseAddress { folds.append(b, count: fold.count) }
        folds.append(0)
        parents.append(parent)
        firstChild.append(-1)
        if parent >= 0 {
            nextSibling.append(firstChild[Int(parent)])
            firstChild[Int(parent)] = id
        } else {
            nextSibling.append(-1)
        }
        sizes.append(size)
        allocs.append(allocated)
        mtimes.append(mtime)
        ctimes.append(ctime)
        flags.append(f)
        if (size != 0 || allocated != 0) && parent >= 0 { addSize(parent, size, allocated) }
        liveCount += 1
        generation &+= 1
        return id
    }

    /// Adds the deltas to `start` and all its ancestors (folder sizes are sums of their contents).
    func addSize(_ start: Int32, _ delta: Int64, _ allocDelta: Int64) {
        var x = start
        while x >= 0 {
            sizes[Int(x)] &+= delta
            allocs[Int(x)] &+= allocDelta
            x = parents[Int(x)]
        }
    }

    /// Recomputes all folder sizes bottom-up (parent ID < child ID).
    func recomputeFolderSizes() {
        let n = count
        for i in 0..<n where flags[i] & EntryFlag.directory != 0 {
            sizes[i] = 0
            allocs[i] = 0
        }
        for i in stride(from: n - 1, through: 0, by: -1) where flags[i] & EntryFlag.deleted == 0 {
            let p = Int(parents[i])
            if p >= 0 {
                sizes[p] &+= sizes[i]
                allocs[p] &+= allocs[i]
            }
        }
    }

    /// Adds a root entry (e.g. "/" or "/Volumes/Backup"); returns the existing one if present.
    @discardableResult
    func addRoot(_ path: String, mtime: Int64 = 0) -> Int32 {
        if let r = rootIDs.first(where: { pathString($0) == path }) { return r }
        let raw = Array(path.utf8)
        let folded = Fold.fold(path)
        let id = raw.withUnsafeBufferPointer { n in
            folded.withUnsafeBufferPointer { f in
                append(name: n, fold: f, parent: -1, flags: EntryFlag.directory | EntryFlag.root, size: 0, allocated: 0, mtime: mtime)
            }
        }
        rootIDs.append(id)
        return id
    }

    var rootPaths: [(id: Int32, path: String)] { rootIDs.map { ($0, pathString($0)) } }

    /// Updates a listed entry. Folder sizes are aggregated, so a folder's listed size is ignored.
    func update(_ id: Int32, size: Int64, allocated: Int64, mtime: Int64, ctime: Int64, flags f: UInt8) {
        let i = Int(id)
        let isDir = f & EntryFlag.directory != 0
        let newSize = isDir ? sizes[i] : size
        let newAlloc = isDir ? allocs[i] : allocated
        if sizes[i] != newSize || allocs[i] != newAlloc || mtimes[i] != mtime || ctimes[i] != ctime || flags[i] != f {
            if newSize != sizes[i] || newAlloc != allocs[i] { addSize(id, newSize - sizes[i], newAlloc - allocs[i]) }
            mtimes[i] = mtime
            ctimes[i] = ctime
            flags[i] = f
            generation &+= 1
        }
    }

    func children(of id: Int32) -> [Int32] {
        var out: [Int32] = []
        var c = firstChild[Int(id)]
        while c >= 0 {
            out.append(c)
            c = nextSibling[Int(c)]
        }
        return out
    }

    func nameBytes(_ id: Int32) -> [UInt8] { Array(view().name(Int(id))) }

    func findChild(_ parent: Int32, name: [UInt8]) -> Int32? {
        let v = view()
        var c = firstChild[Int(parent)]
        while c >= 0 {
            let n = v.name(Int(c))
            if n.count == name.count && memcmp(n.baseAddress!, name, n.count) == 0 { return c }
            c = nextSibling[Int(c)]
        }
        // Fall back to a normalisation/case-insensitive comparison (APFS is usually case-insensitive).
        var folded: [UInt8] = []
        name.withUnsafeBufferPointer { Fold.append($0, to: &folded) }
        c = firstChild[Int(parent)]
        while c >= 0 {
            let f = v.fold(Int(c))
            if f.count == folded.count && memcmp(f.baseAddress!, folded, f.count) == 0 { return c }
            c = nextSibling[Int(c)]
        }
        return nil
    }

    /// Resolves an absolute path to an entry ID.
    func lookup(_ path: String) -> Int32? {
        let p = Array(path.utf8)
        var best: Int32 = -1
        var bestLen = -1
        for r in rootIDs {
            let rp = nameBytes(r)
            guard rp.count > bestLen, p.count >= rp.count, Array(p[0..<rp.count]) == rp else { continue }
            if p.count == rp.count || rp.last == UInt8(ascii: "/") || p[rp.count] == UInt8(ascii: "/") {
                best = r
                bestLen = rp.count
            }
        }
        guard best >= 0 else { return nil }
        var cur = best
        for comp in p[bestLen...].split(separator: UInt8(ascii: "/")) {
            guard let c = findChild(cur, name: Array(comp)) else { return nil }
            cur = c
        }
        return cur
    }

    func pathString(_ id: Int32) -> String {
        var out: [UInt8] = []
        out.reserveCapacity(128)
        view().appendPath(Int(id), folded: false, to: &out)
        return String(decoding: out, as: UTF8.self)
    }

    func entryInfo(_ id: Int32) -> EntryInfo? {
        guard id >= 0, Int(id) < count else { return nil }
        let v = view()
        let i = Int(id)
        let p = parents[i]
        return EntryInfo(id: id, name: String(decoding: v.name(i), as: UTF8.self),
                         parentPath: p >= 0 ? pathString(p) : "",
                         size: sizes[i], allocated: allocs[i], mtime: mtimes[i], created: ctimes[i], flags: flags[i])
    }

    /// Tombstones `id` and its whole subtree.
    func removeSubtree(_ id: Int32) {
        guard isLive(id) else { return }
        let p = parents[Int(id)]
        if p >= 0 { addSize(p, -sizes[Int(id)], -allocs[Int(id)]) }
        if p >= 0 {
            var c = firstChild[Int(p)]
            if c == id {
                firstChild[Int(p)] = nextSibling[Int(id)]
            } else {
                while c >= 0 {
                    let n = nextSibling[Int(c)]
                    if n == id {
                        nextSibling[Int(c)] = nextSibling[Int(id)]
                        break
                    }
                    c = n
                }
            }
        } else {
            rootIDs.removeAll { $0 == id }
        }
        markDeleted(id)
    }

    /// Tombstones all descendants of `id` but keeps `id` itself.
    func removeChildren(_ id: Int32) {
        addSize(id, -sizes[Int(id)], -allocs[Int(id)])
        var c = firstChild[Int(id)]
        firstChild[Int(id)] = -1
        while c >= 0 {
            let n = nextSibling[Int(c)]
            markDeleted(c)
            c = n
        }
    }

    private func markDeleted(_ id: Int32) {
        var stack: [Int32] = [id]
        while let x = stack.popLast() {
            let i = Int(x)
            guard flags[i] & EntryFlag.deleted == 0 else { continue }
            flags[i] |= EntryFlag.deleted
            liveCount -= 1
            var c = firstChild[i]
            while c >= 0 {
                stack.append(c)
                c = nextSibling[Int(c)]
            }
            firstChild[i] = -1
        }
        generation &+= 1
    }

    // MARK: Name order

    /// Recomputes the global name ordering. Sorting happens under the read lock (searches keep
    /// running), the result is installed under the write lock.
    public func rebuildNameOrder() {
        let (order, rank) = lock.read { () -> ([Int32], [Int32]) in
            let v = view()
            let n = count
            var ids: [Int32] = []
            ids.reserveCapacity(liveCount)
            for i in 0..<n where v.flags[i] & (EntryFlag.deleted | EntryFlag.root) == 0 {
                ids.append(Int32(i))
            }
            Collation.sortByName(v, &ids)
            var rank = [Int32](repeating: .max, count: n)
            for (r, id) in ids.enumerated() { rank[Int(id)] = Int32(r) }
            return (ids, rank)
        }
        lock.write {
            nameOrder = order
            nameRank = rank
        }
        // The sort keys were large temporary allocations; hand the freed pages back to the system.
        malloc_zone_pressure_relief(nil, 0)
    }
}
