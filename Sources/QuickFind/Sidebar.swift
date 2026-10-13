import AppKit
import QuickFindCore

/// Finder-like sidebar: favourites (editable, drag folders in) and volumes with free space.
final class Sidebar: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
    final class Section {
        let title: String
        var items: [Item] = []
        init(_ title: String) { self.title = title }
    }

    final class Item {
        let path: String
        let title: String
        let symbol: String
        let detail: String
        let isFavorite: Bool
        init(path: String, title: String, symbol: String, detail: String = "", isFavorite: Bool) {
            self.path = path
            self.title = title
            self.symbol = symbol
            self.detail = detail
            self.isFavorite = isFavorite
        }
    }

    let outline = NSOutlineView()
    let scrollView = NSScrollView()
    /// Called when the user picks a place.
    var onSelect: ((String) -> Void)?

    private let favorites = Section(L("Favoriten"))
    private let places = Section(L("Orte"))
    private var sections: [Section] { [favorites, places] }
    private var suppressSelection = false
    private let volumes = VolumeCapacity()

    override init() {
        super.init()
        let col = NSTableColumn(identifier: .init("place"))
        outline.addTableColumn(col)
        outline.outlineTableColumn = col
        outline.headerView = nil
        outline.style = .sourceList
        outline.rowSizeStyle = .default
        outline.floatsGroupRows = false
        outline.indentationPerLevel = 0
        outline.dataSource = self
        outline.delegate = self
        outline.registerForDraggedTypes([.fileURL])
        outline.draggingDestinationFeedbackStyle = .sourceList
        let menu = NSMenu()
        menu.delegate = self
        outline.menu = menu
        scrollView.documentView = outline
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        reload()
    }

    // MARK: Content

    static let defaultFavorites: [String] = {
        let h = NSHomeDirectory()
        return [h, h + "/Desktop", h + "/Documents", h + "/Downloads", "/Applications", h + "/Pictures"]
    }()

    static var favoritePaths: [String] {
        get { UserDefaults.standard.stringArray(forKey: "sidebarFavorites") ?? defaultFavorites }
        set { UserDefaults.standard.set(newValue, forKey: "sidebarFavorites") }
    }

    private static func symbol(for path: String) -> String {
        let h = NSHomeDirectory()
        switch path {
        case h: return "house"
        case h + "/Desktop": return "menubar.dock.rectangle"
        case h + "/Documents": return "doc"
        case h + "/Downloads": return "arrow.down.circle"
        case "/Applications": return "square.grid.3x3"
        case h + "/Pictures": return "photo"
        case h + "/Movies": return "film"
        case h + "/Music": return "music.note"
        default: return "folder"
        }
    }

    func reload() {
        favorites.items = Self.favoritePaths.filter { FileManager.default.fileExists(atPath: $0) }.map {
            Item(path: $0, title: FileManager.default.displayName(atPath: $0), symbol: Self.symbol(for: $0), isFavorite: true)
        }
        var vols = ["/"]
        let keys: [URLResourceKey] = [.volumeIsBrowsableKey]
        for url in FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        where url.path.hasPrefix("/Volumes/") {
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) == nil { vols.append(url.path) }
        }
        places.items = vols.map { p in
            let v = volumes.info(for: p)
            let free = v.total > 0 ? L("%@ frei", Format.size(v.free)) : ""
            return Item(path: p, title: FileManager.default.displayName(atPath: p),
                        symbol: p == "/" ? "internaldrive" : "externaldrive", detail: free, isFavorite: false)
        }
        let previous = (outline.item(atRow: outline.selectedRow) as? Item)?.path
        suppressSelection = true
        outline.reloadData()
        outline.expandItem(nil, expandChildren: true)
        suppressSelection = false
        highlight(previous)
    }

    /// Marks the place matching `path` (folder view) or clears the selection (search).
    func highlight(_ path: String?) {
        suppressSelection = true
        defer { suppressSelection = false }
        guard let path, let item = sections.flatMap(\.items).first(where: { $0.path == path }) else {
            outline.deselectAll(nil)
            return
        }
        let row = outline.row(forItem: item)
        if row >= 0 { outline.selectRowIndexes([row], byExtendingSelection: false) }
    }

    func addFavorite(_ path: String, at index: Int? = nil) {
        var list = Self.favoritePaths
        list.removeAll { $0 == path }
        list.insert(path, at: min(index ?? list.count, list.count))
        Self.favoritePaths = list
        reload()
    }

    // MARK: Outline

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil { return sections.count }
        return (item as? Section)?.items.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        item == nil ? sections[index] : (item as! Section).items[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { item is Section }
    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool { item is Section }
    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool { item is Item }
    func outlineView(_ outlineView: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool { false }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        if let s = item as? Section {
            let cell = outlineView.makeView(withIdentifier: .init("header"), owner: self) as? NSTableCellView ?? {
                let c = NSTableCellView()
                c.identifier = .init("header")
                let tf = NSTextField(labelWithString: "")
                tf.font = .systemFont(ofSize: 11, weight: .semibold)
                tf.textColor = .secondaryLabelColor
                tf.translatesAutoresizingMaskIntoConstraints = false
                c.addSubview(tf)
                c.textField = tf
                NSLayoutConstraint.activate([
                    tf.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 2),
                    tf.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                ])
                return c
            }()
            cell.textField?.stringValue = s.title
            return cell
        }
        guard let it = item as? Item else { return nil }
        let cell = outlineView.makeView(withIdentifier: .init("place"), owner: self) as? PlaceCell ?? PlaceCell()
        cell.identifier = .init("place")
        cell.configure(it)
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !suppressSelection, let it = outline.item(atRow: outline.selectedRow) as? Item else { return }
        onSelect?(it.path)
    }

    // MARK: Drag folders into "Favoriten"

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?,
                     proposedChildIndex index: Int) -> NSDragOperation {
        guard droppedFolders(info).count > 0 else { return [] }
        if item as? Section === favorites, index >= 0 { return .link }
        // Dropped onto a favourite or elsewhere: insert at the end of the favourites.
        outlineView.setDropItem(favorites, dropChildIndex: favorites.items.count)
        return .link
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        let folders = droppedFolders(info)
        guard !folders.isEmpty else { return false }
        let visible = favorites.items.map(\.path)
        var position = index >= 0 ? index : visible.count
        for f in folders {
            // Translate the position among visible favourites into the stored list.
            let stored = Self.favoritePaths.filter { $0 != f }
            let anchor = position < visible.count ? visible[position] : nil
            let storedIndex = anchor.flatMap { stored.firstIndex(of: $0) } ?? stored.count
            addFavorite(f, at: storedIndex)
            position += 1
        }
        return true
    }

    private func droppedFolders(_ info: NSDraggingInfo) -> [String] {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }.map(\.path)
    }

    // MARK: Context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = outline.clickedRow
        if row >= 0, let it = outline.item(atRow: row) as? Item {
            let reveal = menu.add(L("Im Finder zeigen"), #selector(revealClicked(_:)), target: self)
            reveal.representedObject = it.path
            if it.isFavorite {
                let remove = menu.add(L("Aus der Seitenleiste entfernen"), #selector(removeClicked(_:)), target: self)
                remove.representedObject = it.path
            }
            menu.addItem(.separator())
        }
        menu.add(L("Standard-Favoriten wiederherstellen"), #selector(resetFavorites(_:)), target: self)
    }

    @objc private func revealClicked(_ sender: NSMenuItem) {
        guard let p = sender.representedObject as? String else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)])
    }

    @objc private func removeClicked(_ sender: NSMenuItem) {
        guard let p = sender.representedObject as? String else { return }
        Self.favoritePaths = Self.favoritePaths.filter { $0 != p }
        reload()
    }

    @objc private func resetFavorites(_ sender: Any?) {
        Self.favoritePaths = Self.defaultFavorites
        reload()
    }
}

/// Sidebar row: symbol, name and (for volumes) free space.
private final class PlaceCell: NSTableCellView {
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        icon.symbolConfiguration = .init(pointSize: 13, weight: .regular)
        icon.contentTintColor = .controlAccentColor
        title.font = .systemFont(ofSize: 13)
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detail.font = .systemFont(ofSize: 10)
        detail.textColor = .secondaryLabelColor
        detail.setContentCompressionResistancePriority(.required, for: .horizontal)
        for v in [icon, title, detail] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        imageView = icon
        textField = title
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            detail.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 4),
            detail.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            detail.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ it: Sidebar.Item) {
        icon.image = NSImage(systemSymbolName: it.symbol, accessibilityDescription: it.title)
        title.stringValue = it.title
        detail.stringValue = it.detail
    }
}
