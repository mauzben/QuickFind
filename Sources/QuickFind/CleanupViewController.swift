import AppKit
import Quartz
import QuickFindCore

/// Cleanup assistant: categories on the left, candidates with checkboxes on the right.
/// Items only ever go to the Trash (restorable with "Zurücklegen").
final class CleanupViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate,
    NSOutlineViewDataSource, NSOutlineViewDelegate {

    /// Outline nodes must be classes (NSOutlineView keeps them by identity).
    final class GroupNode {
        let group: CleanupGroup
        var items: [ItemNode] = []
        init(_ group: CleanupGroup) { self.group = group }
    }

    final class ItemNode {
        let item: CleanupItem
        weak var group: GroupNode?
        let isKeep: Bool
        init(_ item: CleanupItem, group: GroupNode?, isKeep: Bool) {
            self.item = item
            self.group = group
            self.isKeep = isKeep
        }
    }

    private struct Option {
        let label: String
        let titles: [String]
        let values: [Int64]
        let defaultIndex: Int
    }

    private let manager: IndexManager
    /// QF_CLEANUP_HOME (developer override) analyses another folder as if it were the home folder.
    private var settings = CleanupSettings(home: ProcessInfo.processInfo.environment["QF_CLEANUP_HOME"] ?? NSHomeDirectory())
    private var results: [CleanupCategory: [GroupNode]] = [:]
    private var flatItems: [CleanupCategory: [ItemNode]] = [:]
    private var progress: [CleanupCategory: Double] = [:]
    private var running = Set<CleanupCategory>()
    private var selected: [CleanupCategory: Set<String>] = [:]
    private var current = CleanupCategory.duplicates
    private var cancel = CancelToken()
    private let queue = DispatchQueue(label: "QuickFind.cleanup", qos: .userInitiated, attributes: .concurrent)
    private let icons = IconCache()

    private let categoryTable = NSTableView()
    private let outline = CleanupOutlineView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let explanation = NSTextField(wrappingLabelWithString: "")
    private let optionLabel = NSTextField(labelWithString: "")
    private let optionPopup = NSPopUpButton()
    private let summaryLabel = NSTextField(labelWithString: "")
    private let messageLabel = NSTextField(labelWithString: "")
    private let emptyLabel = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private let trashButton = NSButton(title: L("In den Papierkorb legen …"), target: nil, action: nil)
    private let selectAllButton = NSButton(title: L("Alle auswählen"), target: nil, action: nil)
    private let selectNoneButton = NSButton(title: L("Auswahl aufheben"), target: nil, action: nil)

    private static let options: [CleanupCategory: Option] = [
        .duplicates: Option(label: "Dateien ab", titles: ["100 KB", "1 MB", "10 MB", "100 MB"],
                            values: [100 << 10, 1 << 20, 10 << 20, 100 << 20], defaultIndex: 1),
        .largeFiles: Option(label: "Dateien ab", titles: ["100 MB", "250 MB", "500 MB", "1 GB"],
                            values: [100 << 20, 250 << 20, 500 << 20, 1 << 30], defaultIndex: 1),
        .largeFolders: Option(label: "Ordner ab", titles: ["500 MB", "1 GB", "5 GB", "10 GB"],
                              values: [500 << 20, 1 << 30, 5 << 30, 10 << 30], defaultIndex: 1),
        .oldDownloads: Option(label: "Unverändert seit", titles: ["30 Tagen", "90 Tagen", "6 Monaten", "1 Jahr"],
                              values: [30, 90, 182, 365], defaultIndex: 1),
        .oldLargeFiles: Option(label: "Unverändert seit", titles: ["6 Monaten", "1 Jahr", "2 Jahren", "5 Jahren"],
                               values: [182, 365, 730, 1826], defaultIndex: 1),
    ]

    private static let explanations: [CleanupCategory: String] = [
        .duplicates: "Dateien mit exakt gleichem Inhalt – per Prüfsumme (SHA-256) verglichen, auch bei unterschiedlichen Namen. Von jeder Gruppe bleibt die älteste Datei erhalten, die Kopien sind vorausgewählt. Alle Dateien einer Gruppe lassen sich nicht auswählen.",
        .largeFiles: "Die größten Dateien in deinem Benutzerordner. Nichts ist vorausgewählt – entscheide selbst, was weg kann.",
        .largeFolders: "Die Ordner, in denen der Speicher wirklich steckt. Liegt der Großteil eines Ordners in einem einzigen Unterordner, wird dieser gezeigt. Ganze Hauptordner wie Dokumente oder Bilder werden nie vorgeschlagen. Nichts ist vorausgewählt.",
        .emptyFolders: "Ordner ohne Inhalt (ein vom Finder angelegtes .DS_Store zählt nicht). Bei verschachtelten leeren Ordnern wird nur der oberste gezeigt. Sie belegen kaum Platz, machen aber unübersichtlich. Nichts ist vorausgewählt.",
        .oldDownloads: "Objekte im Ordner „Downloads“, die lange nicht verändert wurden. Nichts ist vorausgewählt.",
        .oldLargeFiles: "Dateien ab 50 MB, die lange nicht verändert wurden – oft alte Videos, Archive oder Backups. Nichts ist vorausgewählt.",
        .installers: "Installationsprogramme und Disk-Images (.dmg, .pkg, .xip, .iso). Nach der Installation werden sie meist nicht mehr gebraucht.",
        .caches: "Zwischenspeicher von Programmen in ~/Library/Caches (ohne Apple-eigene). Programme legen sie bei Bedarf neu an – beende die betroffenen Programme vorher.",
    ]

    init(manager: IndexManager) {
        self.manager = manager
        super.init(nibName: nil, bundle: nil)
        for (c, o) in Self.options { apply(o.values[o.defaultIndex], to: c) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        view = OpaqueView()
        view.wantsLayer = true
        buildUI()
    }

    /// Called whenever the assistant is shown in the main window; the first time it starts the analysis.
    func didAppear() {
        if results.isEmpty && running.isEmpty { rescanAll() }
        view.window?.makeFirstResponder(categoryTable)
    }

    // MARK: UI

    private func buildUI() {
        let content = view

        let col = NSTableColumn(identifier: .init("category"))
        categoryTable.addTableColumn(col)
        categoryTable.headerView = nil
        categoryTable.style = .sourceList
        categoryTable.rowHeight = 46
        categoryTable.dataSource = self
        categoryTable.delegate = self
        let categoryScroll = NSScrollView()
        categoryScroll.documentView = categoryTable
        categoryScroll.drawsBackground = false
        categoryScroll.hasVerticalScroller = true

        let sidebar = NSVisualEffectView()
        sidebar.material = .sidebar
        sidebar.blendingMode = .withinWindow
        categoryScroll.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(categoryScroll)

        titleLabel.font = .boldSystemFont(ofSize: 18)
        explanation.font = .systemFont(ofSize: 12)
        explanation.textColor = .secondaryLabelColor
        optionLabel.font = .systemFont(ofSize: 12)
        optionPopup.target = self
        optionPopup.action = #selector(optionChanged(_:))
        optionPopup.controlSize = .small

        for (id, title, width) in [("check", "", 26.0), ("name", "Name", 340.0), ("folder", "Ordner", 220.0),
                                   ("size", "Größe", 75.0), ("modified", "Geändert", 82.0), ("created", "Erstellt", 82.0)] {
            let c = NSTableColumn(identifier: .init(id))
            c.title = L(title)
            c.width = width
            c.minWidth = id == "check" ? 26 : 60
            if id == "check" { c.maxWidth = 26 }
            // Only name and folder grow with the window.
            if id != "name" && id != "folder" { c.resizingMask = .userResizingMask }
            if id == "size" { c.headerCell.alignment = .right }
            outline.addTableColumn(c)
            if id == "name" { outline.outlineTableColumn = c }
        }
        outline.dataSource = self
        outline.delegate = self
        outline.rowHeight = 22
        outline.usesAlternatingRowBackgroundColors = true
        outline.allowsMultipleSelection = true
        outline.style = .fullWidth
        outline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outline.autosaveName = "CleanupOutline3"
        outline.autosaveTableColumns = true
        outline.target = self
        outline.doubleAction = #selector(revealSelection(_:))
        outline.previewURLs = { [weak self] in self?.selectedRowURLs() ?? [] }
        outline.toggleCheck = { [weak self] in self?.toggleSelectedRows() }
        let menu = NSMenu()
        menu.add(L("Im Finder zeigen"), #selector(revealSelection(_:)), target: self)
        menu.add(L("Öffnen"), #selector(openSelection(_:)), target: self)
        menu.add(L("Übersicht (Quick Look)"), #selector(quickLook(_:)), target: self)
        outline.menu = menu
        let outlineScroll = NSScrollView()
        outlineScroll.documentView = outline
        outlineScroll.hasVerticalScroller = true
        outlineScroll.borderType = .bezelBorder

        emptyLabel.font = .systemFont(ofSize: 15)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        summaryLabel.font = .systemFont(ofSize: 12, weight: .medium)
        messageLabel.font = .systemFont(ofSize: 11)
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.lineBreakMode = .byTruncatingTail
        let protectedNote = NSTextField(wrappingLabelWithString: L(
            "Geschützt und nie vorgeschlagen: System, Programme, ~/Library (außer Caches), versteckte Ordner, Inhalte von App-Paketen und Mediatheken, Git-Projekte, installierte Software und Dateien, die nur in der Cloud liegen. Alles landet im Papierkorb und lässt sich dort mit „Zurücklegen“ wiederherstellen."))
        protectedNote.font = .systemFont(ofSize: 11)
        protectedNote.textColor = .tertiaryLabelColor

        trashButton.target = self
        trashButton.action = #selector(moveToTrash(_:))
        trashButton.bezelStyle = .rounded
        trashButton.hasDestructiveAction = true
        trashButton.keyEquivalent = "\u{8}"
        trashButton.keyEquivalentModifierMask = .command
        selectAllButton.target = self
        selectAllButton.action = #selector(checkAllCandidates(_:))
        selectNoneButton.target = self
        selectNoneButton.action = #selector(uncheckAll(_:))
        let reveal = NSButton(title: L("Im Finder zeigen"), target: self, action: #selector(revealSelection(_:)))
        let rescan = NSButton(title: L("Neu prüfen"), target: self, action: #selector(rescanCurrent(_:)))

        let views: [NSView] = [sidebar, titleLabel, explanation, optionLabel, optionPopup, spinner, outlineScroll, emptyLabel,
                               summaryLabel, messageLabel, protectedNote, selectAllButton, selectNoneButton, reveal, rescan,
                               trashButton]
        for v in views {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        let pad: CGFloat = 16
        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: content.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 230),
            categoryScroll.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            categoryScroll.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            categoryScroll.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 8),
            categoryScroll.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor),

            titleLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: pad),
            titleLabel.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: pad),
            spinner.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 8),
            spinner.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            optionPopup.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -pad),
            optionPopup.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            optionLabel.trailingAnchor.constraint(equalTo: optionPopup.leadingAnchor, constant: -6),
            optionLabel.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),

            explanation.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
            explanation.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            explanation.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -pad),

            outlineScroll.topAnchor.constraint(equalTo: explanation.bottomAnchor, constant: 12),
            outlineScroll.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            outlineScroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -pad),
            emptyLabel.centerXAnchor.constraint(equalTo: outlineScroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: outlineScroll.centerYAnchor),
            emptyLabel.widthAnchor.constraint(lessThanOrEqualTo: outlineScroll.widthAnchor, constant: -40),

            summaryLabel.topAnchor.constraint(equalTo: outlineScroll.bottomAnchor, constant: 10),
            summaryLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            messageLabel.centerYAnchor.constraint(equalTo: summaryLabel.centerYAnchor),
            messageLabel.leadingAnchor.constraint(equalTo: summaryLabel.trailingAnchor, constant: 12),
            messageLabel.trailingAnchor.constraint(lessThanOrEqualTo: selectAllButton.leadingAnchor, constant: -12),
            selectNoneButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -pad),
            selectNoneButton.centerYAnchor.constraint(equalTo: summaryLabel.centerYAnchor),
            selectAllButton.trailingAnchor.constraint(equalTo: selectNoneButton.leadingAnchor, constant: -6),
            selectAllButton.centerYAnchor.constraint(equalTo: summaryLabel.centerYAnchor),

            protectedNote.topAnchor.constraint(equalTo: summaryLabel.bottomAnchor, constant: 10),
            protectedNote.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            protectedNote.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -pad),

            reveal.topAnchor.constraint(equalTo: protectedNote.bottomAnchor, constant: 10),
            reveal.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            reveal.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -pad),
            rescan.leadingAnchor.constraint(equalTo: reveal.trailingAnchor, constant: 8),
            rescan.centerYAnchor.constraint(equalTo: reveal.centerYAnchor),
            trashButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -pad),
            trashButton.centerYAnchor.constraint(equalTo: reveal.centerYAnchor),
        ])
        categoryTable.selectRowIndexes([current.rawValue], byExtendingSelection: false)
        showCategory()
    }

    // MARK: Scanning

    private func apply(_ value: Int64, to c: CleanupCategory) {
        switch c {
        case .duplicates: settings.minDuplicateSize = value
        case .largeFiles: settings.minLargeSize = value
        case .largeFolders: settings.minFolderSize = value
        case .oldDownloads: settings.downloadsAgeDays = Int(value)
        case .oldLargeFiles: settings.oldAgeDays = Int(value)
        default: break
        }
    }

    private func rescanAll() {
        cancel.cancel()
        cancel = CancelToken()
        // Fast categories first; the duplicate check reads files and comes last.
        for c in CleanupCategory.allCases.filter({ $0 != .duplicates }) + [.duplicates] { scan(c) }
    }

    private func scan(_ c: CleanupCategory) {
        guard manager.isReady else {
            running.insert(c)
            updateSidebar()
            showCategory()
            // The index is still being built: try again shortly.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.scan(c) }
            return
        }
        running.insert(c)
        progress[c] = 0
        updateSidebar()
        if c == current { showCategory() }
        var s = settings
        s.now = Int64(Date().timeIntervalSince1970)
        let token = cancel
        let index = manager.index
        queue.async { [weak self] in
            let groups = Cleanup.run(c, index: index, settings: s, progress: { p in
                DispatchQueue.main.async {
                    self?.progress[c] = p
                    self?.updateSidebar()
                    if self?.current == c { self?.updateHeader() }
                }
            }, cancel: token)
            DispatchQueue.main.async {
                guard let self, !token.isCancelled else { return }
                self.install(groups, for: c)
            }
        }
    }

    private func install(_ groups: [CleanupGroup], for c: CleanupCategory) {
        running.remove(c)
        var nodes: [GroupNode] = []
        var flat: [ItemNode] = []
        var preselected = Set<String>()
        for g in groups {
            if g.keep != nil {
                let node = GroupNode(g)
                node.items = g.items.enumerated().map { ItemNode($0.element, group: node, isKeep: $0.offset == g.keep) }
                for it in node.items where !it.isKeep && c.preselects { preselected.insert(it.item.path) }
                nodes.append(node)
            } else {
                flat += g.items.map { ItemNode($0, group: nil, isKeep: false) }
            }
        }
        results[c] = nodes
        flatItems[c] = flat
        selected[c] = preselected
        updateSidebar()
        if c == current { showCategory() }
    }

    // MARK: Display

    private var currentRoots: [AnyObject] {
        let groups = results[current] ?? []
        return groups.isEmpty ? (flatItems[current] ?? []) : groups
    }

    private func showCategory() {
        updateHeader()
        if let o = Self.options[current] {
            optionPopup.removeAllItems()
            optionPopup.addItems(withTitles: o.titles.map(L))
            let currentValue: Int64 = {
                switch current {
                case .duplicates: return settings.minDuplicateSize
                case .largeFiles: return settings.minLargeSize
                case .largeFolders: return settings.minFolderSize
                case .oldDownloads: return Int64(settings.downloadsAgeDays)
                default: return Int64(settings.oldAgeDays)
                }
            }()
            optionPopup.selectItem(at: o.values.firstIndex(of: currentValue) ?? o.defaultIndex)
            optionLabel.stringValue = L(o.label)
            optionPopup.isHidden = false
            optionLabel.isHidden = false
        } else {
            optionPopup.isHidden = true
            optionLabel.isHidden = true
        }
        outline.reloadData()
        outline.expandItem(nil, expandChildren: true)
        updateSummary()
    }

    private func updateHeader() {
        titleLabel.stringValue = current.title
        explanation.stringValue = Self.explanations[current].map(L) ?? ""
        let isRunning = running.contains(current)
        if isRunning { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        let empty = currentRoots.isEmpty
        emptyLabel.isHidden = !empty
        if isRunning {
            emptyLabel.stringValue = !manager.isReady ? L("Der Index wird noch aufgebaut …")
                : current == .duplicates ? L("Inhalte werden verglichen … %@", Format.percent(progress[current] ?? 0))
                : L("Wird geprüft …")
        } else {
            emptyLabel.stringValue = L("Nichts gefunden – hier ist alles aufgeräumt. 🎉")
        }
    }

    private func reclaimable(_ c: CleanupCategory) -> (count: Int, size: Int64) {
        let groups = results[c] ?? []
        let flat = flatItems[c] ?? []
        let g = groups.reduce((0, Int64(0))) { ($0.0 + $1.items.count - 1, $0.1 + $1.group.reclaimable) }
        let f = flat.reduce((0, Int64(0))) { ($0.0 + 1, $0.1 + $1.item.size) }
        return (g.0 + f.0, g.1 + f.1)
    }

    private func updateSidebar() {
        let row = categoryTable.selectedRow
        categoryTable.reloadData()
        if row >= 0 { categoryTable.selectRowIndexes([row], byExtendingSelection: false) }
    }

    private var selectedItems: [ItemNode] {
        let paths = selected[current] ?? []
        let all = (results[current] ?? []).flatMap(\.items) + (flatItems[current] ?? [])
        return all.filter { paths.contains($0.item.path) }
    }

    private func updateSummary() {
        let items = selectedItems
        let size = items.reduce(Int64(0)) { $0 + $1.item.size }
        summaryLabel.stringValue = items.isEmpty ? L("Nichts ausgewählt")
            : L(items.count == 1 ? "Ausgewählt: %1$@ Objekt · %2$@" : "Ausgewählt: %1$@ Objekte · %2$@", Format.count(items.count), Format.size(size))
        trashButton.isEnabled = !items.isEmpty
        let hasItems = !currentRoots.isEmpty
        selectAllButton.isEnabled = hasItems
        selectNoneButton.isEnabled = !items.isEmpty
        selectAllButton.title = current == .duplicates ? L("Alle Kopien auswählen") : L("Alle auswählen")
    }

    // MARK: Sidebar table

    func numberOfRows(in tableView: NSTableView) -> Int { CleanupCategory.allCases.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let c = CleanupCategory.allCases[row]
        let cell = tableView.makeView(withIdentifier: .init("cat"), owner: self) as? CategoryCell ?? CategoryCell()
        cell.identifier = .init("cat")
        let subtitle: String
        if running.contains(c) {
            subtitle = c == .duplicates && (progress[c] ?? 0) > 0 ? L("Wird geprüft … %@", Format.percent(progress[c] ?? 0)) : L("Wird geprüft …")
        } else if results[c] == nil && flatItems[c] == nil {
            subtitle = ""
        } else {
            let r = reclaimable(c)
            subtitle = r.count == 0 ? L("Nichts gefunden")
                : c == .emptyFolders ? (r.count == 1 ? L("1 Ordner") : L("%@ Ordner", Format.count(r.count)))
                : "\(Format.count(r.count)) · \(Format.size(r.size))"
        }
        cell.configure(symbol: c.symbol, title: c.title, subtitle: subtitle)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let t = notification.object as? NSTableView, t === categoryTable, t.selectedRow >= 0,
              let c = CleanupCategory(rawValue: t.selectedRow) else { return }
        current = c
        messageLabel.stringValue = ""
        showCategory()
    }

    // MARK: Outline

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil { return currentRoots.count }
        return (item as? GroupNode)?.items.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil { return currentRoots[index] }
        return (item as! GroupNode).items[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { item is GroupNode }

    /// Duplicate groups are full-width header rows.
    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool { item is GroupNode }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool { item is ItemNode }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        if let g = item as? GroupNode {
            guard tableColumn == nil else { return nil }
            let cell = textCell("group")
            let size = g.group.items.first?.size ?? 0
            cell.textField?.stringValue = L("%1$@ × gleicher Inhalt · je %2$@ · %3$@ frei", Format.count(g.items.count), Format.size(size),
                                             Format.size(g.group.reclaimable))
            cell.textField?.font = .boldSystemFont(ofSize: 12)
            cell.imageView?.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
            return cell
        }
        guard let id = tableColumn?.identifier.rawValue, let node = item as? ItemNode else { return nil }
        let it = node.item
        switch id {
        case "check":
            let cell = outline.makeView(withIdentifier: .init("checkCell"), owner: self) as? CheckCell ?? CheckCell()
            cell.identifier = .init("checkCell")
            cell.box.state = (selected[current] ?? []).contains(it.path) ? .on : .off
            cell.onToggle = { [weak self, weak node] on in
                guard let self, let node else { return }
                self.setChecked(node, on)
            }
            return cell
        case "name":
            let cell = textCell(id)
            cell.textField?.font = .systemFont(ofSize: 12)
            cell.textField?.stringValue = node.isKeep ? it.name + "  · " + L("Original, bleibt") : it.name
            cell.textField?.textColor = node.isKeep ? .secondaryLabelColor : .labelColor
            if let info = manager.index.info(it.id) { cell.imageView?.image = icons.icon(for: info) }
            return cell
        case "folder":
            let cell = textCell(id)
            cell.textField?.stringValue = (it.path as NSString).deletingLastPathComponent
                .replacingOccurrences(of: NSHomeDirectory(), with: "~")
            return cell
        case "size":
            let cell = textCell(id)
            cell.textField?.stringValue = Format.size(it.size)
            return cell
        case "modified":
            let cell = textCell(id)
            cell.textField?.stringValue = Self.day(it.mtime)
            return cell
        default:
            let cell = textCell(id)
            cell.textField?.stringValue = Self.day(it.created)
            return cell
        }
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    private static func day(_ t: Int64) -> String {
        t == 0 ? "" : dayFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(t)))
    }

    private func textCell(_ id: String) -> NSTableCellView {
        if let c = outline.makeView(withIdentifier: .init(id), owner: self) as? NSTableCellView {
            c.textField?.textColor = .labelColor
            return c
        }
        let c = NSTableCellView()
        c.identifier = .init(id)
        let tf = NSTextField(labelWithString: "")
        tf.font = .systemFont(ofSize: 12)
        tf.lineBreakMode = id == "folder" ? .byTruncatingMiddle : .byTruncatingTail
        tf.maximumNumberOfLines = 1
        tf.translatesAutoresizingMaskIntoConstraints = false
        tf.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        if id == "size" { tf.alignment = .right }
        c.addSubview(tf)
        c.textField = tf
        var leading = c.leadingAnchor
        if id == "name" || id == "group" {
            let iv = NSImageView()
            iv.translatesAutoresizingMaskIntoConstraints = false
            c.addSubview(iv)
            c.imageView = iv
            NSLayoutConstraint.activate([
                iv.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 2),
                iv.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                iv.widthAnchor.constraint(equalToConstant: 16),
                iv.heightAnchor.constraint(equalToConstant: 16),
            ])
            leading = iv.trailingAnchor
        }
        NSLayoutConstraint.activate([
            tf.leadingAnchor.constraint(equalTo: leading, constant: 4),
            tf.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -2),
            tf.centerYAnchor.constraint(equalTo: c.centerYAnchor),
        ])
        return c
    }

    // MARK: Selection (checkboxes)

    /// Checks/unchecks an item. Within a duplicate group at least one file must stay unchecked.
    private func setChecked(_ node: ItemNode, _ on: Bool) {
        var set = selected[current] ?? []
        if on {
            if let g = node.group, g.items.allSatisfy({ $0 === node || set.contains($0.item.path) }) {
                NSSound.beep()
                messageLabel.stringValue = L("Von jeder Dublette bleibt mindestens eine Datei erhalten.")
                reloadRow(node)
                return
            }
            set.insert(node.item.path)
        } else {
            set.remove(node.item.path)
        }
        selected[current] = set
        messageLabel.stringValue = ""
        reloadRow(node)
        updateSummary()
    }

    private func reloadRow(_ node: ItemNode) {
        let row = outline.row(forItem: node)
        if row >= 0 { outline.reloadData(forRowIndexes: [row], columnIndexes: [0]) }
    }

    /// Space bar is Quick Look; ⌘/Return toggles the checkboxes of the selected rows.
    private func toggleSelectedRows() {
        let nodes = outline.selectedRowIndexes.compactMap { outline.item(atRow: $0) as? ItemNode }
        guard !nodes.isEmpty else { return }
        let set = selected[current] ?? []
        let turnOn = nodes.contains { !set.contains($0.item.path) }
        for n in nodes { setChecked(n, turnOn) }
    }

    @objc private func checkAllCandidates(_ sender: Any?) {
        var set = Set<String>()
        for g in results[current] ?? [] {
            for it in g.items where !it.isKeep { set.insert(it.item.path) }
        }
        for it in flatItems[current] ?? [] { set.insert(it.item.path) }
        selected[current] = set
        outline.reloadData()
        updateSummary()
    }

    @objc private func uncheckAll(_ sender: Any?) {
        selected[current] = []
        outline.reloadData()
        updateSummary()
    }

    @objc private func optionChanged(_ sender: NSPopUpButton) {
        guard let o = Self.options[current] else { return }
        apply(o.values[sender.indexOfSelectedItem], to: current)
        scan(current)
    }

    @objc private func rescanCurrent(_ sender: Any?) {
        messageLabel.stringValue = ""
        scan(current)
    }

    // MARK: Actions

    private func selectedRowURLs() -> [URL] {
        outline.selectedRowIndexes.compactMap { (outline.item(atRow: $0) as? ItemNode)?.item.path }.map { URL(fileURLWithPath: $0) }
    }

    @objc private func revealSelection(_ sender: Any?) {
        var urls = selectedRowURLs()
        if urls.isEmpty, outline.clickedRow >= 0, let n = outline.item(atRow: outline.clickedRow) as? ItemNode {
            urls = [URL(fileURLWithPath: n.item.path)]
        }
        if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }

    @objc private func openSelection(_ sender: Any?) {
        for url in selectedRowURLs().prefix(20) { NSWorkspace.shared.open(url) }
    }

    @objc private func quickLook(_ sender: Any?) { outline.toggleQuickLook() }

    @objc private func moveToTrash(_ sender: Any?) {
        guard let window = view.window else { return }
        var items = selectedItems
        // Safety re-check right before deleting: the file still exists, is not protected, and each
        // duplicate group keeps at least one existing, unselected copy.
        let fm = FileManager.default
        let home = settings.home
        var skipped = 0
        let selectedPaths = Set(items.map(\.item.path))
        items = items.filter { node in
            guard fm.fileExists(atPath: node.item.path),
                  !Cleanup.isProtected(node.item.path, home: home, allowLibraryCaches: current == .caches,
                                       isDirectory: node.item.isDirectory) else {
                skipped += 1
                return false
            }
            if let g = node.group {
                let keeps = g.items.filter { !selectedPaths.contains($0.item.path) && fm.fileExists(atPath: $0.item.path) }
                if keeps.isEmpty {
                    skipped += 1
                    return false
                }
            }
            return true
        }
        guard !items.isEmpty else {
            messageLabel.stringValue = L("Nichts zu tun – die Auswahl hat sich auf der Festplatte geändert. Bitte neu prüfen.")
            return
        }
        let size = items.reduce(Int64(0)) { $0 + $1.item.size }
        let a = NSAlert()
        a.messageText = L(items.count == 1 ? "%@ Objekt in den Papierkorb legen?" : "%@ Objekte in den Papierkorb legen?", Format.count(items.count))
        a.informativeText = L("Nach dem Leeren des Papierkorbs werden ca. %@ frei.\nBis dahin kannst du alles im Papierkorb mit „Zurücklegen“ wiederherstellen.", Format.size(size))
            + (skipped > 0 ? "\n\n" + L("%@ Objekt(e) wurden übersprungen, weil sie sich inzwischen geändert haben.", Format.count(skipped)) : "")
        a.addButton(withTitle: L("In den Papierkorb legen"))
        a.addButton(withTitle: L("Abbrechen"))
        a.buttons[0].hasDestructiveAction = true
        a.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.trash(items)
        }
    }

    private func trash(_ items: [ItemNode]) {
        let category = current
        let urls = items.map { URL(fileURLWithPath: $0.item.path) }
        NSWorkspace.shared.recycle(urls) { [weak self] trashed, error in
            DispatchQueue.main.async {
                guard let self else { return }
                let done = Set(trashed.keys.map(\.path))
                let freed = items.filter { done.contains($0.item.path) }.reduce(Int64(0)) { $0 + $1.item.size }
                self.remove(done, from: category)
                var text = L(done.count == 1 ? "%1$@ Objekt in den Papierkorb gelegt – %2$@ werden nach dem Leeren frei."
                                            : "%1$@ Objekte in den Papierkorb gelegt – %2$@ werden nach dem Leeren frei.",
                             Format.count(done.count), Format.size(freed))
                if let error, done.count < items.count {
                    text += " " + L("%1$@ nicht möglich: %2$@", Format.count(items.count - done.count), error.localizedDescription)
                }
                self.messageLabel.stringValue = text
            }
        }
    }

    /// Removes trashed paths from all categories (a file can appear in several).
    private func remove(_ paths: Set<String>, from category: CleanupCategory) {
        for c in CleanupCategory.allCases {
            if var groups = results[c] {
                for g in groups { g.items.removeAll { paths.contains($0.item.path) } }
                groups.removeAll { $0.items.count < 2 }
                results[c] = groups
            }
            flatItems[c]?.removeAll { paths.contains($0.item.path) }
            selected[c]?.subtract(paths)
        }
        updateSidebar()
        showCategory()
    }
}

/// Sidebar row: symbol, title and a subtitle with count and size.
private final class CategoryCell: NSTableCellView {
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        title.font = .systemFont(ofSize: 13, weight: .medium)
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        icon.symbolConfiguration = .init(pointSize: 16, weight: .regular)
        icon.contentTintColor = .controlAccentColor
        for v in [icon, title, subtitle] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 22),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            title.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            title.bottomAnchor.constraint(equalTo: centerYAnchor, constant: 1),
            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            subtitle.topAnchor.constraint(equalTo: centerYAnchor, constant: 2),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(symbol: String, title t: String, subtitle s: String) {
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: t)
        title.stringValue = t
        subtitle.stringValue = s
    }
}

/// Checkbox cell reporting toggles to the controller.
private final class CheckCell: NSTableCellView {
    let box = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    var onToggle: ((Bool) -> Void)?

    init() {
        super.init(frame: .zero)
        box.target = self
        box.action = #selector(toggled)
        box.translatesAutoresizingMaskIntoConstraints = false
        addSubview(box)
        NSLayoutConstraint.activate([
            box.centerXAnchor.constraint(equalTo: centerXAnchor),
            box.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func toggled() { onToggle?(box.state == .on) }
}

/// Covers the search view underneath while the assistant is shown in the main window.
private final class OpaqueView: NSView {
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor }
}

/// Outline with Quick Look (space) and keyboard toggling of checkboxes (Return).
final class CleanupOutlineView: NSOutlineView, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    var previewURLs: (() -> [URL])?
    var toggleCheck: (() -> Void)?
    private var items: [URL] = []

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if event.keyCode == 49 && mods.isEmpty { toggleQuickLook(); return }
        if (event.keyCode == 36 || event.keyCode == 76) && mods.isEmpty { toggleCheck?(); return }
        super.keyDown(with: event)
    }

    func toggleQuickLook() {
        guard let panel = QLPreviewPanel.shared() else { return }
        if QLPreviewPanel.sharedPreviewPanelExists() && panel.isVisible {
            panel.orderOut(nil)
        } else {
            window?.makeFirstResponder(self)
            panel.makeKeyAndOrderFront(nil)
        }
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        items = previewURLs?() ?? []
        panel.dataSource = self
        panel.delegate = self
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { items.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! { items[index] as NSURL }

    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard let event, event.type == .keyDown else { return false }
        keyDown(with: event)
        items = previewURLs?() ?? []
        panel.reloadData()
        return true
    }
}
