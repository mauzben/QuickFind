import Foundation

private struct SplitMix {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func pick<T>(_ a: [T]) -> T { a[Int(next() % UInt64(a.count))] }
}

/// Builds realistic-looking synthetic indexes for benchmarks.
public enum Synthetic {
    static let words = ["report", "invoice", "photo", "image", "backup", "project", "config", "readme", "license",
                        "main", "index", "test", "build", "release", "draft", "final", "notes", "budget", "summary",
                        "Vertrag", "Rechnung", "Urlaub", "Müller", "Präsentation", "data", "cache", "log", "lib",
                        "module", "source", "assets", "icon", "screen", "shot", "music", "video", "movie", "song",
                        "archive", "document", "letter", "resume", "plan", "design", "sketch", "mockup", "app",
                        "server", "client", "api", "util", "helper", "core", "view", "model", "controller",
                        "settings", "profile", "user", "admin", "public", "private", "temp", "old", "new", "copy"]
    static let exts = ["txt", "pdf", "jpg", "png", "swift", "js", "json", "md", "docx", "xlsx", "mp3", "mp4",
                       "zip", "h", "c", "py", "html", "css", "plist", "log", "dylib", "heic", "mov", "pages"]

    public static func fill(_ index: FileIndex, count: Int) {
        var rng = SplitMix(state: 42)
        index.lock.write {
            index.reset()
            var dirs: [Int32] = [index.addRoot("/")]
            var name: [UInt8] = []
            var fold: [UInt8] = []
            let now = Int64(Date().timeIntervalSince1970)
            while index.count < count {
                // Prefer recent directories to get a deep, realistic tree.
                let r = rng.next()
                let parent = r % 4 == 0 ? rng.pick(dirs) : dirs[max(0, dirs.count - 1 - Int(r >> 40) % 64)]
                let isDir = rng.next() % 9 == 0
                var s = rng.pick(words)
                if rng.next() % 2 == 0 { s += rng.pick(["_", "-", " ", ""]) + rng.pick(words) }
                if rng.next() % 3 == 0 { s += String(rng.next() % 3000) }
                if rng.next() % 5 == 0 { s = s.capitalized }
                if !isDir { s += "." + rng.pick(exts) }
                name = Array(s.utf8)
                fold.removeAll(keepingCapacity: true)
                name.withUnsafeBufferPointer { Fold.append($0, to: &fold) }
                let id = name.withUnsafeBufferPointer { n in
                    fold.withUnsafeBufferPointer { f in
                        index.append(name: n, fold: f, parent: parent, flags: isDir ? EntryFlag.directory : 0,
                                     size: isDir ? 0 : Int64(rng.next() % 50_000_000), allocated: 0,
                                     mtime: now - Int64(rng.next() % (86400 * 1500)))
                    }
                }
                if isDir { dirs.append(id) }
            }
        }
    }
}

/// End-to-end checks: scanning, query syntax, sorting, persistence and live FSEvents updates.
public enum SelfTest {
    private static var failures = 0

    private static func check(_ cond: Bool, _ what: String) {
        print((cond ? "  ✓ " : "  ✗ FEHLER: ") + what)
        if !cond { failures += 1 }
    }

    public static func run() -> Bool {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("qf-selftest-\(getpid())")
        let root = base.appendingPathComponent("tree")
        try? fm.removeItem(at: base)
        func mk(_ rel: String, _ bytes: Int = 0) {
            let u = root.appendingPathComponent(rel)
            try? fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            fm.createFile(atPath: u.path, contents: Data(repeating: 65, count: bytes))
        }
        mk("Docs/Report 2024.pdf", 2_000_000)
        mk("Docs/report-draft.docx", 1000)
        mk("Docs/Archiv/old_report.txt", 10)
        mk("Photos/IMG_0001.JPG", 3_000_000)
        mk("Photos/IMG_0002.jpg", 4_000_000)
        mk("Photos/Urlaub/strand.png", 500)
        mk("Code/main.swift", 300)
        mk("Code/mainframe.c", 300)
        mk("Code/.hidden", 1)
        mk("Musik/Müller – Lied.mp3", 5_000_000)
        mk("Musik/" + "Mu\u{0308}ller decomposed.txt", 5)
        try? fm.createDirectory(at: root.appendingPathComponent("Empty Folder"), withIntermediateDirectories: true)
        for n in ["Datei10.txt", "Datei2.txt", "Zebra.txt", "Ärger.txt"] { mk("Sortierung/" + n, 200) }

        var config = IndexManager.Configuration()
        config.customRoots = [root.path]
        config.excludedPaths = [root.appendingPathComponent("Docs/Archiv").path]
        let store = base.appendingPathComponent("index.qfi")
        let m = IndexManager(configuration: config, storeURL: store)
        m.startSynchronously()
        let idx = m.index

        func names(_ q: String, _ o: SearchOptions = SearchOptions(), sort: SortKey = .name, asc: Bool = true) -> [String] {
            let r = SearchEngine.search(idx, QueryParser.parse(q, options: o), sort: sort, ascending: asc)!
            return r.ids.compactMap { idx.info($0)?.name }
        }

        print("Scan")
        check(idx.stats.count == 22, "22 Einträge inkl. Wurzel indiziert (ohne ausgeschlossenen Ordner), ist \(idx.stats.count)")
        check(names("old_report").isEmpty, "Ausgeschlossener Ordner wird nicht indiziert")

        print("Suchsyntax")
        check(names("report") == ["Report 2024.pdf", "report-draft.docx"], "Teilstring, case-insensitiv, nach Name sortiert")
        check(names("report pdf") == ["Report 2024.pdf"], "UND")
        check(Set(names("strand | main.swift")) == ["strand.png", "main.swift"], "ODER mit |")
        check(Set(names("img|strand")) == ["IMG_0001.JPG", "IMG_0002.jpg", "strand.png"], "ODER ohne Leerzeichen")
        check(names("img !0001") == ["IMG_0002.jpg"], "NICHT mit !")
        check(names("*.jpg") == ["IMG_0001.JPG", "IMG_0002.jpg"], "Wildcard *.jpg")
        check(names("img_000?.jpg").count == 2, "Wildcard ?")
        check(names("ext:jpg;png").count == 3, "ext:")
        check(Set(names("folder:")) == ["Docs", "Photos", "Urlaub", "Code", "Musik", "Empty Folder", "Sortierung"], "folder:")
        check(names("file: photos").isEmpty && names("folder: photos") == ["Photos"], "file:/folder: kombiniert")
        check(names("case:img_0002").isEmpty && names("case:IMG_0002") == ["IMG_0002.jpg"], "case:")
        check(Set(names("photos/urlaub")) == ["Urlaub", "strand.png"], "Pfadsuche bei /")
        check(names("photos/ img").count == 2, "Pfadsuche Präfix")
        check(names("/photos/ img").count == 2 && names("/docs/archiv/").isEmpty, "Pfadsuche mit führendem /")
        check(names("/hotos/ img").isEmpty, "führendes / verlangt Ordnergrenze")
        check(names("ww:main") == ["main.swift"], "Ganze Wörter (ww:)")
        check(names("\"report 2024\"") == ["Report 2024.pdf"], "Phrase in Anführungszeichen")
        check(Set(names("size:>2.5mb")) == ["IMG_0001.JPG", "IMG_0002.jpg", "Müller – Lied.mp3", "Photos", "Musik"],
              "size:>2.5mb (inkl. Ordnergrößen)")
        check(names("size:<100") == [".hidden", "Empty Folder", "Mu\u{0308}ller decomposed.txt"], "size:<100")
        check(names("dm:today").count == 21, "dm:today")
        check(names("dc:today").count == 21 && names("dc:<2000-01-01").isEmpty, "dc: (Erstellungsdatum)")
        let created = SearchEngine.search(idx, QueryParser.parse("img_0001"))!.ids.first.flatMap { idx.info($0)?.created } ?? 0
        check(abs(created - Int64(Date().timeIntervalSince1970)) < 600, "Erstellungsdatum wird indiziert")

        check(names("regex:^img_\\d+\\.jpg$") == ["IMG_0001.JPG", "IMG_0002.jpg"], "regex:")
        check(names("müller").count == 2, "Unicode: NFC-Suche findet NFC und NFD-Namen")
        check(names("lied", { var o = SearchOptions(); o.filter = .audio; return o }()) == ["Müller – Lied.mp3"], "Filter Audio")
        check(names(".hidden") == [".hidden"], "Versteckte Dateien")

        print("Sortierung")
        check(names("datei") == ["Datei2.txt", "Datei10.txt"], "Zahlen numerisch (Datei2 vor Datei10)")
        check(names("txt sortierung/") == ["Ärger.txt", "Datei2.txt", "Datei10.txt", "Zebra.txt"], "Umlaute wie im Finder (Ärger vor Zebra)")
        idx.rebuildNameOrder()
        check(names("txt sortierung/") == ["Ärger.txt", "Datei2.txt", "Datei10.txt", "Zebra.txt"], "dito mit vorberechneter Rangfolge")
        check(names("ext:mp3|pdf|docx", sort: .type) == ["report-draft.docx", "Müller – Lied.mp3", "Report 2024.pdf"],
              "nach Typ (Endung)")
        func folderSize(_ n: String) -> Int64? {
            SearchEngine.search(idx, QueryParser.parse("folder: ww:\(n)"))!.ids.first.flatMap { idx.info($0)?.size }
        }
        check(folderSize("Docs") == 2_001_000, "Ordnergröße Docs = Summe des Inhalts")
        check(folderSize("Photos") == 7_000_500, "Ordnergröße mit Unterordnern")
        let bySize = names("img", sort: .size, asc: false)
        check(bySize == ["IMG_0002.jpg", "IMG_0001.JPG"], "nach Größe absteigend")
        let byPath = names("report|strand", sort: .path)
        check(byPath == ["Report 2024.pdf", "report-draft.docx", "strand.png"], "nach Pfad")
        idx.rebuildNameOrder()
        check(names("").count == 21 && names("").first == ".hidden", "leere Suche = alles, mit Rangfolge sortiert")

        print("Ordneransicht")
        let rootPath = idx.path(of: idx.id(forPath: root.path) ?? -1) ?? IndexManager.normalizeUserPath(root.path)
        func contents(_ rel: String, hidden: Bool = false, _ q: String = "") -> [String] {
            let p = rel.isEmpty ? rootPath : rootPath + "/" + rel
            return SearchEngine.contents(of: p, in: idx, query: QueryParser.parse(q), includeHidden: hidden)?
                .ids.compactMap { idx.info($0)?.name } ?? ["<fehlt>"]
        }
        check(contents("") == ["Code", "Docs", "Empty Folder", "Musik", "Photos", "Sortierung"], "Inhalt der Wurzel, Ordner wie im Finder")
        check(contents("Code") == ["main.swift", "mainframe.c"] && contents("Code", hidden: true).first == ".hidden",
              "versteckte Dateien nur auf Wunsch")
        check(contents("Photos", "ext:jpg") == ["IMG_0001.JPG", "IMG_0002.jpg"], "Filter innerhalb des Ordners")
        check(SearchEngine.contents(of: rootPath + "/gibtsnicht", in: idx, query: QueryParser.parse(""), includeHidden: false) == nil,
              "unbekannter Ordner → nil")

        print("Speicherplatz & Ordnersuche")
        mk("Docs/Kopie/report-draft.docx", 1000)
        mk("Musik/Kopie/Report 2024.pdf", 1)
        func waitUntil(_ cond: () -> Bool) {
            let deadline = Date().addingTimeInterval(8)
            while !cond() && Date() < deadline { usleep(100_000) }
        }
        waitUntil { names("kopie/ report").count == 2 }
        check(names("dupe:") == ["report-draft.docx", "report-draft.docx"], "dupe: = gleicher Name und gleiche Größe")
        let inDocs = SearchEngine.search(idx, QueryParser.parse("report"), within: rootPath + "/Docs")!
        check(Set(inDocs.ids.compactMap { idx.info($0)?.path.replacingOccurrences(of: rootPath + "/", with: "") })
              == ["Docs/Report 2024.pdf", "Docs/report-draft.docx", "Docs/Kopie/report-draft.docx"], "Suche nur in einem Ordner (inkl. Unterordner)")
        let allInDocs = SearchEngine.search(idx, QueryParser.parse(""), within: rootPath + "/Docs")!
        check(allInDocs.ids.count == 4 && !allInDocs.ids.contains(idx.id(forPath: rootPath + "/Docs")!),
              "leere Suche im Ordner = gesamter Inhalt ohne den Ordner selbst")
        check(allInDocs.totalSize == 2_000_000 + 1000 + 1000, "Gesamtgröße der Treffer (nur Dateien)")
        check(SearchEngine.search(idx, QueryParser.parse("report"), within: rootPath + "/gibtsnicht")!.ids.isEmpty,
              "unbekannter Ordner liefert nichts")
        // Sparse file (like Docker.raw): large logical size, almost nothing allocated.
        let sparse = root.appendingPathComponent("Sparse/disk.raw")
        try? fm.createDirectory(at: sparse.deletingLastPathComponent(), withIntermediateDirectories: true)
        fm.createFile(atPath: sparse.path, contents: nil)
        if let h = try? FileHandle(forWritingTo: sparse) { try? h.truncate(atOffset: 10_000_000_000); try? h.close() }
        waitUntil { names("disk.raw").count == 1 }
        let sparseInfo = SearchEngine.search(idx, QueryParser.parse("disk.raw"))!.ids.first.flatMap { idx.info($0) }
        check(sparseInfo?.size == 10_000_000_000 && (sparseInfo?.allocated ?? .max) < 1_000_000,
              "Sparse-Datei: 10 GB logisch, belegt fast nichts")
        let sparseDir = idx.id(forPath: rootPath + "/Sparse").flatMap { idx.info($0) }
        check(sparseDir?.size == 10_000_000_000 && (sparseDir?.allocated ?? .max) < 1_000_000, "Ordner summiert auch den belegten Platz")
        check(names("size:>1gb") == ["disk.raw"], "size: bei Ordnern = belegter Platz (Sparse-Ordner gilt nicht als groß)")
        let img = SearchEngine.search(idx, QueryParser.parse("img_0001"))!.ids.first.flatMap { idx.info($0) }
        check((img?.allocated ?? 0) >= 3_000_000, "normale Datei: belegt ≥ Größe")
        try? fm.removeItem(at: sparse.deletingLastPathComponent())
        waitUntil { names("disk.raw").isEmpty }
        let rootInfo = idx.id(forPath: rootPath).flatMap { idx.info($0) }
        check((rootInfo?.allocated ?? .max) < 50_000_000, "gelöschte Sparse-Datei wird vom belegten Platz abgezogen")
        try? fm.removeItem(at: root.appendingPathComponent("Docs/Kopie"))
        try? fm.removeItem(at: root.appendingPathComponent("Musik/Kopie"))
        waitUntil { names("kopie").isEmpty }

        print("Abgleich nach verlorenen Ereignissen")
        let before = idx.stats
        m.reconcileForTesting(rootPath)
        check(idx.stats.count == before.count, "Abgleich ohne Änderungen: Index bleibt vollständig und gleich groß")
        // Changes the index has not seen yet (applied directly, events still pending) are picked up.
        mk("Musik/Abgleich/neu.mp3", 10)
        m.reconcileForTesting(rootPath)
        check(names("abgleich").count == 1 && names("neu.mp3").count == 1, "Abgleich findet neue Ordner und Dateien")
        try? fm.removeItem(at: root.appendingPathComponent("Musik/Abgleich"))
        m.reconcileForTesting(rootPath)
        check(names("neu.mp3").isEmpty, "Abgleich entfernt gelöschte Einträge")

        print("Aufräumen")
        let two = 2 << 20
        let same = Data((0..<two).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        var other = same
        other[two / 2] ^= 0xFF                                    // same size, different content
        var third = same
        third[0] ^= 0xFF
        func put(_ rel: String, _ data: Data, ageDays: Int = 0) {
            let u = root.appendingPathComponent(rel)
            try? fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: u)
            if ageDays > 0 {
                try? fm.setAttributes([.modificationDate: Date().addingTimeInterval(-Double(ageDays) * 86400)], ofItemAtPath: u.path)
            }
        }
        put("Aufraeumen/original.bin", same)
        usleep(1_100_000)                                         // later creation date for the copy
        put("Aufraeumen/Unterordner/kopie mit anderem Namen.bin", same)
        put("Aufraeumen/anders.bin", other)
        try? fm.linkItem(atPath: root.appendingPathComponent("Aufraeumen/original.bin").path,
                         toPath: root.appendingPathComponent("Aufraeumen/hardlink.bin").path)
        put("Aufraeumen/Tool.app/Contents/Resources/x.bin", same)
        put("Aufraeumen/node_modules/paket/x.bin", same)
        put("Aufraeumen/.versteckt/x.bin", same)
        put("Aufraeumen/Projekt/quelle/x.bin", same)
        put("Aufraeumen/Projekt/.git/HEAD", Data("ref".utf8))
        put("Aufraeumen/miniconda3/lib/x.bin", same)
        put("Downloads/alt.zip", Data(count: 1000), ageDays: 200)
        put("Downloads/neu.zip", Data(count: 1000))
        put("Downloads/setup.dmg", third)
        put("Library/Caches/com.beispiel.app/cache.db", Data(count: two))
        put("Library/Caches/com.apple.irgendwas/cache.db", Data(count: two + 1))
        put("Library/Preferences/einstellung.plist", same)
        waitUntil { names("cache.db").count == 2 && names("setup.dmg").count == 1 && names("x.bin").count == 5 }

        var cs = CleanupSettings(home: root.path)
        cs.minLargeSize = 1 << 20
        func run(_ c: CleanupCategory) -> [[String]] {
            Cleanup.run(c, index: idx, settings: cs).map { $0.items.map { $0.path.replacingOccurrences(of: rootPath + "/", with: "") } }
        }
        let dupes = Cleanup.run(.duplicates, index: idx, settings: cs)
        check(dupes.count == 1 && dupes[0].items.map(\.name) == ["original.bin", "kopie mit anderem Namen.bin"],
              "Dubletten: nur inhaltsgleiche Dateien, unabhängig vom Namen")
        check(dupes.first?.keep == 0 && dupes.first?.reclaimable == dupes.first?.items[1].size, "Dubletten: älteste Datei wird behalten")
        let large = run(.largeFiles).flatMap { $0 }
        check(large.contains("Aufraeumen/original.bin") && large.contains("Photos/IMG_0002.jpg"), "Große Dateien gefunden")
        check(!large.contains { $0.contains(".app/") || $0.contains("node_modules") || $0.contains(".versteckt") || $0.hasPrefix("Library/") },
              "Geschützt: App-Inhalte, node_modules, versteckte Ordner, Library")
        check(!large.contains { $0.contains("Projekt/") || $0.contains("miniconda3") },
              "Geschützt: Git-Projekte und installierte Software")
        check(run(.oldDownloads).flatMap { $0 } == ["Downloads/alt.zip"], "Alte Downloads (älter als 90 Tage)")
        check(run(.installers).flatMap { $0 } == ["Downloads/setup.dmg"], "Installationsdateien")
        check(run(.caches).flatMap { $0 } == ["Library/Caches/com.beispiel.app"], "App-Caches ohne Apple-eigene")
        let home = "/Users/x"
        check(Cleanup.isProtected("/Users/x/Pictures/Photos Library.photoslibrary/originals/a.jpg", home: home)
              && Cleanup.isProtected("/Applications/Safari.app", home: home)
              && Cleanup.isProtected("/Users/x/.Trash/a", home: home)
              && !Cleanup.isProtected("/Users/x/Downloads/Alt.app", home: home)
              && !Cleanup.isProtected("/Users/x/Documents/a.pdf", home: home), "Schutzregeln")
        // Empty and large folders.
        for d in ["Aufraeumen/Leer/Unterleer/NochLeer", "Aufraeumen/NurDSStore"] {
            try? fm.createDirectory(at: root.appendingPathComponent(d), withIntermediateDirectories: true)
        }
        put("Aufraeumen/NurDSStore/.DS_Store", Data(count: 10))
        try? fm.createDirectory(at: root.appendingPathComponent("LeererHauptordner"), withIntermediateDirectories: true)
        waitUntil { names("nochleer").count == 1 && names("leererhauptordner").count == 1 }
        let empties = run(.emptyFolders).flatMap { $0 }
        check(empties.contains("Aufraeumen/Leer") && empties.contains("Aufraeumen/NurDSStore")
              && !empties.contains { $0.hasPrefix("Aufraeumen/Leer/") },
              "Leere Ordner: oberster leerer Ordner, .DS_Store zählt nicht")
        check(!empties.contains("LeererHauptordner") && !empties.contains { $0.contains("Projekt") || $0.contains(".app") },
              "Leere Ordner: Hauptordner, Projekte und Pakete geschützt")
        cs.minFolderSize = 1 << 20
        let bigFolders = run(.largeFolders).flatMap { $0 }
        check(bigFolders.contains("Aufraeumen/Unterordner") && !bigFolders.contains("Aufraeumen") && !bigFolders.contains("Photos"),
              "Große Ordner: ab Mindestgröße, ohne Hauptordner")
        check(!bigFolders.contains { $0.contains(".app") || $0.contains("miniconda3") || $0.contains("node_modules")
                                     || $0.contains(".versteckt") || $0.contains("Projekt") },
              "Große Ordner: Pakete, Software, versteckte Ordner und Projekte geschützt")
        try? fm.removeItem(at: root.appendingPathComponent("LeererHauptordner"))
        for d in ["Aufraeumen", "Downloads", "Library"] { try? fm.removeItem(at: root.appendingPathComponent(d)) }
        waitUntil { names("cache.db").isEmpty && names("original.bin").isEmpty }

        print("Persistenz")
        m.save()
        let copy = FileIndex()
        let meta = try? copy.load(from: store)
        check(meta != nil && copy.stats.count == idx.stats.count, "Snapshot laden: gleiche Anzahl")
        let r1 = SearchEngine.search(copy, QueryParser.parse("report"))!.ids.compactMap { copy.info($0)?.path }
        let r2 = SearchEngine.search(idx, QueryParser.parse("report"))!.ids.compactMap { idx.info($0)?.path }
        check(r1 == r2 && !r1.isEmpty, "Snapshot liefert identische Ergebnisse")
        let docsCopy = SearchEngine.search(copy, QueryParser.parse("folder: ww:docs"))!.ids.first.flatMap { copy.info($0)?.size }
        check(docsCopy == 2_001_000, "Ordnergrößen nach dem Laden")
        check(!fm.fileExists(atPath: store.path + ".scanning"), "kein Scan-Marker nach abgeschlossenem Scan")
        // Simulate a quit during a scan: the next start must rebuild instead of loading the snapshot.
        fm.createFile(atPath: store.path + ".scanning", contents: nil)
        let restarted = IndexManager(configuration: config, storeURL: store)
        restarted.startSynchronously()
        check(restarted.index.stats.count == idx.stats.count && !fm.fileExists(atPath: store.path + ".scanning"),
              "unterbrochener Scan → Neuaufbau beim nächsten Start")

        print("Live-Updates (FSEvents)")
        func waitFor(_ what: String, _ cond: () -> Bool) {
            let deadline = Date().addingTimeInterval(8)
            while !cond() && Date() < deadline { usleep(100_000) }
            check(cond(), what)
        }
        mk("Docs/neu erstellt.txt", 42)
        waitFor("Neue Datei erscheint") { names("neu erstellt") == ["neu erstellt.txt"] }
        try? fm.moveItem(at: root.appendingPathComponent("Photos"), to: root.appendingPathComponent("Bilder"))
        waitFor("Umbenannter Ordner: neuer Pfad") {
            let r = SearchEngine.search(idx, QueryParser.parse("strand"))!.ids.compactMap { idx.info($0)?.path }
            return r == [root.resolvingSymlinksInPath().path.replacingOccurrences(of: "/var/", with: "/private/var/") + "/Bilder/Urlaub/strand.png"]
        }
        try? fm.removeItem(at: root.appendingPathComponent("Code"))
        waitFor("Gelöschter Ordner verschwindet samt Inhalt") { names("main").isEmpty }
        let f = root.appendingPathComponent("Docs/report-draft.docx")
        try? Data(repeating: 1, count: 12345).write(to: f)
        waitFor("Größenänderung wird übernommen") {
            let r = SearchEngine.search(idx, QueryParser.parse("report-draft"))!
            return r.ids.first.flatMap { idx.info($0)?.size } == 12345
        }
        waitFor("Ordnergröße folgt Änderungen") { folderSize("Docs") == 2_000_000 + 12345 + 42 }

        try? fm.removeItem(at: base)
        print(failures == 0 ? "\nAlle Tests bestanden." : "\n\(failures) Test(s) fehlgeschlagen.")
        return failures == 0
    }
}
