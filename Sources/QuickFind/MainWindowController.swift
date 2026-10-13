import AppKit
import CoreServices
import Quartz
import QuickFindCore

/// The search window: search field + filter, virtual result table, status bar.
final class MainWindowController: NSWindowController, NSWindowDelegate, NSSearchFieldDelegate, NSTableViewDataSource,
    NSTableViewDelegate, NSMenuItemValidation, NSMenuDelegate, ResultsTableActions {
    private let manager: IndexManager
    private var index: FileIndex { manager.index }

    private let searchField = NSSearchField()
    private let filterPopup = NSPopUpButton()
    private let tableView = ResultsTableView()
    private let scrollView = NSScrollView()
    private let countLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let progress = NSProgressIndicator()
    private let backButton = NSButton()
    private let forwardButton = NSButton()
    private let upButton = NSButton()
    private let pathControl = NSPathControl()
    private var pathBarHeight: NSLayoutConstraint!

    /// A place in the navigation history: a folder (empty search) or a search.
    private struct Location: Equatable {
        var folder: String
        var search: String
    }

    private var browsePath = NSHomeDirectory()
    private var backStack: [Location] = []
    private var forwardStack: [Location] = []
    private var showHidden = false
    private var pendingSelectName: String?
    private var pendingSelectDeadline = Date.distantPast
    private var pendingRename = false
    private let scopeControl = NSSegmentedControl(labels: [L("Überall"), L("Dieser Ordner")], trackingMode: .selectOne,
                                                  target: nil, action: nil)
    private var searchInFolder = Prefs.searchInFolder
    private var totalSize: Int64 = 0
    private var totalAllocated: Int64 = 0
    private let volumes = VolumeCapacity()
    /// The cleanup assistant, shown in place of the results (created on first use).
    private var cleanup: CleanupViewController?
    private weak var topSeparator: NSBox?
    private var isShowingCleanup: Bool { cleanup?.view.superview != nil }
    private let cleanupButton = NSButton(title: L("Aufräumen"), image: NSImage(systemSymbolName: "sparkles",
                                         accessibilityDescription: L("Aufräumen"))!, target: nil, action: nil)
    private let lowSpaceButton = NSButton(title: "", target: nil, action: nil)
    private let sidebar = Sidebar()
    private let sidebarBackground = NSVisualEffectView()
    private var sidebarWidth: NSLayoutConstraint!
    private var showSidebar = Prefs.showSidebar
    private weak var sidebarSeparator: NSBox?

    // Columns
    private var hiddenColumns = Prefs.hiddenColumns
    private let headerMenu = NSMenu()
    private struct EntryMeta {
        var lastUsed: Int64?
        var tags: [String]
    }
    private var metaCache: [Int32: EntryMeta] = [:]
    /// Reference for "Belegung" in the folder view: the space the shown folder uses.
    private var folderAllocated: Int64 = 0
    private var renamingField: NSTextField?
    private var renamingPath: String?
    private var renameCancelled = false
    private var isBrowsing: Bool { searchField.stringValue.trimmingCharacters(in: .whitespaces).isEmpty }

    private var results: [Int32] = []
    private var query: Query?
    private var options = Prefs.searchOptions
    private var sortKey = Prefs.sortKey
    private var ascending = Prefs.sortAscending
    private var lastSearchSeconds = 0.0
    private var shownGeneration: UInt64 = 0

    private let searchQueue = DispatchQueue(label: "QuickFind.search", qos: .userInteractive)
    private var searchToken: CancelToken?
    private var searchSeq = 0
    private var refreshTimer: Timer?
    private var infoCache: [Int32: EntryInfo] = [:]
    private let icons = IconCache()
    private let typeNames = TypeNames()
    private let boldFont = NSFont.systemFont(ofSize: 12, weight: .bold)
    private let regularFont = NSFont.systemFont(ofSize: 12)
    private let truncating: NSParagraphStyle = {
        let p = NSMutableParagraphStyle()
        p.lineBreakMode = .byTruncatingTail
        return p
    }()

    init(manager: IndexManager) {
        self.manager = manager
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 660),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.title = "QuickFind"
        w.minSize = NSSize(width: 560, height: 320)
        w.isReleasedWhenClosed = false
        if !w.setFrameUsingName("MainWindow") { w.center() }
        w.setFrameAutosaveName("MainWindow")
        super.init(window: w)
        w.delegate = self
        buildUI()
        let env = ProcessInfo.processInfo.environment
        if let q = env["QF_QUERY"] { searchField.stringValue = q }
        if let f = env["QF_FOLDER"] { browsePath = f }
        updatePlaceholder()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refreshIfIndexChanged()
        }
        search()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: UI

    private func buildUI() {
        guard let content = window?.contentView else { return }

        searchField.placeholderString = L("Suchen")
        searchField.font = .systemFont(ofSize: 15)
        searchField.controlSize = .large
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = true
        searchField.sendsWholeSearchString = false
        searchField.focusRingType = .default

        filterPopup.addItems(withTitles: FileFilter.allCases.map(\.title))
        filterPopup.selectItem(at: options.filter.rawValue)
        filterPopup.target = self
        filterPopup.action = #selector(filterPopupChanged(_:))
        filterPopup.controlSize = .large

        for (b, symbol, tip, action) in [(backButton, "chevron.left", L("Zurück (⌘[)"), #selector(goBack(_:))),
                                         (forwardButton, "chevron.right", L("Vorwärts (⌘])"), #selector(goForward(_:))),
                                         (upButton, "arrow.up", L("Übergeordneter Ordner (⌘↑)"), #selector(goUp(_:)))] {
            b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
            b.bezelStyle = .texturedRounded
            b.controlSize = .large
            b.toolTip = tip
            b.target = self
            b.action = action
        }

        scopeControl.selectedSegment = searchInFolder ? 1 : 0
        scopeControl.controlSize = .large
        scopeControl.target = self
        scopeControl.action = #selector(scopeChanged(_:))
        scopeControl.setToolTip(L("Auf der ganzen Festplatte suchen"), forSegment: 0)
        scopeControl.setToolTip(L("Nur im aktuellen Ordner und seinen Unterordnern suchen"), forSegment: 1)

        cleanupButton.imagePosition = .imageLeading
        cleanupButton.controlSize = .large
        cleanupButton.bezelStyle = .rounded
        cleanupButton.target = self
        cleanupButton.action = #selector(toggleCleanup(_:))
        cleanupButton.toolTip = L("Aufräum-Assistent: Dubletten, große und alte Dateien, Installer, Caches (⌃⌘0)")
        lowSpaceButton.isBordered = false
        lowSpaceButton.font = .systemFont(ofSize: 11, weight: .medium)
        lowSpaceButton.contentTintColor = .systemOrange
        lowSpaceButton.target = self
        lowSpaceButton.action = #selector(openCleanup(_:))
        lowSpaceButton.isHidden = true

        pathControl.pathStyle = .standard
        pathControl.controlSize = .small
        pathControl.focusRingType = .none
        pathControl.target = self
        pathControl.action = #selector(pathControlClicked(_:))
        pathControl.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        for (id, title, width, minWidth) in [("name", "Name", 280.0, 120.0), ("path", "Pfad", 360.0, 120.0),
                                             ("size", "Größe", 90.0, 60.0), ("share", "Belegung", 110.0, 70.0),
                                             ("date", "Änderungsdatum", 140.0, 90.0), ("type", "Typ", 120.0, 60.0),
                                             ("created", "Erstellt am", 140.0, 90.0), ("lastUsed", "Zuletzt geöffnet", 140.0, 90.0),
                                             ("tags", "Tags", 120.0, 60.0)] {
            let c = NSTableColumn(identifier: .init(id))
            c.title = L(title)
            c.width = width
            c.minWidth = minWidth
            // "Zuletzt geöffnet" and tags come from Spotlight per visible row, so they cannot be sorted.
            if id != "lastUsed" && id != "tags" {
                c.sortDescriptorPrototype = NSSortDescriptor(key: id == "share" ? "allocated" : id, ascending: id != "share")
            }
            if id == "lastUsed" { c.headerToolTip = L("Laut Spotlight zuletzt geöffnet (nicht sortierbar)") }
            if id == "size" {
                c.headerCell.alignment = .right
                c.headerToolTip = L("Ordner: tatsächlich belegter Speicher. Dateien: Größe wie im Finder.")
            }
            if id == "share" {
                c.headerToolTip = L("Anteil am Gesamtspeicher des Volumes (tatsächlich belegter Speicher)")
            }
            tableView.addTableColumn(c)
        }
        tableView.sortDescriptors = [NSSortDescriptor(key: sortKey.rawValue, ascending: ascending)]
        tableView.autosaveName = "ResultsTable"
        tableView.autosaveTableColumns = true
        tableView.style = .fullWidth
        tableView.rowHeight = 20
        tableView.intercellSpacing = NSSize(width: 6, height: 1)
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = true
        tableView.allowsColumnReordering = true
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.dataSource = self
        tableView.delegate = self
        tableView.actions = self
        tableView.target = self
        tableView.doubleAction = #selector(tableDoubleClicked(_:))
        tableView.setDraggingSourceOperationMask([.copy, .move, .link], forLocal: false)
        tableView.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        tableView.registerForDraggedTypes([.fileURL])
        tableView.menu = makeContextMenu()
        headerMenu.delegate = self
        tableView.headerView?.menu = headerMenu

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        countLabel.font = .systemFont(ofSize: 11)
        countLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .right
        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false

        let topSeparator = NSBox()
        topSeparator.boxType = .separator
        let bottomSeparator = NSBox()
        bottomSeparator.boxType = .separator

        sidebarBackground.material = .sidebar
        sidebarBackground.blendingMode = .withinWindow
        sidebar.scrollView.translatesAutoresizingMaskIntoConstraints = false
        sidebarBackground.addSubview(sidebar.scrollView)
        sidebar.onSelect = { [weak self] path in self?.navigate(to: path) }
        let sidebarSeparator = NSBox()
        sidebarSeparator.boxType = .separator

        let pathSeparator = NSBox()
        pathSeparator.boxType = .separator
        let pathBar = NSView()
        pathBar.translatesAutoresizingMaskIntoConstraints = false
        pathControl.translatesAutoresizingMaskIntoConstraints = false
        pathBar.addSubview(pathControl)
        pathBar.clipsToBounds = true

        for v in [sidebarBackground, sidebarSeparator, backButton, forwardButton, upButton, searchField, scopeControl, filterPopup,
                  cleanupButton, lowSpaceButton, topSeparator, scrollView, pathSeparator, pathBar,
                  bottomSeparator, countLabel, statusLabel, progress] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        NSLayoutConstraint.activate([
            backButton.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            backButton.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),
            forwardButton.leadingAnchor.constraint(equalTo: backButton.trailingAnchor, constant: 2),
            forwardButton.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),
            upButton.leadingAnchor.constraint(equalTo: forwardButton.trailingAnchor, constant: 6),
            upButton.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),
            searchField.topAnchor.constraint(equalTo: content.topAnchor, constant: 10),
            searchField.leadingAnchor.constraint(equalTo: upButton.trailingAnchor, constant: 10),
            searchField.trailingAnchor.constraint(equalTo: scopeControl.leadingAnchor, constant: -8),
            scopeControl.trailingAnchor.constraint(equalTo: filterPopup.leadingAnchor, constant: -8),
            scopeControl.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),
            filterPopup.trailingAnchor.constraint(equalTo: cleanupButton.leadingAnchor, constant: -8),
            cleanupButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
            cleanupButton.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),
            filterPopup.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),
            filterPopup.widthAnchor.constraint(equalToConstant: 130),

            topSeparator.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 10),
            topSeparator.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            topSeparator.trailingAnchor.constraint(equalTo: content.trailingAnchor),

            scrollView.topAnchor.constraint(equalTo: topSeparator.bottomAnchor),
            sidebarBackground.topAnchor.constraint(equalTo: topSeparator.bottomAnchor),
            sidebarBackground.bottomAnchor.constraint(equalTo: bottomSeparator.topAnchor),
            sidebarBackground.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            sidebar.scrollView.topAnchor.constraint(equalTo: sidebarBackground.topAnchor, constant: 4),
            sidebar.scrollView.bottomAnchor.constraint(equalTo: sidebarBackground.bottomAnchor),
            sidebar.scrollView.leadingAnchor.constraint(equalTo: sidebarBackground.leadingAnchor),
            sidebar.scrollView.trailingAnchor.constraint(equalTo: sidebarBackground.trailingAnchor),
            sidebarSeparator.topAnchor.constraint(equalTo: topSeparator.bottomAnchor),
            sidebarSeparator.bottomAnchor.constraint(equalTo: bottomSeparator.topAnchor),
            sidebarSeparator.leadingAnchor.constraint(equalTo: sidebarBackground.trailingAnchor),
            sidebarSeparator.widthAnchor.constraint(equalToConstant: 1),
            scrollView.leadingAnchor.constraint(equalTo: sidebarSeparator.trailingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: pathSeparator.topAnchor),

            pathSeparator.leadingAnchor.constraint(equalTo: sidebarSeparator.trailingAnchor),
            pathSeparator.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            pathSeparator.bottomAnchor.constraint(equalTo: pathBar.topAnchor),
            pathBar.leadingAnchor.constraint(equalTo: sidebarSeparator.trailingAnchor),
            pathBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            pathBar.bottomAnchor.constraint(equalTo: bottomSeparator.topAnchor),
            pathControl.leadingAnchor.constraint(equalTo: pathBar.leadingAnchor, constant: 8),
            pathControl.trailingAnchor.constraint(lessThanOrEqualTo: pathBar.trailingAnchor, constant: -8),
            pathControl.centerYAnchor.constraint(equalTo: pathBar.centerYAnchor),

            bottomSeparator.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bottomSeparator.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bottomSeparator.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -24),

            countLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            countLabel.centerYAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
            progress.trailingAnchor.constraint(equalTo: statusLabel.leadingAnchor, constant: -6),
            progress.centerYAnchor.constraint(equalTo: countLabel.centerYAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
            statusLabel.centerYAnchor.constraint(equalTo: countLabel.centerYAnchor),
            lowSpaceButton.leadingAnchor.constraint(equalTo: countLabel.trailingAnchor, constant: 16),
            lowSpaceButton.centerYAnchor.constraint(equalTo: countLabel.centerYAnchor),
            statusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: lowSpaceButton.trailingAnchor, constant: 20),
        ])
        sidebarWidth = sidebarBackground.widthAnchor.constraint(equalToConstant: showSidebar ? 215 : 0)
        sidebarWidth.isActive = true
        sidebarBackground.isHidden = !showSidebar
        sidebarSeparator.isHidden = !showSidebar
        self.sidebarSeparator = sidebarSeparator
        self.topSeparator = topSeparator
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.sidebar.reload() }
        }
        pathBarHeight = pathBar.heightAnchor.constraint(equalToConstant: 24)
        pathBarHeight.isActive = true
        window?.initialFirstResponder = searchField
        placeNewColumnsOnce()
        // Fit all columns (including ones added in newer versions) into the window.
        content.layoutSubtreeIfNeeded()
        tableView.sizeToFit()
    }

    /// Columns added in an update are appended after the user's saved layout; move them next to
    /// "Größe" once, afterwards the user's own arrangement is kept.
    private func placeNewColumnsOnce() {
        let key = "placedColumns.share.v2"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        for (id, after) in [("share", "size")] {
            let from = tableView.column(withIdentifier: .init(id))
            let anchor = tableView.column(withIdentifier: .init(after))
            guard from >= 0, anchor >= 0 else { continue }
            let to = from > anchor ? anchor + 1 : anchor
            if from != to { tableView.moveColumn(from, toColumn: to) }
        }
    }

    private func makeContextMenu() -> NSMenu {
        let m = NSMenu()
        m.add(L("Öffnen"), #selector(openSelection(_:)), target: self)
        m.add(L("Im Finder zeigen"), #selector(revealSelection(_:)), target: self)
        m.add(L("Enthaltenden Ordner anzeigen"), #selector(showEnclosingFolder(_:)), target: self)
        m.add(L("Zur Seitenleiste hinzufügen"), #selector(addToSidebar(_:)), target: self)
        m.addItem(.separator())
        m.add(L("Umbenennen"), #selector(renameSelection(_:)), target: self)
        m.add(L("Neuer Ordner"), #selector(newFolder(_:)), target: self)
        m.add(L("Übersicht (Quick Look)"), #selector(toggleQuickLook(_:)), target: self)
        m.addItem(.separator())
        m.add(L("Kopieren"), #selector(copyFiles(_:)), target: self)
        m.add(L("Vollständigen Pfad kopieren"), #selector(copyPaths(_:)), target: self)
        m.add(L("Namen kopieren"), #selector(copyNames(_:)), target: self)
        m.addItem(.separator())
        m.add(L("Im Terminal öffnen"), #selector(openInTerminal(_:)), target: self)
        m.addItem(.separator())
        m.add(L("In den Papierkorb legen"), #selector(moveSelectionToTrash(_:)), target: self)
        return m
    }

    func showAndFocus() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        focusSearchField(nil)
    }

    /// Hot key behaviour: bring to front, or hide if already frontmost.
    func toggleVisibility() {
        if NSApp.isActive, window?.isKeyWindow == true {
            NSApp.hide(nil)
        } else {
            showAndFocus()
        }
    }

    // MARK: Searching

    private func search(keepSelection: Bool = false, refresh: Bool = false) {
        // Searching or navigating returns from the cleanup assistant to the results.
        if !refresh { hideCleanup() }
        updateMode()
        if isBrowsing {
            loadFolder(keepSelection: keepSelection, refresh: refresh)
            return
        }
        let text = searchField.stringValue
        let opts = options, key = sortKey, asc = ascending
        let within = searchInFolder ? browsePath : nil
        let keep = keepSelection ? Set(tableView.selectedRowIndexes.compactMap { $0 < results.count ? results[$0] : nil }) : []
        searchToken?.cancel()
        let token = CancelToken()
        searchToken = token
        searchSeq += 1
        let seq = searchSeq
        let index = self.index
        searchQueue.async { [weak self] in
            let q = QueryParser.parse(text, options: opts)
            guard let r = SearchEngine.search(index, q, within: within, sort: key, ascending: asc, cancel: token) else { return }
            DispatchQueue.main.async {
                guard let self, seq == self.searchSeq else { return }
                self.apply(r, query: q, keep: keep, newQuery: !keepSelection, refresh: refresh)
            }
        }
    }

    /// Shows the contents of `browsePath` from the index (Finder-like view for an empty search).
    private func loadFolder(keepSelection: Bool, refresh: Bool = false) {
        let path = browsePath, opts = options, key = sortKey, asc = ascending, hidden = showHidden
        let ready = manager.isReady
        let keep = keepSelection ? Set(tableView.selectedRowIndexes.compactMap { $0 < results.count ? results[$0] : nil }) : []
        searchToken?.cancel()
        searchSeq += 1
        let seq = searchSeq
        let index = self.index
        searchQueue.async { [weak self] in
            let q = QueryParser.parse("", options: opts)
            // Taken before the lookup: if the folder is not indexed yet, the empty result must not
            // count as up to date, so the view reloads once the scan has added it.
            let generation = index.stats.generation
            var folder = path
            var r = SearchEngine.contents(of: folder, in: index, query: q, includeHidden: hidden, sort: key, ascending: asc)
            // Folder deleted meanwhile: fall back to the nearest existing parent.
            while r == nil && ready && folder != "/" {
                folder = (folder as NSString).deletingLastPathComponent
                r = SearchEngine.contents(of: folder, in: index, query: q, includeHidden: hidden, sort: key, ascending: asc)
            }
            DispatchQueue.main.async {
                guard let self, seq == self.searchSeq, self.isBrowsing else { return }
                if folder != self.browsePath {
                    self.browsePath = folder
                    self.updateMode()
                }
                let result = r ?? SearchResult(ids: [], seconds: 0, indexedCount: 0, generation: generation)
                self.apply(result, query: q, keep: keep, newQuery: !keepSelection, refresh: refresh)
            }
        }
    }

    private func apply(_ r: SearchResult, query q: Query, keep: Set<Int32>, newQuery: Bool, refresh: Bool = false) {
        // Reference for the "Belegung" bars must be current before any row is drawn.
        if isBrowsing { folderAllocated = index.id(forPath: browsePath).flatMap { index.info($0)?.allocated } ?? 0 }
        // Periodic refresh with the same rows: only redraw visible rows whose data changed.
        if refresh && r.ids == results && pendingSelectName == nil {
            shownGeneration = r.generation
            lastSearchSeconds = r.seconds
            totalSize = r.totalSize
            totalAllocated = r.totalAllocated
            let visible = tableView.rows(in: tableView.visibleRect)
            var changed = IndexSet()
            for row in visible.location..<min(results.count, visible.location + visible.length) {
                let id = results[row]
                let new = index.info(id)
                if let old = infoCache[id], let new, old.size == new.size, old.allocated == new.allocated,
                   old.mtime == new.mtime, old.flags == new.flags, old.name == new.name { continue }
                infoCache[id] = new
                changed.insert(row)
            }
            if !changed.isEmpty {
                tableView.reloadData(forRowIndexes: changed, columnIndexes: IndexSet(0..<tableView.numberOfColumns))
            }
            updateCountLabel()
            return
        }
        results = r.ids
        query = q
        lastSearchSeconds = r.seconds
        totalSize = r.totalSize
        totalAllocated = r.totalAllocated
        shownGeneration = r.generation
        infoCache.removeAll(keepingCapacity: true)
        metaCache.removeAll(keepingCapacity: true)
        tableView.reloadData()
        if let name = pendingSelectName, let row = results.indices.first(where: { info($0)?.name == name }) {
            // Item created/renamed/navigated to: select it (and start renaming a new folder).
            tableView.selectRowIndexes([row], byExtendingSelection: false)
            tableView.scrollRowToVisible(row)
            pendingSelectName = nil
            if pendingRename {
                pendingRename = false
                DispatchQueue.main.async { self.beginRename(row) }
            }
        } else if !keep.isEmpty {
            var rows = IndexSet()
            for (i, id) in results.enumerated() where keep.contains(id) { rows.insert(i) }
            tableView.selectRowIndexes(rows, byExtendingSelection: false)
        } else if newQuery, !results.isEmpty {
            tableView.scrollRowToVisible(0)
        }
        // The index learns about new files a moment later (FSEvents); give up after the deadline.
        if pendingSelectName != nil && Date() > pendingSelectDeadline {
            pendingSelectName = nil
            pendingRename = false
        }
        updateCountLabel()
        tableView.refreshPreview()
    }

    private var lastRefresh = Date.distantPast

    /// macOS changes files all the time; refresh at most every second while QuickFind is in front,
    /// every 10 s in the background, and not at all while the window is hidden or covered.
    private func refreshIfIndexChanged() {
        guard let w = window, w.isVisible, w.occlusionState.contains(.visible), renamingField == nil else { return }
        if !NSApp.isActive && Date().timeIntervalSince(lastRefresh) < 10 { return }
        if index.stats.generation != shownGeneration {
            lastRefresh = Date()
            search(keepSelection: true, refresh: true)
        }
    }

    @objc private func openCleanup(_ sender: Any?) { showCleanup() }

    @objc private func toggleCleanup(_ sender: Any?) {
        if isShowingCleanup {
            hideCleanup()
            focusSearchField(nil)
        } else {
            showCleanup()
        }
    }

    /// Shows the cleanup assistant inside this window, below the search bar.
    func showCleanup() {
        guard let content = window?.contentView, let topSeparator else { return }
        if !isShowingCleanup {
            if cleanup == nil { cleanup = CleanupViewController(manager: manager) }
            guard let v = cleanup?.view else { return }
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
            NSLayoutConstraint.activate([
                v.topAnchor.constraint(equalTo: topSeparator.bottomAnchor),
                v.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                v.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                v.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            ])
            cleanupButton.title = L("Zur Suche")
            cleanupButton.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: L("Zur Suche"))
            cleanupButton.toolTip = L("Aufräum-Assistent schließen und zur Suche zurückkehren")
        }
        cleanup?.didAppear()
    }

    private func hideCleanup() {
        guard isShowingCleanup else { return }
        cleanup?.view.removeFromSuperview()
        cleanupButton.title = L("Aufräumen")
        cleanupButton.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: L("Aufräumen"))
        cleanupButton.toolTip = L("Aufräum-Assistent: Dubletten, große und alte Dateien, Installer, Caches (⌃⌘0)")
    }

    /// Orange hint in the status bar when less than 15 % of the boot volume is free.
    private func updateLowSpaceHint() {
        let v = volumes.info(for: "/")
        let low = v.total > 0 && Double(v.free) / Double(v.total) < 0.15
        lowSpaceButton.isHidden = !low
        if low {
            lowSpaceButton.title = L("⚠︎ Nur noch %@ frei – Aufräumen …", Format.size(v.free))
        }
    }

    private func updateCountLabel() {
        updateLowSpaceHint()
        let n = results.count
        let objects = L(n == 1 ? "%@ Objekt" : "%@ Objekte", Format.count(n))
        if isBrowsing {
            var text = objects
            folderAllocated = 0
            if let folder = index.id(forPath: browsePath).flatMap({ index.info($0) }) {
                folderAllocated = folder.allocated
                let v = volumes.info(for: browsePath)
                text += "  ·  " + L("%@ belegt", Format.size(folder.allocated))
                if v.total > 0 { text += " (" + L("%1$@ von %2$@", Format.percent(Double(folder.allocated) / Double(v.total)), Format.size(v.total)) + ")" }
                if v.free > 0 && lowSpaceButton.isHidden { text += "  ·  " + L("%@ frei", Format.size(v.free)) }
            }
            countLabel.stringValue = text
        } else {
            let time = lastSearchSeconds < 0.001 ? "<1 ms" : String(format: "%.1f ms", lastSearchSeconds * 1000)
            let size = totalSize > 0 ? "  ·  " + L("%@ belegt", Format.size(totalAllocated)) : ""
            countLabel.stringValue = "\(objects)\(size)  ·  \(time)"
        }
    }

    // MARK: Columns

    /// Hidden = chosen by the user, plus "Pfad" in the folder view (all rows share the same path).
    private func applyColumnVisibility() {
        var changed = false
        for c in tableView.tableColumns where c.identifier.rawValue != "name" {
            let id = c.identifier.rawValue
            let hide = hiddenColumns.contains(id) || (id == "path" && isBrowsing)
            if c.isHidden != hide {
                c.isHidden = hide
                changed = true
            }
        }
        if changed { tableView.sizeToFit() }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === headerMenu else { return }
        menu.removeAllItems()
        let title = NSMenuItem(title: L("Spalten"), action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        for c in tableView.tableColumns where c.identifier.rawValue != "name" {
            let id = c.identifier.rawValue
            let item = menu.add(c.title + (id == "path" && isBrowsing ? " " + L("(nur bei der Suche)") : ""),
                                #selector(toggleColumn(_:)), target: self)
            item.representedObject = id
            item.state = hiddenColumns.contains(id) ? .off : .on
        }
    }

    @objc private func toggleColumn(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        if hiddenColumns.contains(id) { hiddenColumns.remove(id) } else { hiddenColumns.insert(id) }
        Prefs.hiddenColumns = hiddenColumns
        applyColumnVisibility()
    }

    /// "Zuletzt geöffnet" and Finder tags, fetched for visible rows only and cached per search.
    private func meta(_ info: EntryInfo) -> EntryMeta {
        if let m = metaCache[info.id] { return m }
        var m = EntryMeta(lastUsed: nil, tags: [])
        if let item = MDItemCreate(kCFAllocatorDefault, info.path as CFString),
           let date = MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date {
            m.lastUsed = Int64(date.timeIntervalSince1970)
        }
        m.tags = (try? URL(fileURLWithPath: info.path).resourceValues(forKeys: [.tagNamesKey]))?.tagNames ?? []
        metaCache[info.id] = m
        return m
    }

    // MARK: Folder navigation

    /// Switches path bar, path column, title and buttons between folder view and search.
    private func updateMode() {
        let browsing = isBrowsing
        pathBarHeight.constant = browsing ? 24 : 0
        pathControl.isHidden = !browsing
        applyColumnVisibility()
        pathControl.url = URL(fileURLWithPath: browsePath)
        window?.title = browsing ? FileManager.default.displayName(atPath: browsePath) : "QuickFind"
        window?.subtitle = browsing ? "QuickFind" : L("Suche")
        backButton.isEnabled = !backStack.isEmpty
        forwardButton.isEnabled = !forwardStack.isEmpty
        upButton.isEnabled = !browsing || browsePath != "/"
        tableView.tableColumn(withIdentifier: .init("share"))?.headerToolTip = browsing
            ? L("Anteil am belegten Speicher dieses Ordners")
            : L("Anteil am Gesamtspeicher der Festplatte")
        sidebar.highlight(browsing ? browsePath : nil)
        updatePlaceholder()
    }

    @objc func toggleSidebar(_ sender: Any?) {
        showSidebar.toggle()
        Prefs.showSidebar = showSidebar
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            sidebarWidth.animator().constant = showSidebar ? 215 : 0
        }
        sidebarBackground.isHidden = !showSidebar
        sidebarSeparator?.isHidden = !showSidebar
    }

    @objc func addToSidebar(_ sender: Any?) {
        guard let row = targetRows.first, let i = info(row), isBrowsable(i) else { return }
        sidebar.addFavorite(i.path)
        if !showSidebar { toggleSidebar(nil) }
    }

    @objc private func scopeChanged(_ sender: NSSegmentedControl) {
        searchInFolder = sender.selectedSegment == 1
        Prefs.searchInFolder = searchInFolder
        updatePlaceholder()
        if !isBrowsing { search() }
        window?.makeFirstResponder(searchField)
    }

    @objc func searchEverywhere(_ sender: Any?) {
        scopeControl.selectedSegment = 0
        scopeChanged(scopeControl)
    }

    @objc func searchInCurrentFolder(_ sender: Any?) {
        scopeControl.selectedSegment = 1
        scopeChanged(scopeControl)
    }

    private var currentLocation: Location {
        Location(folder: browsePath, search: isBrowsing ? "" : searchField.stringValue)
    }

    private func go(to location: Location, select: String? = nil) {
        browsePath = location.folder
        searchField.stringValue = location.search
        pendingSelectName = select
        search()
        if isBrowsing { window?.makeFirstResponder(tableView) }
    }

    /// Opens a folder inside QuickFind and records the current place for "Zurück".
    func navigate(to folder: String, select: String? = nil) {
        let target = Location(folder: folder, search: "")
        guard target != currentLocation else { return }
        backStack.append(currentLocation)
        forwardStack.removeAll()
        go(to: target, select: select)
    }

    @objc func goBack(_ sender: Any?) {
        guard let loc = backStack.popLast() else { return }
        forwardStack.append(currentLocation)
        go(to: loc)
    }

    @objc func goForward(_ sender: Any?) {
        guard let loc = forwardStack.popLast() else { return }
        backStack.append(currentLocation)
        go(to: loc)
    }

    @objc func goUp(_ sender: Any?) {
        if !isBrowsing {
            navigate(to: browsePath)
            return
        }
        guard browsePath != "/" else { return }
        navigate(to: (browsePath as NSString).deletingLastPathComponent, select: (browsePath as NSString).lastPathComponent)
    }

    @objc func goToPlace(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        navigate(to: path)
    }

    @objc func toggleHiddenFiles(_ sender: Any?) {
        showHidden.toggle()
        search(keepSelection: true)
    }

    @objc private func pathControlClicked(_ sender: NSPathControl) {
        guard let url = sender.clickedPathItem?.url else { return }
        navigate(to: url.path)
    }

    /// Folders open inside QuickFind; packages such as apps are treated as files (like the Finder).
    private func isBrowsable(_ info: EntryInfo) -> Bool {
        info.isDirectory && !Packages.isPackage(info)
    }

    @objc func showEnclosingFolder(_ sender: Any?) {
        guard let row = targetRows.first, let i = info(row) else { return }
        navigate(to: i.parentPath, select: i.name)
    }

    func indexStatusChanged(_ s: IndexManager.Status) {
        switch s.phase {
        case .starting, .loading:
            statusLabel.stringValue = L("Lade Index …")
            progress.startAnimation(nil)
        case .scanning:
            statusLabel.stringValue = L("Indiziere … %@ Objekte", Format.count(s.count))
            progress.startAnimation(nil)
        case .ready:
            statusLabel.stringValue = L("%@ Objekte im Index", Format.count(s.count))
            progress.stopAnimation(nil)
        }
        refreshIfIndexChanged()
    }

    private func updatePlaceholder() {
        var flags: [String] = []
        if options.matchCase { flags.append(L("Groß/klein")) }
        if options.matchWholeWord { flags.append(L("Ganze Wörter")) }
        if options.matchPath { flags.append(L("Pfad")) }
        if options.regex { flags.append("Regex") }
        if options.filter != .all { flags.append(options.filter.title) }
        let base = searchInFolder ? L("In „%@“ suchen", FileManager.default.displayName(atPath: browsePath)) : L("Suchen")
        searchField.placeholderString = flags.isEmpty ? base : "\(base) (\(flags.joined(separator: ", ")))"
    }

    private func optionsChanged() {
        Prefs.searchOptions = options
        filterPopup.selectItem(at: options.filter.rawValue)
        updatePlaceholder()
        search()
    }

    func controlTextDidChange(_ obj: Notification) {
        if obj.object as? NSSearchField === searchField { search() }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let tf = obj.object as? NSTextField, tf === renamingField else { return }
        finishRename(tf)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if control === renamingField {
            if sel == #selector(NSResponder.cancelOperation(_:)) {
                renameCancelled = true
                window?.makeFirstResponder(tableView)
                return true
            }
            return false
        }
        if sel == #selector(NSResponder.moveDown(_:)) || sel == #selector(NSResponder.insertNewline(_:)) {
            focusResults()
            return true
        }
        return false
    }

    private func focusResults() {
        guard !results.isEmpty else { return }
        if tableView.selectedRow < 0 { tableView.selectRowIndexes([0], byExtendingSelection: false) }
        window?.makeFirstResponder(tableView)
        tableView.scrollRowToVisible(tableView.selectedRow)
    }

    // MARK: Table data

    private func info(_ row: Int) -> EntryInfo? {
        guard row >= 0, row < results.count else { return nil }
        let id = results[row]
        if let i = infoCache[id] { return i }
        guard let i = index.info(id) else { return nil }
        if infoCache.count > 4000 { infoCache.removeAll(keepingCapacity: true) }
        infoCache[id] = i
        return i
    }

    func numberOfRows(in tableView: NSTableView) -> Int { results.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let col = tableColumn, let info = info(row) else { return nil }
        let cell = cellView(col.identifier)
        switch col.identifier.rawValue {
        case "name":
            cell.imageView?.image = icons.icon(for: info)
            // Folder view shows the Finder's localised names ("Dienstprogramme"); search shows real names.
            let name = isBrowsing ? FileManager.default.displayName(atPath: info.path) : info.name
            cell.textField?.attributedStringValue = highlighted(name)
        case "path":
            cell.textField?.stringValue = info.parentPath
        case "size":
            // Folders: space actually used (a logical sum would be inflated by sparse files such as
            // Docker.raw and by cloud files that are online only). Files: size as in the Finder.
            // Symlinks and unindexed mount points have no meaningful size of their own.
            if info.isSymlink || (info.isDirectory && info.flags & EntryFlag.mountPoint != 0) {
                cell.textField?.stringValue = ""
            } else {
                cell.textField?.stringValue = Format.size(info.isDirectory ? info.allocated : info.size)
            }
        case "type":
            var name = typeNames.name(for: info)
            if info.isOnlineOnly { name += " · " + L("nur online") }
            cell.textField?.stringValue = name
        case "created":
            cell.textField?.stringValue = Format.date(info.created)
        case "lastUsed":
            cell.textField?.stringValue = meta(info).lastUsed.map(Format.date) ?? ""
        case "tags":
            cell.textField?.stringValue = meta(info).tags.joined(separator: ", ")
        case "share":
            // Folder view: share of the shown folder. Search: share of the whole volume's capacity.
            let total = isBrowsing ? folderAllocated : volumes.info(for: info.path).total
            let share = total > 0 && !info.isSymlink ? min(1, Double(info.allocated) / Double(total)) : -1
            (cell as? ShareCellView)?.show(share)
        case "date":
            cell.textField?.stringValue = Format.date(info.mtime)
        default:
            break
        }
        return cell
    }

    private func cellView(_ id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        if let c = tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView { return c }
        if id.rawValue == "share" {
            let c = ShareCellView()
            c.identifier = id
            return c
        }
        let c = NSTableCellView()
        c.identifier = id
        let tf = NSTextField(labelWithString: "")
        tf.font = regularFont
        tf.lineBreakMode = id.rawValue == "path" ? .byTruncatingMiddle : .byTruncatingTail
        tf.maximumNumberOfLines = 1
        tf.usesSingleLineMode = true
        tf.cell?.wraps = false
        tf.translatesAutoresizingMaskIntoConstraints = false
        tf.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        if id.rawValue == "size" { tf.alignment = .right }
        c.addSubview(tf)
        c.textField = tf
        var leading = c.leadingAnchor
        if id.rawValue == "name" {
            let iv = NSImageView()
            iv.imageScaling = .scaleProportionallyDown
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

    /// Bold match highlighting like Everything.
    private func highlighted(_ name: String) -> NSAttributedString {
        let s = NSMutableAttributedString(string: name, attributes: [.font: regularFont, .paragraphStyle: truncating])
        guard let terms = query?.highlights, !terms.isEmpty else { return s }
        let ns = name as NSString
        let opts: NSString.CompareOptions = options.matchCase ? [] : [.caseInsensitive]
        for t in terms where !t.isEmpty {
            var from = 0
            while from < ns.length {
                let f = ns.range(of: t, options: opts, range: NSRange(location: from, length: ns.length - from))
                if f.location == NSNotFound { break }
                s.addAttribute(.font, value: boldFont, range: f)
                from = f.location + max(1, f.length)
            }
        }
        return s
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let sd = tableView.sortDescriptors.first, let k = sd.key, let key = SortKey(rawValue: k) else { return }
        sortKey = key
        ascending = sd.ascending
        Prefs.sortKey = key
        Prefs.sortAscending = sd.ascending
        search(keepSelection: true)
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard let i = info(row) else { return nil }
        return URL(fileURLWithPath: i.path) as NSURL
    }

    func tableViewSelectionDidChange(_ notification: Notification) { tableView.refreshPreview() }

    // MARK: Editing (rename, new folder, paste, drag & drop)

    @objc func renameSelection(_ sender: Any?) {
        guard targetRows.count == 1, let row = targetRows.first else { return }
        beginRename(row)
    }

    /// Turns the name cell into an editable field; the base name is preselected (like the Finder).
    private func beginRename(_ row: Int) {
        guard let i = info(row), let col = tableView.tableColumns.firstIndex(where: { $0.identifier.rawValue == "name" })
        else { return }
        tableView.selectRowIndexes([row], byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
        guard let cell = tableView.view(atColumn: col, row: row, makeIfNecessary: true) as? NSTableCellView,
              let tf = cell.textField else { return }
        renameCancelled = false
        renamingField = tf
        renamingPath = i.path
        tf.stringValue = i.name
        tf.isEditable = true
        tf.isSelectable = true
        tf.delegate = self
        window?.makeFirstResponder(tf)
        let base = i.isDirectory && !Packages.isPackage(i) ? i.name : (i.name as NSString).deletingPathExtension
        tf.currentEditor()?.selectedRange = NSRange(location: 0, length: (base as NSString).length)
    }

    private func finishRename(_ tf: NSTextField) {
        let path = renamingPath
        renamingField = nil
        renamingPath = nil
        tf.isEditable = false
        tf.isSelectable = false
        let newName = tf.stringValue.trimmingCharacters(in: .whitespaces)
        if let path, !renameCancelled, newName != (path as NSString).lastPathComponent {
            do {
                let target = try FileOperations.rename(path, to: newName)
                selectSoon((target as NSString).lastPathComponent)
            } catch {
                NSAlert(error: error).beginSheetModal(for: window!)
            }
        }
        infoCache.removeAll(keepingCapacity: true)
        let row = tableView.selectedRow
        if row >= 0 { tableView.reloadData(forRowIndexes: [row], columnIndexes: IndexSet(0..<tableView.numberOfColumns)) }
        window?.makeFirstResponder(tableView)
    }

    /// Selects `name` as soon as the index has picked it up (FSEvents arrive a moment later).
    private func selectSoon(_ name: String, rename: Bool = false) {
        pendingSelectName = name
        pendingSelectDeadline = Date().addingTimeInterval(5)
        pendingRename = rename
    }

    @objc func newFolder(_ sender: Any?) {
        guard isBrowsing else { return }
        do {
            selectSoon(try FileOperations.newFolder(in: browsePath), rename: true)
        } catch {
            NSAlert(error: error).beginSheetModal(for: window!)
        }
    }

    @objc func pasteFiles(_ sender: Any?) { transferFromPasteboard(move: false) }
    @objc func moveFilesHere(_ sender: Any?) { transferFromPasteboard(move: true) }

    private func transferFromPasteboard(move: Bool) {
        let urls = FileOperations.fileURLs(from: .general)
        guard isBrowsing, !urls.isEmpty else { return }
        FileOperations.transfer(urls, to: browsePath, move: move) { [weak self] errors in
            FileOperations.showErrors(errors, title: move ? L("Bewegen nicht möglich") : L("Einsetzen nicht möglich"), in: self?.window)
            if let first = urls.first { self?.selectSoon(first.lastPathComponent) }
        }
    }

    /// Drop target: a folder row, or (in the folder view) the shown folder itself.
    private func dropFolder(row: Int, operation: NSTableView.DropOperation) -> String? {
        if operation == .on, let i = info(row), isBrowsable(i) { return i.path }
        return isBrowsing ? browsePath : nil
    }

    private func dragOperation(_ info: NSDraggingInfo, to folder: String) -> NSDragOperation {
        let urls = FileOperations.fileURLs(from: info.draggingPasteboard)
        guard !urls.isEmpty, !urls.contains(where: { $0.path == folder || folder.hasPrefix($0.path + "/") }) else { return [] }
        let mask = info.draggingSourceOperationMask
        if mask.contains(.move) && FileOperations.shouldMove(urls, to: folder) && mask != .copy { return .move }
        return mask.contains(.copy) ? .copy : []
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation op: NSTableView.DropOperation) -> NSDragOperation {
        guard let folder = dropFolder(row: row, operation: op) else { return [] }
        if folder == browsePath && isBrowsing && !(op == .on && self.info(row).map(isBrowsable) == true) {
            tableView.setDropRow(-1, dropOperation: .on)   // highlight the whole list = current folder
        }
        return dragOperation(info, to: folder)
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                   dropOperation op: NSTableView.DropOperation) -> Bool {
        guard let folder = row < 0 ? (isBrowsing ? browsePath : nil) : dropFolder(row: row, operation: op) else { return false }
        let operation = dragOperation(info, to: folder)
        guard !operation.isEmpty else { return false }
        let urls = FileOperations.fileURLs(from: info.draggingPasteboard)
        let move = operation == .move
        FileOperations.transfer(urls, to: folder, move: move) { [weak self] errors in
            FileOperations.showErrors(errors, title: move ? L("Bewegen nicht möglich") : L("Kopieren nicht möglich"), in: self?.window)
        }
        return true
    }

    // MARK: Disk space

    private func setSort(_ key: SortKey, ascending asc: Bool) {
        sortKey = key
        ascending = asc
        Prefs.sortKey = key
        Prefs.sortAscending = asc
        tableView.sortDescriptors = [NSSortDescriptor(key: key.rawValue, ascending: asc)]
    }

    /// Shows an analysis as a normal search (in the current folder if "Dieser Ordner" is active).
    private func runAnalysis(_ query: String) {
        if currentLocation != Location(folder: browsePath, search: query) {
            backStack.append(currentLocation)
            forwardStack.removeAll()
        }
        searchField.stringValue = query
        setSort(.allocated, ascending: false)
        search()
        window?.makeFirstResponder(tableView)
    }

    @objc func showLargestFiles(_ sender: Any?) { runAnalysis("file: size:>100mb") }
    @objc func showDuplicates(_ sender: Any?) { runAnalysis("dupe: size:>1mb") }

    @objc func showOldLargeFiles(_ sender: Any?) {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        let yearAgo = Calendar.current.date(byAdding: .year, value: -1, to: Date()) ?? Date()
        runAnalysis("file: size:>50mb dm:<\(f.string(from: yearAgo))")
    }

    @objc func showFolderBySize(_ sender: Any?) {
        if !isBrowsing { navigate(to: browsePath) }
        setSort(.allocated, ascending: false)
    }

    // MARK: Actions

    private var targetRows: IndexSet {
        let clicked = tableView.clickedRow
        if clicked >= 0 && !tableView.selectedRowIndexes.contains(clicked) { return [clicked] }
        return tableView.selectedRowIndexes
    }

    private var targetPaths: [String] { targetRows.compactMap { info($0)?.path } }
    private var targetURLs: [URL] { targetPaths.map { URL(fileURLWithPath: $0) } }

    func previewURLs() -> [URL] { tableView.selectedRowIndexes.compactMap { info($0) }.map { URL(fileURLWithPath: $0.path) } }

    @objc private func tableDoubleClicked(_ sender: Any?) {
        guard tableView.clickedRow >= 0 else { return }
        openSelection(sender)
    }

    @objc func openSelection(_ sender: Any?) {
        let rows = targetRows
        if rows.count == 1, let i = info(rows.first!), isBrowsable(i) {
            navigate(to: i.path)
            return
        }
        for url in targetURLs.prefix(50) { NSWorkspace.shared.open(url) }
    }

    @objc func revealSelection(_ sender: Any?) {
        let urls = targetURLs
        if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }

    @objc func toggleQuickLook(_ sender: Any?) {
        guard let panel = QLPreviewPanel.shared() else { return }
        if QLPreviewPanel.sharedPreviewPanelExists() && panel.isVisible {
            panel.orderOut(nil)
        } else if !tableView.selectedRowIndexes.isEmpty {
            window?.makeFirstResponder(tableView)
            panel.makeKeyAndOrderFront(nil)
        }
    }

    @objc func copyFiles(_ sender: Any?) {
        let urls = targetURLs
        guard !urls.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(urls as [NSURL])
    }

    @objc func copyPaths(_ sender: Any?) {
        let paths = targetPaths
        guard !paths.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
    }

    @objc func copyNames(_ sender: Any?) {
        let names = targetRows.compactMap { info($0)?.name }
        guard !names.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(names.joined(separator: "\n"), forType: .string)
    }

    @objc func openInTerminal(_ sender: Any?) {
        guard let row = targetRows.first, let i = info(row) else { return }
        let dir = URL(fileURLWithPath: i.isDirectory ? i.path : i.parentPath)
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return }
        NSWorkspace.shared.open([dir], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }

    @objc func moveSelectionToTrash(_ sender: Any?) {
        let urls = targetURLs
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.recycle(urls) { _, error in
            if let error { DispatchQueue.main.async { NSAlert(error: error).runModal() } }
        }
    }

    @objc func focusSearchField(_ sender: Any?) {
        window?.makeFirstResponder(searchField)
        searchField.selectText(nil)
    }

    func typeIntoSearchField(_ text: String) {
        window?.makeFirstResponder(searchField)
        guard let editor = searchField.currentEditor() else { return }
        editor.selectedRange = NSRange(location: (searchField.stringValue as NSString).length, length: 0)
        editor.insertText(text)
    }

    @objc func toggleMatchCase(_ sender: Any?) { options.matchCase.toggle(); optionsChanged() }
    @objc func toggleWholeWord(_ sender: Any?) { options.matchWholeWord.toggle(); optionsChanged() }
    @objc func toggleMatchPath(_ sender: Any?) { options.matchPath.toggle(); optionsChanged() }
    @objc func toggleRegex(_ sender: Any?) { options.regex.toggle(); optionsChanged() }

    @objc func selectFilter(_ sender: NSMenuItem) {
        options.filter = FileFilter(rawValue: sender.tag) ?? .all
        optionsChanged()
    }

    @objc private func filterPopupChanged(_ sender: NSPopUpButton) {
        options.filter = FileFilter(rawValue: sender.indexOfSelectedItem) ?? .all
        optionsChanged()
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(toggleMatchCase(_:)): item.state = options.matchCase ? .on : .off
        case #selector(toggleWholeWord(_:)): item.state = options.matchWholeWord ? .on : .off
        case #selector(toggleMatchPath(_:)): item.state = options.matchPath ? .on : .off
        case #selector(toggleRegex(_:)): item.state = options.regex ? .on : .off
        case #selector(selectFilter(_:)): item.state = options.filter.rawValue == item.tag ? .on : .off
        case #selector(goBack(_:)): return !backStack.isEmpty
        case #selector(goForward(_:)): return !forwardStack.isEmpty
        case #selector(goUp(_:)): return !isBrowsing || browsePath != "/"
        case #selector(toggleHiddenFiles(_:)): item.state = showHidden ? .on : .off
        case #selector(showEnclosingFolder(_:)), #selector(renameSelection(_:)): return targetRows.count == 1
        case #selector(newFolder(_:)): return isBrowsing
        case #selector(toggleSidebar(_:)): item.title = showSidebar ? L("Seitenleiste ausblenden") : L("Seitenleiste einblenden")
        case #selector(addToSidebar(_:)):
            return targetRows.count == 1 && targetRows.first.flatMap { info($0) }.map(isBrowsable) == true
        case #selector(pasteFiles(_:)), #selector(moveFilesHere(_:)):
            return isBrowsing && !FileOperations.fileURLs(from: .general).isEmpty
        case #selector(searchEverywhere(_:)): item.state = searchInFolder ? .off : .on
        case #selector(searchInCurrentFolder(_:)): item.state = searchInFolder ? .on : .off
        case #selector(openSelection(_:)), #selector(revealSelection(_:)), #selector(copyFiles(_:)),
             #selector(copyPaths(_:)), #selector(copyNames(_:)), #selector(moveSelectionToTrash(_:)),
             #selector(openInTerminal(_:)), #selector(toggleQuickLook(_:)):
            return !targetRows.isEmpty
        default: break
        }
        return true
    }
}

/// "Anteil" column: share of the current folder (or of all results) as a bar plus percentage.
final class ShareCellView: NSTableCellView {
    private let bar = NSLevelIndicator()
    private let label = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        bar.levelIndicatorStyle = .continuousCapacity
        bar.minValue = 0
        bar.maxValue = 100
        bar.controlSize = .small
        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        label.textColor = .secondaryLabelColor
        label.alignment = .right
        for v in [bar, label] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            bar.centerYAnchor.constraint(equalTo: centerYAnchor),
            bar.heightAnchor.constraint(equalToConstant: 8),
            label.leadingAnchor.constraint(equalTo: bar.trailingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.widthAnchor.constraint(equalToConstant: 48),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// `share` in 0…1, or negative to show nothing.
    func show(_ share: Double) {
        bar.isHidden = share < 0
        bar.doubleValue = max(0, share) * 100
        label.stringValue = share < 0 ? "" : Format.percent(share)
    }
}
