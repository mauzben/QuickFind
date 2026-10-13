import Foundation

public enum SortKey: String, Codable, CaseIterable {
    case name, path, size, allocated, date, created, type
}

public struct SearchResult {
    public let ids: [Int32]
    public let seconds: Double
    public let indexedCount: Int
    public let generation: UInt64
    /// Sum of the sizes of all files in the result (folders are not counted twice).
    public let totalSize: Int64
    /// Sum of the space the result's files use on disk.
    public let totalAllocated: Int64

    public init(ids: [Int32], seconds: Double, indexedCount: Int, generation: UInt64, totalSize: Int64 = 0,
                totalAllocated: Int64 = 0) {
        self.ids = ids
        self.seconds = seconds
        self.indexedCount = indexedCount
        self.generation = generation
        self.totalSize = totalSize
        self.totalAllocated = totalAllocated
    }
}

/// Lazily built per-entry state for terms that need the full path. Caches the parent's path,
/// because consecutive IDs usually share a parent directory.
struct Scratch {
    var id = -1
    var path: [UInt8] = []
    var folded: [UInt8] = []
    var hasPath = false
    var hasFolded = false
    var parentPath: [UInt8] = []
    var parentFolded: [UInt8] = []
    var parentPathID = -2
    var parentFoldedID = -2
    var window: [UInt8] = []
    var comps: [Int] = []

    /// Appends the last ≤ maxLen bytes of path(p) to `out`.
    static func appendTail(_ p: Int, _ v: IndexView, folded: Bool, maxLen: Int, comps: inout [Int], into out: inout [UInt8]) {
        guard maxLen > 0 else { return }
        comps.removeAll(keepingCapacity: true)
        var len = 0
        var x = p
        while x >= 0 && len < maxLen {
            comps.append(x)
            len += (folded ? v.fold(x) : v.name(x)).count + 1
            x = Int(v.parents[x])
        }
        let start = out.count
        // Stopped below the root: the path continues above, so a separator precedes the first component.
        if x >= 0 { out.append(UInt8(ascii: "/")) }
        for c in comps.reversed() {
            if out.count > start && out.last != UInt8(ascii: "/") { out.append(UInt8(ascii: "/")) }
            out.append(contentsOf: folded ? v.fold(c) : v.name(c))
        }
        let extra = out.count - start - maxLen
        if extra > 0 { out.removeSubrange(start..<start + extra) }
    }

    @inline(__always) mutating func begin(_ i: Int) {
        if id != i {
            id = i
            hasPath = false
            hasFolded = false
        }
    }

    private static func build(_ i: Int, _ v: IndexView, folded: Bool, parentID: inout Int, parent: inout [UInt8],
                              into out: inout [UInt8]) {
        let p = Int(v.parents[i])
        if p != parentID {
            parent.removeAll(keepingCapacity: true)
            if p >= 0 { v.appendPath(p, folded: folded, to: &parent) }
            parentID = p
        }
        out.removeAll(keepingCapacity: true)
        out.append(contentsOf: parent)
        if !out.isEmpty && out.last != UInt8(ascii: "/") { out.append(UInt8(ascii: "/")) }
        out.append(contentsOf: folded ? v.fold(i) : v.name(i))
    }

    @inline(__always) mutating func with(_ i: Int, _ v: IndexView, path matchPath: Bool, case matchCase: Bool,
                                          _ body: (UnsafeBufferPointer<UInt8>) -> Bool) -> Bool {
        if !matchPath { return body(matchCase ? v.name(i) : v.fold(i)) }
        if matchCase {
            if !hasPath {
                Self.build(i, v, folded: false, parentID: &parentPathID, parent: &parentPath, into: &path)
                hasPath = true
            }
            return path.withUnsafeBufferPointer(body)
        } else {
            if !hasFolded {
                Self.build(i, v, folded: true, parentID: &parentFoldedID, parent: &parentFolded, into: &folded)
                hasFolded = true
            }
            return folded.withUnsafeBufferPointer(body)
        }
    }
}

@inline(__always) private func isWordByte(_ b: UInt8) -> Bool {
    b >= 0x80 || (b >= 48 && b <= 57) || (b | 0x20 >= 97 && b | 0x20 <= 122) || b == 95
}

/// Non-refcounted needle reference for the hot loop.
struct RawNeedle {
    let ptr: UnsafePointer<UInt8>
    let count: Int
}

enum Match {
    @inline(__always) static func contains(_ h: UnsafeBufferPointer<UInt8>, _ n: RawNeedle, wholeWord: Bool) -> Bool {
        guard n.count <= h.count, let base = h.baseAddress else { return false }
        if !wholeWord { return memmem(base, h.count, n.ptr, n.count) != nil }
        var start = 0
        while start + n.count <= h.count {
            guard let hit = memmem(base + start, h.count - start, n.ptr, n.count) else { return false }
            let pos = UnsafePointer<UInt8>(hit.assumingMemoryBound(to: UInt8.self)) - base
            let okL = pos == 0 || !isWordByte(h[pos - 1])
            let okR = pos + n.count == h.count || !isWordByte(h[pos + n.count])
            if okL && okR { return true }
            start = pos + 1
        }
        return false
    }

    /// `*` / `?` matching on UTF-8 bytes; `?` consumes one whole character.
    static func wildcard(_ p: RawNeedle, _ s: UnsafeBufferPointer<UInt8>) -> Bool {
        @inline(__always) func charLen(_ b: UInt8) -> Int { b < 0x80 ? 1 : b >= 0xF0 ? 4 : b >= 0xE0 ? 3 : b >= 0xC0 ? 2 : 1 }
        let pc = p.count, sc = s.count, pp = p.ptr
        var pi = 0, si = 0, starP = -1, starS = 0
        while si < sc {
            if pi < pc && pp[pi] == UInt8(ascii: "?") {
                si += charLen(s[si])
                pi += 1
            } else if pi < pc && pp[pi] == UInt8(ascii: "*") {
                starP = pi
                starS = si
                pi += 1
            } else if pi < pc && pp[pi] == s[si] {
                pi += 1
                si += 1
            } else if starP >= 0 {
                pi = starP + 1
                starS += charLen(s[starS])
                si = starS
            } else {
                return false
            }
        }
        while pi < pc && pp[pi] == UInt8(ascii: "*") { pi += 1 }
        return pi == pc && si == sc
    }
}

private let bundleExtensions: Set<[UInt8]> = Set(["app", "bundle", "framework", "key", "numbers", "pages", "pkg", "mpkg", "plugin",
                                                  "rtfd", "photoslibrary", "musiclibrary", "xcodeproj", "xcworkspace", "playground"]
    .map { Array($0.utf8) })

/// Flat, trivially copyable form of a Term. Copying it in the hot loop costs no refcounting,
/// which would otherwise serialise all cores on the shared objects' reference counts.
struct CTerm {
    enum Kind: UInt8 { case any, never, text, wildcard, regex, ext, size, date, created, dupe }
    var kind: Kind
    var negate: Bool
    var matchCase: Bool
    var matchPath: Bool
    var wholeWord: Bool
    var type: TypeRequirement
    var needles: UnsafePointer<RawNeedle>?
    var needleCount: Int
    var lo: Int64
    var hi: Int64
    var regex: Unmanaged<NSRegularExpression>?
    /// Per-entry memo for substring path terms: 0 = unknown, 1 = no match, 2 = match.
    var memo: UnsafeMutablePointer<UInt8>?
    var maxNeedle = 0

    /// Path substring match in O(1) amortised per entry: an entry matches if its parent's path
    /// matches, or if the window "tail of parent path + / + own name" contains the needle.
    func pathMatch(_ x: Int, _ v: IndexView, _ memo: UnsafeMutablePointer<UInt8>, _ s: inout Scratch) -> Bool {
        if memo[x] != 0 { return memo[x] == 2 }
        let p = Int(v.parents[x])
        var r = p >= 0 && pathMatch(p, v, memo, &s)
        if !r {
            s.window.removeAll(keepingCapacity: true)
            if p >= 0 { Scratch.appendTail(p, v, folded: !matchCase, maxLen: maxNeedle - 1, comps: &s.comps, into: &s.window) }
            if !s.window.isEmpty && s.window.last != UInt8(ascii: "/") { s.window.append(UInt8(ascii: "/")) }
            s.window.append(contentsOf: matchCase ? v.name(x) : v.fold(x))
            let ns = needles!, nc = needleCount
            r = s.window.withUnsafeBufferPointer { h in
                for k in 0..<nc where Match.contains(h, ns[k], wholeWord: false) { return true }
                return false
            }
        }
        memo[x] = r ? 2 : 1
        return r
    }

    @inline(__always) func test(_ i: Int, _ v: IndexView, _ s: inout Scratch) -> Bool {
        let isDir = v.flags[i] & EntryFlag.directory != 0
        switch type {
        case .file where isDir: return negate
        case .folder where !isDir: return negate
        default: break
        }
        let r: Bool
        switch kind {
        case .any:
            r = true
        case .never:
            r = false
        case .text:
            if let m = memo { return pathMatch(i, v, m, &s) != negate }
            let ns = needles!, nc = needleCount, ww = wholeWord
            r = s.with(i, v, path: matchPath, case: matchCase) { h in
                for k in 0..<nc where Match.contains(h, ns[k], wholeWord: ww) { return true }
                return false
            }
        case .wildcard:
            let p = needles![0]
            r = s.with(i, v, path: matchPath, case: matchCase) { Match.wildcard(p, $0) }
        case .regex:
            let re = regex!
            r = s.with(i, v, path: matchPath, case: matchCase) { h in
                let str = String(decoding: h, as: UTF8.self)
                return re._withUnsafeGuaranteedRef {
                    $0.firstMatch(in: str, range: NSRange(location: 0, length: str.utf16.count)) != nil
                }
            }
        case .ext:
            let f = v.fold(i)
            var dot = f.count - 1
            while dot >= 0 && f[dot] != UInt8(ascii: ".") { dot -= 1 }
            if dot <= 0 {
                r = false
            } else {
                let ep = f.baseAddress! + dot + 1
                let elen = f.count - dot - 1
                var hit = false
                for k in 0..<needleCount {
                    let e = needles![k]
                    if e.count == elen && memcmp(ep, e.ptr, elen) == 0 {
                        hit = true
                        break
                    }
                }
                if hit && isDir { hit = bundleExtensions.contains(Array(UnsafeBufferPointer(start: ep, count: elen))) }
                r = hit
            }
        case .size:
            // Folders have no meaningful logical size (sparse/cloud files inflate it): use the space used.
            let sz = isDir ? v.allocs[i] : v.sizes[i]
            r = sz >= lo && sz <= hi
        case .date:
            let t = v.mtimes[i]
            r = t >= lo && t <= hi
        case .created:
            let t = v.ctimes[i]
            r = t >= lo && t <= hi
        case .dupe:
            r = memo![i] == 1
        }
        return r != negate
    }
}

/// Owns the flat term/group arrays for one search. Keeps the Query (and so the needle
/// storage and regexes) alive.
final class CompiledQuery {
    let query: Query
    let terms: UnsafeMutableBufferPointer<CTerm>
    let groupEnds: UnsafeMutableBufferPointer<Int>
    private var needleBlocks: [UnsafeMutableBufferPointer<RawNeedle>] = []

    init(_ q: Query) {
        query = q
        let all = q.groups.flatMap { $0 }
        terms = .allocate(capacity: max(1, all.count))
        groupEnds = .allocate(capacity: max(1, q.groups.count))
        var end = 0
        for (gi, g) in q.groups.enumerated() {
            end += g.count
            groupEnds[gi] = end
        }
        for (k, t) in all.enumerated() {
            var c = CTerm(kind: .any, negate: t.negate, matchCase: t.matchCase, matchPath: t.matchPath,
                          wholeWord: t.wholeWord, type: t.type, needles: nil, needleCount: 0, lo: 0, hi: 0, regex: nil,
                          memo: nil, maxNeedle: 0)
            func setNeedles(_ ns: [Needle]) {
                let block = UnsafeMutableBufferPointer<RawNeedle>.allocate(capacity: max(1, ns.count))
                for (j, n) in ns.enumerated() { block[j] = RawNeedle(ptr: UnsafePointer(n.ptr), count: n.count) }
                needleBlocks.append(block)
                c.needles = UnsafePointer(block.baseAddress!)
                c.needleCount = ns.count
            }
            switch t.kind {
            case .any: c.kind = .any
            case .never: c.kind = .never
            case .text(let ns):
                c.kind = .text
                setNeedles(ns)
                c.maxNeedle = ns.map(\.count).max() ?? 0
            case .wildcard(let n): c.kind = .wildcard; setNeedles([n])
            case .regex(let re): c.kind = .regex; c.regex = Unmanaged.passUnretained(re)
            case .ext(let ns): c.kind = .ext; setNeedles(ns)
            case .size(let r): c.kind = .size; c.lo = r.lowerBound; c.hi = r.upperBound
            case .date(let r): c.kind = .date; c.lo = r.lowerBound; c.hi = r.upperBound
            case .created(let r): c.kind = .created; c.lo = r.lowerBound; c.hi = r.upperBound
            case .dupe: c.kind = .dupe
            }
            (terms.baseAddress! + k).initialize(to: c)
        }
    }

    /// Folder the search is restricted to (-1 = everywhere) and its memo: 0 unknown, 1 outside, 2 inside.
    var withinID = -1
    private(set) var withinMemo: UnsafeMutablePointer<UInt8>?

    /// Allocates per-search memos once the index size is known (called under the read lock).
    func prepare(_ v: IndexView, within: Int32?) {
        let count = v.count
        var dupes: UnsafeMutablePointer<UInt8>?
        for k in 0..<query.groups.reduce(0, { $0 + $1.count }) {
            if terms[k].kind == .text && terms[k].matchPath && !terms[k].wholeWord && terms[k].memo == nil {
                let m = UnsafeMutablePointer<UInt8>.allocate(capacity: max(1, count))
                m.initialize(repeating: 0, count: max(1, count))
                terms[k].memo = m
            }
            if terms[k].kind == .dupe && terms[k].memo == nil {
                if dupes == nil { dupes = Self.findDuplicates(v) }
                terms[k].memo = dupes
            }
        }
        if let w = within {
            withinID = Int(w)
            let m = UnsafeMutablePointer<UInt8>.allocate(capacity: max(1, count))
            m.initialize(repeating: 0, count: max(1, count))
            withinMemo = m
        }
    }

    /// Marks files whose (folded name, size) occurs more than once (empty files are ignored).
    static func findDuplicates(_ v: IndexView) -> UnsafeMutablePointer<UInt8> {
        let n = v.count
        let marks = UnsafeMutablePointer<UInt8>.allocate(capacity: max(1, n))
        marks.initialize(repeating: 0, count: max(1, n))
        var first: [UInt64: Int32] = [:]
        first.reserveCapacity(n / 2)
        for i in 0..<n {
            let f = v.flags[i]
            guard f & (EntryFlag.directory | EntryFlag.deleted | EntryFlag.symlink) == 0, v.sizes[i] > 0 else { continue }
            var h = Hasher()
            h.combine(bytes: UnsafeRawBufferPointer(v.fold(i)))
            h.combine(v.sizes[i])
            let key = UInt64(bitPattern: Int64(h.finalize()))
            if let j = first[key] {
                let a = v.fold(i), b = v.fold(Int(j))
                if v.sizes[i] == v.sizes[Int(j)] && a.count == b.count && memcmp(a.baseAddress!, b.baseAddress!, a.count) == 0 {
                    marks[i] = 1
                    marks[Int(j)] = 1
                }
            } else {
                first[key] = Int32(i)
            }
        }
        return marks
    }

    /// True if `i` is the search folder or below it.
    @inline(__always) func isWithin(_ i: Int, _ v: IndexView) -> Bool {
        guard let m = withinMemo else { return true }
        if i == withinID { return true }
        if m[i] != 0 { return m[i] == 2 }
        let p = Int(v.parents[i])
        let r = p >= 0 && isWithin(p, v)
        m[i] = r ? 2 : 1
        return r
    }

    deinit {
        let n = query.groups.reduce(0) { $0 + $1.count }
        var freed = Set<UnsafeMutablePointer<UInt8>>()
        for k in 0..<n {
            if let m = terms[k].memo, freed.insert(m).inserted { m.deallocate() }
        }
        withinMemo?.deallocate()
        terms.deallocate()
        groupEnds.deallocate()
        for b in needleBlocks { b.deallocate() }
    }
}

public enum SearchEngine {
    /// Runs `query` against the index. Returns nil when cancelled.
    /// Runs `query` against the index, optionally only below the folder `within`.
    /// Returns nil when cancelled (or an empty result if `within` is not in the index).
    public static func search(_ index: FileIndex, _ query: Query, within: String? = nil, sort: SortKey = .name,
                              ascending: Bool = true, cancel: CancelToken? = nil) -> SearchResult? {
        let start = DispatchTime.now().uptimeNanoseconds
        let cq = CompiledQuery(query)
        return withExtendedLifetime(cq) {
            index.lock.read { () -> SearchResult? in
                let v = index.view()
                var withinID: Int32?
                if let w = within {
                    guard let id = index.lookup(w) else {
                        return SearchResult(ids: [], seconds: 0, indexedCount: index.liveCount, generation: index.generation)
                    }
                    withinID = id
                }
                cq.prepare(v, within: withinID)
                guard var ids = query.matchesEverything && withinID == nil ? allLive(v) : scan(v, cq, cancel) else { return nil }
                if cancel?.isCancelled == true { return nil }
                // Sum before sorting: IDs are still ascending, so memory is read sequentially.
                var total: Int64 = 0, allocated: Int64 = 0
                for id in ids where v.flags[Int(id)] & EntryFlag.directory == 0 {
                    total &+= v.sizes[Int(id)]
                    allocated &+= v.allocs[Int(id)]
                }
                sortIDs(index, v, &ids, sort, ascending)
                let secs = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
                return SearchResult(ids: ids, seconds: secs, indexedCount: index.liveCount, generation: index.generation,
                                    totalSize: total, totalAllocated: allocated)
            }
        }
    }

    /// Lists the contents of one folder from the index (Finder-like browsing), optionally
    /// filtered by `query`. Returns nil if the folder is not in the index.
    public static func contents(of path: String, in index: FileIndex, query: Query, includeHidden: Bool,
                                sort: SortKey = .name, ascending: Bool = true) -> SearchResult? {
        let start = DispatchTime.now().uptimeNanoseconds
        let cq = CompiledQuery(query)
        return withExtendedLifetime(cq) {
            index.lock.read { () -> SearchResult? in
                guard let dir = index.lookup(path), index.isDirectory(dir) else { return nil }
                let v = index.view()
                cq.prepare(v, within: nil)
                var scratch = Scratch()
                let ends = UnsafeMutableBufferPointer(rebasing: cq.groupEnds[0..<query.groups.count])
                var ids = index.children(of: dir).filter { id in
                    let f = v.flags[Int(id)]
                    if !includeHidden && f & EntryFlag.hidden != 0 { return false }
                    return query.matchesEverything || matches(Int(id), v, cq.terms, ends, &scratch)
                }
                sortIDs(index, v, &ids, sort, ascending)
                let secs = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
                return SearchResult(ids: ids, seconds: secs, indexedCount: index.liveCount, generation: index.generation)
            }
        }
    }

    /// Re-sorts an existing result list (e.g. when the user clicks a column header).
    public static func sorted(_ index: FileIndex, _ ids: [Int32], sort: SortKey, ascending: Bool) -> [Int32] {
        index.lock.read {
            let v = index.view()
            var out = ids.filter { index.isLive($0) }
            sortIDs(index, v, &out, sort, ascending)
            return out
        }
    }

    static func allLive(_ v: IndexView) -> [Int32] {
        var ids: [Int32] = []
        ids.reserveCapacity(v.count)
        for i in 0..<v.count where v.flags[i] & (EntryFlag.deleted | EntryFlag.root) == 0 { ids.append(Int32(i)) }
        return ids
    }

    @inline(__always) static func matches(_ i: Int, _ v: IndexView, _ terms: UnsafeMutableBufferPointer<CTerm>,
                                          _ ends: UnsafeMutableBufferPointer<Int>, _ s: inout Scratch) -> Bool {
        if v.flags[i] & (EntryFlag.deleted | EntryFlag.root) != 0 { return false }
        s.begin(i)
        var t = 0
        for g in 0..<ends.count {
            let end = ends[g]
            var any = false
            while t < end {
                if terms[t].test(i, v, &s) {
                    any = true
                    break
                }
                t += 1
            }
            if !any { return false }
            t = end
        }
        return true
    }

    static func scan(_ v: IndexView, _ cq: CompiledQuery, _ cancel: CancelToken?) -> [Int32]? {
        let n = v.count
        guard n > 0 else { return [] }
        let chunks = min(512, max(1, n / 8192))
        var parts = [[Int32]](repeating: [], count: chunks)
        let driver = cq.query.driver.map { (needle: RawNeedle(ptr: UnsafePointer($0.needle.ptr), count: $0.needle.count),
                                            caseSensitive: $0.caseSensitive) }
        let terms = cq.terms
        let ends = UnsafeMutableBufferPointer(rebasing: cq.groupEnds[0..<cq.query.groups.count])
        parts.withUnsafeMutableBufferPointer { pb in
            DispatchQueue.concurrentPerform(iterations: chunks) { c in
                if c & 15 == 0, cancel?.isCancelled == true { return }
                let lo = c * n / chunks, hi = (c + 1) * n / chunks
                var out: [Int32] = []
                var scratch = Scratch()
                if let d = driver {
                    // Scan the whole (folded) name buffer of this chunk with memmem and map hits back to IDs.
                    let buf = d.caseSensitive ? v.names : v.folds
                    let off = d.caseSensitive ? v.nameOff : v.foldOff
                    let end = hi < n ? Int(off[hi]) : (d.caseSensitive ? v.namesEnd : v.foldsEnd)
                    var p = Int(off[lo])
                    while p < end {
                        guard let hit = memmem(buf + p, end - p, d.needle.ptr, d.needle.count) else { break }
                        let pos = UnsafePointer<UInt8>(hit.assumingMemoryBound(to: UInt8.self)) - buf
                        var a = lo, b = hi
                        while b - a > 1 {
                            let m = (a + b) >> 1
                            if Int(off[m]) <= pos { a = m } else { b = m }
                        }
                        if matches(a, v, terms, ends, &scratch) && cq.isWithin(a, v) && a != cq.withinID { out.append(Int32(a)) }
                        p = a + 1 < n ? Int(off[a + 1]) : end
                    }
                } else {
                    for i in lo..<hi where matches(i, v, terms, ends, &scratch) && cq.isWithin(i, v) && i != cq.withinID {
                        out.append(Int32(i))
                    }
                }
                pb[c] = out
            }
        }
        if cancel?.isCancelled == true { return nil }
        var ids: [Int32] = []
        ids.reserveCapacity(parts.reduce(0) { $0 + $1.count })
        for p in parts { ids.append(contentsOf: p) }
        return ids
    }

    // MARK: Sorting

    static func sortIDs(_ index: FileIndex, _ v: IndexView, _ ids: inout [Int32], _ key: SortKey, _ asc: Bool) {
        var reversed = false
        let rank = index.nameRank
        let order = index.nameOrder
        rank.withUnsafeBufferPointer { rk in
            @inline(__always) func r(_ id: Int32) -> Int32 { Int(id) < rk.count ? rk[Int(id)] : .max }
            let allRanked = !rk.isEmpty && ids.allSatisfy { r($0) != .max }
            @inline(__always) func nameLess(_ a: Int32, _ b: Int32) -> Bool {
                if allRanked { return r(a) < r(b) }
                let ra = r(a), rb = r(b)
                if ra != .max && rb != .max { return ra < rb }
                return v.lessByName(a, b)
            }
            switch key {
            case .name:
                if allRanked && ids.count > 100_000 && ids.count > v.count / 32 {
                    // Bitmap filter over the global name order: O(n) instead of O(k log k).
                    var bits = [UInt64](repeating: 0, count: v.count / 64 + 1)
                    for id in ids { bits[Int(id) >> 6] |= 1 << UInt64(id & 63) }
                    var out: [Int32] = []
                    out.reserveCapacity(ids.count)
                    for id in order where bits[Int(id) >> 6] & (1 << UInt64(id & 63)) != 0 { out.append(id) }
                    ids = out
                } else if allRanked {
                    var keyed = ids.map { (UInt64(UInt32(bitPattern: r($0))) << 32) | UInt64(UInt32(bitPattern: $0)) }
                    keyed.sort()
                    ids = keyed.map { Int32(truncatingIfNeeded: $0 & 0xFFFF_FFFF) }
                } else {
                    Collation.sortByName(v, &ids)
                }
            case .size, .allocated:
                // Folders first in both directions (like Everything), each group by size.
                var dirs = ids.filter { v.flags[Int($0)] & EntryFlag.directory != 0 }
                var files = ids.filter { v.flags[Int($0)] & EntryFlag.directory == 0 }
                let values = key == .size ? v.sizes : v.allocs
                func bySize(_ a: Int32, _ b: Int32) -> Bool {
                    let sa = values[Int(a)], sb = values[Int(b)]
                    return sa != sb ? sa < sb : nameLess(a, b)
                }
                func byAllocated(_ a: Int32, _ b: Int32) -> Bool {
                    let sa = v.allocs[Int(a)], sb = v.allocs[Int(b)]
                    return sa != sb ? sa < sb : nameLess(a, b)
                }
                ParallelSort.sort(&dirs, by: byAllocated)   // folders show no logical size
                ParallelSort.sort(&files, by: bySize)
                if !asc {
                    dirs.reverse()
                    files.reverse()
                }
                ids = dirs + files
                reversed = true
            case .type:
                ParallelSort.sort(&ids) { a, b in
                    let ea = v.ext(Int(a)), eb = v.ext(Int(b))
                    let r = memcmp(ea.baseAddress!, eb.baseAddress!, min(ea.count, eb.count))
                    if r != 0 { return r < 0 }
                    if ea.count != eb.count { return ea.count < eb.count }
                    return nameLess(a, b)
                }
            case .date, .created:
                let times = key == .date ? v.mtimes : v.ctimes
                ParallelSort.sort(&ids) { a, b in
                    let ta = times[Int(a)], tb = times[Int(b)]
                    return ta != tb ? ta < tb : nameLess(a, b)
                }
            case .path:
                // Rank distinct parent directories by their folded path, then sort by (parent, name).
                var parentSet = Set<Int32>()
                for id in ids { parentSet.insert(v.parents[Int(id)]) }
                var parentList = Array(parentSet)
                var paths: [Int32: [UInt8]] = [:]
                paths.reserveCapacity(parentList.count)
                for p in parentList {
                    var b: [UInt8] = []
                    if p >= 0 { v.appendPath(Int(p), folded: true, to: &b) }
                    paths[p] = Collation.key(b)
                }
                parentList.sort { a, b in
                    let pa = paths[a]!, pb = paths[b]!
                    return pa.lexicographicallyPrecedes(pb)
                }
                var prank: [Int32: Int32] = [:]
                prank.reserveCapacity(parentList.count)
                for (i, p) in parentList.enumerated() { prank[p] = Int32(i) }
                var pr = [Int32](repeating: 0, count: v.count)
                for id in ids { pr[Int(id)] = prank[v.parents[Int(id)]]! }
                ParallelSort.sort(&ids) { a, b in
                    let x = pr[Int(a)], y = pr[Int(b)]
                    return x != y ? x < y : nameLess(a, b)
                }
            }
        }
        if !asc && !reversed { ids.reverse() }
    }
}
