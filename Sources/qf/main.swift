import Foundation
import QuickFindCore

// qf – command line front-end for QuickFindCore (scanning, searching, benchmarks, self test).

setvbuf(stdout, nil, _IOLBF, 0)

struct Args {
    var command = "help"
    var positional: [String] = []
    var roots: [String] = []
    var excludes: [String] = []
    var store: URL = IndexManager.defaultStoreURL
    var limit = 20
    var sort: SortKey = .name
    var descending = false
    var options = SearchOptions()
    var synthetic = 0
    var seconds = 0.0
    var raw = false

    init(_ argv: [String]) {
        var it = argv.dropFirst().makeIterator()
        if let c = it.next() { command = c }
        while let a = it.next() {
            switch a {
            case "--root": roots.append(it.next() ?? "/")
            case "--exclude": excludes.append(it.next() ?? "")
            case "--store": store = URL(fileURLWithPath: it.next() ?? "")
            case "--limit": limit = Int(it.next() ?? "") ?? limit
            case "--sort": sort = SortKey(rawValue: it.next() ?? "") ?? .name
            case "--desc": descending = true
            case "--case": options.matchCase = true
            case "--path": options.matchPath = true
            case "--regex": options.regex = true
            case "--ww": options.matchWholeWord = true
            case "--synthetic": synthetic = Int(it.next() ?? "") ?? 1_000_000
            case "--seconds": seconds = Double(it.next() ?? "") ?? 0
            case "--raw": raw = true
            default: positional.append(a)
            }
        }
    }

    var configuration: IndexManager.Configuration {
        var c = IndexManager.Configuration()
        c.excludedPaths = excludes
        if !roots.isEmpty { c.customRoots = roots }
        return c
    }
}

func ms(_ s: Double) -> String { String(format: "%.2f ms", s * 1000) }

func printResults(_ index: FileIndex, _ r: SearchResult, limit: Int, raw: Bool = false) {
    for id in r.ids.prefix(limit) {
        guard let info = index.info(id) else { continue }
        if raw {
            print("\(info.isDirectory ? "d" : "f")\t\(info.size)\t\(info.path)")
            continue
        }
        let size = (info.isDirectory ? "📁 " : "") + ByteCountFormatter.string(fromByteCount: info.size, countStyle: .file)
        print(String(format: "%10@  ", size as NSString) + info.path)
    }
    print("— \(r.ids.count) Treffer von \(r.indexedCount) in \(ms(r.seconds))")
}

let args = Args(CommandLine.arguments)

switch args.command {
case "scan":
    try? FileManager.default.removeItem(at: args.store)
    let m = IndexManager(configuration: args.configuration, storeURL: args.store)
    m.log = { print($0) }
    let t0 = Date()
    m.startSynchronously()
    let (count, _) = m.index.stats
    print("Fertig: \(count) Einträge in \(String(format: "%.2f", Date().timeIntervalSince(t0))) s, RAM ≈ \(m.index.memoryBytes / 1_048_576) MB")
    print("Index: \(args.store.path)")

case "search":
    let m = IndexManager(configuration: args.configuration, storeURL: args.store)
    let t0 = Date()
    guard (try? m.index.load(from: args.store)) != nil else {
        print("Kein Index unter \(args.store.path) – zuerst `qf scan` ausführen.")
        exit(1)
    }
    print("Index geladen in \(ms(Date().timeIntervalSince(t0)))")
    m.index.rebuildNameOrder()
    let q = QueryParser.parse(args.positional.joined(separator: " "), options: args.options)
    if let r = SearchEngine.search(m.index, q, sort: args.sort, ascending: !args.descending) {
        printResults(m.index, r, limit: args.limit, raw: args.raw)
        if args.raw { exit(0) }
    }

case "bench":
    let index = FileIndex()
    var t0 = Date()
    if args.synthetic > 0 {
        Synthetic.fill(index, count: args.synthetic)
        print("Synthetischer Index: \(index.stats.count) Einträge in \(ms(Date().timeIntervalSince(t0)))")
    } else {
        guard let meta = try? index.load(from: args.store) else {
            print("Kein Index unter \(args.store.path)")
            exit(1)
        }
        print("Index geladen: \(index.stats.count) Einträge in \(ms(Date().timeIntervalSince(t0))) (gespeichert \(meta.savedAt))")
    }
    t0 = Date()
    index.rebuildNameOrder()
    print("Namensreihenfolge berechnet in \(ms(Date().timeIntervalSince(t0)))")
    print("RAM ≈ \(index.memoryBytes / 1_048_576) MB\n")
    let queries = ["", "a", "e", "lib", "test", "png", "report 2024", "*.jpg", "ext:pdf;docx", "readme | license",
                   "!e", "config json", "dylib", "usr/lib", "regex:^lib.*\\.dylib$", "size:>10mb", "folder:", "dm:thisyear",
                   "case:Info.plist", "ww:main"]
    print("Abfrage                          Treffer      Suche+Sortierung (Median von 7)")
    for text in queries {
        let q = QueryParser.parse(text, options: args.options)
        var times: [Double] = []
        var hits = 0
        for _ in 0..<7 {
            let r = SearchEngine.search(index, q, sort: args.sort, ascending: true)!
            times.append(r.seconds)
            hits = r.ids.count
        }
        times.sort()
        let label = text.isEmpty ? "(leer = alles)" : text
        print(label.padding(toLength: 32, withPad: " ", startingAt: 0) + String(format: "%10d", hits) + "      " + ms(times[3]))
    }

case "watch":
    let m = IndexManager(configuration: args.configuration, storeURL: args.store)
    m.log = { print($0) }
    m.statusQueue = DispatchQueue(label: "status")
    m.onStatus = { print("Status: \($0.phase) \($0.count) \($0.detail)") }
    m.startSynchronously()
    m.start()
    if args.seconds > 0 {
        DispatchQueue.global().asyncAfter(deadline: .now() + args.seconds) {
            m.save()
            exit(0)
        }
    }
    dispatchMain()

case "reconcile":
    // Loads/scans the index, then reconciles each root as after lost FSEvents (timing check).
    let m = IndexManager(configuration: args.configuration, storeURL: args.store)
    m.log = { print($0) }
    m.startSynchronously()
    for r in args.roots { m.reconcileForTesting(r) }

case "cleanup":
    // Runs the cleanup assistant's categories on the saved index (home = first --root or ~).
    let index = FileIndex()
    guard (try? index.load(from: args.store)) != nil else {
        print("Kein Index unter \(args.store.path)")
        exit(1)
    }
    let settings = CleanupSettings(home: args.roots.first ?? NSHomeDirectory())
    for c in CleanupCategory.allCases {
        let t0 = Date()
        let groups = Cleanup.run(c, index: index, settings: settings)
        let items = groups.reduce(0) { $0 + $1.items.count }
        let freed = groups.reduce(Int64(0)) { $0 + $1.reclaimable }
        print(c.title.padding(toLength: 22, withPad: " ", startingAt: 0)
              + String(format: "%6d Objekte  %10@  %8.0f ms", items,
                       ByteCountFormatter.string(fromByteCount: freed, countStyle: .file) as NSString,
                       Date().timeIntervalSince(t0) * 1000))
        for g in groups.prefix(args.limit) where c == .duplicates {
            print("   " + g.items.map { $0.path.replacingOccurrences(of: settings.home + "/", with: "") }.joined(separator: "  =  "))
        }
    }

case "selftest":
    exit(SelfTest.run() ? 0 : 1)

default:
    print("""
    qf – QuickFind Kommandozeile

      qf scan   [--root PFAD]... [--exclude PFAD]... [--store DATEI]
      qf search ABFRAGE [--limit N] [--sort name|path|size|date] [--desc] [--case] [--path] [--regex] [--ww] [--store DATEI]
      qf bench  [--store DATEI | --synthetic N]
      qf watch  [--root PFAD]... [--store DATEI] [--seconds N]
      qf selftest
    """)
}
