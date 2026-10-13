import Foundation

/// Finder-like name ordering: diacritics are ignored on the primary level ("Ärger" sorts with
/// "A"), and digit runs compare numerically ("Datei2" < "Datei10"). Names get a byte key once,
/// so sorting itself is plain memcmp.
enum Collation {
    private static let locale = Locale(identifier: "de_DE")

    /// Appends the sort key for a folded (lowercase NFC) name.
    static func appendKey(_ folded: UnsafeBufferPointer<UInt8>, to out: inout [UInt8]) {
        var ascii = true
        for b in folded where b >= 0x80 {
            ascii = false
            break
        }
        if ascii {
            encode(folded, &out)
        } else {
            let s = String(decoding: folded, as: UTF8.self)
                .folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: locale)
            let bytes = Array(s.utf8)
            bytes.withUnsafeBufferPointer { encode($0, &out) }
        }
    }

    /// Copies bytes; a digit run becomes 0x30, its length (without leading zeros), its digits.
    /// Since 0x30 can only meet another digit run at the same position, shorter numbers sort first.
    private static func encode(_ p: UnsafeBufferPointer<UInt8>, _ out: inout [UInt8]) {
        var i = 0
        while i < p.count {
            let b = p[i]
            guard b >= 48 && b <= 57 else {
                out.append(b)
                i += 1
                continue
            }
            var j = i
            while j < p.count && p[j] >= 48 && p[j] <= 57 { j += 1 }
            var s = i
            while s < j - 1 && p[s] == 48 { s += 1 }
            let len = min(j - s, 255)
            out.append(0x30)
            out.append(UInt8(len))
            out.append(contentsOf: UnsafeBufferPointer(rebasing: p[s..<s + len]))
            i = j
        }
    }

    /// Builds keys for `ids` in parallel. Returns concatenated key bytes and offsets (count + 1).
    static func keys(_ v: IndexView, _ ids: UnsafeBufferPointer<Int32>) -> (bytes: Buffer<UInt8>, offsets: Buffer<Int>) {
        let n = ids.count
        let chunks = max(1, min(64, n / 20_000))
        var parts = [[UInt8]](repeating: [], count: chunks)
        var lengths = [[Int32]](repeating: [], count: chunks)
        parts.withUnsafeMutableBufferPointer { pb in
            lengths.withUnsafeMutableBufferPointer { lb in
                DispatchQueue.concurrentPerform(iterations: chunks) { c in
                    let lo = c * n / chunks, hi = (c + 1) * n / chunks
                    var local: [UInt8] = []
                    var lens: [Int32] = []
                    local.reserveCapacity((hi - lo) * 24)
                    lens.reserveCapacity(hi - lo)
                    for k in lo..<hi {
                        let before = local.count
                        appendKey(v.fold(Int(ids[k])), to: &local)
                        lens.append(Int32(local.count - before))
                    }
                    pb[c] = local
                    lb[c] = lens
                }
            }
        }
        let bytes = Buffer<UInt8>(capacity: parts.reduce(0) { $0 + $1.count })
        let offsets = Buffer<Int>(capacity: n + 1)
        offsets.append(0)
        for c in 0..<chunks {
            parts[c].withUnsafeBufferPointer { if let b = $0.baseAddress { bytes.append(b, count: $0.count) } }
            parts[c] = []
            for l in lengths[c] { offsets.append(offsets[offsets.count - 1] + Int(l)) }
            lengths[c] = []
        }
        return (bytes, offsets)
    }

    /// Sorts IDs by name in Finder order (ties: folded bytes, then ID).
    static func sortByName(_ v: IndexView, _ ids: inout [Int32]) {
        guard ids.count > 1 else { return }
        var order = ids
        ids.withUnsafeBufferPointer { idb in
            let (bytes, offsets) = keys(v, idb)
            var pos = (0..<Int32(idb.count)).map { $0 }
            let kb = bytes.base, ko = offsets.base
            withExtendedLifetime((bytes, offsets)) {
                ParallelSort.sort(&pos) { a, b in
                    let sa = ko[Int(a)], la = ko[Int(a) + 1] - sa
                    let sb = ko[Int(b)], lb = ko[Int(b) + 1] - sb
                    let r = memcmp(kb + sa, kb + sb, min(la, lb))
                    if r != 0 { return r < 0 }
                    if la != lb { return la < lb }
                    return v.lessByName(idb[Int(a)], idb[Int(b)])
                }
            }
            for (k, p) in pos.enumerated() { order[k] = idb[Int(p)] }
        }
        ids = order
    }

    /// Key for an arbitrary folded byte string (e.g. a folded path).
    static func key(_ folded: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        folded.withUnsafeBufferPointer { appendKey($0, to: &out) }
        return out
    }
}
