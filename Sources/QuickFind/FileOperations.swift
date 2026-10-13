import AppKit
import QuickFindCore

/// Finder-like file operations (copy, move, rename, new folder). Errors are collected and shown once.
enum FileOperations {
    /// "Neuer Ordner", "Neuer Ordner 2", … — the first name not taken in `folder`.
    static func uniqueName(_ base: String, in folder: String) -> String {
        let fm = FileManager.default
        if !fm.fileExists(atPath: (folder as NSString).appendingPathComponent(base)) { return base }
        let ext = (base as NSString).pathExtension
        let stem = ext.isEmpty ? base : (base as NSString).deletingPathExtension
        var n = 2
        while true {
            let name = ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)"
            if !fm.fileExists(atPath: (folder as NSString).appendingPathComponent(name)) { return name }
            n += 1
        }
    }

    static func newFolder(in folder: String) throws -> String {
        let name = uniqueName(L("Neuer Ordner"), in: folder)
        try FileManager.default.createDirectory(atPath: (folder as NSString).appendingPathComponent(name),
                                                withIntermediateDirectories: false)
        return name
    }

    static func rename(_ path: String, to newName: String) throws -> String {
        guard !newName.isEmpty, !newName.contains("/"), newName != ".", newName != ".." else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        let target = ((path as NSString).deletingLastPathComponent as NSString).appendingPathComponent(newName)
        // A pure case change ("bild" → "Bild") is allowed on case-insensitive volumes.
        if target.lowercased() != path.lowercased(), FileManager.default.fileExists(atPath: target) {
            throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: target])
        }
        try FileManager.default.moveItem(atPath: path, toPath: target)
        return target
    }

    /// Moving is the default on the same volume, copying across volumes (as in the Finder).
    static func shouldMove(_ urls: [URL], to folder: String) -> Bool {
        let dest = (try? URL(fileURLWithPath: folder).resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObject
        return urls.allSatisfy { url in
            let v = (try? url.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObject
            return v != nil && v == dest
        }
    }

    /// Copies or moves `urls` into `folder` in the background; existing names are not overwritten.
    static func transfer(_ urls: [URL], to folder: String, move: Bool, completion: @escaping ([String]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var errors: [String] = []
            let fm = FileManager.default
            for url in urls {
                let target = (folder as NSString).appendingPathComponent(url.lastPathComponent)
                if url.path == target { continue }
                if target.hasPrefix(url.path + "/") {
                    errors.append(L("„%@“ kann nicht in sich selbst bewegt werden.", url.lastPathComponent))
                    continue
                }
                if fm.fileExists(atPath: target) {
                    errors.append(L("„%@“ existiert bereits in diesem Ordner.", url.lastPathComponent))
                    continue
                }
                do {
                    if move { try fm.moveItem(atPath: url.path, toPath: target) } else { try fm.copyItem(atPath: url.path, toPath: target) }
                } catch {
                    errors.append("„\(url.lastPathComponent)“: \(error.localizedDescription)")
                }
            }
            DispatchQueue.main.async { completion(errors) }
        }
    }

    static func showErrors(_ errors: [String], title: String, in window: NSWindow?) {
        guard !errors.isEmpty else { return }
        let a = NSAlert()
        a.messageText = title
        a.informativeText = errors.prefix(10).joined(separator: "\n") + (errors.count > 10 ? "\n" + L("… und %@ weitere", Format.count(errors.count - 10)) : "")
        if let window { a.beginSheetModal(for: window) } else { a.runModal() }
    }

    static func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }
}
