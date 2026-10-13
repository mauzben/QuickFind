import AppKit
import Carbon.HIToolbox
import QuickFindCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Developer overrides: QF_ROOTS=/a:/b indexes only these folders, QF_STORE=file uses another index file.
    private static let env = ProcessInfo.processInfo.environment
    private static let devRoots = env["QF_ROOTS"].map { $0.split(separator: ":").map(String.init) }

    private let manager: IndexManager = {
        var c = Prefs.configuration
        if let r = devRoots { c.customRoots = r }
        let store = env["QF_STORE"].map { URL(fileURLWithPath: $0) } ?? IndexManager.defaultStoreURL
        return IndexManager(configuration: c, storeURL: store)
    }()
    private var mainWindow: MainWindowController!
    private var settingsWindow: SettingsWindowController?
    private var helpWindow: HelpWindowController?
    private var statusItem: NSStatusItem?
    private let hotKey = HotKey()
    private var launchedAtLogin = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(Prefs.showDockIcon ? .regular : .accessory)
        // A login-item launch carries keyAELaunchedAsLogInItem in its open-application event.
        if let event = NSAppleEventManager.shared().currentAppleEvent, event.eventID == AEEventID(kAEOpenApplication) {
            launchedAtLogin = event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue
                == OSType(keyAELaunchedAsLogInItem)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMainMenu()
        mainWindow = MainWindowController(manager: manager)
        var lastPhase = IndexManager.Phase.starting
        manager.onStatus = { [weak self] status in
            self?.mainWindow.indexStatusChanged(status)
            if lastPhase == .scanning && status.phase == .ready && self?.manager.isReady == true {
                Prefs.indexedWithFullDiskAccess = Permissions.hasFullDiskAccess
                Prefs.indexVersion = Prefs.currentIndexVersion
            }
            lastPhase = status.phase
        }
        manager.log = { NSLog("QuickFind: %@", $0) }
        setupStatusItem()
        if Prefs.hotKeyEnabled && !registerHotKey() {
            NSLog("QuickFind: Kurzbefehl %@ ist bereits belegt", Prefs.hotKey.display)
        }

        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.manager.volumesDidChange() }
        }

        // Started at login: stay quietly in the menu bar and keep the index current.
        if !launchedAtLogin { mainWindow.showAndFocus() }
        if Self.env["QF_SHOW_SETTINGS"] != nil { showSettings() }
        if Self.env["QF_SHOW_CLEANUP"] != nil { showCleanup() }
        let firstRun = !FileManager.default.fileExists(atPath: manager.storeURL.path)
        if firstRun && Self.devRoots == nil && !Permissions.hasFullDiskAccess {
            DispatchQueue.main.async { [self] in
                runOnboarding()
                manager.start()
            }
        } else {
            // Access granted since the last full scan: protected folders were skipped, so rescan once.
            let accessGranted = Permissions.hasFullDiskAccess && !Prefs.indexedWithFullDiskAccess
            let outdated = Prefs.indexVersion < Prefs.currentIndexVersion
            let rescan = !firstRun && Self.devRoots == nil && (accessGranted || outdated)
            if rescan { NSLog("QuickFind: Index wird neu aufgebaut (Vollzugriff neu: %d, veraltet: %d)", accessGranted, outdated) }
            manager.start(rescan: rescan)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        mainWindow.showAndFocus()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        manager.save()
    }

    // MARK: Onboarding

    /// Asks for Full Disk Access before the first scan, so macOS does not prompt per folder.
    private func runOnboarding() {
        while !Permissions.hasFullDiskAccess {
            let a = NSAlert()
            a.messageText = L("Festplattenvollzugriff erteilen")
            a.informativeText = L("Damit QuickFind wie „Everything“ wirklich alle Dateien findet, benötigt es den Festplattenvollzugriff.\n\n1. Auf „Systemeinstellungen öffnen“ klicken.\n2. QuickFind in der Liste einschalten (fehlt es, mit „+“ hinzufügen).\n3. Zurückkehren und „Prüfen & indizieren“ wählen. Meldet macOS, dass QuickFind neu gestartet werden muss, einfach neu öffnen.\n\nOhne Vollzugriff werden geschützte Ordner übersprungen und macOS fragt ggf. pro Ordner nach.")
            a.addButton(withTitle: L("Prüfen & indizieren"))
            a.addButton(withTitle: L("Systemeinstellungen öffnen"))
            a.addButton(withTitle: L("Ohne Vollzugriff fortfahren"))
            switch a.runModal() {
            case .alertFirstButtonReturn: continue
            case .alertSecondButtonReturn: Permissions.openFullDiskAccessSettings()
            default: return
            }
        }
    }

    // MARK: Hot key / status item

    /// (Re-)registers the global shortcut from the preferences. Returns false if macOS refuses it.
    @discardableResult
    private func registerHotKey() -> Bool {
        guard Prefs.hotKeyEnabled else {
            hotKey.unregister()
            return true
        }
        return hotKey.register(Prefs.hotKey) { [weak self] in self?.mainWindow.toggleVisibility() }
    }

    private func setDockIcon(_ visible: Bool) {
        Prefs.showDockIcon = visible
        NSApp.setActivationPolicy(visible ? .regular : .accessory)
        // Changing the policy deactivates the app; bring the settings back to the front.
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            self.settingsWindow?.window?.makeKeyAndOrderFront(nil)
        }
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "QuickFind")
        let m = NSMenu()
        m.add(L("QuickFind öffnen"), #selector(showMainWindow), target: self)
        m.add(L("Aufräumen …"), #selector(showCleanup), target: self)
        m.add(L("Index neu aufbauen"), #selector(rebuildIndex), target: self)
        m.addItem(.separator())
        m.add(L("Einstellungen …"), #selector(showSettings), target: self)
        m.add(L("QuickFind beenden"), #selector(NSApplication.terminate(_:)))
        item.menu = m
        statusItem = item
    }

    @objc private func showMainWindow() { mainWindow.showAndFocus() }

    @objc private func rebuildIndex() { manager.rebuild() }

    @objc private func saveIndex() { DispatchQueue.global().async { [manager] in manager.save() } }

    @objc private func showSettings() {
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController(
                manager: manager,
                applyHotKey: { [weak self] in self?.registerHotKey() ?? false },
                applyDockIcon: { [weak self] in self?.setDockIcon($0) })
        }
        settingsWindow?.showWindow(nil)
    }

    @objc private func showCleanup() {
        mainWindow.showAndFocus()
        mainWindow.showCleanup()
    }

    @objc private func showHelp() {
        if helpWindow == nil { helpWindow = HelpWindowController() }
        helpWindow?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: Menu

    private func buildMainMenu() {
        let main = NSMenu()
        func submenu(_ title: String) -> NSMenu {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let m = NSMenu(title: title)
            item.submenu = m
            main.addItem(item)
            return m
        }

        let app = submenu("QuickFind")
        app.add(L("Über QuickFind"), #selector(NSApplication.orderFrontStandardAboutPanel(_:)))
        app.addItem(.separator())
        app.add(L("Einstellungen …"), #selector(showSettings), ",", target: self)
        app.addItem(.separator())
        app.add(L("QuickFind ausblenden"), #selector(NSApplication.hide(_:)), "h")
        app.add(L("Andere ausblenden"), #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option])
        app.add(L("Alle einblenden"), #selector(NSApplication.unhideAllApplications(_:)))
        app.addItem(.separator())
        app.add(L("QuickFind beenden"), #selector(NSApplication.terminate(_:)), "q")

        let file = submenu(L("Ablage"))
        file.add(L("Neuer Ordner"), #selector(MainWindowController.newFolder(_:)), "n", [.command, .shift])
        file.add(L("Öffnen"), #selector(MainWindowController.openSelection(_:)), "o")
        file.add(L("Umbenennen"), #selector(MainWindowController.renameSelection(_:)),
                 String(Character(UnicodeScalar(NSF2FunctionKey)!)), [])
        file.add(L("Im Finder zeigen"), #selector(MainWindowController.revealSelection(_:)), "\r")
        file.add(L("Übersicht (Quick Look)"), #selector(MainWindowController.toggleQuickLook(_:)), "y")
        file.add(L("Im Terminal öffnen"), #selector(MainWindowController.openInTerminal(_:)))
        file.addItem(.separator())
        file.add(L("In den Papierkorb legen"), #selector(MainWindowController.moveSelectionToTrash(_:)), "\u{8}")
        file.addItem(.separator())
        file.add(L("Fenster schließen"), #selector(NSWindow.performClose(_:)), "w")

        let edit = submenu(L("Bearbeiten"))
        edit.add(L("Widerrufen"), Selector(("undo:")), "z")
        edit.add(L("Wiederholen"), Selector(("redo:")), "z", [.command, .shift])
        edit.addItem(.separator())
        edit.add(L("Ausschneiden"), #selector(NSText.cut(_:)), "x")
        edit.add(L("Kopieren"), #selector(NSText.copy(_:)), "c")
        edit.add(L("Einsetzen"), #selector(NSText.paste(_:)), "v")
        edit.add(L("Objekt hierher bewegen"), #selector(MainWindowController.moveFilesHere(_:)), "v", [.command, .option])
        edit.add(L("Alles auswählen"), #selector(NSText.selectAll(_:)), "a")
        edit.addItem(.separator())
        edit.add(L("Vollständigen Pfad kopieren"), #selector(MainWindowController.copyPaths(_:)), "c", [.command, .option])
        edit.add(L("Namen kopieren"), #selector(MainWindowController.copyNames(_:)))
        edit.addItem(.separator())
        edit.add(L("Suchen"), #selector(MainWindowController.focusSearchField(_:)), "f")

        let search = submenu(L("Suche"))
        search.add(L("Groß-/Kleinschreibung beachten"), #selector(MainWindowController.toggleMatchCase(_:)), "i", [.command, .option])
        search.add(L("Nur ganze Wörter"), #selector(MainWindowController.toggleWholeWord(_:)), "b", [.command, .option])
        search.add(L("Pfad durchsuchen"), #selector(MainWindowController.toggleMatchPath(_:)), "u", [.command, .option])
        search.add(L("Reguläre Ausdrücke"), #selector(MainWindowController.toggleRegex(_:)), "r", [.command, .option])
        search.addItem(.separator())
        search.add(L("Überall suchen"), #selector(MainWindowController.searchEverywhere(_:)), "e", [.command, .option])
        search.add(L("Nur in diesem Ordner suchen"), #selector(MainWindowController.searchInCurrentFolder(_:)), "f", [.command, .option])
        search.addItem(.separator())
        for f in FileFilter.allCases {
            search.add(f.title, #selector(MainWindowController.selectFilter(_:)), "\(f.rawValue + 1)", tag: f.rawValue)
        }

        let go = submenu(L("Gehe zu"))
        let up = String(Character(UnicodeScalar(NSUpArrowFunctionKey)!))
        go.add(L("Zurück"), #selector(MainWindowController.goBack(_:)), "[")
        go.add(L("Vorwärts"), #selector(MainWindowController.goForward(_:)), "]")
        go.add(L("Übergeordneter Ordner"), #selector(MainWindowController.goUp(_:)), up)
        go.addItem(.separator())
        let home = NSHomeDirectory()
        for (title, path, key, mods) in [("Benutzerordner", home, "h", NSEvent.ModifierFlags([.command, .shift])),
                                         ("Schreibtisch", home + "/Desktop", "d", [.command, .shift]),
                                         ("Dokumente", home + "/Documents", "o", [.command, .shift]),
                                         ("Downloads", home + "/Downloads", "l", [.command, .option]),
                                         ("Programme", "/Applications", "a", [.command, .shift]),
                                         ("Festplatte", "/", "c", [.command, .shift])] {
            let item = go.add(L(title), #selector(MainWindowController.goToPlace(_:)), key, mods)
            item.representedObject = path
        }
        go.addItem(.separator())
        go.add(L("Versteckte Dateien einblenden"), #selector(MainWindowController.toggleHiddenFiles(_:)), ".", [.command, .shift])
        go.add(L("Seitenleiste ausblenden"), #selector(MainWindowController.toggleSidebar(_:)), "s", [.command, .option])

        let space = submenu(L("Speicherplatz"))
        space.add(L("Aufräumen …"), #selector(showCleanup), "0", [.command, .control], target: self)
        space.addItem(.separator())
        space.add(L("Ordnerinhalt nach Größe"), #selector(MainWindowController.showFolderBySize(_:)), "1", [.command, .control])
        space.add(L("Größte Dateien (über 100 MB)"), #selector(MainWindowController.showLargestFiles(_:)), "2", [.command, .control])
        space.add(L("Doppelte Dateien (über 1 MB)"), #selector(MainWindowController.showDuplicates(_:)), "3", [.command, .control])
        space.add(L("Große, alte Dateien (über 50 MB, älter als 1 Jahr)"), #selector(MainWindowController.showOldLargeFiles(_:)),
                  "4", [.command, .control])
        space.addItem(.separator())
        let hint = space.add(L("Bei „Dieser Ordner“ wird nur der aktuelle Ordner analysiert."), nil)
        hint.isEnabled = false

        let idx = submenu(L("Index"))
        idx.add(L("Index neu aufbauen"), #selector(rebuildIndex), target: self)
        idx.add(L("Index jetzt speichern"), #selector(saveIndex), "s", target: self)

        let window = submenu(L("Fenster"))
        window.add(L("Im Dock ablegen"), #selector(NSWindow.performMiniaturize(_:)), "m")
        window.add(L("Zoomen"), #selector(NSWindow.performZoom(_:)))
        window.addItem(.separator())
        window.add(L("QuickFind-Suchfenster"), #selector(showMainWindow), "1", [.command, .option], target: self)
        NSApp.windowsMenu = window

        let help = submenu(L("Hilfe"))
        help.add(L("Suchsyntax"), #selector(showHelp), "?", target: self)
        NSApp.helpMenu = help

        NSApp.mainMenu = main
    }
}
