import AppKit
import Carbon.HIToolbox
import QuickFindCore
import ServiceManagement
import UniformTypeIdentifiers

/// Persisted user preferences.
enum Prefs {
    private static let d = UserDefaults.standard

    private static func load<T: Decodable>(_ key: String) -> T? {
        d.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    private static func store<T: Encodable>(_ v: T, _ key: String) {
        d.set(try? JSONEncoder().encode(v), forKey: key)
    }

    static var configuration: IndexManager.Configuration {
        get { load("configuration") ?? IndexManager.Configuration() }
        set { store(newValue, "configuration") }
    }

    static var searchOptions: SearchOptions {
        get { load("searchOptions") ?? SearchOptions() }
        set { store(newValue, "searchOptions") }
    }

    static var sortKey: SortKey {
        get { SortKey(rawValue: d.string(forKey: "sortKey") ?? "") ?? .name }
        set { d.set(newValue.rawValue, forKey: "sortKey") }
    }

    static var sortAscending: Bool {
        get { d.object(forKey: "sortAscending") as? Bool ?? true }
        set { d.set(newValue, forKey: "sortAscending") }
    }

    static var hotKeyEnabled: Bool {
        get { d.object(forKey: "hotKeyEnabled") as? Bool ?? true }
        set { d.set(newValue, forKey: "hotKeyEnabled") }
    }

    static var hotKey: HotKey.Shortcut {
        get { load("hotKey") ?? .default }
        set { store(newValue, "hotKey") }
    }

    /// Whether the current index was built with Full Disk Access (otherwise protected
    /// folders are in it but empty, and a rescan is needed once access is granted).
    static var indexedWithFullDiskAccess: Bool {
        get { d.bool(forKey: "indexedWithFullDiskAccess") }
        set { d.set(newValue, forKey: "indexedWithFullDiskAccess") }
    }

    /// Search scope: false = everywhere, true = current folder (and below).
    static var searchInFolder: Bool {
        get { d.bool(forKey: "searchInFolder") }
        set { d.set(newValue, forKey: "searchInFolder") }
    }

    /// Bumped when an update needs existing indexes rebuilt once (2: snapshots saved mid-scan could be incomplete).
    static let currentIndexVersion = 2
    static var indexVersion: Int {
        get { d.integer(forKey: "indexVersion") }
        set { d.set(newValue, forKey: "indexVersion") }
    }

    /// Columns the user has hidden (right-click on the header).
    static var hiddenColumns: Set<String> {
        get { Set(d.stringArray(forKey: "hiddenColumns") ?? ["created", "lastUsed", "tags"]) }
        set { d.set(Array(newValue).sorted(), forKey: "hiddenColumns") }
    }

    static var showSidebar: Bool {
        get { d.object(forKey: "showSidebar") as? Bool ?? true }
        set { d.set(newValue, forKey: "showSidebar") }
    }

    static var showDockIcon: Bool {
        get { d.object(forKey: "showDockIcon") as? Bool ?? true }
        set { d.set(newValue, forKey: "showDockIcon") }
    }
}

/// "Open at login" via SMAppService (macOS 13+).
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
    static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    static func set(_ enabled: Bool) throws {
        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }

    static func openSettings() { SMAppService.openSystemSettingsLoginItems() }
}

enum Permissions {
    /// Full Disk Access can only be detected by trying to read a file it protects.
    static var hasFullDiskAccess: Bool {
        let probes = ["/Library/Application Support/com.apple.TCC/TCC.db",
                      NSHomeDirectory() + "/Library/Application Support/com.apple.TCC/TCC.db"]
        for p in probes {
            let fd = open(p, O_RDONLY)
            if fd >= 0 {
                close(fd)
                return true
            }
        }
        return false
    }

    static func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}

enum Format {
    static let number: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f
    }()

    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("ddMMyyyyHHmm")
        return f
    }()

    static let bytes: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()

    static func count(_ n: Int) -> String { number.string(from: NSNumber(value: n)) ?? "\(n)" }

    private static let percentFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .percent
        f.maximumFractionDigits = 1
        return f
    }()

    /// 0.0412 → "4,1 %"; tiny non-zero shares → "<0,1 %".
    static func percent(_ share: Double) -> String {
        if share > 0 && share < 0.001 { return "<" + (percentFormatter.string(from: 0.001) ?? "0,1 %") }
        percentFormatter.maximumFractionDigits = share < 0.1 ? 1 : 0
        return percentFormatter.string(from: NSNumber(value: share)) ?? ""
    }
    static func size(_ n: Int64) -> String { bytes.string(fromByteCount: n) }
    static func date(_ t: Int64) -> String { t == 0 ? "" : dateFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(t))) }
}

/// Folder extensions the Finder treats as single items (apps, bundles, Pages documents …).
enum Packages {
    private static var cache: [String: UTType?] = [:]

    /// The directory type for a folder extension, or nil if such folders are plain folders.
    static func type(forFolderExtension ext: String) -> UTType? {
        let ext = ext.lowercased()
        guard !ext.isEmpty else { return nil }
        if let t = cache[ext] { return t }
        let t = UTType(filenameExtension: ext, conformingTo: .directory)
            .flatMap { $0.conforms(to: .package) || $0.conforms(to: .bundle) ? $0 : nil }
        cache[ext] = t
        return t
    }

    static func isPackage(_ info: EntryInfo) -> Bool {
        info.isDirectory && type(forFolderExtension: (info.name as NSString).pathExtension) != nil
    }
}

/// Total and free capacity per volume (the boot volume, or /Volumes/<name>), cached briefly.
final class VolumeCapacity {
    struct Info {
        var total: Int64
        var free: Int64
    }

    private var cache: [String: (info: Info, at: Date)] = [:]

    func info(for path: String) -> Info {
        var key = "/"
        if path.hasPrefix("/Volumes/") {
            let parts = path.split(separator: "/", maxSplits: 3)
            if parts.count >= 2 { key = "/Volumes/" + parts[1] }
        }
        if let c = cache[key], Date().timeIntervalSince(c.at) < 30 { return c.info }
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        let v = try? URL(fileURLWithPath: key).resourceValues(forKeys: keys)
        let info = Info(total: Int64(v?.volumeTotalCapacity ?? 0), free: v?.volumeAvailableCapacityForImportantUsage ?? 0)
        cache[key] = (info, Date())
        return info
    }
}

/// Localised kind names ("PDF-Dokument", "Programm", "Ordner", …), cached per extension.
final class TypeNames {
    private var cache: [String: String] = [:]

    func name(for info: EntryInfo) -> String {
        let ext = (info.name as NSString).pathExtension.lowercased()
        if info.isDirectory {
            if let t = Packages.type(forFolderExtension: ext) { return t.localizedDescription ?? L("Paket") }
            return info.flags & EntryFlag.mountPoint != 0 ? L("Volume") : L("Ordner")
        }
        if info.isSymlink && ext.isEmpty { return L("Alias") }
        if let n = cache[ext] { return n }
        let n = ext.isEmpty ? L("Dokument") : (UTType(filenameExtension: ext)?.localizedDescription ?? L("%@-Datei", ext.uppercased()))
        cache[ext] = n
        return n
    }
}

/// File icons, cached per extension (and per path for bundles such as apps).
final class IconCache {
    private var byExtension: [String: NSImage] = [:]
    private let byPath = NSCache<NSString, NSImage>()
    private lazy var folder = sized(NSWorkspace.shared.icon(for: .folder))
    private let bundleExtensions: Set<String> = ["app", "prefpane", "appex", "bundle", "framework", "pages", "numbers",
                                                 "key", "rtfd", "photoslibrary", "xcodeproj", "pkg", "mpkg"]

    init() { byPath.countLimit = 500 }

    private func sized(_ img: NSImage) -> NSImage {
        img.size = NSSize(width: 16, height: 16)
        return img
    }

    func icon(for info: EntryInfo) -> NSImage {
        let ext = (info.name as NSString).pathExtension.lowercased()
        if info.isDirectory {
            guard bundleExtensions.contains(ext) || Packages.isPackage(info) else { return folder }
            let path = info.path
            if let i = byPath.object(forKey: path as NSString) { return i }
            let i = sized(NSWorkspace.shared.icon(forFile: path))
            byPath.setObject(i, forKey: path as NSString)
            return i
        }
        if let i = byExtension[ext] { return i }
        let type = ext.isEmpty ? UTType.data : (UTType(filenameExtension: ext) ?? .data)
        let i = sized(NSWorkspace.shared.icon(for: type))
        byExtension[ext] = i
        return i
    }
}

/// System-wide hot key via the Carbon event API (works without accessibility permission).
final class HotKey {
    struct Shortcut: Codable, Equatable {
        var keyCode: UInt32
        var modifiers: UInt32   // Carbon modifier mask (cmdKey, optionKey, controlKey, shiftKey)
        var key: String         // display name of the key

        static let `default` = Shortcut(keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey | optionKey), key: "Leertaste")

        var display: String {
            var s = ""
            if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
            if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
            if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
            if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
            return s + (key == "Leertaste" ? L("Leertaste") : key)
        }

        /// Builds a shortcut from a key event; nil without ⌘, ⌥ or ⌃ (plain keys would block typing).
        init?(event: NSEvent) {
            let f = event.modifierFlags
            var m: UInt32 = 0
            if f.contains(.command) { m |= UInt32(cmdKey) }
            if f.contains(.option) { m |= UInt32(optionKey) }
            if f.contains(.control) { m |= UInt32(controlKey) }
            guard m != 0 else { return nil }
            if f.contains(.shift) { m |= UInt32(shiftKey) }
            self.init(keyCode: UInt32(event.keyCode), modifiers: m, key: Self.keyName(event))
        }

        init(keyCode: UInt32, modifiers: UInt32, key: String) {
            self.keyCode = keyCode
            self.modifiers = modifiers
            self.key = key
        }

        private static func keyName(_ e: NSEvent) -> String {
            let names: [Int: String] = [kVK_Space: "Leertaste", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫",
                                        kVK_ForwardDelete: "⌦", kVK_LeftArrow: "←", kVK_RightArrow: "→",
                                        kVK_UpArrow: "↑", kVK_DownArrow: "↓", kVK_Home: "↖", kVK_End: "↘",
                                        kVK_PageUp: "⇞", kVK_PageDown: "⇟", kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3",
                                        kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8",
                                        kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12"]
            if let n = names[Int(e.keyCode)] { return n }
            return (e.charactersIgnoringModifiers ?? "?").uppercased()
        }
    }

    private static var action: (() -> Void)?
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?

    /// Registers the shortcut; returns false if macOS refuses it (e.g. already taken).
    @discardableResult
    func register(_ shortcut: Shortcut, action: @escaping () -> Void) -> Bool {
        unregister()
        HotKey.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { HotKey.action?() }
            return noErr
        }, 1, &spec, nil, &handler)
        let id = EventHotKeyID(signature: OSType(0x5146_494E), id: 1) // "QFIN"
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, id, GetApplicationEventTarget(), 0, &ref)
        if status != noErr { unregister() }
        return status == noErr
    }

    func unregister() {
        if let r = ref { UnregisterEventHotKey(r) }
        if let h = handler { RemoveEventHandler(h) }
        ref = nil
        handler = nil
    }
}

extension NSMenu {
    @discardableResult
    func add(_ title: String, _ action: Selector?, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command,
             target: AnyObject? = nil, tag: Int = 0) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = mods
        item.target = target
        item.tag = tag
        addItem(item)
        return item
    }
}
