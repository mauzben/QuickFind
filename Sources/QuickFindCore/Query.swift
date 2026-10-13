import Foundation

public struct SearchOptions: Equatable, Codable {
    public var matchCase = false
    public var matchWholeWord = false
    public var matchPath = false
    public var regex = false
    public var filter: FileFilter = .all
    public init() {}
}

public enum FileFilter: Int, CaseIterable, Codable {
    case all, audio, compressed, document, executable, folder, picture, video

    public var title: String {
        switch self {
        case .all: return L("Alles")
        case .audio: return L("Audio")
        case .compressed: return L("Archive")
        case .document: return L("Dokumente")
        case .executable: return L("Programme")
        case .folder: return L("Ordner (Filter)")
        case .picture: return L("Bilder")
        case .video: return L("Videos")
        }
    }

    var extensions: [String] {
        switch self {
        case .all, .folder: return []
        case .audio: return ["aac", "aif", "aiff", "alac", "caf", "flac", "m4a", "mid", "midi", "mp3", "ogg", "opus", "wav", "wma"]
        case .compressed: return ["7z", "bz2", "dmg", "gz", "iso", "lz", "lzma", "rar", "sit", "tar", "tbz", "tgz", "xip", "xz", "z", "zip", "zst"]
        case .document: return ["csv", "doc", "docx", "epub", "htm", "html", "key", "md", "numbers", "odp", "ods", "odt", "pages", "pdf", "ppt", "pptx", "rtf", "rtfd", "tex", "txt", "xls", "xlsx"]
        case .executable: return ["app", "bat", "bin", "cmd", "command", "exe", "jar", "msi", "pkg", "mpkg", "py", "sh", "tool"]
        case .picture: return ["avif", "bmp", "cr2", "cr3", "dng", "gif", "heic", "heif", "ico", "icns", "jpeg", "jpg", "nef", "png", "psd", "raw", "arw", "svg", "tif", "tiff", "webp"]
        case .video: return ["3gp", "avi", "flv", "m2ts", "m4v", "mkv", "mov", "mp4", "mpeg", "mpg", "mts", "webm", "wmv"]
        }
    }
}

/// Heap-allocated needle so the hot loop can use raw pointers.
final class Needle {
    let ptr: UnsafeMutablePointer<UInt8>
    let count: Int

    init(_ bytes: [UInt8]) {
        count = bytes.count
        ptr = .allocate(capacity: max(1, bytes.count))
        ptr.initialize(from: bytes, count: bytes.count)
    }

    deinit { ptr.deallocate() }
}

enum TypeRequirement { case any, file, folder }

enum TermKind {
    case text([Needle])
    case wildcard(Needle)
    case regex(NSRegularExpression)
    case ext([Needle])
    case size(ClosedRange<Int64>)
    case date(ClosedRange<Int64>)
    case created(ClosedRange<Int64>)
    /// Files whose (name, size) occurs more than once in the index.
    case dupe
    case any
    case never
}

struct Term {
    var kind: TermKind = .any
    var negate = false
    var matchCase = false
    var matchPath = false
    var wholeWord = false
    var type: TypeRequirement = .any
}

/// A parsed search: AND over groups, OR inside each group.
public final class Query {
    let groups: [[Term]]
    /// Plain words to highlight in the UI.
    public let highlights: [String]
    public let text: String
    public let options: SearchOptions

    init(groups: [[Term]], highlights: [String], text: String, options: SearchOptions) {
        self.groups = groups
        self.highlights = highlights
        self.text = text
        self.options = options
    }

    public var matchesEverything: Bool { groups.isEmpty }

    /// The best term to drive a linear memmem scan over the whole name buffer.
    var driver: (needle: Needle, caseSensitive: Bool)? {
        var best: (Needle, Bool)?
        for g in groups where g.count == 1 {
            let t = g[0]
            guard !t.negate, !t.matchPath, case .text(let ns) = t.kind, ns.count == 1 else { continue }
            if best == nil || ns[0].count > best!.0.count { best = (ns[0], t.matchCase) }
        }
        return best.map { (needle: $0.0, caseSensitive: $0.1) }
    }
}

/// Parses Everything-style search syntax.
public enum QueryParser {
    private enum Token {
        case word(String)
        case or
    }

    public static func parse(_ text: String, options: SearchOptions = SearchOptions()) -> Query {
        var groups: [[Term]] = []
        var highlights: [String] = []

        if options.regex {
            let pattern = text.trimmingCharacters(in: .whitespaces)
            if !pattern.isEmpty {
                var t = Term(matchCase: options.matchCase, matchPath: options.matchPath || pattern.contains("/"))
                if let re = try? NSRegularExpression(pattern: pattern, options: options.matchCase ? [] : [.caseInsensitive]) {
                    t.kind = .regex(re)
                } else {
                    t.kind = .never
                }
                groups.append([t])
            }
        } else {
            var pendingOr = false
            for token in tokenize(text) {
                switch token {
                case .or:
                    pendingOr = true
                case .word(let w):
                    let terms = splitOr(w).compactMap { parseTerm($0, options, &highlights) }
                    guard !terms.isEmpty else { continue }
                    if pendingOr, !groups.isEmpty {
                        groups[groups.count - 1].append(contentsOf: terms)
                    } else {
                        groups.append(terms)
                    }
                    pendingOr = false
                }
            }
        }

        switch options.filter {
        case .all: break
        case .folder: groups.append([Term(type: .folder)])
        default: groups.append([Term(kind: .ext(options.filter.extensions.map { Needle(Array($0.utf8)) }))])
        }
        return Query(groups: groups, highlights: highlights, text: text, options: options)
    }

    private static func tokenize(_ s: String) -> [Token] {
        var tokens: [Token] = []
        var cur = ""
        var inQuote = false
        func flush() {
            if cur == "|" { tokens.append(.or) } else if !cur.isEmpty { tokens.append(.word(cur)) }
            cur = ""
        }
        for ch in s {
            if ch == "\"" { inQuote.toggle(); cur.append(ch); continue }
            if !inQuote && ch.isWhitespace { flush(); continue }
            cur.append(ch)
        }
        flush()
        return tokens
    }

    /// Splits `a|b` on bars outside quotes.
    private static func splitOr(_ w: String) -> [String] {
        var parts: [String] = []
        var cur = ""
        var inQuote = false
        for ch in w {
            if ch == "\"" { inQuote.toggle() }
            if ch == "|" && !inQuote {
                parts.append(cur)
                cur = ""
            } else {
                cur.append(ch)
            }
        }
        parts.append(cur)
        return parts.filter { !$0.isEmpty }
    }

    private static let modifiers = ["case:", "nocase:", "path:", "nopath:", "ww:", "wholeword:", "noww:", "nowholeword:",
                                    "file:", "files:", "folder:", "folders:", "ext:", "regex:", "size:", "dm:", "datemodified:", "dc:", "datecreated:",
                                    "dupe:"]

    private static func parseTerm(_ raw: String, _ o: SearchOptions, _ highlights: inout [String]) -> Term? {
        var t = Term(matchCase: o.matchCase, matchPath: o.matchPath, wholeWord: o.matchWholeWord)
        var s = Substring(raw)
        while s.hasPrefix("!") {
            t.negate.toggle()
            s = s.dropFirst()
        }
        modifierLoop: while true {
            let lower = s.lowercased()
            guard let m = modifiers.first(where: { lower.hasPrefix($0) }) else { break }
            s = s.dropFirst(m.count)
            let value = unquote(String(s))
            switch m {
            case "case:": t.matchCase = true
            case "nocase:": t.matchCase = false
            case "path:": t.matchPath = true
            case "nopath:": t.matchPath = false
            case "ww:", "wholeword:": t.wholeWord = true
            case "noww:", "nowholeword:": t.wholeWord = false
            case "file:", "files:": t.type = .file
            case "folder:", "folders:": t.type = .folder
            case "ext:":
                let exts = value.split(whereSeparator: { $0 == ";" || $0 == "," })
                    .map { Needle(Fold.fold(String($0.drop(while: { $0 == "." })))) }
                t.kind = exts.isEmpty ? .any : .ext(exts)
                return t
            case "regex:":
                guard !value.isEmpty else { return nil }
                let re = try? NSRegularExpression(pattern: value, options: t.matchCase ? [] : [.caseInsensitive])
                t.kind = re.map { .regex($0) } ?? .never
                if value.contains("/") { t.matchPath = true }
                return t
            case "size:":
                t.kind = ValueParser.size(value).map { .size($0) } ?? .never
                return t
            case "dupe:":
                t.kind = .dupe
                return t
            case "dc:", "datecreated:":
                t.kind = ValueParser.date(value).map { .created($0) } ?? .never
                return t
            case "dm:", "datemodified:":
                t.kind = ValueParser.date(value).map { .date($0) } ?? .never
                return t
            default: break
            }
            if s.isEmpty { break modifierLoop }
        }

        let value = unquote(String(s))
        if value.isEmpty {
            return t.type == .any ? nil : t   // bare `file:` / `folder:`
        }
        if value.contains("/") { t.matchPath = true }
        if value.contains("*") || value.contains("?") {
            t.kind = .wildcard(Needle(t.matchCase ? Array(value.precomposedStringWithCanonicalMapping.utf8) : Fold.fold(value)))
        } else if t.matchCase {
            let nfc = Array(value.precomposedStringWithCanonicalMapping.utf8)
            let nfd = Array(value.decomposedStringWithCanonicalMapping.utf8)
            t.kind = .text(nfc == nfd ? [Needle(nfc)] : [Needle(nfc), Needle(nfd)])
        } else {
            t.kind = .text([Needle(Fold.fold(value))])
        }
        if !t.negate, !value.contains("*"), !value.contains("?") {
            highlights.append(t.matchPath ? (value.split(separator: "/").last.map(String.init) ?? value) : value)
        }
        return t
    }

    private static func unquote(_ s: String) -> String { s.replacingOccurrences(of: "\"", with: "") }
}

/// Parses `size:` and `dm:` values.
enum ValueParser {
    static let kb: Int64 = 1024, mb: Int64 = 1024 * 1024, gb: Int64 = 1024 * 1024 * 1024

    static func size(_ v: String) -> ClosedRange<Int64>? {
        let s = v.lowercased()
        switch s {
        case "empty": return 0...0
        case "tiny": return 0...(10 * kb)
        case "small": return (10 * kb + 1)...(100 * kb)
        case "medium": return (100 * kb + 1)...mb
        case "large": return (mb + 1)...(16 * mb)
        case "huge": return (16 * mb + 1)...(128 * mb)
        case "gigantic": return (128 * mb + 1)...Int64.max
        default: break
        }
        return range(s, parse: { bytes($0).map { ($0, $0) } })
    }

    private static func bytes(_ s: String) -> Int64? {
        let units: [(String, Int64)] = [("tb", gb * 1024), ("gb", gb), ("mb", mb), ("kb", kb), ("t", gb * 1024),
                                        ("g", gb), ("m", mb), ("k", kb), ("b", 1)]
        var num = s
        var mult: Int64 = 1
        for (u, m) in units where num.hasSuffix(u) {
            num = String(num.dropLast(u.count))
            mult = m
            break
        }
        guard let d = Double(num.replacingOccurrences(of: ",", with: ".")) else { return nil }
        return Int64(d * Double(mult))
    }

    /// Handles `a..b`, `>x`, `>=x`, `<x`, `<=x`, `=x` and plain `x`. `parse` returns the
    /// (start, end) of the period a single value denotes.
    private static func range(_ s: String, parse: (String) -> (Int64, Int64)?) -> ClosedRange<Int64>? {
        if let r = s.range(of: "..") {
            guard let a = parse(String(s[..<r.lowerBound])), let b = parse(String(s[r.upperBound...])), a.0 <= b.1 else { return nil }
            return a.0...b.1
        }
        for op in [">=", "<=", ">", "<", "="] where s.hasPrefix(op) {
            guard let v = parse(String(s.dropFirst(op.count))) else { return nil }
            switch op {
            case ">=": return v.0...Int64.max
            case "<=": return Int64.min...v.1
            case ">": return v.1 == Int64.max ? nil : (v.1 + 1)...Int64.max
            case "<": return v.0 == Int64.min ? nil : Int64.min...(v.0 - 1)
            default: return v.0...v.1
            }
        }
        guard let v = parse(s) else { return nil }
        return v.0...v.1
    }

    static func date(_ v: String, now: Date = Date()) -> ClosedRange<Int64>? {
        range(v.lowercased(), parse: { period($0, now: now) })
    }

    private static func period(_ s: String, now: Date) -> (Int64, Int64)? {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        cal.firstWeekday = 2
        func span(_ c: Calendar.Component, _ offset: Int) -> (Int64, Int64)? {
            guard let base = cal.date(byAdding: c, value: offset, to: now),
                  let iv = cal.dateInterval(of: c == .day ? .day : c, for: base) else { return nil }
            return (Int64(iv.start.timeIntervalSince1970), Int64(iv.end.timeIntervalSince1970) - 1)
        }
        switch s {
        case "today", "heute": return span(.day, 0)
        case "yesterday", "gestern": return span(.day, -1)
        case "thisweek", "diesewoche": return span(.weekOfYear, 0)
        case "lastweek", "letztewoche": return span(.weekOfYear, -1)
        case "thismonth", "diesermonat": return span(.month, 0)
        case "lastmonth", "letztermonat": return span(.month, -1)
        case "thisyear", "diesesjahr": return span(.year, 0)
        case "lastyear", "letztesjahr": return span(.year, -1)
        default: break
        }
        // yyyy, yyyy-mm, yyyy-mm-dd, dd.mm.yyyy
        var y = 0, m = 0, d = 0
        let dash = s.split(separator: "-").map { Int($0) }
        let dot = s.split(separator: ".").map { Int($0) }
        if dash.allSatisfy({ $0 != nil }), (1...3).contains(dash.count), (dash[0] ?? 0) > 999 {
            y = dash[0]!
            m = dash.count > 1 ? dash[1]! : 0
            d = dash.count > 2 ? dash[2]! : 0
        } else if dot.count == 3, dot.allSatisfy({ $0 != nil }) {
            d = dot[0]!; m = dot[1]!; y = dot[2]!
            if y < 100 { y += 2000 }
        } else {
            return nil
        }
        let comp: Calendar.Component = d > 0 ? .day : (m > 0 ? .month : .year)
        guard let start = cal.date(from: DateComponents(year: y, month: max(m, 1), day: max(d, 1))),
              let iv = cal.dateInterval(of: comp, for: start) else { return nil }
        return (Int64(iv.start.timeIntervalSince1970), Int64(iv.end.timeIntervalSince1970) - 1)
    }
}
