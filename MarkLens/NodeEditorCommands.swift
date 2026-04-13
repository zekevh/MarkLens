import AppKit
import Combine
import SwiftUI

@MainActor
final class NodeEditorCommandController: ObservableObject {
    @Published var debugBlocks = false

    private var eventMonitor: Any?

    func installMonitor(manager: BlocksManager) {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { [weak self, weak manager] event in
            guard let self, let manager else { return event }
            return self.handle(event, manager: manager)
        }
    }

    func removeMonitor() {
        guard let eventMonitor else { return }
        NSEvent.removeMonitor(eventMonitor)
        self.eventMonitor = nil
    }

    private func handle(_ event: NSEvent, manager: BlocksManager) -> NSEvent? {
        switch event.type {
        case .leftMouseDown:
            manager.allBlocksSelected = false
            manager.clearCrossBlockSelection()
            return event

        default:
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let character = event.charactersIgnoringModifiers?.lowercased()

            if isDeleteKey(event), handleDelete(manager: manager) {
                return nil
            }

            if isTabKey(event), handleIndent(manager: manager, flags: flags) {
                return nil
            }

            if flags == [.command, .shift] && character == "d" {
                debugBlocks.toggle()
                return nil
            }

            if flags == .command && character == "a" {
                manager.allBlocksSelected = true
                NSApp.keyWindow?.makeFirstResponder(nil)
                return nil
            }

            if flags == .command && character == "c", handleCopy(manager: manager) {
                return nil
            }

            clearSelectionStateIfNeeded(manager: manager)
            return event
        }
    }

    private func isDeleteKey(_ event: NSEvent) -> Bool {
        event.keyCode == 51 || event.keyCode == 117
    }

    private func isTabKey(_ event: NSEvent) -> Bool {
        event.keyCode == 48
    }

    private func handleDelete(manager: BlocksManager) -> Bool {
        if manager.allBlocksSelected {
            manager.deleteAllSelectedBlocks()
            manager.allBlocksSelected = false
            manager.clearCrossBlockSelection()
            return true
        }

        guard (!manager.crossSelectedIDs.isEmpty || manager.crossCursorID != nil),
              let anchorTextView = NSApp.keyWindow?.firstResponder as? BlockNSTextView else {
            return false
        }

        let cursorRanges = crossBlockCursorRanges(manager: manager)
        if manager.deleteCrossBlockSelection(
            anchorID: anchorTextView.blockID,
            anchorRange: anchorTextView.selectedRange(),
            cursorRangeByID: cursorRanges
        ) {
            manager.allBlocksSelected = false
            manager.clearCrossBlockSelection()
            return true
        }

        return false
    }

    private func handleIndent(manager: BlocksManager, flags: NSEvent.ModifierFlags) -> Bool {
        if manager.allBlocksSelected {
            manager.indentBlocks(ids: Set(manager.blocks.map(\.id)), outdent: flags.contains(.shift))
            return true
        }

        guard !manager.crossSelectedIDs.isEmpty || manager.crossCursorID != nil,
              let anchorID = (NSApp.keyWindow?.firstResponder as? BlockNSTextView)?.blockID else {
            return false
        }

        var ids = manager.crossSelectedIDs
        ids.insert(anchorID)
        if let cursorID = manager.crossCursorID {
            ids.insert(cursorID)
        }

        guard ids.count > 1 else { return false }
        manager.indentBlocks(ids: ids, outdent: flags.contains(.shift))
        return true
    }

    private func handleCopy(manager: BlocksManager) -> Bool {
        if manager.allBlocksSelected {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(serializeMarkdownBlocks(manager.blocks), forType: .string)
            return true
        }

        guard !manager.crossSelectedIDs.isEmpty || manager.crossCursorID != nil,
              let anchorTextView = NSApp.keyWindow?.firstResponder as? BlockNSTextView else {
            return false
        }

        let anchorID = anchorTextView.blockID
        let selectedRange = anchorTextView.selectedRange()
        let anchorText = selectedRange.length > 0
            ? (anchorTextView.string as NSString).substring(with: selectedRange)
            : anchorTextView.string
        let registeredTextViews = manager.registry.allRegistered()

        var parts: [String] = []
        for block in manager.blocks {
            if block.id == anchorID {
                parts.append(anchorText)
            } else if manager.crossSelectedIDs.contains(block.id) {
                parts.append(block.content)
            } else if block.id == manager.crossCursorID,
                      let textView = registeredTextViews.first(where: { $0.0 == block.id })?.1 as? BlockNSTextView,
                      let range = textView.crossBlockSelectionRange,
                      range.length > 0 {
                parts.append((textView.string as NSString).substring(with: range))
            }
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(parts.joined(separator: "\n"), forType: .string)
        return true
    }

    private func clearSelectionStateIfNeeded(manager: BlocksManager) {
        if manager.allBlocksSelected {
            manager.allBlocksSelected = false
        }
        if !manager.crossSelectedIDs.isEmpty || manager.crossCursorID != nil {
            manager.clearCrossBlockSelection()
        }
    }

    private func crossBlockCursorRanges(manager: BlocksManager) -> [UUID: NSRange] {
        guard let cursorID = manager.crossCursorID,
              let cursorTextView = manager.registry.allRegistered().first(where: { $0.0 == cursorID })?.1 as? BlockNSTextView,
              let range = cursorTextView.crossBlockSelectionRange,
              range.length > 0 else {
            return [:]
        }

        return [cursorID: range]
    }
}
