import SwiftUI
import AppKit

// MARK: - NodeEditorView

struct NodeEditorView: View {
    @Binding var text: String
    var searchText: String
    var onTextChange: (String) -> Void

    @State private var blocks: [MarkdownBlock] = []
    @State private var hoveredID: UUID? = nil
    @State private var dropTargetID: UUID? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach($blocks) { $block in
                    BlockRowView(
                        block: $block,
                        searchText: searchText,
                        isHovered: hoveredID == block.id,
                        isDropTarget: dropTargetID == block.id,
                        onHover: { hovered in hoveredID = hovered ? block.id : nil },
                        onInsertAfter: { newContent in insertBlock(after: block.id, content: newContent) },
                        onMergeWithPrevious: { trailing in mergeWithPrevious(block.id, trailing: trailing) }
                    )
                    .dropDestination(for: String.self) { items, _ in
                        guard let idString = items.first,
                              let sourceID = UUID(uuidString: idString),
                              sourceID != block.id,
                              let from = blocks.firstIndex(where: { $0.id == sourceID }),
                              let to   = blocks.firstIndex(where: { $0.id == block.id })
                        else { return false }
                        withAnimation(.easeInOut(duration: 0.2)) {
                            blocks.move(fromOffsets: IndexSet(integer: from),
                                        toOffset: to > from ? to + 1 : to)
                        }
                        return true
                    } isTargeted: { targeted in
                        dropTargetID = targeted ? block.id : nil
                    }
                }
            }
            .padding(.horizontal, 48)
            .padding(.vertical, 40)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onAppear {
            let parsed = parseMarkdownBlocks(text)
            blocks = parsed.isEmpty ? [MarkdownBlock(content: "")] : parsed
        }
        .onChange(of: blocks) { _, newBlocks in
            // Only write to disk — don't mutate the binding mid-update
            // (documentText stays stale while editing; file switch via .id() re-parses)
            let serialized = serializeMarkdownBlocks(newBlocks)
            guard serialized != text else { return }
            onTextChange(serialized)
        }
    }

    private func insertBlock(after id: UUID, content: String) {
        guard let idx = blocks.firstIndex(where: { $0.id == id }) else { return }
        blocks.insert(MarkdownBlock(content: content), at: idx + 1)
    }

    private func mergeWithPrevious(_ id: UUID, trailing: String) {
        guard let idx = blocks.firstIndex(where: { $0.id == id }), idx > 0 else { return }
        if !trailing.isEmpty {
            let sep = blocks[idx - 1].content.isEmpty ? "" : "\n"
            blocks[idx - 1].content += sep + trailing
        }
        blocks.remove(at: idx)
    }
}

// MARK: - BlockRowView

struct BlockRowView: View {
    @Binding var block: MarkdownBlock
    var searchText: String
    var isHovered: Bool
    var isDropTarget: Bool
    var onHover: (Bool) -> Void
    var onInsertAfter: (String) -> Void
    var onMergeWithPrevious: (String) -> Void

    @State private var height: CGFloat = 32

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // Drag handle — visible on hover, acts as the draggable source
            Image(systemName: "circle.grid.2x3.fill")
                .font(.system(size: 10))
                .foregroundStyle(isHovered ? Color.secondary.opacity(0.45) : .clear)
                .frame(width: 28, height: max(height, 24))
                .contentShape(Rectangle())
                .draggable(block.id.uuidString)
                .onContinuousHover { phase in
                    if case .active = phase { NSCursor.openHand.set() }
                    else { NSCursor.arrow.set() }
                }

            // Per-block inline editor
            BlockEditorView(
                content: $block.content,
                searchText: searchText,
                onHeightChange: { h in height = h },
                onInsertAfter: onInsertAfter,
                onMergeWithPrevious: onMergeWithPrevious
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
        .onHover { onHover($0) }
    }
}

// MARK: - BlockEditorView (NSViewRepresentable)

struct BlockEditorView: NSViewRepresentable {
    @Binding var content: String
    var searchText: String
    var onHeightChange: (CGFloat) -> Void
    var onInsertAfter: (String) -> Void
    var onMergeWithPrevious: (String) -> Void

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
            let loc = tv.selectedRange().location
            let str = tv.string
            let before = String(str.prefix(loc))
            let after  = String(str.suffix(str.count - loc))
            coord.isLoading = true
            tv.string = before
            coord.isLoading = false
            coord.onTextChange(before)
            coord.updateHeight(for: tv)
            coord.onInsertAfter(after)
        }
        textView.onBackspaceAtStart = { [weak coord, weak textView] in
            guard let coord, let tv = textView else { return }
            coord.onMergeWithPrevious(tv.string)
        }

        if !content.isEmpty {
            context.coordinator.isLoading = true
            textView.string = content
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
        context.coordinator.onInsertAfter       = onInsertAfter
        context.coordinator.onMergeWithPrevious = onMergeWithPrevious

        // Sync external content changes (e.g. merge appended to this block)
        if textView.string != content {
            context.coordinator.isLoading = true
            textView.string = content
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
            onInsertAfter:       onInsertAfter,
            onMergeWithPrevious: onMergeWithPrevious
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

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let ch = event.charactersIgnoringModifiers?.lowercased()
        if ch == "o" && (flags == .command || flags == [.command, .shift]) { return false }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        let isReturn    = event.keyCode == 36
        let isBackspace = event.keyCode == 51
        let isShift     = event.modifierFlags.contains(.shift)

        if isReturn, !isShift {
            onEnter?(); return
        }
        if isBackspace {
            let range = selectedRange()
            if range.location == 0 && range.length == 0 {
                onBackspaceAtStart?(); return
            }
        }
        super.keyDown(with: event)
    }
}

// MARK: - BlockEditorCoordinator

@MainActor
final class BlockEditorCoordinator: NSObject {
    // Composition: delegate highlighting work to an inner EditorCoordinator
    private let highlighter: EditorCoordinator

    var onTextChange:        (String) -> Void
    var onHeightChange:      (CGFloat) -> Void
    var onInsertAfter:       (String) -> Void
    var onMergeWithPrevious: (String) -> Void
    var isLoading = false

    init(
        onTextChange:        @escaping (String) -> Void,
        onHeightChange:      @escaping (CGFloat) -> Void,
        onInsertAfter:       @escaping (String) -> Void,
        onMergeWithPrevious: @escaping (String) -> Void
    ) {
        self.highlighter        = EditorCoordinator(onTextChange: { _ in })
        self.onTextChange        = onTextChange
        self.onHeightChange      = onHeightChange
        self.onInsertAfter       = onInsertAfter
        self.onMergeWithPrevious = onMergeWithPrevious
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
        }
    }
}

