import SwiftUI
import Combine
import AppKit

// MARK: - CursorPlacement

enum CursorPlacement {
    case start
    case end
    case position(Int)
}

// MARK: - BlockRegistry
// Holds weak refs to each block's NSTextView so we can focus them cross-block.
// Supports a pending focus: if the target block isn't rendered yet (e.g. just inserted),
// the focus is deferred and applied the moment the text view registers itself.

@MainActor
final class BlockRegistry: ObservableObject {
    private final class WeakRef { weak var value: NSTextView? }
    private var store: [UUID: WeakRef] = [:]
    private var pendingID: UUID?
    private var pendingPlacement: CursorPlacement = .start

    func allRegistered() -> [(UUID, NSTextView)] {
        store.compactMap { id, ref in ref.value.map { (id, $0) } }
    }

    /// Called by each BlockNSTextView.mouseDragged — routes cross-block detection to NodeEditorView.
    var onCrossBlockDrag: ((UUID, CGFloat) -> Void)?
    /// Called when the user clicks a markdown link. Receives the raw URL/path string from the syntax.
    var onLinkClick: ((String) -> Void)?

    func register(_ tv: NSTextView, id: UUID) {
        let ref = WeakRef(); ref.value = tv
        store[id] = ref
        if pendingID == id {
            applyFocus(to: tv, placement: pendingPlacement)
            pendingID = nil
        }
    }

    func focus(_ id: UUID, at placement: CursorPlacement) {
        if let tv = store[id]?.value, tv.window != nil {
            applyFocus(to: tv, placement: placement)
        } else {
            pendingID = id
            pendingPlacement = placement
        }
    }

    private func applyFocus(to tv: NSTextView, placement: CursorPlacement) {
        if tv.window != nil {
            doFocus(tv, placement: placement)
        } else {
            // Text view not yet in window (e.g. freshly inserted block) — defer one run loop
            Task { @MainActor [weak tv] in
                guard let tv else { return }
                self.doFocus(tv, placement: placement)
            }
        }
    }

    private func doFocus(_ tv: NSTextView, placement: CursorPlacement) {
        tv.window?.makeFirstResponder(tv)
        let pos: Int
        switch placement {
        case .start:           pos = 0
        case .end:             pos = tv.string.count
        case .position(let p): pos = min(max(p, 0), tv.string.count)
        }
        tv.setSelectedRange(NSRange(location: pos, length: 0))
        Task { scrollCursorToVisible(in: tv) }
    }
}

// MARK: - BlocksManager
// Owns the blocks array and routes every structural mutation through the window's
// UndoManager so Cmd+Z interleaves block operations with within-block typing.

@MainActor
final class BlocksManager: ObservableObject {
    private static let indentUnit = "    "

    @Published var blocks: [MarkdownBlock] = []
    @Published var allBlocksSelected = false
    @Published var crossSelectedIDs: Set<UUID> = []
    // ID of the block currently under the cursor during a cross-block drag.
    // Used for copy and to drive crossBlockSelectionRange on its NSTextView.
    @Published var crossCursorID: UUID? = nil
    let registry = BlockRegistry()

    // Injected from SwiftUI environment — same instance NSTextView uses for within-block undo.
    var undoManager: UndoManager?

    func load(from text: String) {
        let parsed = parseMarkdownBlocks(text)
        blocks = parsed.isEmpty ? [MarkdownBlock(content: "")] : parsed
    }

    func syncBlockKinds(from previous: [MarkdownBlock]) {
        guard !blocks.isEmpty else { return }

        let idsAreStable =
            previous.count == blocks.count &&
            zip(previous, blocks).allSatisfy { $0.id == $1.id }

        guard idsAreStable else {
            reclassifyBlocks(at: Array(blocks.indices))
            return
        }

        let dirtyIndexes = previous.indices.filter { index in
            previous[index].content != blocks[index].content || previous[index].kind != blocks[index].kind
        }
        reclassifyBlocks(at: dirtyIndexes)
    }

    /// Clears all cross-block selection state and wipes crossBlockSelectionRange
    /// from every registered NSTextView so highlights don't linger.
    func clearCrossBlockSelection() {
        crossSelectedIDs = []
        crossCursorID = nil
        for (_, tv) in registry.allRegistered() {
            (tv as? BlockNSTextView)?.crossBlockSelectionRange = nil
        }
    }

    private func reclassifyBlocks(at indexes: [Int]) {
        for index in Set(indexes).sorted() where blocks.indices.contains(index) {
            let classified = MarkdownEngine.classifyBlockSource(
                blocks[index].content,
                isFirstBlock: index == 0
            )
            if blocks[index].kind != classified {
                blocks[index].kind = classified
            }
        }
    }

    // MARK: Split (Enter)

    func splitBlock(id: UUID, originalContent: String, at loc: Int, newBefore: String? = nil, newAfter: String? = nil, newBlockCursorPos: Int? = nil) {
        guard let idx = blocks.firstIndex(where: { $0.id == id }) else { return }
        // Capture undo manager before mutating so the closure never touches NSApp.
        let um = undoManager
        let before = newBefore ?? String(originalContent.prefix(loc))
        let after  = newAfter  ?? String(originalContent.suffix(originalContent.count - loc))
        let newBlock = MarkdownBlock(content: after)
        let sourceID = id
        let newID    = newBlock.id

        um?.registerUndo(withTarget: self) { mgr in
            MainActor.assumeIsolated {
                guard let ni = mgr.blocks.firstIndex(where: { $0.id == newID }) else { return }
                mgr.blocks.remove(at: ni)
                if let si = mgr.blocks.firstIndex(where: { $0.id == sourceID }) {
                    mgr.blocks[si].content = originalContent
                }
                mgr.registry.focus(sourceID, at: .position(loc))
            }
        }
        um?.setActionName("Split Block")

        blocks[idx].content = before
        blocks.insert(newBlock, at: idx + 1)
        let placement: CursorPlacement = newBlockCursorPos.map { .position($0) } ?? .start
        registry.focus(newID, at: placement)
    }

    // MARK: Merge (Backspace at block start)

    func mergeWithPrevious(_ id: UUID, trailing: String) {
        guard let idx = blocks.firstIndex(where: { $0.id == id }), idx > 0 else { return }
        let um = undoManager
        let prevIdx             = idx - 1
        let prevID              = blocks[prevIdx].id
        let originalPrevContent = blocks[prevIdx].content
        let currentID           = blocks[idx].id
        let junctionPos         = originalPrevContent.count + (originalPrevContent.isEmpty ? 0 : 1)

        um?.registerUndo(withTarget: self) { mgr in
            MainActor.assumeIsolated {
                guard let pi = mgr.blocks.firstIndex(where: { $0.id == prevID }) else { return }
                mgr.blocks[pi].content = originalPrevContent
                let restored = MarkdownBlock(id: currentID, content: trailing)
                mgr.blocks.insert(restored, at: pi + 1)
                mgr.registry.focus(currentID, at: .start)
            }
        }
        um?.setActionName("Merge Blocks")

        if !trailing.isEmpty {
            let sep = blocks[prevIdx].content.isEmpty ? "" : "\n"
            blocks[prevIdx].content += sep + trailing
        }
        blocks.remove(at: idx)
        registry.focus(prevID, at: .position(junctionPos))
    }

    // MARK: Move (drag reorder)

    func moveBlock(from: Int, to: Int) {
        // After move(fromOffsets:[f], toOffset:t):
        //   t > f  →  element lands at t-1   →  undo: from=t-1, to=f
        //   t <= f →  element lands at t     →  undo: from=t,   to=f+1
        let um = undoManager
        let undoFrom = to > from ? to - 1 : to
        let undoTo   = to > from ? from   : from + 1

        um?.registerUndo(withTarget: self) { mgr in
            MainActor.assumeIsolated {
                mgr.blocks.move(fromOffsets: IndexSet(integer: undoFrom), toOffset: undoTo)
            }
        }
        um?.setActionName("Move Block")

        blocks.move(fromOffsets: IndexSet(integer: from), toOffset: to)
    }

    // MARK: Multi-block indentation

    func indentBlocks(ids: Set<UUID>, outdent: Bool) {
        guard !ids.isEmpty else { return }

        let originalContents = Dictionary(uniqueKeysWithValues: blocks.compactMap { block in
            ids.contains(block.id) ? (block.id, block.content) : nil
        })
        guard !originalContents.isEmpty else { return }

        let um = undoManager
        um?.registerUndo(withTarget: self) { mgr in
            MainActor.assumeIsolated {
                for index in mgr.blocks.indices {
                    guard let original = originalContents[mgr.blocks[index].id] else { continue }
                    mgr.blocks[index].content = original
                }
            }
        }
        um?.setActionName(outdent ? "Outdent Blocks" : "Indent Blocks")

        for index in blocks.indices where ids.contains(blocks[index].id) {
            blocks[index].content = outdent
                ? Self.outdentedBlockContent(blocks[index].content)
                : Self.indentedBlockContent(blocks[index].content)
        }
    }

    private static func indentedBlockContent(_ content: String) -> String {
        content
            .components(separatedBy: "\n")
            .map { indentUnit + $0 }
            .joined(separator: "\n")
    }

    private static func outdentedBlockContent(_ content: String) -> String {
        content
            .components(separatedBy: "\n")
            .map { line in
                if line.hasPrefix("\t") { return String(line.dropFirst()) }
                let removed = min(line.prefix { $0 == " " }.count, indentUnit.count)
                return String(line.dropFirst(removed))
            }
            .joined(separator: "\n")
    }

    // MARK: Multi-block deletion

    func deleteAllSelectedBlocks() {
        let originalBlocks = blocks
        let originalFocusID = blocks.first?.id

        undoManager?.registerUndo(withTarget: self) { mgr in
            MainActor.assumeIsolated {
                mgr.blocks = originalBlocks
                if let originalFocusID {
                    mgr.registry.focus(originalFocusID, at: .start)
                }
            }
        }
        undoManager?.setActionName("Delete Selection")

        let replacement = MarkdownBlock(content: "")
        blocks = [replacement]
        registry.focus(replacement.id, at: .start)
    }

    @discardableResult
    func deleteCrossBlockSelection(anchorID: UUID, anchorRange: NSRange, cursorRangeByID: [UUID: NSRange]) -> Bool {
        guard let anchorIndex = blocks.firstIndex(where: { $0.id == anchorID }) else { return false }

        let involvedIDs = Set([anchorID] + Array(crossSelectedIDs) + Array(cursorRangeByID.keys))
        guard involvedIDs.count > 1 || anchorRange.length > 0 else { return false }

        let originalBlocks = blocks
        let originalFocusID = anchorID
        let safeAnchorRange = clampedRange(anchorRange, for: blocks[anchorIndex].content)

        undoManager?.registerUndo(withTarget: self) { mgr in
            MainActor.assumeIsolated {
                mgr.blocks = originalBlocks
                mgr.registry.focus(originalFocusID, at: .position(min(safeAnchorRange.location, mgr.blocks.first(where: { $0.id == originalFocusID })?.content.count ?? 0)))
            }
        }
        undoManager?.setActionName("Delete Selection")

        // Single block selection can occur if the anchor has a native range but the
        // cross-block state is still populated from the drag gesture teardown.
        if cursorRangeByID.isEmpty && crossSelectedIDs.isEmpty {
            let ns = blocks[anchorIndex].content as NSString
            blocks[anchorIndex].content = ns.replacingCharacters(in: safeAnchorRange, with: "")
            registry.focus(anchorID, at: .position(safeAnchorRange.location))
            return true
        }

        let cursorID = cursorRangeByID.keys.compactMap { id in
            blocks.contains(where: { $0.id == id }) ? id : nil
        }.min { lhs, rhs in
            (blocks.firstIndex(where: { $0.id == lhs }) ?? 0) < (blocks.firstIndex(where: { $0.id == rhs }) ?? 0)
        }

        guard let cursorID,
              let cursorIndex = blocks.firstIndex(where: { $0.id == cursorID }),
              let rawCursorRange = cursorRangeByID[cursorID] else {
            let ns = blocks[anchorIndex].content as NSString
            blocks[anchorIndex].content = ns.replacingCharacters(in: safeAnchorRange, with: "")
            for id in crossSelectedIDs {
                if let index = blocks.firstIndex(where: { $0.id == id }) {
                    blocks.remove(at: index)
                }
            }
            if blocks.isEmpty {
                let replacement = MarkdownBlock(content: "")
                blocks = [replacement]
                registry.focus(replacement.id, at: .start)
            } else {
                registry.focus(anchorID, at: .position(min(safeAnchorRange.location, blocks[anchorIndex].content.count)))
            }
            return true
        }

        let safeCursorRange = clampedRange(rawCursorRange, for: blocks[cursorIndex].content)
        let startIndex: Int
        let endIndex: Int
        let startRange: NSRange
        let endRange: NSRange

        if anchorIndex <= cursorIndex {
            startIndex = anchorIndex
            endIndex = cursorIndex
            startRange = safeAnchorRange
            endRange = safeCursorRange
        } else {
            startIndex = cursorIndex
            endIndex = anchorIndex
            startRange = safeCursorRange
            endRange = safeAnchorRange
        }

        let startContent = blocks[startIndex].content as NSString
        let endContent = blocks[endIndex].content as NSString
        let prefix = startContent.substring(to: startRange.location)
        let suffixStart = endRange.location + endRange.length
        let suffix = endContent.substring(from: min(suffixStart, endContent.length))
        let merged = prefix + suffix

        blocks[startIndex].content = merged
        if endIndex > startIndex {
            blocks.removeSubrange((startIndex + 1)...endIndex)
        }

        let focusID = blocks[startIndex].id
        registry.focus(focusID, at: .position(prefix.count))
        return true
    }

    private func clampedRange(_ range: NSRange, for content: String) -> NSRange {
        let length = (content as NSString).length
        let location = min(max(0, range.location), length)
        let maxLength = max(0, length - location)
        return NSRange(location: location, length: min(max(0, range.length), maxLength))
    }

    // MARK: Navigation (no undo needed)

    func navigatePrevious(from id: UUID, placement: CursorPlacement) {
        guard let idx = blocks.firstIndex(where: { $0.id == id }), idx > 0 else { return }
        registry.focus(blocks[idx - 1].id, at: placement)
    }

    func navigateNext(from id: UUID, placement: CursorPlacement) {
        guard let idx = blocks.firstIndex(where: { $0.id == id }), idx < blocks.count - 1 else { return }
        registry.focus(blocks[idx + 1].id, at: placement)
    }
}

// MARK: - NodeEditorView

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
                        onSplitBlock:        { orig, loc, nb, na, cp in manager.splitBlock(id: block.id, originalContent: orig, at: loc, newBefore: nb, newAfter: na, newBlockCursorPos: cp) },
                        onMergeWithPrevious: { trailing   in manager.mergeWithPrevious(block.id, trailing: trailing) },
                        onNavigatePrevious:  { placement  in manager.navigatePrevious(from: block.id, placement: placement) },
                        onNavigateNext:      { placement  in manager.navigateNext(from: block.id, placement: placement) }
                    )
                    .dropDestination(for: String.self) { items, _ in
                        guard let idString = items.first,
                              let sourceID = UUID(uuidString: idString),
                              sourceID != block.id,
                              let from = manager.blocks.firstIndex(where: { $0.id == sourceID }),
                              let to   = manager.blocks.firstIndex(where: { $0.id == block.id })
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

                default: // .keyDown
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
                    // Cmd+Shift+D: debug overlay
                    if flags == [.command, .shift] && ch == "d" {
                        debugBlocks.toggle()
                        return nil
                    }
                    // Cmd+A: select all blocks immediately
                    if flags == .command && ch == "a" {
                        manager.allBlocksSelected = true
                        NSApp.keyWindow?.makeFirstResponder(nil)
                        return nil
                    }
                    // Cmd+C: copy selected content in document order
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
                    // Any other key dismisses the cross-block / all-blocks selection
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
            // Route mouseDragged events from each BlockNSTextView to the cross-block
            // detection logic here. NSTextView's internal drag-select loop calls
            // mouseDragged(with:) directly, which is why this is more reliable than
            // an NSEvent local monitor (which misses events consumed by nextEvent()).
            manager.registry.onCrossBlockDrag = { [weak manager] anchorID, mouseY in
                guard let manager else { return }
                let registered = manager.registry.allRegistered()
                guard let anchorTV = registered.first(where: { $0.0 == anchorID })?.1 else { return }
                let anchorFrame = windowFrame(of: anchorTV)

                // Mouse returned inside anchor bounds — cancel cross-block highlight
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
                            blockTV?.crossBlockSelectionRange = nil; continue
                        }
                        if mouseY >= f.minY && mouseY <= f.maxY {
                            // Cursor block — partial selection from char 0 to cursor
                            let end = min(crossBlockCharIndex(in: tv, windowY: mouseY) + 1, totalLength)
                            blockTV?.crossBlockSelectionRange = NSRange(location: 0, length: end)
                            newCursorID = id
                        } else if f.maxY >= mouseY {
                            // Fully between anchor and cursor
                            blockTV?.crossBlockSelectionRange = NSRange(location: 0, length: totalLength)
                            crossIDs.insert(id)
                        } else {
                            blockTV?.crossBlockSelectionRange = nil
                        }
                    } else {
                        guard f.minY >= anchorFrame.maxY else {
                            blockTV?.crossBlockSelectionRange = nil; continue
                        }
                        if mouseY >= f.minY && mouseY <= f.maxY {
                            // Cursor block — partial selection from cursor to end
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
            manager.syncBlockKinds(from: oldBlocks)
            let serialized = serializeMarkdownBlocks(manager.blocks)
            guard serialized != text else { return }
            // Keep documentText in sync so reloadIfChangedOnDisk can correctly
            // detect whether there are real unsaved edits vs. a clean state.
            text = serialized
            onTextChange(serialized)
        }
        .onChange(of: text) { _, newText in
            // Re-parse when the text is updated externally (e.g. silent reload or
            // "Use Disk Version" — both set documentText without recreating this view).
            let serialized = serializeMarkdownBlocks(manager.blocks)
            guard newText != serialized else { return }
            manager.load(from: newText)
        }
    }
}

// MARK: - DragStrip

private struct DragStrip: View {
    let blockID: UUID
    let height: CGFloat
    @State private var hovered = false

    var body: some View {
        Color.clear
            .frame(width: 40, height: height)
            .overlay {
                RoundedRectangle(cornerRadius: 99)
                    .fill(Color.secondary.opacity(hovered ? 0.12 : 0))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .overlay {
                        Image(systemName: "circle.grid.2x3.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.secondary.opacity(hovered ? 0.5 : 0))
                    }
                    .animation(.easeInOut(duration: 0.15), value: hovered)
            }
            .contentShape(Rectangle())
            .draggable(blockID.uuidString)
            .onHover { isHovered in
                hovered = isHovered
                if isHovered { NSCursor.openHand.set() }
                else { NSCursor.arrow.set() }
            }
    }
}

// MARK: - BlockRowView

struct BlockRowView: View {
    @Binding var block: MarkdownBlock
    var index: Int
    var searchText: String
    var fileURL: URL?
    var isDropTarget: Bool
    var debugBlocks: Bool
    var isBlockSelected: Bool
    var registry: BlockRegistry
    var onSplitBlock: (String, Int, String?, String?, Int?) -> Void
    var onMergeWithPrevious: (String) -> Void
    var onNavigatePrevious: (CursorPlacement) -> Void
    var onNavigateNext: (CursorPlacement) -> Void

    @State private var height: CGFloat = 32
    @State private var isFrontMatterExpanded = false
    @State private var isHTMLEditing = false

    private var blockPadding: (top: CGFloat, bottom: CGFloat) {
        if block.kind == .frontMatter { return (top: 0, bottom: 18) }
        let t = block.content.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("# ")      { return (top: 40, bottom: 8) }
        if t.hasPrefix("## ")     { return (top: 32, bottom: 6) }
        if t.hasPrefix("### ")    { return (top: 24, bottom: 4) }
        if t.hasPrefix("####")    { return (top: 20, bottom: 4) }
        return (top: 0, bottom: 0)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            DragStrip(blockID: block.id, height: max(visibleEditorHeight, previewHeight + 24))

            VStack(alignment: .leading, spacing: 10) {
                if block.kind == .frontMatter {
                    VStack(alignment: .leading, spacing: 0) {
                        Button {
                            withAnimation(.easeInOut(duration: 0.24)) {
                                isFrontMatterExpanded.toggle()
                            }
                        } label: {
                            HStack(alignment: .center, spacing: 0) {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .rotationEffect(.degrees(isFrontMatterExpanded ? 90 : 0))
                                    .frame(width: 18, height: 18)

                            FrontMatterSummaryLabel(content: block.content)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)

                        if isFrontMatterExpanded {
                            BlockEditorView(
                                blockID: block.id,
                                blockKind: block.kind,
                                content: $block.content,
                                searchText: searchText,
                                registry: registry,
                                onHeightChange: { h in height = h },
                                onSplitBlock: onSplitBlock,
                                onMergeWithPrevious: onMergeWithPrevious,
                                onNavigatePrevious: onNavigatePrevious,
                                onNavigateNext: onNavigateNext
                            )
                            .frame(height: max(height, 24))
                            .padding(.horizontal, 14)
                            .padding(.bottom, 12)
                            .transition(.opacity)
                        }
                    }
                    .background {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color(NSColor.controlBackgroundColor).opacity(0.72))
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
                    }
                } else {
                    if let imageInfo = imageInfo,
                       let resolvedURL = MarkdownEngine.resolveImageURL(imageInfo.destination, relativeTo: fileURL) {
                        ImageBlockPreview(url: resolvedURL, alt: imageInfo.alt)
                    }

                    if let htmlSource = htmlSource {
                        if isHTMLEditing {
                            HStack {
                                Text("HTML Source")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button("Done") {
                                    withAnimation(.easeInOut(duration: 0.16)) {
                                        isHTMLEditing = false
                                    }
                                }
                                .buttonStyle(.borderless)
                                .font(.caption)
                            }

                            BlockEditorView(
                                blockID: block.id,
                                blockKind: block.kind,
                                content: $block.content,
                                searchText: searchText,
                                registry: registry,
                                onHeightChange: { h in height = h },
                                onSplitBlock: onSplitBlock,
                                onMergeWithPrevious: onMergeWithPrevious,
                                onNavigatePrevious: onNavigatePrevious,
                                onNavigateNext: onNavigateNext
                            )
                            .frame(height: max(height, 96))
                        } else {
                            HTMLBlockPreview(html: htmlSource) {
                                withAnimation(.easeInOut(duration: 0.16)) {
                                    isHTMLEditing = true
                                }
                            }
                        }
                    } else if let codeFenceLanguage = codeFenceLanguage {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(codeFenceLanguage)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Spacer()
                            }
                            .padding(.horizontal, 2)

                            BlockEditorView(
                                blockID: block.id,
                                blockKind: block.kind,
                                content: $block.content,
                                searchText: searchText,
                                registry: registry,
                                onHeightChange: { h in height = h },
                                onSplitBlock: onSplitBlock,
                                onMergeWithPrevious: onMergeWithPrevious,
                                onNavigatePrevious: onNavigatePrevious,
                                onNavigateNext: onNavigateNext
                            )
                            .frame(height: max(height, 96))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 12)
                            .background {
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(Color.secondary.opacity(0.08))
                            }
                            .overlay {
                                RoundedRectangle(cornerRadius: 10)
                                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                            }
                        }
                        .padding(.vertical, 10)
                    } else {
                        BlockEditorView(
                            blockID: block.id,
                            blockKind: block.kind,
                            content: $block.content,
                            searchText: searchText,
                            registry: registry,
                            onHeightChange: { h in height = h },
                            onSplitBlock: onSplitBlock,
                            onMergeWithPrevious: onMergeWithPrevious,
                            onNavigatePrevious: onNavigatePrevious,
                            onNavigateNext: onNavigateNext
                        )
                        .frame(height: max(height, 24))
                    }
                }
            }
        }
        .overlay(alignment: .top) {
            // Drop insertion indicator
            if isDropTarget {
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(height: 2)
            }
        }
        .overlay {
            if isBlockSelected {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.accentColor.opacity(0.15))
                    .allowsHitTesting(false)
            }
        }
        .overlay {
            if debugBlocks {
                BlockDebugOverlay(block: block, index: index)
            }
        }
        .padding(.top, index == 0 ? 0 : blockPadding.top)
        .padding(.bottom, blockPadding.bottom)
    }

    private var imageInfo: ImageInfo? {
        if case let .imageBlock(info) = block.kind { return info }
        return nil
    }

    private var htmlSource: String? {
        if block.kind == .htmlBlock { return block.content }
        return nil
    }

    private var codeFenceLanguage: String? {
        guard case let .codeFence(language) = block.kind else { return nil }
        return language?.isEmpty == false ? language?.uppercased() : "Code"
    }

    private var previewHeight: CGFloat {
        if imageInfo != nil { return 220 }
        if htmlSource != nil && !isHTMLEditing { return 180 }
        return 0
    }

    private var visibleEditorHeight: CGFloat {
        if block.kind == .frontMatter && !isFrontMatterExpanded { return 28 }
        if htmlSource != nil && !isHTMLEditing { return 0 }
        return max(height, 24)
    }
}

private struct FrontMatterSummaryLabel: View {
    let content: String

    private var title: String? {
        frontMatterScalarValue(for: "title")
    }

    private var tags: [String] {
        frontMatterListValue(for: "tags")
    }

    var body: some View {
        HStack(spacing: 10) {
            Text("Front Matter")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            if let title, !title.isEmpty {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }

            ForEach(tags, id: \.self) { tag in
                Text(tag)
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Color.accentColor.opacity(0.12), in: Capsule())
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func frontMatterScalarValue(for key: String) -> String? {
        let normalized = content.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        let prefix = "\(key):"

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(prefix) else { continue }
            let value = trimmed.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }
        return nil
    }

    private func frontMatterListValue(for key: String) -> [String] {
        let normalized = content.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        let listHeader = "\(key):"
        guard let startIndex = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == listHeader }) else {
            return []
        }

        var result: [String] = []
        for line in lines.dropFirst(startIndex + 1) {
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            guard line.hasPrefix("  - ") || line.hasPrefix("\t- ") else { break }
            let value = line.trimmingCharacters(in: .whitespaces).dropFirst(2).trimmingCharacters(in: .whitespaces)
            if !value.isEmpty { result.append(value) }
        }
        return result
    }
}

private struct ImageBlockPreview: View {
    let url: URL
    let alt: String

    var body: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case let .success(image):
                image
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: 220, alignment: .leading)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            case .failure:
                previewFallback(systemImage: "photo.badge.exclamationmark", text: alt.isEmpty ? url.lastPathComponent : alt)
            case .empty:
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.secondary.opacity(0.08))
                    .frame(maxWidth: .infinity, minHeight: 120, maxHeight: 220)
                    .overlay(ProgressView())
            @unknown default:
                previewFallback(systemImage: "photo", text: alt.isEmpty ? url.lastPathComponent : alt)
            }
        }
    }

    @ViewBuilder
    private func previewFallback(systemImage: String, text: String) -> some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(Color.secondary.opacity(0.08))
            .frame(maxWidth: .infinity, minHeight: 120, maxHeight: 220)
            .overlay {
                VStack(spacing: 8) {
                    Image(systemName: systemImage)
                        .font(.system(size: 24))
                        .foregroundStyle(.secondary)
                    Text(text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 12)
                }
            }
    }
}

private struct HTMLBlockPreview: View {
    let html: String
    let onEdit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("HTML Preview")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Edit HTML", action: onEdit)
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
            .padding(.horizontal, 2)

            HTMLPreviewTextView(html: html)
                .frame(maxWidth: .infinity, minHeight: 120, maxHeight: 180)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                }
                .contentShape(RoundedRectangle(cornerRadius: 10))
                .onTapGesture(perform: onEdit)
        }
        .padding(.vertical, 10)
    }
}

private struct HTMLPreviewTextView: NSViewRepresentable {
    let html: String

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 14, height: 12)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        textView.textStorage?.setAttributedString(renderedHTML)
    }

    private var renderedHTML: NSAttributedString {
        let wrapped = """
        <div style="font-family: -apple-system, BlinkMacSystemFont, 'SF Pro Text', sans-serif; font-size: 14px; line-height: 1.5; color: #f2f2f7;">
        \(html)
        </div>
        """

        guard let data = wrapped.data(using: .utf8),
              let attr = try? NSMutableAttributedString(
                data: data,
                options: [
                    .documentType: NSAttributedString.DocumentType.html,
                    .characterEncoding: String.Encoding.utf8.rawValue
                ],
                documentAttributes: nil
              ) else {
            return NSAttributedString(string: html)
        }

        let fullRange = NSRange(location: 0, length: attr.length)
        attr.addAttributes([
            .foregroundColor: NSColor.labelColor,
            .font: NSFont.systemFont(ofSize: 14)
        ], range: fullRange)
        return attr
    }
}

// MARK: - Debug Overlay

private struct BlockDebugOverlay: View {
    let block: MarkdownBlock
    let index: Int

    var blockType: (label: String, color: Color) {
        if block.kind == .frontMatter { return ("yaml", .brown) }
        let t = block.content.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("######") { return ("H6", .purple) }
        if t.hasPrefix("#####")  { return ("H5", .purple) }
        if t.hasPrefix("####")   { return ("H4", .purple) }
        if t.hasPrefix("###")    { return ("H3", .purple) }
        if t.hasPrefix("##")     { return ("H2", .purple) }
        if t.hasPrefix("# ")     { return ("H1", .purple) }
        if t.hasPrefix("```")    { return ("code", .orange) }
        if t.hasPrefix("|")      { return ("table", .teal) }
        if t.hasPrefix(">")      { return ("quote", .indigo) }
        if t.hasPrefix("- ") || t.hasPrefix("* ") || t.hasPrefix("+ ") { return ("ul", .green) }
        if t.first?.isNumber == true && t.dropFirst().hasPrefix(". ") { return ("ol", .green) }
        if t == "---" || t == "***" || t == "___" { return ("hr", .gray) }
        if t.isEmpty             { return ("empty", .gray) }
        return ("¶", .blue)
    }

    var body: some View {
        let (label, color) = blockType
        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: 3)
                .stroke(color.opacity(0.6), lineWidth: 1)
            HStack(spacing: 3) {
                Text("#\(index)")
                    .monospacedDigit()
                Text(label)
            }
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .foregroundStyle(.white)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(color.opacity(0.8), in: RoundedRectangle(cornerRadius: 3))
            .padding(2)
        }
    }
}

// MARK: - Scroll helper

@MainActor
private func scrollCursorToVisible(in textView: NSTextView) {
    guard let lm = textView.layoutManager,
          let tc = textView.textContainer else { return }
    let charRange = textView.selectedRange()
    guard charRange.location != NSNotFound else { return }
    lm.ensureLayout(for: tc)
    let glyphCount = lm.numberOfGlyphs
    guard glyphCount > 0 else { return }
    let loc = min(charRange.location, textView.string.count)
    let glyphIndex = loc < textView.string.count ? lm.glyphIndexForCharacter(at: loc) : glyphCount - 1
    var lineRect = lm.lineFragmentRect(forGlyphAt: min(glyphIndex, glyphCount - 1), effectiveRange: nil)
    lineRect = lineRect.offsetBy(dx: textView.textContainerInset.width,
                                 dy: textView.textContainerInset.height)
    var outerSV: NSScrollView?
    var view: NSView? = textView.superview
    while let v = view {
        if let sv = v as? NSScrollView, sv.documentView !== textView { outerSV = sv; break }
        view = v.superview
    }
    guard let outerSV, let docView = outerSV.documentView else { return }
    var target = textView.convert(lineRect, to: docView)
    target = target.insetBy(dx: 0, dy: -60)
    NSAnimationContext.runAnimationGroup { ctx in
        ctx.duration = 0.12
        outerSV.contentView.animator().scrollToVisible(target)
    }
}

@MainActor
private func windowFrame(of view: NSView) -> CGRect {
    view.convert(view.bounds, to: nil)
}

@MainActor
private func crossBlockCharIndex(in textView: NSTextView, windowY: CGFloat) -> Int {
    guard let lm = textView.layoutManager, let tc = textView.textContainer else { return 0 }
    let viewPoint = textView.convert(NSPoint(x: textView.bounds.midX, y: windowY), from: nil)
    let containerPoint = NSPoint(
        x: viewPoint.x - textView.textContainerOrigin.x,
        y: viewPoint.y - textView.textContainerOrigin.y
    )
    let glyphIndex = lm.glyphIndex(for: containerPoint, in: tc, fractionOfDistanceThroughGlyph: nil)
    return lm.characterIndexForGlyph(at: glyphIndex)
}

// MARK: - List continuation helper

private struct ListContinuationResult {
    let prefix: String
    let isEmpty: Bool
}

private let orderedListRegex = try! NSRegularExpression(pattern: #"^(\d+)\. "#)
private let alphaListRegex   = try! NSRegularExpression(pattern: #"^([a-zA-Z])\. "#)
private let yamlListRegex    = try! NSRegularExpression(pattern: #"^(\s*)-\s?"#)

private func listContinuationPrefix(from text: String) -> ListContinuationResult? {
    // Task lists (check before plain unordered so "- [ ] " is matched first)
    for taskPrefix in ["- [x] ", "- [X] ", "- [ ] "] {
        if text.hasPrefix(taskPrefix) {
            let rest = text.dropFirst(taskPrefix.count)
            return ListContinuationResult(prefix: "- [ ] ", isEmpty: rest.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }
    // Unordered lists
    for marker in ["- ", "* ", "+ "] {
        if text.hasPrefix(marker) {
            let rest = text.dropFirst(marker.count)
            return ListContinuationResult(prefix: marker, isEmpty: rest.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }
    // Numeric ordered lists: "1. ", "2. ", etc.
    let nsText = text as NSString
    let nsRange = NSRange(location: 0, length: nsText.length)
    if let match = orderedListRegex.firstMatch(in: text, range: nsRange),
       let numRange = Range(match.range(at: 1), in: text) {
        let num = Int(text[numRange]) ?? 1
        let rest = text.dropFirst(match.range.length)
        return ListContinuationResult(prefix: "\(num + 1). ", isEmpty: rest.trimmingCharacters(in: .whitespaces).isEmpty)
    }
    // Alphabetical ordered lists: "a. ", "b. ", etc.
    if let match = alphaListRegex.firstMatch(in: text, range: nsRange),
       let letterRange = Range(match.range(at: 1), in: text),
       let scalar = text[letterRange].unicodeScalars.first {
        let nextLetter = String(UnicodeScalar(scalar.value + 1)!)
        let rest = text.dropFirst(match.range.length)
        return ListContinuationResult(prefix: "\(nextLetter). ", isEmpty: rest.trimmingCharacters(in: .whitespaces).isEmpty)
    }
    return nil
}

private func yamlListContinuationPrefix(from line: String) -> ListContinuationResult? {
    let nsLine = line as NSString
    let range = NSRange(location: 0, length: nsLine.length)
    guard let match = yamlListRegex.firstMatch(in: line, range: range),
          let indentRange = Range(match.range(at: 1), in: line) else {
        return nil
    }

    let indent = String(line[indentRange])
    let rest = String(line.dropFirst(match.range.length))
    return ListContinuationResult(
        prefix: "\(indent)- ",
        isEmpty: rest.trimmingCharacters(in: .whitespaces).isEmpty
    )
}

// MARK: - BlockEditorView (NSViewRepresentable)

struct BlockEditorView: NSViewRepresentable {
    var blockID: UUID
    var blockKind: MarkdownBlockKind
    @Binding var content: String
    var searchText: String
    var registry: BlockRegistry
    var onHeightChange: (CGFloat) -> Void
    var onSplitBlock: (String, Int, String?, String?, Int?) -> Void
    var onMergeWithPrevious: (String) -> Void
    var onNavigatePrevious: (CursorPlacement) -> Void
    var onNavigateNext: (CursorPlacement) -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let storage = NSTextStorage()
        let layout = MarkdownLayoutManager()
        let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)

        let textView = BlockNSTextView(frame: .zero, textContainer: container)
        textView.blockID = blockID
        textView.registry = registry
        configureTextView(textView)
        textView.delegate = context.coordinator
        textView.textStorage?.delegate = context.coordinator

        let coord = context.coordinator
        textView.onEnter = { [weak coord, weak textView] in
            guard let coord, let tv = textView else { return }
            if blockKind == .frontMatter {
                let selectedRange = tv.selectedRange()
                let originalContent = tv.string as NSString
                let safeLocation = min(selectedRange.location, originalContent.length)
                let lineRange = originalContent.lineRange(for: NSRange(location: safeLocation, length: 0))
                let line = originalContent.substring(with: lineRange)

                if let lp = yamlListContinuationPrefix(from: line) {
                    let insertion = lp.isEmpty ? "\n" : "\n" + lp.prefix
                    if tv.shouldChangeText(in: selectedRange, replacementString: insertion) {
                        tv.replaceCharacters(in: selectedRange, with: insertion)
                        tv.didChangeText()
                        tv.setSelectedRange(NSRange(location: safeLocation + insertion.count, length: 0))
                    }
                    return
                }

                tv.insertNewline(nil)
                return
            }
            guard !tv.string.hasPrefix("```"), !tv.string.hasPrefix("|") else {
                tv.insertNewline(nil); return
            }
            let loc             = tv.selectedRange().location
            let originalContent = tv.string
            var newBefore       = String(originalContent.prefix(loc))
            let rawAfter        = String(originalContent.suffix(originalContent.count - loc))
            var newAfter        = rawAfter
            var cursorPos: Int? = nil

            if let lp = listContinuationPrefix(from: newBefore) {
                if lp.isEmpty {
                    // Empty list item — break out of list
                    newBefore = ""
                } else {
                    newAfter  = lp.prefix + rawAfter
                    cursorPos = lp.prefix.count
                }
            }

            // Immediately truncate the text view so it doesn't flash the full content
            coord.isLoading = true
            tv.undoManager?.disableUndoRegistration()
            tv.string = newBefore
            tv.undoManager?.enableUndoRegistration()
            coord.isLoading = false
            coord.onTextChange(newBefore)
            coord.updateHeight(for: tv)
            // Block-level split is registered with the app UndoManager
            coord.onSplitBlock(originalContent, loc, newBefore, newAfter, cursorPos)
        }
        textView.onBackspaceAtStart = { [weak coord, weak textView] in
            guard let coord, let tv = textView else { return }
            coord.onMergeWithPrevious(tv.string)
        }
        textView.onNavigatePrevious = { [weak coord] p in coord?.onNavigatePrevious(p) }
        textView.onNavigateNext     = { [weak coord] p in coord?.onNavigateNext(p) }

        registry.register(textView, id: blockID)
        context.coordinator.registerTextView(textView)

        if !content.isEmpty {
            context.coordinator.isLoading = true
            textView.undoManager?.disableUndoRegistration()
            textView.string = content
            textView.undoManager?.enableUndoRegistration()
            context.coordinator.isLoading = false
            context.coordinator.applyFullHighlight(to: textView.textStorage!)
        }

        let scroll = NSScrollView()
        scroll.hasVerticalScroller   = false
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.documentView = textView
        textView.autoresizingMask = [NSView.AutoresizingMask.width]

        Task { [weak textView] in guard let tv = textView else { return }; coord.updateHeight(for: tv) }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView else { return }

        // Refresh callbacks so they never go stale across re-renders
        context.coordinator.onTextChange        = { [self] t in content = t }
        context.coordinator.onHeightChange      = onHeightChange
        context.coordinator.onSplitBlock        = onSplitBlock
        context.coordinator.onMergeWithPrevious = onMergeWithPrevious
        context.coordinator.onNavigatePrevious  = onNavigatePrevious
        context.coordinator.onNavigateNext      = onNavigateNext

        // Sync external content changes (e.g. merge appended to this block)
        if textView.string != content {
            context.coordinator.isLoading = true
            textView.undoManager?.disableUndoRegistration()
            textView.string = content
            textView.undoManager?.enableUndoRegistration()
            context.coordinator.isLoading = false
            if let storage = textView.textStorage {
                context.coordinator.applyFullHighlight(to: storage)
            }
            let coord = context.coordinator
            Task { [weak textView] in guard let tv = textView else { return }; coord.updateHeight(for: tv) }
        }

        context.coordinator.applySearchHighlights(to: textView, query: searchText)
    }

    func makeCoordinator() -> BlockEditorCoordinator {
        BlockEditorCoordinator(
            blockKind:           blockKind,
            onTextChange:        { [self] t in content = t },
            onHeightChange:      onHeightChange,
            onSplitBlock:        onSplitBlock,
            onMergeWithPrevious: onMergeWithPrevious,
            onNavigatePrevious:  onNavigatePrevious,
            onNavigateNext:      onNavigateNext
        )
    }

    private func configureTextView(_ tv: NSTextView) {
        tv.isEditable   = true
        tv.isSelectable = true
        tv.allowsUndo   = true
        tv.isRichText   = false
        tv.importsGraphics = false
        tv.font       = Styles.bodyFont
        tv.textColor  = .labelColor
        tv.backgroundColor  = .clear
        tv.drawsBackground  = false
        tv.isVerticallyResizable   = true
        tv.isHorizontallyResizable = false
        tv.minSize   = .zero
        tv.maxSize   = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.textContainerInset = NSSize(width: 0, height: 4)
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.lineFragmentPadding = 0
        tv.isAutomaticQuoteSubstitutionEnabled  = false
        tv.isAutomaticDashSubstitutionEnabled   = false
        tv.isAutomaticTextReplacementEnabled    = false
        tv.isAutomaticLinkDetectionEnabled      = false
        tv.isAutomaticSpellingCorrectionEnabled = true
        tv.isContinuousSpellCheckingEnabled     = true
        tv.isGrammarCheckingEnabled             = true
        tv.typingAttributes = Styles.baseAttributes
        // Prevent NSTextView from overriding our custom link colour/underline.
        // Cursor changes on hover are handled by BlockNSTextView.resetCursorRects().
        tv.linkTextAttributes = [:]
    }
}

// MARK: - BlockNSTextView

private final class BlockNSTextView: NSTextView {
    private static let indentUnit = "    "

    var blockID: UUID = UUID()
    var onEnter: (() -> Void)?
    var onBackspaceAtStart: (() -> Void)?
    var onNavigatePrevious: ((CursorPlacement) -> Void)?
    var onNavigateNext:     ((CursorPlacement) -> Void)?
    // Weak ref so mouseDragged can route cross-block events without a strong cycle.
    weak var registry: BlockRegistry?

    /// When set, draws a selection highlight using glyph rects from the layout manager.
    /// This lets non-focused blocks show precise, line-snapping selection during a
    /// cross-block drag — identical visually to the focused block's native selection.
    var crossBlockSelectionRange: NSRange? {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        // Draw cross-block selection background first so text renders on top.
        // drawsBackground = false means super won't wipe this with a fill.
        if let range = crossBlockSelectionRange, range.length > 0,
           let lm = layoutManager, let tc = textContainer {
            NSColor.selectedTextBackgroundColor.setFill()
            let glyphRange = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            lm.enumerateEnclosingRects(
                forGlyphRange: glyphRange,
                withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                in: tc
            ) { [weak self] rect, _ in
                guard let self else { return }
                rect.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y).fill()
            }
        }
        super.draw(dirtyRect)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if toggleTaskCheckboxIfHit(at: point) { return }
        // Single click on a link opens it; double-click falls through for word selection.
        if event.clickCount == 1 && handleLinkClickIfHit(at: point) { return }

        let anchorID = blockID
        let weakRegistry = registry

        // NSTextView.mouseDown runs a blocking run-loop using window.nextEvent(),
        // which means mouseDragged(with:) is never called on this subclass during
        // a drag-to-select gesture. Installing a Timer in .eventTracking mode is
        // the only way to observe mouse position while that loop is active.
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { _ in
            Task { @MainActor in
                guard NSEvent.pressedMouseButtons & 1 == 1 else { return }
                guard let window = NSApp.keyWindow else { return }
                let winPt = window.convertPoint(fromScreen: NSEvent.mouseLocation)
                weakRegistry?.onCrossBlockDrag?(anchorID, winPt.y)
            }
        }
        RunLoop.current.add(timer, forMode: .eventTracking)

        super.mouseDown(with: event)   // blocks until mouse-up

        timer.invalidate()
    }

    /// Fallback path: called when NSTextView uses normal event dispatch instead of
    /// its blocking loop (e.g. some system configurations). Both paths are safe.
    override func mouseDragged(with event: NSEvent) {
        super.mouseDragged(with: event)
        registry?.onCrossBlockDrag?(blockID, event.locationInWindow.y)
    }

    private func toggleTaskCheckboxIfHit(at point: NSPoint) -> Bool {
        guard let lm = layoutManager, let tc = textContainer else { return false }
        var fraction: CGFloat = 0
        let glyphIndex = lm.glyphIndex(for: point, in: tc, fractionOfDistanceThroughGlyph: &fraction)
        guard glyphIndex < lm.numberOfGlyphs else { return false }
        let charIndex = lm.characterIndexForGlyph(at: glyphIndex)

        let ns = string as NSString
        let lineRange = ns.lineRange(for: NSRange(location: charIndex, length: 0))
        let lineStr = ns.substring(with: lineRange)

        guard let m = Patterns.taskListItem.firstMatch(
            in: lineStr,
            range: NSRange(location: 0, length: (lineStr as NSString).length)
        ) else { return false }

        // Map checkbox range from line-local to full-string coordinates
        let localCheckbox = m.range(at: 2)
        let checkboxRange = NSRange(location: lineRange.location + localCheckbox.location,
                                    length: localCheckbox.length)

        // Only toggle if the click landed between the bullet and the end of the checkbox
        guard charIndex >= lineRange.location,
              charIndex <= checkboxRange.location + checkboxRange.length else { return false }

        let current = ns.substring(with: checkboxRange)
        let replacement = current.lowercased() == "[x]" ? "[ ]" : "[x]"

        guard shouldChangeText(in: checkboxRange, replacementString: replacement) else { return false }
        replaceCharacters(in: checkboxRange, with: replacement)
        didChangeText()
        return true
    }

    /// Returns true and opens the link if the click landed on text with a `.link` attribute.
    private func handleLinkClickIfHit(at point: NSPoint) -> Bool {
        guard let lm = layoutManager, let tc = textContainer,
              let ts = textStorage else { return false }
        var fraction: CGFloat = 0
        let glyphIndex = lm.glyphIndex(for: point, in: tc, fractionOfDistanceThroughGlyph: &fraction)
        guard glyphIndex < lm.numberOfGlyphs else { return false }
        let charIndex = lm.characterIndexForGlyph(at: glyphIndex)
        guard charIndex < ts.length else { return false }
        guard let urlStr = ts.attribute(.link, at: charIndex, effectiveRange: nil) as? String,
              !urlStr.isEmpty else { return false }
        registry?.onLinkClick?(urlStr)
        return true
    }

    /// Adds a pointing-hand cursor over every range that carries a `.link` attribute so
    /// the user gets a visual affordance that clicking opens the link.
    override func resetCursorRects() {
        super.resetCursorRects()
        guard let lm = layoutManager, let tc = textContainer, let ts = textStorage else { return }
        let full = NSRange(location: 0, length: ts.length)
        ts.enumerateAttribute(.link, in: full, options: []) { value, range, _ in
            guard value != nil else { return }
            let glyphRange = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            lm.enumerateEnclosingRects(
                forGlyphRange: glyphRange,
                withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                in: tc
            ) { [weak self] rect, _ in
                guard let self else { return }
                addCursorRect(rect.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y),
                              cursor: .pointingHand)
            }
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let ch = event.charactersIgnoringModifiers?.lowercased()
        if ch == "o" && (flags == .command || flags == [.command, .shift]) { return false }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        let mods     = event.modifierFlags
        let isShift  = mods.contains(.shift)
        let isOpt    = mods.contains(.option)
        let isCmd    = mods.contains(.command)
        let isCtrl   = mods.contains(.control)
        let modified = isShift || isOpt || isCmd || isCtrl

        switch event.keyCode {
        case 48 where !isOpt && !isCmd && !isCtrl:      // Tab / Shift+Tab
            if isShift { outdentSelection() } else { indentSelection() }
            return
        case 36 where !isShift:                          // Return
            onEnter?(); return
        case 51:                                         // Backspace
            let r = selectedRange()
            if r.location == 0 && r.length == 0 { onBackspaceAtStart?(); return }
            // Paired deletion: if the cursor sits between an auto-paired opener/closer
            // (e.g. [|] or `|`), delete both characters at once.
            if r.length == 0, r.location > 0, r.location < string.count {
                let ns   = string as NSString
                let prev = ns.substring(with: NSRange(location: r.location - 1, length: 1))
                let next = ns.substring(with: NSRange(location: r.location,     length: 1))
                if (prev == "[" && next == "]") || (prev == "`" && next == "`")
                    || (prev == "*" && next == "*") || (prev == "_" && next == "_") {
                    let delRange = NSRange(location: r.location - 1, length: 2)
                    if shouldChangeText(in: delRange, replacementString: "") {
                        replaceCharacters(in: delRange, with: "")
                        didChangeText()
                        setSelectedRange(NSRange(location: r.location - 1, length: 0))
                    }
                    return
                }
            }
        case 123 where !modified:                        // Left arrow
            if selectedRange().location == 0 && selectedRange().length == 0 {
                onNavigatePrevious?(.end); return
            }
        case 124 where !modified:                        // Right arrow
            if selectedRange().location == string.count && selectedRange().length == 0 {
                onNavigateNext?(.start); return
            }
        case 126 where !modified:                        // Up arrow
            if isOnFirstLine() { onNavigatePrevious?(.end); return }
        case 125 where !modified:                        // Down arrow
            if isOnLastLine()  { onNavigateNext?(.start); return }
        default: break
        }
        super.keyDown(with: event)
    }

    private func isOnFirstLine() -> Bool {
        guard let lm = layoutManager, lm.numberOfGlyphs > 0 else { return true }
        let loc = selectedRange().location
        let gi  = loc < string.count ? lm.glyphIndexForCharacter(at: loc) : lm.numberOfGlyphs - 1
        let cur = lm.lineFragmentRect(forGlyphAt: min(gi, lm.numberOfGlyphs - 1), effectiveRange: nil)
        let top = lm.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil)
        return abs(cur.minY - top.minY) < 1
    }

    private func isOnLastLine() -> Bool {
        guard let lm = layoutManager, lm.numberOfGlyphs > 0 else { return true }
        let loc = selectedRange().location
        let gi  = loc < string.count ? lm.glyphIndexForCharacter(at: loc) : lm.numberOfGlyphs - 1
        let cur  = lm.lineFragmentRect(forGlyphAt: min(gi, lm.numberOfGlyphs - 1), effectiveRange: nil)
        let last = lm.lineFragmentRect(forGlyphAt: lm.numberOfGlyphs - 1, effectiveRange: nil)
        return abs(cur.minY - last.minY) < 1
    }

    private func indentSelection() {
        applyIndentation(outdent: false)
    }

    private func outdentSelection() {
        applyIndentation(outdent: true)
    }

    private func applyIndentation(outdent: Bool) {
        let selection = selectedRange()
        let ns = string as NSString
        let affectedRange = lineRangeForIndentation(from: selection, in: ns)
        let original = ns.substring(with: affectedRange)
        let lines = original.components(separatedBy: "\n")

        var updatedLines: [String] = []
        var selectionLocation = selection.location
        var selectionLength = selection.length

        for (index, line) in lines.enumerated() {
            let isLastTrailingEmptyLine = index == lines.count - 1 && line.isEmpty && original.hasSuffix("\n")
            if isLastTrailingEmptyLine {
                updatedLines.append(line)
                continue
            }

            if outdent {
                let removedCount: Int
                if line.hasPrefix("\t") {
                    removedCount = 1
                } else {
                    removedCount = min(line.prefix { $0 == " " }.count, Self.indentUnit.count)
                }

                if removedCount > 0 {
                    let lineStart = affectedRange.location + originalOffset(ofLineAt: index, in: lines)
                    if selection.location > lineStart {
                        let deltaBeforeSelection = min(removedCount, selection.location - lineStart)
                        selectionLocation -= deltaBeforeSelection
                    }

                    let selectionEnd = selection.location + selection.length
                    let lineSelectionStart = max(selection.location, lineStart)
                    let lineSelectionEnd = min(selectionEnd, lineStart + line.count)
                    if lineSelectionEnd > lineSelectionStart {
                        let overlap = min(removedCount, lineSelectionEnd - lineStart)
                        selectionLength -= min(overlap, selectionLength)
                    }
                }

                updatedLines.append(String(line.dropFirst(removedCount)))
            } else {
                let lineStart = affectedRange.location + originalOffset(ofLineAt: index, in: lines)
                if selection.location >= lineStart {
                    selectionLocation += Self.indentUnit.count
                }
                if selection.location + selection.length > lineStart {
                    selectionLength += Self.indentUnit.count
                }
                updatedLines.append(Self.indentUnit + line)
            }
        }

        let replacement = updatedLines.joined(separator: "\n")
        guard shouldChangeText(in: affectedRange, replacementString: replacement) else { return }
        replaceCharacters(in: affectedRange, with: replacement)
        didChangeText()
        let replacementLength = (replacement as NSString).length
        let safeLocation = min(max(0, selectionLocation), affectedRange.location + replacementLength)
        let safeLength = min(max(0, selectionLength), affectedRange.location + replacementLength - safeLocation)
        setSelectedRange(NSRange(location: safeLocation, length: safeLength))
    }

    private func lineRangeForIndentation(from selection: NSRange, in text: NSString) -> NSRange {
        if selection.length == 0 {
            return text.lineRange(for: selection)
        }

        let startLine = text.lineRange(for: NSRange(location: selection.location, length: 0))
        let endLocation = max(selection.location, selection.location + selection.length - 1)
        let endLine = text.lineRange(for: NSRange(location: endLocation, length: 0))
        let upperBound = endLine.location + endLine.length
        return NSRange(location: startLine.location, length: upperBound - startLine.location)
    }

    private func originalOffset(ofLineAt index: Int, in lines: [String]) -> Int {
        guard index > 0 else { return 0 }
        return lines[..<index].reduce(0) { $0 + $1.count + 1 }
    }
}

// MARK: - BlockEditorCoordinator

@MainActor
final class BlockEditorCoordinator: NSObject {
    // Composition: delegate highlighting work to an inner EditorCoordinator
    private let highlighter: EditorCoordinator
    private let blockKind: MarkdownBlockKind

    var onTextChange:        (String) -> Void
    var onHeightChange:      (CGFloat) -> Void
    var onSplitBlock:        (String, Int, String?, String?, Int?) -> Void
    var onMergeWithPrevious: (String) -> Void
    var onNavigatePrevious:  (CursorPlacement) -> Void
    var onNavigateNext:      (CursorPlacement) -> Void
    var isLoading = false

    init(
        blockKind: MarkdownBlockKind,
        onTextChange:        @escaping (String) -> Void,
        onHeightChange:      @escaping (CGFloat) -> Void,
        onSplitBlock:        @escaping (String, Int, String?, String?, Int?) -> Void,
        onMergeWithPrevious: @escaping (String) -> Void,
        onNavigatePrevious:  @escaping (CursorPlacement) -> Void,
        onNavigateNext:      @escaping (CursorPlacement) -> Void
    ) {
        self.blockKind          = blockKind
        self.highlighter         = EditorCoordinator(onTextChange: { _ in })
        self.onTextChange        = onTextChange
        self.onHeightChange      = onHeightChange
        self.onSplitBlock        = onSplitBlock
        self.onMergeWithPrevious = onMergeWithPrevious
        self.onNavigatePrevious  = onNavigatePrevious
        self.onNavigateNext      = onNavigateNext
    }

    func applyFullHighlight(to storage: NSTextStorage) {
        highlighter.applyFullHighlight(to: storage)
        removeCodeFenceBackgroundIfNeeded(from: storage)
    }

    func registerTextView(_ tv: NSTextView) {
        highlighter.textView = tv
    }

    func applySearchHighlights(to textView: NSTextView, query: String) {
        highlighter.applySearchHighlights(to: textView, query: query)
    }

    func updateHeight(for textView: NSTextView) {
        guard let lm = textView.layoutManager, let tc = textView.textContainer else { return }
        lm.ensureLayout(for: tc)
        let rect  = lm.usedRect(for: tc)
        let inset = textView.textContainerInset
        onHeightChange(max(ceil(rect.height) + inset.height * 2, 24))
    }

    private func removeCodeFenceBackgroundIfNeeded(from storage: NSTextStorage) {
        guard case .codeFence = blockKind else { return }
        storage.removeAttribute(.backgroundColor, range: NSRange(location: 0, length: storage.length))
    }

}


extension BlockEditorCoordinator: @preconcurrency NSTextStorageDelegate {
    func textStorage(
        _ textStorage: NSTextStorage,
        didProcessEditing editedMask: NSTextStorageEditActions,
        range editedRange: NSRange,
        changeInLength delta: Int
    ) {
        // Forward to the inner coordinator so all highlight logic runs untouched
        highlighter.textStorage(textStorage,
                                didProcessEditing: editedMask,
                                range: editedRange,
                                changeInLength: delta)
        removeCodeFenceBackgroundIfNeeded(from: textStorage)
    }
}

extension BlockEditorCoordinator: NSTextViewDelegate {
    // Prevent re-entrancy when we manually apply an auto-pair replacement.
    private static var isApplyingAutoPair = false

    func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
        guard !Self.isApplyingAutoPair, !isLoading else { return true }
        guard let typed = replacementString, typed.count == 1 else { return true }
        let ns = textView.string as NSString
        let cursorPos = range.location
        let prevChar  = cursorPos > 0            ? ns.substring(with: NSRange(location: cursorPos - 1, length: 1)) : ""
        let nextChar  = cursorPos < ns.length    ? ns.substring(with: NSRange(location: cursorPos,     length: 1)) : ""

        // ── Wrap a selection in delimiters ────────────────────────────────────
        if range.length > 0 {
            let (open, close): (String, String)
            switch typed {
            case "*": (open, close) = ("*",  "*")
            case "`": (open, close) = ("`",  "`")
            case "_": (open, close) = ("_",  "_")
            case "[": (open, close) = ("[",  "]")
            default:  return true
            }
            let sel = ns.substring(with: range)
            applyAutoPair(in: textView, replace: range,
                          with: open + sel + close,
                          cursorAt: range.location + open.count + sel.count)
            return false
        }

        switch typed {

        // ── Star: * → *|* ────────────────────────────────────────────────────
        // Same mechanic as `[` → `[|]`: the very first `*` auto-pairs immediately.
        // If the cursor already sits before a closing `*`, skip over it instead.
        // HR guard: if the line prefix is all `*` (e.g. user building `***`) skip
        // auto-pairing to avoid creating `****` which matches the HR pattern.
        case "*":
            if prevChar == "*" && nextChar == "*" {
                // Cursor is inside *|* — insert another * here and one after closing *
                // i.e. expand *|* → **|**
                applyAutoPair(in: textView,
                              replace: range,
                              with: "**", cursorAt: cursorPos + 1)
                return false
            }
            // HR guard: avoid auto-pairing on otherwise-blank lines made of only `*`
            let starLineRange = ns.lineRange(for: NSRange(location: cursorPos, length: 0))
            let starPrefix = ns.substring(with: NSRange(location: starLineRange.location,
                                                        length: cursorPos - starLineRange.location))
                .trimmingCharacters(in: .whitespaces)
            if !starPrefix.isEmpty && starPrefix.allSatisfy({ $0 == "*" }) { return true }
            applyAutoPair(in: textView, replace: range, with: "**", cursorAt: cursorPos + 1)
            return false

        // ── Underscore: _ → _|_ ──────────────────────────────────────────────
        case "_":
            if prevChar == "_" && nextChar == "_" {
                // Cursor is inside _|_ — expand to __|__
                applyAutoPair(in: textView,
                              replace: range,
                              with: "__", cursorAt: cursorPos + 1)
                return false
            }
            let usLineRange = ns.lineRange(for: NSRange(location: cursorPos, length: 0))
            let usPrefix = ns.substring(with: NSRange(location: usLineRange.location,
                                                      length: cursorPos - usLineRange.location))
                .trimmingCharacters(in: .whitespaces)
            if !usPrefix.isEmpty && usPrefix.allSatisfy({ $0 == "_" }) { return true }
            applyAutoPair(in: textView, replace: range, with: "__", cursorAt: cursorPos + 1)
            return false

        // ── Inline code: ` → `|` ─────────────────────────────────────────────
        // Single backtick auto-pairs. When the user is building `` ` `` → ` ``` `
        // (prevChar already `` ` ``) we skip so the block-based code-fence can form.
        case "`" where prevChar != "`":
            if nextChar == "`" {
                // Skip over the closing ` the user already inserted
                applySkipOver(in: textView, to: cursorPos + 1)
                return false
            }
            applyAutoPair(in: textView, replace: range,
                          with: "``",
                          cursorAt: cursorPos + 1)
            return false

        // ── Brackets: [ → [|] ────────────────────────────────────────────────
        case "[":
            applyAutoPair(in: textView, replace: range,
                          with: "[]",
                          cursorAt: cursorPos + 1)
            return false

        // ── Skip over matching closing delimiter ─────────────────────────────
        // If the cursor is sitting right before the closing char we already
        // auto-inserted, just glide past it instead of doubling it up.
        case "]" where nextChar == "]",
             ")" where nextChar == ")":
            applySkipOver(in: textView, to: cursorPos + 1)
            return false

        default:
            return true
        }
    }

    private func applyAutoPair(in textView: NSTextView, replace range: NSRange,
                               with text: String, cursorAt pos: Int) {
        Self.isApplyingAutoPair = true
        defer { Self.isApplyingAutoPair = false }
        textView.insertText(text, replacementRange: range)
        textView.setSelectedRange(NSRange(location: pos, length: 0))
    }

    private func applySkipOver(in textView: NSTextView, to pos: Int) {
        textView.setSelectedRange(NSRange(location: pos, length: 0))
    }

    func textDidChange(_ notification: Notification) {
        guard !isLoading, let tv = notification.object as? NSTextView else { return }
        onTextChange(tv.string)
        tv.typingAttributes = Styles.baseAttributes
        Task { [weak self, weak tv] in
            guard let self, let tv else { return }
            self.updateHeight(for: tv)
            scrollCursorToVisible(in: tv)
        }
    }
}
