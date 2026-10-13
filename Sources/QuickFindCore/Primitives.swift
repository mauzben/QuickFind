import Foundation

/// A growable, manually managed array of trivial values with stable raw-pointer access.
/// Not thread-safe on its own: FileIndex guards every instance with its RWLock.
///
/// Large buffers come straight from the kernel (mmap): untouched capacity costs no memory, and
/// freed buffers return to the system at once instead of lingering in malloc's caches.
public final class Buffer<T> {
    public private(set) var base: UnsafeMutablePointer<T>
    public private(set) var count = 0
    public private(set) var capacity: Int
    private var mapped: Bool

    private static var mmapThreshold: Int { 256 * 1024 }

    public init(capacity: Int = 1024) {
        self.capacity = Swift.max(16, capacity)
        (base, mapped) = Buffer.allocate(self.capacity)
    }

    deinit { Buffer.release(base, capacity: capacity, mapped: mapped) }

    private static func allocate(_ n: Int) -> (UnsafeMutablePointer<T>, Bool) {
        let bytes = n * MemoryLayout<T>.stride
        if bytes >= mmapThreshold {
            let p = mmap(nil, bytes, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0)
            guard let p, p != MAP_FAILED else { fatalError("out of memory") }
            return (p.bindMemory(to: T.self, capacity: n), true)
        }
        guard let raw = malloc(bytes) else { fatalError("out of memory") }
        return (raw.bindMemory(to: T.self, capacity: n), false)
    }

    private static func release(_ p: UnsafeMutablePointer<T>, capacity: Int, mapped: Bool) {
        if mapped { munmap(UnsafeMutableRawPointer(p), capacity * MemoryLayout<T>.stride) } else { free(p) }
    }

    private func move(toCapacity c: Int) {
        let (p, m) = Buffer.allocate(c)
        if count > 0 { p.update(from: base, count: Swift.min(count, c)) }
        Buffer.release(base, capacity: capacity, mapped: mapped)
        base = p
        mapped = m
        capacity = c
    }

    public func reserve(_ minimum: Int) {
        guard minimum > capacity else { return }
        var c = capacity
        while c < minimum { c *= 2 }
        move(toCapacity: c)
    }

    @inline(__always) public subscript(i: Int) -> T {
        get { base[i] }
        set { base[i] = newValue }
    }

    @inline(__always) public func append(_ v: T) {
        if count == capacity { reserve(count + 1) }
        base[count] = v
        count += 1
    }

    public func append(_ src: UnsafePointer<T>, count n: Int) {
        guard n > 0 else { return }
        reserve(count + n)
        (base + count).update(from: src, count: n)
        count += n
    }

    public func removeAll() { count = 0 }

    /// Releases unused capacity (keeps some headroom for live updates).
    public func shrinkToFit(headroom: Int = 0) {
        let c = Swift.max(16, count + headroom)
        guard c < capacity else { return }
        move(toCapacity: c)
    }

    /// Resizes to `n` elements. New elements are uninitialised (only use with trivial types).
    public func resize(_ n: Int) {
        reserve(n)
        count = n
    }

    public func fill(_ v: T) { base.update(repeating: v, count: count) }

    /// Bytes actually in use (untouched mmap capacity is not backed by memory).
    public var bytes: Int { count * MemoryLayout<T>.stride }

    public var bufferPointer: UnsafeBufferPointer<T> { UnsafeBufferPointer(start: base, count: count) }
}

/// pthread reader/writer lock. Not recursive.
public final class RWLock {
    private let l: UnsafeMutablePointer<pthread_rwlock_t>

    public init() {
        l = .allocate(capacity: 1)
        l.initialize(to: pthread_rwlock_t())
        pthread_rwlock_init(l, nil)
    }

    deinit {
        pthread_rwlock_destroy(l)
        l.deallocate()
    }

    @inline(__always) public func read<R>(_ body: () throws -> R) rethrows -> R {
        pthread_rwlock_rdlock(l)
        defer { pthread_rwlock_unlock(l) }
        return try body()
    }

    @inline(__always) public func write<R>(_ body: () throws -> R) rethrows -> R {
        pthread_rwlock_wrlock(l)
        defer { pthread_rwlock_unlock(l) }
        return try body()
    }
}

/// os_unfair_lock wrapper.
public final class Mutex {
    private let l: UnsafeMutablePointer<os_unfair_lock>

    public init() {
        l = .allocate(capacity: 1)
        l.initialize(to: os_unfair_lock())
    }

    deinit { l.deallocate() }

    @inline(__always) public func withLock<R>(_ body: () throws -> R) rethrows -> R {
        os_unfair_lock_lock(l)
        defer { os_unfair_lock_unlock(l) }
        return try body()
    }
}

public final class CancelToken {
    private let m = Mutex()
    private var flag = false
    public init() {}
    public var isCancelled: Bool { m.withLock { flag } }
    public func cancel() { m.withLock { flag = true } }
}

/// Case folding used for case-insensitive search: Unicode NFC + lowercase.
public enum Fold {
    /// Appends the folded form of the UTF-8 bytes in `p` to `out`.
    public static func append(_ p: UnsafeBufferPointer<UInt8>, to out: inout [UInt8]) {
        var ascii = true
        for b in p where b >= 0x80 {
            ascii = false
            break
        }
        if ascii {
            for b in p { out.append(b &- 65 < 26 ? b | 0x20 : b) }
        } else {
            let s = String(decoding: p, as: UTF8.self)
            out.append(contentsOf: s.precomposedStringWithCanonicalMapping.lowercased().utf8)
        }
    }

    public static func fold(_ s: String) -> [UInt8] {
        Array(s.precomposedStringWithCanonicalMapping.lowercased().utf8)
    }
}

/// Sorts large Int32 arrays on all cores (chunked sort + pairwise merge).
enum ParallelSort {
    static func sort(_ a: inout [Int32], by less: (Int32, Int32) -> Bool) {
        let n = a.count
        guard n >= 200_000 else {
            a.sort(by: less)
            return
        }
        let k = 8
        var bounds = (0...k).map { $0 * n / k }
        a.withUnsafeMutableBufferPointer { buf in
            DispatchQueue.concurrentPerform(iterations: k) { i in
                var slice = UnsafeMutableBufferPointer(rebasing: buf[bounds[i]..<bounds[i + 1]])
                slice.sort(by: less)
            }
        }
        var src = a
        var dst = [Int32](repeating: 0, count: n)
        while bounds.count > 2 {
            let pairs = (bounds.count - 1 + 1) / 2
            var next = [0]
            for p in 0..<pairs {
                next.append(bounds[min(2 * p + 2, bounds.count - 1)])
            }
            src.withUnsafeBufferPointer { s in
                dst.withUnsafeMutableBufferPointer { d in
                    DispatchQueue.concurrentPerform(iterations: pairs) { p in
                        let lo = bounds[2 * p]
                        let mid = bounds[min(2 * p + 1, bounds.count - 1)]
                        let hi = bounds[min(2 * p + 2, bounds.count - 1)]
                        var i = lo, j = mid, o = lo
                        while i < mid && j < hi {
                            if less(s[j], s[i]) { d[o] = s[j]; j += 1 } else { d[o] = s[i]; i += 1 }
                            o += 1
                        }
                        while i < mid { d[o] = s[i]; i += 1; o += 1 }
                        while j < hi { d[o] = s[j]; j += 1; o += 1 }
                    }
                }
            }
            swap(&src, &dst)
            bounds = next
        }
        a = src
    }
}
