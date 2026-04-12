import SwiftUI
import Combine
import AppKit

enum CursorPlacement {
    case start
    case end
    case position(Int)
}

@MainActor
final class BlockRegistry: ObservableObject {
    private final class WeakRef { weak var value: NSTextView? }
    private var store: [UUID: WeakRef] = [:]
    private var pendingID: UUID?
    private var pendingPlacement: CursorPlacement = .start

    func allRegistered() -> [(UUID, NSTextView)] {
        store.compactMap { id, ref in ref.value.map { (id, $0) } }
    }

    var onCrossBlockDrag: ((UUID, CGFloat) -> Void)?
    var onLinkClick: ((String) -> Void)?

    func register(_ tv: NSTextView, id: UUID) {
        let ref = WeakRef()
        ref.value = tv
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
        case .start:
            pos = 0
        case .end:
            pos = tv.string.count
        case let .position(p):
            pos = min(max(p, 0), tv.string.count)
        }
        tv.setSelectedRange(NSRange(location: pos, length: 0))
        Task { scrollCursorToVisible(in: tv) }
    }
}

@MainActor
final class BlocksManager: ObservableObject {
    private static let indentUnit = "    "

    @Published var blocks: [MarkdownBlock] = []
    @Published var allBlocksSelected = false
    @Published var crossSelectedIDs: Set<UUID> = []
    @Published var crossCursorID: UUID? = nil
    let registry = BlockRegistry()

    var undoManager: UndoManager?
    private var documentBuffer = BlockDocumentBuffer()

    func load(from text: String) {
        let parsed = parseMarkdownBlocks(text)
        blocks = parsed.isEmpty ? [MarkdownBlock(content: "")] : parsed
        _ = documentBuffer.load(blocks: blocks)
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

    func synchronizeDocument(from previous: [MarkdownBlock]) -> String {
        syncBlockKinds(from: previous)
        return documentBuffer.sync(from: previous, to: blocks)
    }

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

    func splitBlock(id: UUID, originalContent: String, at loc: Int, newBefore: String? = nil, newAfter: String? = nil, newBlockCursorPos: Int? = nil) {
        guard let idx = blocks.firstIndex(where: { $0.id == id }) else { return }
        let um = undoManager
        let before = newBefore ?? String(originalContent.prefix(loc))
        let after = newAfter ?? String(originalContent.suffix(originalContent.count - loc))
        let newBlock = MarkdownBlock(content: after)
        let sourceID = id
        let newID = newBlock.id

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

    func mergeWithPrevious(_ id: UUID, trailing: String) {
        guard let idx = blocks.firstIndex(where: { $0.id == id }), idx > 0 else { return }
        let um = undoManager
        let prevIdx = idx - 1
        let prevID = blocks[prevIdx].id
        let originalPrevContent = blocks[prevIdx].content
        let currentID = blocks[idx].id
        let junctionPos = originalPrevContent.count + (originalPrevContent.isEmpty ? 0 : 1)

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

    func moveBlock(from: Int, to: Int) {
        let um = undoManager
        let undoFrom = to > from ? to - 1 : to
        let undoTo = to > from ? from : from + 1

        um?.registerUndo(withTarget: self) { mgr in
            MainActor.assumeIsolated {
                mgr.blocks.move(fromOffsets: IndexSet(integer: undoFrom), toOffset: undoTo)
            }
        }
        um?.setActionName("Move Block")

        blocks.move(fromOffsets: IndexSet(integer: from), toOffset: to)
    }

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

    func navigatePrevious(from id: UUID, placement: CursorPlacement) {
        guard let idx = blocks.firstIndex(where: { $0.id == id }), idx > 0 else { return }
        registry.focus(blocks[idx - 1].id, at: placement)
    }

    func navigateNext(from id: UUID, placement: CursorPlacement) {
        guard let idx = blocks.firstIndex(where: { $0.id == id }), idx < blocks.count - 1 else { return }
        registry.focus(blocks[idx + 1].id, at: placement)
    }
}

@MainActor
func scrollCursorToVisible(in textView: NSTextView) {
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
        if let sv = v as? NSScrollView, sv.documentView !== textView {
            outerSV = sv
            break
        }
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
func windowFrame(of view: NSView) -> CGRect {
    view.convert(view.bounds, to: nil)
}

@MainActor
func crossBlockCharIndex(in textView: NSTextView, windowY: CGFloat) -> Int {
    guard let lm = textView.layoutManager, let tc = textView.textContainer else { return 0 }
    let viewPoint = textView.convert(NSPoint(x: textView.bounds.midX, y: windowY), from: nil)
    let containerPoint = NSPoint(
        x: viewPoint.x - textView.textContainerOrigin.x,
        y: viewPoint.y - textView.textContainerOrigin.y
    )
    let glyphIndex = lm.glyphIndex(for: containerPoint, in: tc, fractionOfDistanceThroughGlyph: nil)
    return lm.characterIndexForGlyph(at: glyphIndex)
}
