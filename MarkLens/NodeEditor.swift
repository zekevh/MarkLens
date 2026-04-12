import SwiftUI
import Combine
import AppKit

struct NodeEditorView: View {
    @Binding var text: String
    var searchText: String
    var fileURL: URL?
    var onTextChange: (String) -> Void
    var onLinkClick: ((String) -> Void)? = nil

    @StateObject private var manager = BlocksManager()
    @Environment(\.undoManager) private var undoManager
    @State private var dropTargetID: UUID? = nil
    @State private var debugBlocks = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array($manager.blocks.enumerated()), id: \.element.id) { index, $block in
                    BlockRowView(
                        block: $block,
                        index: index,
                        searchText: searchText,
                        fileURL: fileURL,
                        isDropTarget: dropTargetID == block.id,
                        debugBlocks: debugBlocks,
                        isBlockSelected: manager.allBlocksSelected,
                        registry: manager.registry,
                        onSplitBlock: { orig, loc, nb, na, cp in manager.splitBlock(id: block.id, originalContent: orig, at: loc, newBefore: nb, newAfter: na, newBlockCursorPos: cp) },
                        onMergeWithPrevious: { trailing in manager.mergeWithPrevious(block.id, trailing: trailing) },
                        onNavigatePrevious: { placement in manager.navigatePrevious(from: block.id, placement: placement) },
                        onNavigateNext: { placement in manager.navigateNext(from: block.id, placement: placement) }
                    )
                    .dropDestination(for: String.self) { items, _ in
                        guard let idString = items.first,
                              let sourceID = UUID(uuidString: idString),
                              sourceID != block.id,
                              let from = manager.blocks.firstIndex(where: { $0.id == sourceID }),
                              let to = manager.blocks.firstIndex(where: { $0.id == block.id })
                        else { return false }
                        withAnimation(.easeInOut(duration: 0.2)) {
                            manager.moveBlock(from: from, to: to > from ? to + 1 : to)
                        }
                        return true
                    } isTargeted: { targeted in
                        dropTargetID = targeted ? block.id : nil
                    }
                }
            }
            .padding(.leading, 8)
            .padding(.trailing, 48)
            .padding(.top, 20)
            .padding(.bottom, 40)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onAppear {
            NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { [weak manager] event in
                guard let manager else { return event }

                switch event.type {
                case .leftMouseDown:
                    manager.allBlocksSelected = false
                    manager.clearCrossBlockSelection()
                    return event

                default:
                    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                    let ch = event.charactersIgnoringModifiers?.lowercased()
                    if event.keyCode == 51 || event.keyCode == 117 {
                        if manager.allBlocksSelected {
                            manager.deleteAllSelectedBlocks()
                            manager.allBlocksSelected = false
                            manager.clearCrossBlockSelection()
                            return nil
                        }

                        if (!manager.crossSelectedIDs.isEmpty || manager.crossCursorID != nil),
                           let anchorTV = NSApp.keyWindow?.firstResponder as? BlockNSTextView {
                            let registered = manager.registry.allRegistered()
                            var cursorRanges: [UUID: NSRange] = [:]
                            if let cursorID = manager.crossCursorID,
                               let cursorTV = registered.first(where: { $0.0 == cursorID })?.1 as? BlockNSTextView,
                               let range = cursorTV.crossBlockSelectionRange,
                               range.length > 0 {
                                cursorRanges[cursorID] = range
                            }
                            if manager.deleteCrossBlockSelection(
                                anchorID: anchorTV.blockID,
                                anchorRange: anchorTV.selectedRange(),
                                cursorRangeByID: cursorRanges
                            ) {
                                manager.allBlocksSelected = false
                                manager.clearCrossBlockSelection()
                                return nil
                            }
                        }
                    }
                    if event.keyCode == 48 {
                        if manager.allBlocksSelected {
                            manager.indentBlocks(
                                ids: Set(manager.blocks.map(\.id)),
                                outdent: flags.contains(.shift)
                            )
                            return nil
                        }

                        if !manager.crossSelectedIDs.isEmpty || manager.crossCursorID != nil,
                           let anchorID = (NSApp.keyWindow?.firstResponder as? BlockNSTextView)?.blockID {
                            var ids = manager.crossSelectedIDs
                            ids.insert(anchorID)
                            if let cursorID = manager.crossCursorID { ids.insert(cursorID) }
                            if ids.count > 1 {
                                manager.indentBlocks(ids: ids, outdent: flags.contains(.shift))
                                return nil
                            }
                        }
                    }
                    if flags == [.command, .shift] && ch == "d" {
                        debugBlocks.toggle()
                        return nil
                    }
                    if flags == .command && ch == "a" {
                        manager.allBlocksSelected = true
                        NSApp.keyWindow?.makeFirstResponder(nil)
                        return nil
                    }
                    if flags == .command && ch == "c" {
                        if manager.allBlocksSelected {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(serializeMarkdownBlocks(manager.blocks), forType: .string)
                            return nil
                        }
                        if !manager.crossSelectedIDs.isEmpty || manager.crossCursorID != nil,
                           let anchorTV = NSApp.keyWindow?.firstResponder as? BlockNSTextView {
                            let anchorID = anchorTV.blockID
                            let sel = anchorTV.selectedRange()
                            let anchorText = sel.length > 0
                                ? (anchorTV.string as NSString).substring(with: sel)
                                : anchorTV.string
                            let registered = manager.registry.allRegistered()
                            var parts: [String] = []
                            for block in manager.blocks {
                                if block.id == anchorID {
                                    parts.append(anchorText)
                                } else if manager.crossSelectedIDs.contains(block.id) {
                                    parts.append(block.content)
                                } else if block.id == manager.crossCursorID,
                                          let tv = registered.first(where: { $0.0 == block.id })?.1 as? BlockNSTextView,
                                          let range = tv.crossBlockSelectionRange, range.length > 0 {
                                    parts.append((tv.string as NSString).substring(with: range))
                                }
                            }
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(parts.joined(separator: "\n"), forType: .string)
                            return nil
                        }
                    }
                    if manager.allBlocksSelected { manager.allBlocksSelected = false }
                    if !manager.crossSelectedIDs.isEmpty || manager.crossCursorID != nil {
                        manager.clearCrossBlockSelection()
                    }
                    return event
                }
            }
        }
        .onAppear {
            manager.undoManager = undoManager
            manager.load(from: text)
            manager.registry.onLinkClick = onLinkClick
            manager.registry.onCrossBlockDrag = { [weak manager] anchorID, mouseY in
                guard let manager else { return }
                let registered = manager.registry.allRegistered()
                guard let anchorTV = registered.first(where: { $0.0 == anchorID })?.1 else { return }
                let anchorFrame = windowFrame(of: anchorTV)

                guard mouseY < anchorFrame.minY || mouseY > anchorFrame.maxY else {
                    manager.clearCrossBlockSelection()
                    return
                }
                let goingDown = mouseY < anchorFrame.minY
                var crossIDs = Set<UUID>()
                var newCursorID: UUID? = nil

                for (id, tv) in registered {
                    guard id != anchorID else { continue }
                    let blockTV = tv as? BlockNSTextView
                    let f = windowFrame(of: tv)
                    let totalLength = tv.string.count

                    if goingDown {
                        guard f.maxY <= anchorFrame.minY else {
                            blockTV?.crossBlockSelectionRange = nil
                            continue
                        }
                        if mouseY >= f.minY && mouseY <= f.maxY {
                            let end = min(crossBlockCharIndex(in: tv, windowY: mouseY) + 1, totalLength)
                            blockTV?.crossBlockSelectionRange = NSRange(location: 0, length: end)
                            newCursorID = id
                        } else if f.maxY >= mouseY {
                            blockTV?.crossBlockSelectionRange = NSRange(location: 0, length: totalLength)
                            crossIDs.insert(id)
                        } else {
                            blockTV?.crossBlockSelectionRange = nil
                        }
                    } else {
                        guard f.minY >= anchorFrame.maxY else {
                            blockTV?.crossBlockSelectionRange = nil
                            continue
                        }
                        if mouseY >= f.minY && mouseY <= f.maxY {
                            let start = crossBlockCharIndex(in: tv, windowY: mouseY)
                            blockTV?.crossBlockSelectionRange = NSRange(location: start, length: totalLength - start)
                            newCursorID = id
                        } else if f.minY <= mouseY {
                            blockTV?.crossBlockSelectionRange = NSRange(location: 0, length: totalLength)
                            crossIDs.insert(id)
                        } else {
                            blockTV?.crossBlockSelectionRange = nil
                        }
                    }
                }
                manager.crossSelectedIDs = crossIDs
                manager.crossCursorID = newCursorID
            }
        }
        .onChange(of: undoManager) { _, um in
            manager.undoManager = um
        }
        .onChange(of: manager.blocks) { oldBlocks, _ in
            let serialized = manager.synchronizeDocument(from: oldBlocks)
            guard serialized != text else { return }
            text = serialized
            onTextChange(serialized)
        }
        .onChange(of: text) { _, newText in
            let serialized = serializeMarkdownBlocks(manager.blocks)
            guard newText != serialized else { return }
            manager.load(from: newText)
        }
    }
}
