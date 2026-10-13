import AppKit
import QuickFindCore

final class SettingsWindowController: NSWindowController {
    private let manager: IndexManager
    private let applyHotKey: () -> Bool
    private let applyDockIcon: (Bool) -> Void

    private let fdaLabel = NSTextField(labelWithString: "")
    private let externalCheckbox = NSButton(checkboxWithTitle: L("Externe Volumes (/Volumes/…) indizieren"), target: nil, action: nil)
    private let excludesView = NSTextView()
    private let loginCheckbox = NSButton(checkboxWithTitle: L("Bei der Anmeldung starten (hält den Index immer aktuell)"),
                                         target: nil, action: nil)
    private let loginHint = NSTextField(wrappingLabelWithString: "")
    private let dockCheckbox = NSButton(checkboxWithTitle: L("Symbol im Dock anzeigen"), target: nil, action: nil)
    private let hotKeyCheckbox = NSButton(checkboxWithTitle: L("Globaler Kurzbefehl:"), target: nil, action: nil)
    private let hotKeyButton = NSButton(title: "", target: nil, action: nil)
    private let hotKeyHint = NSTextField(labelWithString: "")
    private let statsLabel = NSTextField(wrappingLabelWithString: "")
    private var recorder: Any?

    init(manager: IndexManager, applyHotKey: @escaping () -> Bool, applyDockIcon: @escaping (Bool) -> Void) {
        self.manager = manager
        self.applyHotKey = applyHotKey
        self.applyDockIcon = applyDockIcon
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 640), styleMask: [.titled, .closable],
                         backing: .buffered, defer: false)
        w.title = L("QuickFind – Einstellungen")
        w.isReleasedWhenClosed = false
        w.center()
        super.init(window: w)
        buildUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func showWindow(_ sender: Any?) {
        reload()
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func section(_ title: String) -> NSTextField {
        let l = NSTextField(labelWithString: title)
        l.font = .boldSystemFont(ofSize: 13)
        return l
    }

    private func hint(_ text: String) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: text)
        l.font = .systemFont(ofSize: 11)
        l.textColor = .secondaryLabelColor
        return l
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }

        let fdaButton = NSButton(title: L("Systemeinstellungen öffnen …"), target: self, action: #selector(openFDA))
        let fdaRow = NSStackView(views: [fdaLabel, fdaButton])
        fdaRow.spacing = 12
        let fdaHelp = hint(L("Ohne Festplattenvollzugriff fehlen geschützte Ordner (Mail, Nachrichten, Container anderer Apps …) und macOS fragt pro Ordner nach. Nach dem Aktivieren QuickFind neu starten."))

        loginCheckbox.target = self
        loginCheckbox.action = #selector(loginToggled)
        loginHint.font = .systemFont(ofSize: 11)
        loginHint.textColor = .secondaryLabelColor
        dockCheckbox.target = self
        dockCheckbox.action = #selector(dockToggled)
        let dockHint = hint(L("Ohne Dock-Symbol ist QuickFind über die Lupe in der Menüleiste und den Kurzbefehl erreichbar."))

        hotKeyCheckbox.target = self
        hotKeyCheckbox.action = #selector(hotKeyToggled)
        hotKeyButton.target = self
        hotKeyButton.action = #selector(recordHotKey)
        hotKeyButton.bezelStyle = .rounded
        hotKeyButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true
        hotKeyHint.font = .systemFont(ofSize: 11)
        hotKeyHint.textColor = .secondaryLabelColor
        let hotKeyRow = NSStackView(views: [hotKeyCheckbox, hotKeyButton, hotKeyHint])
        hotKeyRow.spacing = 8

        let excludesScroll = NSScrollView()
        excludesScroll.documentView = excludesView
        excludesScroll.hasVerticalScroller = true
        excludesScroll.borderType = .bezelBorder
        excludesView.isRichText = false
        excludesView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        excludesView.isAutomaticQuoteSubstitutionEnabled = false
        excludesView.autoresizingMask = [.width]
        excludesView.isVerticallyResizable = true
        excludesView.textContainer?.widthTracksTextView = true
        let excludesHelp = hint(L("Ein Pfad pro Zeile, z. B. ~/Library/Caches oder /opt/homebrew"))

        let apply = NSButton(title: L("Übernehmen & neu indizieren"), target: self, action: #selector(applyIndexSettings))
        apply.keyEquivalent = "\r"
        let rebuild = NSButton(title: L("Index neu aufbauen"), target: self, action: #selector(rebuildIndex))
        let buttons = NSStackView(views: [rebuild, NSView(), apply])

        statsLabel.font = .systemFont(ofSize: 11)
        statsLabel.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [
            section(L("Allgemein")), loginCheckbox, loginHint, dockCheckbox, dockHint, hotKeyRow,
            section(L("Festplattenvollzugriff")), fdaRow, fdaHelp,
            section(L("Indizierung")), externalCheckbox, section(L("Ausgeschlossene Ordner")), excludesScroll, excludesHelp,
            statsLabel, buttons,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        for v in [hotKeyRow, fdaHelp, externalCheckbox, excludesHelp, statsLabel] { stack.setCustomSpacing(18, after: v) }
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -20),
            excludesScroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            excludesScroll.heightAnchor.constraint(equalToConstant: 100),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor),
            fdaHelp.widthAnchor.constraint(equalTo: stack.widthAnchor),
            dockHint.widthAnchor.constraint(equalTo: stack.widthAnchor),
            loginHint.widthAnchor.constraint(equalTo: stack.widthAnchor),
            statsLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    private func reload() {
        let c = manager.configuration
        externalCheckbox.state = c.includeExternalVolumes ? .on : .off
        excludesView.string = c.excludedPaths.joined(separator: "\n")
        loginCheckbox.state = LoginItem.isEnabled || LoginItem.needsApproval ? .on : .off
        updateLoginHint()
        dockCheckbox.state = Prefs.showDockIcon ? .on : .off
        hotKeyCheckbox.state = Prefs.hotKeyEnabled ? .on : .off
        hotKeyButton.title = Prefs.hotKey.display
        hotKeyButton.isEnabled = Prefs.hotKeyEnabled
        hotKeyHint.stringValue = ""
        fdaLabel.stringValue = Permissions.hasFullDiskAccess ? L("✅ Erteilt") : L("⚠️ Nicht erteilt")
        let (count, _) = manager.index.stats
        statsLabel.stringValue = L("Index: %1$@ Objekte · ca. %2$@ MB Arbeitsspeicher · gespeichert unter %3$@",
                                   Format.count(count), Format.count(Int(manager.index.memoryBytes / 1_048_576)), manager.storeURL.path)
    }

    private func updateLoginHint() {
        if LoginItem.needsApproval {
            loginHint.stringValue = L("⚠️ macOS muss den Autostart noch erlauben: Systemeinstellungen → Allgemein → Anmeldeobjekte.")
        } else if Bundle.main.bundlePath.hasPrefix("/Applications/") {
            loginHint.stringValue = L("Beim Autostart öffnet sich kein Fenster – QuickFind wartet in der Menüleiste.")
        } else {
            loginHint.stringValue = L("Tipp: QuickFind zuerst in den Ordner „Programme“ legen, sonst zeigt der Autostart auf diese Kopie.")
        }
    }

    // MARK: General

    @objc private func loginToggled() {
        do {
            try LoginItem.set(loginCheckbox.state == .on)
        } catch {
            NSAlert(error: error).runModal()
        }
        loginCheckbox.state = LoginItem.isEnabled || LoginItem.needsApproval ? .on : .off
        updateLoginHint()
        if LoginItem.needsApproval { LoginItem.openSettings() }
    }

    @objc private func dockToggled() { applyDockIcon(dockCheckbox.state == .on) }

    @objc private func hotKeyToggled() {
        Prefs.hotKeyEnabled = hotKeyCheckbox.state == .on
        hotKeyButton.isEnabled = Prefs.hotKeyEnabled
        hotKeyHint.stringValue = applyHotKey() ? "" : L("⚠️ bereits belegt")
    }

    /// Waits for the next key combination and stores it as the global shortcut.
    @objc private func recordHotKey() {
        guard recorder == nil else { return }
        let previous = Prefs.hotKey
        // Suspend the current shortcut so it can be recorded again.
        Prefs.hotKeyEnabled = false
        _ = applyHotKey()
        hotKeyButton.title = L("Tasten drücken …")
        hotKeyHint.stringValue = L("Esc bricht ab")
        recorder = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53 { // Escape
                self.finishRecording(nil, previous: previous)
            } else if let shortcut = HotKey.Shortcut(event: event) {
                self.finishRecording(shortcut, previous: previous)
            } else {
                self.hotKeyHint.stringValue = L("Mit ⌘, ⌥ oder ⌃ kombinieren")
                NSSound.beep()
            }
            return nil
        }
    }

    private func finishRecording(_ shortcut: HotKey.Shortcut?, previous: HotKey.Shortcut) {
        if let m = recorder { NSEvent.removeMonitor(m) }
        recorder = nil
        hotKeyHint.stringValue = ""
        Prefs.hotKeyEnabled = true
        if let shortcut {
            Prefs.hotKey = shortcut
            if !applyHotKey() {
                Prefs.hotKey = previous
                _ = applyHotKey()
                hotKeyHint.stringValue = L("⚠️ %@ ist bereits belegt", shortcut.display)
            }
        }
        else if !applyHotKey() {
            hotKeyHint.stringValue = L("⚠️ bereits belegt")
        }
        hotKeyButton.title = Prefs.hotKey.display
    }

    // MARK: Index

    @objc private func openFDA() { Permissions.openFullDiskAccessSettings() }

    @objc private func rebuildIndex() {
        manager.rebuild()
        window?.close()
    }

    @objc private func applyIndexSettings() {
        var c = manager.configuration
        c.includeExternalVolumes = externalCheckbox.state == .on
        c.excludedPaths = excludesView.string.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if c != manager.configuration {
            var stored = c
            stored.customRoots = nil
            Prefs.configuration = stored
            manager.updateConfiguration(c)
        }
        window?.close()
    }
}

/// Search syntax cheat sheet.
final class HelpWindowController: NSWindowController {
    static var text: String { Localization.isGerman ? germanText : englishText }

    private static var germanText: String { """
    SUCHSYNTAX

    Operatoren
      a b              UND – beide Begriffe müssen vorkommen
      a | b            ODER
      !a               NICHT
      "a b"            exakte Phrase (mit Leerzeichen)

    Platzhalter (vergleichen den ganzen Namen)
      *.jpg            beliebig viele Zeichen
      foto_??.png      genau ein Zeichen

    Pfade
      Enthält ein Begriff „/“, wird der vollständige Pfad durchsucht:
      projekte/ rechnung   „rechnung“ irgendwo unter einem Ordner „…projekte“
      photos/urlaub

    Modifikatoren (vor einen Begriff schreiben)
      case:            Groß-/Kleinschreibung beachten     case:README
      ww:              ganze Wörter                        ww:main
      path:            ganzen Pfad durchsuchen             path:projekte
      file:  folder:   nur Dateien / nur Ordner            folder:backup
      ext:             Endungen                            ext:jpg;png;heic
      regex:           regulärer Ausdruck                  regex:^IMG_\\d+
      size:            Größe (B, KB, MB, GB), auch Ordner  size:>100mb   size:1mb..10mb
                       Spalte „Größe“: Ordner = tatsächlich belegter Speicher, Dateien = Größe wie im Finder
                       Spalte „Belegung“: in der Ordneransicht Anteil am Ordner, bei der Suche
                       Anteil am Gesamtspeicher der Festplatte
      dupe:            Dubletten (gleicher Name + Größe)   dupe: size:>1mb
                       empty tiny small medium large huge gigantic
      dc:              Erstellungsdatum (wie dm:)          dc:thisyear
      dm:              Änderungsdatum                      dm:today   dm:thisweek   dm:2024
                       dm:>2025-01-01   dm:01.03.2025   dm:2024-01..2024-06
                       (auch: heute, gestern, diesewoche, diesermonat, diesesjahr)

    Ordneransicht (Suchfeld leer)
      Doppelklick / ↩  Ordner öffnen (Apps und Dokumente werden normal geöffnet)
      ⌘↑ / ⌘[ / ⌘]     übergeordneter Ordner / zurück / vorwärts
      ⇧⌘H ⇧⌘D ⇧⌘O ⌥⌘L ⇧⌘A ⇧⌘C   Benutzer, Schreibtisch, Dokumente, Downloads, Programme, Festplatte
      ⇧⌘.              versteckte Dateien ein-/ausblenden
      ⌥⌘S              Seitenleiste ein-/ausblenden (Ordner per Drag & Drop als Favorit hinzufügen)
      Kontextmenü „Enthaltenden Ordner anzeigen“ springt von einem Suchtreffer in seinen Ordner.
      ⌥⌘E / ⌥⌘F        überall suchen / nur in diesem Ordner suchen
      Rechtsklick auf die Spaltenüberschrift: Spalten ein-/ausblenden
                       (u. a. „Erstellt am“, „Zuletzt geöffnet“, „Tags“)

    Dateien bearbeiten
      F2               umbenennen                ⇧⌘N  neuer Ordner (Ordneransicht)
      ⌘V / ⌥⌘V         hierher kopieren / bewegen
      Drag & Drop      auf einen Ordner oder in die Ordneransicht (⌥ = kopieren)

    Aufräumen (⌃⌘0, Menü „Speicherplatz“ oder Menüleiste)
      Dubletten (gleicher Inhalt per SHA-256), große Dateien, große Ordner, alte Downloads, große alte
      Dateien, Installationsdateien, leere Ordner und App-Caches. Nur der Benutzerordner; System, Programme, ~/Library,
      versteckte Ordner, App-Pakete, Git-Projekte und Cloud-Dateien sind geschützt.
      Leertaste = Quick Look, ↩ = Häkchen setzen. Alles geht in den Papierkorb („Zurücklegen“ möglich).

    Speicherplatz (Menü „Speicherplatz“)
      ⌃⌘1 Ordnerinhalt nach Größe   ⌃⌘2 größte Dateien   ⌃⌘3 Dubletten   ⌃⌘4 große, alte Dateien

    Tastatur
      ↓ / ↩            in die Ergebnisliste wechseln
      ↩                öffnen                  ⌘↩   im Finder zeigen
      Leertaste        Quick Look              ⌘C   Dateien kopieren
      ⌥⌘C              Pfad kopieren           ⌘⌫   in den Papierkorb
      Tippen           in der Liste sucht weiter
      ⌥⌘I ⌥⌘B ⌥⌘U ⌥⌘R  Groß/klein · ganze Wörter · Pfad · Regex
      ⌘1 … ⌘8          Filter (Alles, Audio, Archive, Dokumente, Programme, Ordner, Bilder, Videos)
      \(Prefs.hotKey.display.padding(toLength: 16, withPad: " ", startingAt: 0)) QuickFind von überall aufrufen (änderbar in den Einstellungen)
    """ }

    private static var englishText: String { """
    SEARCH SYNTAX

    Operators
      a b              AND – both terms must match
      a | b            OR
      !a               NOT
      "a b"            exact phrase (with spaces)

    Wildcards (match the whole name)
      *.jpg            any number of characters
      photo_??.png     exactly one character

    Paths
      If a term contains "/", the full path is searched:
      projects/ invoice    "invoice" anywhere below a folder "…projects"
      photos/holiday

    Modifiers (write before a term)
      case:            match case                          case:README
      ww:              whole words                         ww:main
      path:            search the full path                path:projects
      file:  folder:   files only / folders only           folder:backup
      ext:             extensions                          ext:jpg;png;heic
      regex:           regular expression                  regex:^IMG_\\d+
      size:            size (B, KB, MB, GB), also folders  size:>100mb   size:1mb..10mb
                       "Size" column: folders = space actually used, files = size as in Finder
                       "Usage" column: share of the folder in folder view, share of the
                       whole disk when searching
      dupe:            duplicates (same name + size)       dupe: size:>1mb
                       empty tiny small medium large huge gigantic
      dc:              date created (like dm:)             dc:thisyear
      dm:              date modified                       dm:today   dm:thisweek   dm:2024
                       dm:>2025-01-01   dm:2024-01..2024-06
                       (also: yesterday, lastweek, thismonth, lastmonth, lastyear)

    Folder view (empty search field)
      Double-click / ↩ open folder (apps and documents open normally)
      ⌘↑ / ⌘[ / ⌘]     enclosing folder / back / forward
      ⇧⌘H ⇧⌘D ⇧⌘O ⌥⌘L ⇧⌘A ⇧⌘C   Home, Desktop, Documents, Downloads, Applications, Computer
      ⇧⌘.              show/hide hidden files
      ⌥⌘S              show/hide sidebar (drag folders in to add favorites)
      Context menu "Show Enclosing Folder" jumps from a search result to its folder.
      ⌥⌘E / ⌥⌘F        search everywhere / search this folder only
      Right-click the column header: show/hide columns
                       (e.g. "Date Created", "Last Opened", "Tags")

    Editing files
      F2               rename                    ⇧⌘N  new folder (folder view)
      ⌘V / ⌥⌘V         copy / move here
      Drag & drop      onto a folder or into the folder view (⌥ = copy)

    Clean Up (⌃⌘0, "Storage" menu or menu bar)
      Duplicates (same content via SHA-256), large files, large folders, old downloads, large old
      files, installers, empty folders and app caches. Home folder only; system, Applications, ~/Library,
      hidden folders, app packages, Git projects and cloud files are protected.
      Space = Quick Look, ↩ = toggle checkmark. Everything goes to the Trash ("Put Back" possible).

    Storage ("Storage" menu)
      ⌃⌘1 folder contents by size   ⌃⌘2 largest files   ⌃⌘3 duplicates   ⌃⌘4 large, old files

    Keyboard
      ↓ / ↩            move into the result list
      ↩                open                    ⌘↩   show in Finder
      Space            Quick Look              ⌘C   copy files
      ⌥⌘C              copy path               ⌘⌫   move to Trash
      Typing           in the list continues the search
      ⌥⌘I ⌥⌘B ⌥⌘U ⌥⌘R  match case · whole words · path · regex
      ⌘1 … ⌘8          filter (All, Audio, Archives, Documents, Applications, Folders, Pictures, Videos)
      \(Prefs.hotKey.display.padding(toLength: 16, withPad: " ", startingAt: 0)) open QuickFind from anywhere (change it in Settings)
    """ }

    init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 640), styleMask: [.titled, .closable, .resizable],
                         backing: .buffered, defer: false)
        w.title = L("QuickFind – Suchsyntax")
        w.isReleasedWhenClosed = false
        w.center()
        let scroll = NSTextView.scrollableTextView()
        if let tv = scroll.documentView as? NSTextView {
            tv.string = Self.text
            tv.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            tv.isEditable = false
            tv.textContainerInset = NSSize(width: 12, height: 12)
        }
        w.contentView = scroll
        super.init(window: w)
    }

    override func showWindow(_ sender: Any?) {
        ((window?.contentView as? NSScrollView)?.documentView as? NSTextView)?.string = Self.text
        super.showWindow(sender)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}
