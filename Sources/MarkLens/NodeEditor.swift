import SwiftUI
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
    @Published var blocks: [MarkdownBlock] = []
    let registry = BlockRegistry()

    // Injected from SwiftUI environment — same instance NSTextView uses for within-block undo.
    var undoManager: UndoManager?

    func load(from text: String) {
        let parsed = parseMarkdownBlocks(text)
        blocks = parsed.isEmpty ? [MarkdownBlock(content: "")] : parsed
    }

    // MARK: Split (Enter)

    func splitBlock(id: UUID, originalContent: String, at loc: Int) {
        guard let idx = blocks.firstIndex(where: { $0.id == id }) else { return }
        // Capture undo manager before mutating so the closure never touches NSApp.
        let um = undoManager
        let before = String(originalContent.prefix(loc))
        let after  = String(originalContent.suffix(originalContent.count - loc))
        let newBlock = MarkdownBlock(content: after)
        let sourceID = id
        let newID    = newBlock.id

        um?.registerUndo(withTarget: self) { mgr in
            guard let ni = mgr.blocks.firstIndex(where: { $0.id == newID }) else { return }
            mgr.blocks.remove(at: ni)
            if let si = mgr.blocks.firstIndex(where: { $0.id == sourceID }) {
                mgr.blocks[si].content = originalContent
            }
            mgr.registry.focus(sourceID, at: .position(loc))
        }
        um?.setActionName("Split Block")

        blocks[idx].content = before
        blocks.insert(newBlock, at: idx + 1)
        registry.focus(newID, at: .start)
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
            guard let pi = mgr.blocks.firstIndex(where: { $0.id == prevID }) else { return }
            mgr.blocks[pi].content = originalPrevContent
            let restored = MarkdownBlock(id: currentID, content: trailing)
            mgr.blocks.insert(restored, at: pi + 1)
            mgr.registry.focus(currentID, at: .start)
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
            mgr.blocks.move(fromOffsets: IndexSet(integer: undoFrom), toOffset: undoTo)
        }
        um?.setActionName("Move Block")

        blocks.move(fromOffsets: IndexSet(integer: from), toOffset: to)
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
    var onTextChange: (String) -> Void

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
                        isDropTarget: dropTargetID == block.id,
                        debugBlocks: debugBlocks,
                        registry: manager.registry,
                        onSplitBlock:        { orig, loc in manager.splitBlock(id: block.id, originalContent: orig, at: loc) },
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
            .padding(.top, 72)
            .padding(.bottom, 40)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onAppear {
            NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                if flags == [.command, .shift],
                   event.charactersIgnoringModifiers?.lowercased() == "d" {
                    debugBlocks.toggle()
                    return nil
                }
                return event
            }
        }
        .onAppear {
            manager.undoManager = undoManager
            manager.load(from: text)
        }
        .onChange(of: undoManager) { _, um in
            manager.undoManager = um
        }
        .onChange(of: manager.blocks) { _, newBlocks in
            // Only write to disk — don't mutate the binding mid-update
            // (documentText stays stale while editing; file switch via .id() re-parses)
            let serialized = serializeMarkdownBlocks(newBlocks)
            guard serialized != text else { return }
            onTextChange(serialized)
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
    var isDropTarget: Bool
    var debugBlocks: Bool
    var registry: BlockRegistry
    var onSplitBlock: (String, Int) -> Void   // (originalContent, cursorLocation)
    var onMergeWithPrevious: (String) -> Void
    var onNavigatePrevious: (CursorPlacement) -> Void
    var onNavigateNext: (CursorPlacement) -> Void

    @State private var height: CGFloat = 32

    private var blockPadding: (top: CGFloat, bottom: CGFloat) {
        let t = block.content.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("# ")      { return (top: 40, bottom: 8) }
        if t.hasPrefix("## ")     { return (top: 32, bottom: 6) }
        if t.hasPrefix("### ")    { return (top: 24, bottom: 4) }
        if t.hasPrefix("####")    { return (top: 20, bottom: 4) }
        return (top: 0, bottom: 0)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // Drag strip — pure SwiftUI, left of the NSTextView so no z-order conflict
            DragStrip(blockID: block.id, height: max(height, 24))

            BlockEditorView(
                blockID: block.id,
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
        .overlay(alignment: .top) {
            // Drop insertion indicator
            if isDropTarget {
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(height: 2)
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
}

// MARK: - Debug Overlay

private struct BlockDebugOverlay: View {
    let block: MarkdownBlock
    let index: Int

    var blockType: (label: String, color: Color) {
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

// MARK: - BlockEditorView (NSViewRepresentable)

struct BlockEditorView: NSViewRepresentable {
    var blockID: UUID
    @Binding var content: String
    var searchText: String
    var registry: BlockRegistry
    var onHeightChange: (CGFloat) -> Void
    var onSplitBlock: (String, Int) -> Void   // (originalContent, cursorLocation)
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
        configureTextView(textView)
        textView.delegate = context.coordinator
        textView.textStorage?.delegate = context.coordinator

        let coord = context.coordinator
        textView.onEnter = { [weak coord, weak textView] in
            guard let coord, let tv = textView else { return }
            guard !tv.string.hasPrefix("```"), !tv.string.hasPrefix("|") else {
                tv.insertNewline(nil); return
            }
            let loc             = tv.selectedRange().location
            let originalContent = tv.string
            let before          = String(originalContent.prefix(loc))
            // Immediately truncate the text view so it doesn't flash the full content
            coord.isLoading = true
            tv.undoManager?.disableUndoRegistration()
            tv.string = before
            tv.undoManager?.enableUndoRegistration()
            coord.isLoading = false
            coord.onTextChange(before)
            coord.updateHeight(for: tv)
            // Block-level split is registered with the app UndoManager
            coord.onSplitBlock(originalContent, loc)
        }
        textView.onBackspaceAtStart = { [weak coord, weak textView] in
            guard let coord, let tv = textView else { return }
            coord.onMergeWithPrevious(tv.string)
        }
        textView.onNavigatePrevious = { [weak coord] p in coord?.onNavigatePrevious(p) }
        textView.onNavigateNext     = { [weak coord] p in coord?.onNavigateNext(p) }

        registry.register(textView, id: blockID)

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
        tv.isContinuousSpellCheckingEnabled     = false
        tv.isGrammarCheckingEnabled             = false
        tv.typingAttributes = Styles.baseAttributes
    }
}

// MARK: - BlockNSTextView

private final class BlockNSTextView: NSTextView {
    var onEnter: (() -> Void)?
    var onBackspaceAtStart: (() -> Void)?
    var onNavigatePrevious: ((CursorPlacement) -> Void)?
    var onNavigateNext:     ((CursorPlacement) -> Void)?

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
        let modified = isShift || isOpt || isCmd

        switch event.keyCode {
        case 36 where !isShift:                          // Return
            onEnter?(); return
        case 51:                                         // Backspace
            let r = selectedRange()
            if r.location == 0 && r.length == 0 { onBackspaceAtStart?(); return }
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
}

// MARK: - BlockEditorCoordinator

@MainActor
final class BlockEditorCoordinator: NSObject {
    // Composition: delegate highlighting work to an inner EditorCoordinator
    private let highlighter: EditorCoordinator

    var onTextChange:        (String) -> Void
    var onHeightChange:      (CGFloat) -> Void
    var onSplitBlock:        (String, Int) -> Void   // (originalContent, cursorLocation)
    var onMergeWithPrevious: (String) -> Void
    var onNavigatePrevious:  (CursorPlacement) -> Void
    var onNavigateNext:      (CursorPlacement) -> Void
    var isLoading = false

    init(
        onTextChange:        @escaping (String) -> Void,
        onHeightChange:      @escaping (CGFloat) -> Void,
        onSplitBlock:        @escaping (String, Int) -> Void,
        onMergeWithPrevious: @escaping (String) -> Void,
        onNavigatePrevious:  @escaping (CursorPlacement) -> Void,
        onNavigateNext:      @escaping (CursorPlacement) -> Void
    ) {
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
    }
}

extension BlockEditorCoordinator: NSTextViewDelegate {
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

