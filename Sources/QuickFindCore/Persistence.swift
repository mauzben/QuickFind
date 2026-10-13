import Foundation

public struct IndexMetadata: Codable {
    public var version: Int
    public var lastEventID: UInt64
    public var configKey: String
    public var volumeUUIDs: [String: String]
    public var savedAt: Date
    var count: Int
    var namesCount: Int
    var foldsCount: Int
}

public enum IndexStoreError: Error {
    case badFormat
}

/// Binary snapshot: magic, header length, JSON header, then the raw (compacted) arrays.
extension FileIndex {
    static let magic: UInt32 = 0x5846_5141 // "AQFX"
    static let formatVersion = 3   // 2: allocated sizes, 3: creation dates

    /// Streams a compacted snapshot (live entries only, renumbered) to disk in 1 MB chunks, so saving
    /// needs no second copy of the index in memory. Holds the read lock while writing.
    public func save(to url: URL, lastEventID: UInt64, configKey: String, volumeUUIDs: [String: String]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tmp = url.appendingPathExtension("tmp")
        let fd = open(tmp.path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let out = ChunkWriter(fd: fd)
        defer { close(fd) }

        try lock.read {
            let v = view()
            let n = count
            // Pass 1: new IDs (parents always precede children) and buffer sizes.
            let map = Buffer<Int32>(capacity: max(1, n))
            map.resize(n)
            var live = 0, namesCount = 0, foldsCount = 0
            for i in 0..<n {
                map[i] = -1
                guard v.flags[i] & EntryFlag.deleted == 0 else { continue }
                let p = Int(v.parents[i])
                if p >= 0 && map[p] < 0 { continue }   // orphan of a deleted folder
                map[i] = Int32(live)
                live += 1
                namesCount += v.name(i).count + 1
                foldsCount += v.fold(i).count + 1
            }
            let meta = IndexMetadata(version: Self.formatVersion, lastEventID: lastEventID, configKey: configKey,
                                     volumeUUIDs: volumeUUIDs, savedAt: Date(), count: live,
                                     namesCount: namesCount, foldsCount: foldsCount)
            let header = try JSONEncoder().encode(meta)
            try out.put(Self.magic.littleEndian)
            try out.put(UInt32(header.count).littleEndian)
            try header.withUnsafeBytes { try out.write($0) }

            // Pass 2: one sequential sweep per array.
            func each(_ body: (Int) throws -> Void) rethrows {
                for i in 0..<n where map[i] >= 0 { try body(i) }
            }
            try each { i in try out.write(UnsafeRawBufferPointer(v.name(i))); try out.put(UInt8(0)) }
            try each { i in try out.write(UnsafeRawBufferPointer(v.fold(i))); try out.put(UInt8(0)) }
            var offset: UInt32 = 0
            try each { i in try out.put(offset); offset += UInt32(v.name(i).count + 1) }
            offset = 0
            try each { i in try out.put(offset); offset += UInt32(v.fold(i).count + 1) }
            try each { i in let p = Int(v.parents[i]); try out.put(p >= 0 ? map[p] : Int32(-1)) }
            try each { i in try out.put(v.sizes[i]) }
            try each { i in try out.put(v.allocs[i]) }
            try each { i in try out.put(v.mtimes[i]) }
            try each { i in try out.put(v.ctimes[i]) }
            try each { i in try out.put(v.flags[i]) }
            try out.flush()
        }
        guard rename(tmp.path, url.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    public func load(from url: URL) throws -> IndexMetadata {
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        return try data.withUnsafeBytes { raw -> IndexMetadata in
            guard raw.count >= 8, raw.loadUnaligned(fromByteOffset: 0, as: UInt32.self) == Self.magic else {
                throw IndexStoreError.badFormat
            }
            let hlen = Int(raw.loadUnaligned(fromByteOffset: 4, as: UInt32.self))
            guard 8 + hlen <= raw.count else { throw IndexStoreError.badFormat }
            let meta = try JSONDecoder().decode(IndexMetadata.self, from: Data(raw[8..<8 + hlen]))
            guard meta.version == Self.formatVersion else { throw IndexStoreError.badFormat }
            let n = meta.count
            let expected = meta.namesCount + meta.foldsCount + n * (4 + 4 + 4 + 8 + 8 + 8 + 8 + 1)
            guard raw.count == 8 + hlen + expected else { throw IndexStoreError.badFormat }

            try lock.write {
                reset()
                var off = 8 + hlen
                func read<T>(_ b: Buffer<T>, _ count: Int) {
                    b.resize(count)
                    memcpy(b.base, raw.baseAddress! + off, count * MemoryLayout<T>.stride)
                    off += count * MemoryLayout<T>.stride
                }
                read(names, meta.namesCount)
                read(folds, meta.foldsCount)
                read(nameOff, n)
                read(foldOff, n)
                read(parents, n)
                read(sizes, n)
                read(allocs, n)
                read(mtimes, n)
                read(ctimes, n)
                read(flags, n)
                firstChild.resize(n)
                firstChild.fill(-1)
                nextSibling.resize(n)
                nextSibling.fill(-1)
                var roots: [Int32] = []
                for i in stride(from: n - 1, through: 0, by: -1) {
                    let p = parents[i]
                    if p >= 0 {
                        guard Int(p) < i else {
                            reset()
                            throw IndexStoreError.badFormat
                        }
                        nextSibling[i] = firstChild[Int(p)]
                        firstChild[Int(p)] = Int32(i)
                    } else {
                        roots.append(Int32(i))
                    }
                }
                rootIDs = roots.reversed()
                liveCount = n
                recomputeFolderSizes()
                generation &+= 1
            }
            return meta
        }
    }
}

/// Buffered sequential writer with a fixed 1 MB buffer.
private final class ChunkWriter {
    private let fd: Int32
    private let capacity = 1 << 20
    private let buffer: UnsafeMutableRawPointer
    private var used = 0

    init(fd: Int32) {
        self.fd = fd
        buffer = .allocate(byteCount: capacity, alignment: 16)
    }

    deinit { buffer.deallocate() }

    @inline(__always) func put<T>(_ value: T) throws {
        try withUnsafeBytes(of: value) { try write($0) }
    }

    func write(_ bytes: UnsafeRawBufferPointer) throws {
        var src = bytes
        while !src.isEmpty {
            if used == capacity { try flush() }
            let n = min(src.count, capacity - used)
            (buffer + used).copyMemory(from: src.baseAddress!, byteCount: n)
            used += n
            src = UnsafeRawBufferPointer(rebasing: src[n...])
        }
    }

    func flush() throws {
        var p = 0
        while p < used {
            let w = Darwin.write(fd, buffer + p, used - p)
            if w < 0 {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            p += w
        }
        used = 0
    }
}
