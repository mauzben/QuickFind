import AppKit
import Quartz

protocol ResultsTableActions: AnyObject {
    func openSelection(_ sender: Any?)
    func revealSelection(_ sender: Any?)
    func toggleQuickLook(_ sender: Any?)
    func moveSelectionToTrash(_ sender: Any?)
    func copyFiles(_ sender: Any?)
    func focusSearchField(_ sender: Any?)
    func goUp(_ sender: Any?)
    func renameSelection(_ sender: Any?)
    func pasteFiles(_ sender: Any?)
    func typeIntoSearchField(_ text: String)
    func previewURLs() -> [URL]
}

/// Result list: keyboard handling like Everything/Finder and Quick Look support.
final class ResultsTableView: NSTableView, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    weak var actions: ResultsTableActions?
    private var previewItems: [URL] = []

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        switch Int(event.keyCode) {
        case 36, 76: // Return, Enter
            if mods == .command { actions?.revealSelection(nil) } else if mods.isEmpty { actions?.openSelection(nil) }
            return
        case 49 where mods.isEmpty: // Space
            actions?.toggleQuickLook(nil)
            return
        case 51 where mods == .command, 117 where mods == .command: // ⌘⌫, ⌘⌦
            actions?.moveSelectionToTrash(nil)
            return
        case 120 where mods.isEmpty: // F2 = rename (like Everything)
            actions?.renameSelection(nil)
            return
        case 53: // Escape
            actions?.focusSearchField(nil)
            return
        case 126 where mods == .command: // ⌘↑ parent folder
            actions?.goUp(nil)
            return
        case 125 where mods == .command: // ⌘↓ open
            actions?.openSelection(nil)
            return
        case 126 where mods.isEmpty && selectedRow <= 0: // ↑ in the first row
            actions?.focusSearchField(nil)
            return
        default:
            break
        }
        // Typing while the list has focus continues the search (like Everything).
        if mods.subtracting(.shift).isEmpty, let chars = event.characters, !chars.isEmpty,
           chars.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F && $0.value < 0xF700 }) {
            actions?.typeIntoSearchField(chars)
            return
        }
        super.keyDown(with: event)
    }

    @objc func copy(_ sender: Any?) { actions?.copyFiles(sender) }
    @objc func paste(_ sender: Any?) { actions?.pasteFiles(sender) }

    // MARK: Quick Look

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        previewItems = actions?.previewURLs() ?? []
        panel.dataSource = self
        panel.delegate = self
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
    }

    func refreshPreview() {
        guard QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(), panel.isVisible,
              panel.dataSource === self else { return }
        previewItems = actions?.previewURLs() ?? []
        panel.reloadData()
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { previewItems.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        previewItems[index] as NSURL
    }

    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard let event, event.type == .keyDown else { return false }
        keyDown(with: event)
        return true
    }
}
