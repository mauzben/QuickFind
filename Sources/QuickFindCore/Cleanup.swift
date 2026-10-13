import CryptoKit
import Foundation

/// Categories of the cleanup assistant.
public enum CleanupCategory: Int, CaseIterable {
    case duplicates, largeFiles, largeFolders, oldDownloads, oldLargeFiles, installers, emptyFolders, caches

    public var title: String {
        switch self {
        case .duplicates: return L("Dubletten")
        case .largeFiles: return L("Große Dateien")
        case .largeFolders: return L("Große Ordner")
        case .emptyFolders: return L("Leere Ordner")
        case .oldDownloads: return L("Alte Downloads")
        case .oldLargeFiles: return L("Große, alte Dateien")
        case .installers: return L("Installationsdateien")
        case .caches: return L("App-Caches")
        }
    }

    public var symbol: String {
        switch self {
        case .duplicates: return "doc.on.doc"
        case .largeFiles: return "externaldrive"
        case .largeFolders: return "folder.badge.gearshape"
        case .emptyFolders: return "folder"
        case .oldDownloads: return "arrow.down.circle"
        case .oldLargeFiles: return "clock.arrow.circlepath"
        case .installers: return "shippingbox"
        case .caches: return "archivebox"
        }
    }

    /// Whether the assistant preselects items (only where keeping a copy is guaranteed).
    public var preselects: Bool { self == .duplicates }
}

public struct CleanupItem: Hashable {
    public let id: Int32
    public let path: String
    public let name: String
    /// Space actually used on disk (what is freed after emptying the trash).
    public let size: Int64
    public let mtime: Int64
    public let created: Int64
    public let isDirectory: Bool
}

/// A set of items; for duplicates one group per identical content, `keep` = the suggested original.
public struct CleanupGroup {
    public var items: [CleanupItem]
    public var keep: Int?

    /// Space freed if all but the kept item are removed (or all items for plain lists).
    public var reclaimable: Int64 {
        items.enumerated().reduce(0) { $0 + ($1.offset == keep ? 0 : $1.element.size) }
    }
}

public struct CleanupSettings {
    public var home: String
    public var minDuplicateSize: Int64 = 1 << 20          // 1 MB
    public var minLargeSize: Int64 = 250 << 20           // 250 MB
    public var downloadsAgeDays = 90
    public var minOldSize: Int64 = 50 << 20              // 50 MB
    public var minFolderSize: Int64 = 1 << 30            // 1 GB
    public var oldAgeDays = 365
    public var now = Int64(Date().timeIntervalSince1970)

    public init(home: String = NSHomeDirectory()) {
        self.home = IndexManager.normalizeUserPath(home)
    }
}

public enum Cleanup {
    /// Folders that belong to apps or tools: their contents must never be suggested for deletion.
    static let packageExtensions: Set<String> = [
        "app", "appex", "framework", "bundle", "plugin", "kext", "xpc", "prefpane", "qlgenerator", "mdimporter",
        "photoslibrary", "photolibrary", "musiclibrary", "tvlibrary", "aplibrary", "imovielibrary", "fcpbundle",
        "logicx", "band", "pages", "numbers", "key", "rtfd", "sparsebundle", "vmwarevm", "pvm", "utm",
        "xcodeproj", "xcworkspace", "xcarchive", "lrdata", "lrlibrary", "dSYM",
    ].reduce(into: Set<String>()) { $0.insert($1.lowercased()) }

    /// Folders whose contents are managed by tools or are installed software (identical binaries there
    /// are intentional; deleting single files breaks the tool).
    static let toolFolders: Set<String> = ["node_modules", "DerivedData", "Pods", "site-packages", "__pycache__",
                                           "venv", "Carthage", "vendor", "bin", "sbin", "lib", "lib64", "include",
                                           "share", "libexec", "miniconda3", "anaconda3", "miniforge3", "mambaforge",
                                           "Applications"]

    /// Marker folders of version-controlled projects: nothing inside such a project is suggested.
    static let repositoryMarkers: [[UInt8]] = [".git", ".svn", ".hg"].map { Array($0.utf8) }

    static let installerExtensions: Set<String> = ["dmg", "pkg", "mpkg", "xip", "iso"]

    /// True if `path` must not be offered for deletion. `allowLibraryCaches` admits ~/Library/Caches/<x>.
    /// Folders directly in the home folder (Desktop, Documents, Pictures …) are never offered as a whole.
    public static func isProtected(_ path: String, home: String, allowLibraryCaches: Bool = false,
                                   isDirectory: Bool = false) -> Bool {
        guard path.hasPrefix(home + "/") else { return true }
        let rel = path.dropFirst(home.count + 1)
        let parts = rel.split(separator: "/").map(String.init)
        guard let first = parts.first else { return true }
        if isDirectory && parts.count == 1 { return true }
        if first == "Library" {
            guard allowLibraryCaches, parts.count >= 3, parts[1] == "Caches", !parts[2].hasPrefix("com.apple.") else { return true }
        }
        for (i, p) in parts.enumerated() {
            if p.hasPrefix(".") { return true }                         // hidden files, .Trash, .git …
            if toolFolders.contains(p) { return true }
            // Inside a package (the package itself as last component is fine, e.g. an old .app download).
            let ext = (p as NSString).pathExtension.lowercased()
            if i < parts.count - 1, !ext.isEmpty, packageExtensions.contains(ext) { return true }
        }
        return false
    }

    /// Finds candidates for `category`. Blocking; reports progress (0…1) for duplicate hashing.
    public static func run(_ category: CleanupCategory, index: FileIndex, settings s: CleanupSettings,
                           progress: ((Double) -> Void)? = nil, cancel: CancelToken? = nil) -> [CleanupGroup] {
        switch category {
        case .duplicates:
            return duplicates(index, s, progress, cancel)
        case .largeFiles:
            let items = files(index, under: s.home, s) { v, i in v.allocs[i] >= s.minLargeSize }
            return flat(items)
        case .oldLargeFiles:
            let cutoff = s.now - Int64(s.oldAgeDays) * 86400
            let items = files(index, under: s.home, s) { v, i in v.allocs[i] >= s.minOldSize && v.mtimes[i] < cutoff }
            return flat(items)
        case .installers:
            let items = files(index, under: s.home, s) { v, i in
                v.allocs[i] >= 1 << 20 && installerExtensions.contains(String(decoding: v.ext(i), as: UTF8.self))
            }
            return flat(items)
        case .oldDownloads:
            let cutoff = s.now - Int64(s.downloadsAgeDays) * 86400
            return flat(children(index, of: s.home + "/Downloads", s) { $0.mtime < cutoff })
        case .caches:
            return flat(children(index, of: s.home + "/Library/Caches", s, allowCaches: true) { $0.size >= 1 << 20 })
        case .emptyFolders:
            return flat(emptyFolders(index, s)).map { g in
                var g = g
                g.items.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
                return g
            }
        case .largeFolders:
            return flat(largeFolders(index, s))
        }
    }

    /// Folders below home (memo-based, read lock held by the caller).
    private static func foldersInside(_ index: FileIndex, _ v: IndexView, _ root: Int32) -> (Int) -> Bool {
        let memo = Buffer<UInt8>(capacity: max(1, v.count))
        memo.resize(v.count)
        memo.fill(0)
        func inside(_ i: Int) -> Bool {
            if i == Int(root) { return true }
            if memo[i] != 0 { return memo[i] == 2 }
            let p = Int(v.parents[i])
            let r = p >= 0 && inside(p)
            memo[i] = r ? 2 : 1
            return r
        }
        return inside
    }

    private static let ignorableNames: Set<[UInt8]> = [Array(".DS_Store".utf8), Array("Icon\r".utf8), Array(".localized".utf8)]

    /// Folders containing nothing but other empty folders and Finder files (.DS_Store); only the
    /// topmost folder of an empty subtree is listed.
    static func emptyFolders(_ index: FileIndex, _ s: CleanupSettings) -> [CleanupItem] {
        index.lock.read {
            guard let root = index.lookup(s.home) else { return [] }
            let v = index.view()
            let n = v.count
            // 1 = (so far) empty folder, 0 = has content. Children have larger IDs than parents.
            let empty = Buffer<UInt8>(capacity: max(1, n))
            empty.resize(n)
            for i in 0..<n {
                let f = v.flags[i]
                empty[i] = f & EntryFlag.directory != 0 && f & (EntryFlag.deleted | EntryFlag.mountPoint | EntryFlag.symlink) == 0 ? 1 : 0
            }
            for i in stride(from: n - 1, through: 0, by: -1) where v.flags[i] & EntryFlag.deleted == 0 {
                let p = Int(v.parents[i])
                guard p >= 0, empty[p] == 1 else { continue }
                let isDir = v.flags[i] & EntryFlag.directory != 0
                if isDir ? empty[i] == 0 : !ignorableNames.contains(Array(v.name(i))) { empty[p] = 0 }
            }
            let inside = foldersInside(index, v, root)
            var repoMemo: [Int32: Bool] = [:]
            var out: [CleanupItem] = []
            for i in 0..<n where empty[i] == 1 && i != Int(root) && inside(i) {
                let p = Int(v.parents[i])
                if p >= 0 && empty[p] == 1 && p != Int(root) { continue }   // listed via its empty parent
                let ext = String(decoding: v.ext(i), as: UTF8.self)
                let name = String(decoding: v.name(i), as: UTF8.self)
                if packageExtensions.contains((name as NSString).pathExtension.lowercased()) || !ext.isEmpty && packageExtensions.contains(ext) { continue }
                let it = item(index, v, i)
                if !isProtected(it.path, home: s.home, isDirectory: true) && !insideRepository(index, Int32(i), &repoMemo) {
                    out.append(it)
                }
            }
            return out
        }
    }

    /// Folders that really hold the space: at least `minFolderSize`, and not dominated by a single
    /// subfolder (if one child holds ≥ 75 %, that child is shown instead).
    static func largeFolders(_ index: FileIndex, _ s: CleanupSettings) -> [CleanupItem] {
        index.lock.read {
            guard let root = index.lookup(s.home) else { return [] }
            let v = index.view()
            let n = v.count
            let maxChild = Buffer<Int64>(capacity: max(1, n))
            maxChild.resize(n)
            maxChild.fill(0)
            for i in 0..<n where v.flags[i] & (EntryFlag.deleted | EntryFlag.directory) == EntryFlag.directory {
                let p = Int(v.parents[i])
                if p >= 0 && v.allocs[i] > maxChild[p] { maxChild[p] = v.allocs[i] }
            }
            let inside = foldersInside(index, v, root)
            var repoMemo: [Int32: Bool] = [:]
            var out: [CleanupItem] = []
            for i in 0..<n where v.flags[i] & (EntryFlag.deleted | EntryFlag.directory | EntryFlag.symlink) == EntryFlag.directory
                && v.allocs[i] >= s.minFolderSize && i != Int(root) && inside(i) {
                if Double(maxChild[i]) >= 0.75 * Double(v.allocs[i]) { continue }
                let it = item(index, v, i)
                if !isProtected(it.path, home: s.home, isDirectory: true) && !isRepository(index, Int32(i))
                    && !insideRepository(index, Int32(i), &repoMemo) {
                    out.append(it)
                }
            }
            return Array(out.sorted { $0.size > $1.size }.prefix(40))
        }
    }

    private static func flat(_ items: [CleanupItem]) -> [CleanupGroup] {
        items.isEmpty ? [] : [CleanupGroup(items: items.sorted { $0.size > $1.size }, keep: nil)]
    }

    private static func item(_ index: FileIndex, _ v: IndexView, _ i: Int) -> CleanupItem {
        CleanupItem(id: Int32(i), path: index.pathString(Int32(i)), name: String(decoding: v.name(i), as: UTF8.self),
                    size: v.allocs[i], mtime: v.mtimes[i], created: v.ctimes[i],
                    isDirectory: v.flags[i] & EntryFlag.directory != 0)
    }

    /// Regular, downloaded (not online-only) files below `folder` matching `predicate`, minus protected ones.
    static func files(_ index: FileIndex, under folder: String, _ s: CleanupSettings,
                      _ predicate: (IndexView, Int) -> Bool) -> [CleanupItem] {
        index.lock.read {
            guard let root = index.lookup(folder) else { return [] }
            let v = index.view()
            let skip = EntryFlag.directory | EntryFlag.deleted | EntryFlag.symlink | EntryFlag.dataless | EntryFlag.root
            // memo: 0 unknown, 1 outside, 2 inside `folder`
            let memo = Buffer<UInt8>(capacity: max(1, v.count))
            memo.resize(v.count)
            memo.fill(0)
            func inside(_ i: Int) -> Bool {
                if i == Int(root) { return true }
                if memo[i] != 0 { return memo[i] == 2 }
                let p = Int(v.parents[i])
                let r = p >= 0 && inside(p)
                memo[i] = r ? 2 : 1
                return r
            }
            var inRepo: [Int32: Bool] = [:]
            var out: [CleanupItem] = []
            for i in 0..<v.count where v.flags[i] & skip == 0 && predicate(v, i) && inside(i) {
                let it = item(index, v, i)
                if !isProtected(it.path, home: s.home) && !insideRepository(index, Int32(i), &inRepo) { out.append(it) }
            }
            return out
        }
    }

    /// True if the folder itself is a repository (contains .git/.svn/.hg; read lock held).
    static func isRepository(_ index: FileIndex, _ id: Int32) -> Bool {
        repositoryMarkers.contains { index.findChild(id, name: $0) != nil }
    }

    /// True if an ancestor folder contains .git/.svn/.hg (memoised per folder; read lock held).
    static func insideRepository(_ index: FileIndex, _ id: Int32, _ memo: inout [Int32: Bool]) -> Bool {
        var chain: [Int32] = []
        var p = index.parents[Int(id)]
        var result = false
        while p >= 0 {
            if let known = memo[p] {
                result = known
                break
            }
            chain.append(p)
            if repositoryMarkers.contains(where: { index.findChild(p, name: $0) != nil }) {
                result = true
                break
            }
            p = index.parents[Int(p)]
        }
        for c in chain { memo[c] = result }
        return result
    }

    /// Direct children of `folder` (files and folders) matching `predicate`.
    static func children(_ index: FileIndex, of folder: String, _ s: CleanupSettings, allowCaches: Bool = false,
                         _ predicate: (CleanupItem) -> Bool) -> [CleanupItem] {
        index.lock.read {
            guard let dir = index.lookup(folder) else { return [] }
            let v = index.view()
            return index.children(of: dir).compactMap { id -> CleanupItem? in
                let i = Int(id)
                guard v.flags[i] & (EntryFlag.symlink | EntryFlag.dataless | EntryFlag.deleted) == 0 else { return nil }
                let it = item(index, v, i)
                guard predicate(it), !isProtected(it.path, home: s.home, allowLibraryCaches: allowCaches,
                                                  isDirectory: it.isDirectory) else { return nil }
                return it
            }
        }
    }

    // MARK: Duplicates

    /// Byte-identical files: same size → same hash of the first/last 64 KB → same SHA-256 of the whole
    /// file. Hard links (same inode) are not duplicates. Keeps the oldest file of each group.
    static func duplicates(_ index: FileIndex, _ s: CleanupSettings, _ progress: ((Double) -> Void)?,
                           _ cancel: CancelToken?) -> [CleanupGroup] {
        let candidates = files(index, under: s.home, s) { v, i in v.sizes[i] >= s.minDuplicateSize }
        var bySize: [Int64: [CleanupItem]] = [:]
        for c in candidates { bySize[logicalSize(c.path) ?? -1, default: []].append(c) }
        bySize[-1] = nil
        var sizeGroups = bySize.values.filter { $0.count > 1 }.map(uniqueInodes).filter { $0.count > 1 }
        sizeGroups.sort { ($0.first?.size ?? 0) > ($1.first?.size ?? 0) }

        let total = sizeGroups.count
        let done = Mutex()
        var finished = 0
        var results = [[CleanupGroup]](repeating: [], count: total)
        results.withUnsafeMutableBufferPointer { out in
            DispatchQueue.concurrentPerform(iterations: total) { g in
                if cancel?.isCancelled == true { return }
                var groups: [CleanupGroup] = []
                // Cheap pass first, full hash only for files that still look identical.
                for quick in partition(sizeGroups[g], by: { hash($0.path, sampleOnly: true) }) where quick.count > 1 {
                    for full in partition(quick, by: { hash($0.path, sampleOnly: false) }) where full.count > 1 {
                        let sorted = full.sorted { ($0.created, $0.path.count, $0.path) < ($1.created, $1.path.count, $1.path) }
                        groups.append(CleanupGroup(items: sorted, keep: 0))
                    }
                }
                out[g] = groups
                let n = done.withLock { () -> Int in finished += 1; return finished }
                if n % 8 == 0 || n == total { progress?(Double(n) / Double(max(1, total))) }
            }
        }
        if cancel?.isCancelled == true { return [] }
        return results.flatMap { $0 }.sorted { $0.reclaimable > $1.reclaimable }
    }

    private static func partition(_ items: [CleanupItem], by key: (CleanupItem) -> Data?) -> [[CleanupItem]] {
        var map: [Data: [CleanupItem]] = [:]
        for it in items {
            if let k = key(it) { map[k, default: []].append(it) }
        }
        return Array(map.values)
    }

    private static func logicalSize(_ path: String) -> Int64? {
        var st = stat()
        guard lstat(path, &st) == 0, st.st_mode & S_IFMT == S_IFREG else { return nil }
        return Int64(st.st_size)
    }

    /// Drops additional names of the same inode (hard links free nothing when deleted).
    private static func uniqueInodes(_ items: [CleanupItem]) -> [CleanupItem] {
        var seen = Set<String>()
        return items.filter { it in
            var st = stat()
            guard lstat(it.path, &st) == 0 else { return false }
            return seen.insert("\(st.st_dev):\(st.st_ino)").inserted
        }
    }

    /// SHA-256 of the whole file, or of its first and last 64 KB (`sampleOnly`).
    static func hash(_ path: String, sampleOnly: Bool) -> Data? {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var hasher = SHA256()
        let chunk = sampleOnly ? 64 * 1024 : 1 << 20
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: chunk, alignment: 16)
        defer { buffer.deallocate() }
        func feed(_ n: Int) { hasher.update(bufferPointer: UnsafeRawBufferPointer(start: buffer, count: n)) }
        if sampleOnly {
            let n = read(fd, buffer, chunk)
            guard n >= 0 else { return nil }
            feed(n)
            var st = stat()
            if fstat(fd, &st) == 0, st.st_size > Int64(chunk) {
                let m = pread(fd, buffer, chunk, off_t(st.st_size) - off_t(chunk))
                guard m >= 0 else { return nil }
                feed(m)
            }
        } else {
            while true {
                let n = read(fd, buffer, chunk)
                if n < 0 { return nil }
                if n == 0 { break }
                feed(n)
            }
        }
        return Data(hasher.finalize())
    }
}
