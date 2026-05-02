import SwiftUI
import AppKit

private struct ListContinuationResult {
    let prefix: String
    let isEmpty: Bool
}

private let orderedListRegex = try! NSRegularExpression(pattern: #"^(\d+)\. "#)
private let alphaListRegex = try! NSRegularExpression(pattern: #"^([a-zA-Z])\. "#)
private let yamlListRegex = try! NSRegularExpression(pattern: #"^(\s*)-\s?"#)

private func listContinuationPrefix(from text: String) -> ListContinuationResult? {
    for taskPrefix in ["- [x] ", "- [X] ", "- [ ] "] {
        if text.hasPrefix(taskPrefix) {
            let rest = text.dropFirst(taskPrefix.count)
            return ListContinuationResult(prefix: "- [ ] ", isEmpty: rest.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }
    for marker in ["- ", "* ", "+ "] {
        if text.hasPrefix(marker) {
            let rest = text.dropFirst(marker.count)
            return ListContinuationResult(prefix: marker, isEmpty: rest.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }
    let nsText = text as NSString
    let nsRange = NSRange(location: 0, length: nsText.length)
    if let match = orderedListRegex.firstMatch(in: text, range: nsRange),
       let numRange = Range(match.range(at: 1), in: text) {
        let num = Int(text[numRange]) ?? 1
        let rest = text.dropFirst(match.range.length)
        return ListContinuationResult(prefix: "\(num + 1). ", isEmpty: rest.trimmingCharacters(in: .whitespaces).isEmpty)
    }
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

struct BlockEditorView: NSViewRepresentable {
    var blockID: UUID
    var blockKind: MarkdownBlockKind
    @Binding var content: String
    var searchText: String
    var registry: BlockRegistry
    var isSlashMenuPresented: Bool = false
    var onHeightChange: (CGFloat) -> Void
    var onSplitBlock: (String, Int, String?, String?, Int?) -> Void
    var onMergeWithPrevious: (String) -> Void
    var onNavigatePrevious: (CursorPlacement) -> Void
    var onNavigateNext: (CursorPlacement) -> Void
    var onSlashQueryChange: (String?) -> Void = { _ in }
    var onSlashMoveSelection: (Int) -> Void = { _ in }
    var onSlashConfirmSelection: () -> Void = {}
    var onSlashDismiss: () -> Void = {}

    func makeNSView(context: Context) -> NSScrollView {
        let storage = NSTextStorage()
        let layout = MarkdownLayoutManager()
        let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)

        let textView = BlockNSTextView(frame: .zero, textContainer: container)
        textView.blockID = blockID
        textView.registry = registry
        textView.isSlashMenuPresented = isSlashMenuPresented
        textView.onSlashMoveSelection = onSlashMoveSelection
        textView.onSlashConfirmSelection = onSlashConfirmSelection
        textView.onSlashDismiss = onSlashDismiss
        configureTextView(textView)
        configureTextContainer(container, for: textView)
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
                tv.insertNewline(nil)
                return
            }
            let loc = tv.selectedRange().location
            let originalContent = tv.string
            var newBefore = String(originalContent.prefix(loc))
            let rawAfter = String(originalContent.suffix(originalContent.count - loc))
            var newAfter = rawAfter
            var cursorPos: Int? = nil

            if let lp = listContinuationPrefix(from: newBefore) {
                if lp.isEmpty {
                    newBefore = ""
                } else {
                    newAfter = lp.prefix + rawAfter
                    cursorPos = lp.prefix.count
                }
            }

            coord.isLoading = true
            tv.undoManager?.disableUndoRegistration()
            tv.string = newBefore
            tv.undoManager?.enableUndoRegistration()
            coord.isLoading = false
            coord.onTextChange(newBefore)
            coord.scheduleHeightUpdate(for: tv)
            coord.onSplitBlock(originalContent, loc, newBefore, newAfter, cursorPos)
        }
        textView.onBackspaceAtStart = { [weak coord, weak textView] in
            guard let coord, let tv = textView else { return }
            coord.onMergeWithPrevious(tv.string)
        }
        textView.onNavigatePrevious = { [weak coord] p in coord?.onNavigatePrevious(p) }
        textView.onNavigateNext = { [weak coord] p in coord?.onNavigateNext(p) }

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
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = blockKind == .table
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.documentView = textView
        textView.autoresizingMask = blockKind == .table ? [.height] : [.width]

        Task { [weak textView] in
            guard let tv = textView else { return }
            coord.scheduleHeightUpdate(for: tv)
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? BlockNSTextView else { return }

        context.coordinator.onTextChange = { [self] t in content = t }
        context.coordinator.onHeightChange = onHeightChange
        context.coordinator.onSplitBlock = onSplitBlock
        context.coordinator.onMergeWithPrevious = onMergeWithPrevious
        context.coordinator.onNavigatePrevious = onNavigatePrevious
        context.coordinator.onNavigateNext = onNavigateNext
        context.coordinator.onSlashQueryChange = onSlashQueryChange
        textView.isSlashMenuPresented = isSlashMenuPresented
        textView.onSlashMoveSelection = onSlashMoveSelection
        textView.onSlashConfirmSelection = onSlashConfirmSelection
        textView.onSlashDismiss = onSlashDismiss

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
            Task { [weak textView] in
                guard let tv = textView else { return }
                coord.scheduleHeightUpdate(for: tv)
            }
        }

        context.coordinator.applySearchHighlights(to: textView, query: searchText)
    }

    func makeCoordinator() -> BlockEditorCoordinator {
        BlockEditorCoordinator(
            blockKind: blockKind,
            onTextChange: { [self] t in content = t },
            onHeightChange: onHeightChange,
            onSplitBlock: onSplitBlock,
            onMergeWithPrevious: onMergeWithPrevious,
            onNavigatePrevious: onNavigatePrevious,
            onNavigateNext: onNavigateNext
        )
    }

    private func configureTextView(_ tv: NSTextView) {
        tv.isEditable = true
        tv.isSelectable = true
        tv.allowsUndo = true
        tv.isRichText = false
        tv.importsGraphics = false
        tv.font = Styles.bodyFont
        tv.textColor = .labelColor
        tv.backgroundColor = .clear
        tv.drawsBackground = false
        tv.isVerticallyResizable = true
        tv.minSize = .zero
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.textContainerInset = NSSize(width: 0, height: 4)
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticLinkDetectionEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = true
        tv.isContinuousSpellCheckingEnabled = true
        tv.isGrammarCheckingEnabled = true
        tv.typingAttributes = Styles.baseAttributes
        tv.linkTextAttributes = [:]
    }

    private func configureTextContainer(_ container: NSTextContainer, for textView: NSTextView) {
        container.lineFragmentPadding = 0
        container.heightTracksTextView = false

        if blockKind == .table {
            container.widthTracksTextView = false
            container.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                             height: CGFloat.greatestFiniteMagnitude)
            textView.isHorizontallyResizable = true
        } else {
            container.widthTracksTextView = true
            textView.isHorizontallyResizable = false
        }
    }
}

final class BlockNSTextView: NSTextView {
    private static let indentUnit = "    "

    var blockID: UUID = UUID()
    var onEnter: (() -> Void)?
    var onBackspaceAtStart: (() -> Void)?
    var onNavigatePrevious: ((CursorPlacement) -> Void)?
    var onNavigateNext: ((CursorPlacement) -> Void)?
    var onSlashMoveSelection: ((Int) -> Void)?
    var onSlashConfirmSelection: (() -> Void)?
    var onSlashDismiss: (() -> Void)?
    weak var registry: BlockRegistry?
    var isSlashMenuPresented = false

    var crossBlockSelectionRange: NSRange? {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
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
        if event.clickCount == 1 && handleLinkClickIfHit(at: point) { return }

        let anchorID = blockID
        let weakRegistry = registry
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { _ in
            Task { @MainActor in
                guard NSEvent.pressedMouseButtons & 1 == 1 else { return }
                guard let window = NSApp.keyWindow else { return }
                let winPt = window.convertPoint(fromScreen: NSEvent.mouseLocation)
                weakRegistry?.onCrossBlockDrag?(anchorID, winPt.y)
            }
        }
        RunLoop.current.add(timer, forMode: .eventTracking)

        super.mouseDown(with: event)
        timer.invalidate()
    }

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

        let localCheckbox = m.range(at: 2)
        let checkboxRange = NSRange(location: lineRange.location + localCheckbox.location,
                                    length: localCheckbox.length)

        guard charIndex >= lineRange.location,
              charIndex <= checkboxRange.location + checkboxRange.length else { return false }

        let current = ns.substring(with: checkboxRange)
        let replacement = current.lowercased() == "[x]" ? "[ ]" : "[x]"

        guard shouldChangeText(in: checkboxRange, replacementString: replacement) else { return false }
        replaceCharacters(in: checkboxRange, with: replacement)
        didChangeText()
        return true
    }

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
                addCursorRect(rect.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y), cursor: .pointingHand)
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
        let mods = event.modifierFlags
        let isShift = mods.contains(.shift)
        let isOpt = mods.contains(.option)
        let isCmd = mods.contains(.command)
        let isCtrl = mods.contains(.control)
        let modified = isShift || isOpt || isCmd || isCtrl

        switch event.keyCode {
        case 48 where !isOpt && !isCmd && !isCtrl:
            if isShift { outdentSelection() } else { indentSelection() }
            return
        case 53 where isSlashMenuPresented && !modified:
            onSlashDismiss?()
            return
        case 36 where !isShift:
            if isSlashMenuPresented {
                onSlashConfirmSelection?()
                return
            }
            onEnter?()
            return
        case 51:
            let r = selectedRange()
            if r.location == 0 && r.length == 0 {
                onBackspaceAtStart?()
                return
            }
            if r.length == 0, r.location > 0, r.location < string.count {
                let ns = string as NSString
                let prev = ns.substring(with: NSRange(location: r.location - 1, length: 1))
                let next = ns.substring(with: NSRange(location: r.location, length: 1))
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
        case 123 where !modified:
            if selectedRange().location == 0 && selectedRange().length == 0 {
                onNavigatePrevious?(.end)
                return
            }
        case 124 where !modified:
            if selectedRange().location == string.count && selectedRange().length == 0 {
                onNavigateNext?(.start)
                return
            }
        case 126 where !modified:
            if isSlashMenuPresented {
                onSlashMoveSelection?(-1)
                return
            }
            if isOnFirstLine() {
                onNavigatePrevious?(.end)
                return
            }
        case 125 where !modified:
            if isSlashMenuPresented {
                onSlashMoveSelection?(1)
                return
            }
            if isOnLastLine() {
                onNavigateNext?(.start)
                return
            }
        default:
            break
        }
        super.keyDown(with: event)
    }

    private func isOnFirstLine() -> Bool {
        guard let lm = layoutManager, lm.numberOfGlyphs > 0 else { return true }
        let loc = selectedRange().location
        let gi = loc < string.count ? lm.glyphIndexForCharacter(at: loc) : lm.numberOfGlyphs - 1
        let cur = lm.lineFragmentRect(forGlyphAt: min(gi, lm.numberOfGlyphs - 1), effectiveRange: nil)
        let top = lm.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil)
        return abs(cur.minY - top.minY) < 1
    }

    private func isOnLastLine() -> Bool {
        guard let lm = layoutManager, lm.numberOfGlyphs > 0 else { return true }
        let loc = selectedRange().location
        let gi = loc < string.count ? lm.glyphIndexForCharacter(at: loc) : lm.numberOfGlyphs - 1
        let cur = lm.lineFragmentRect(forGlyphAt: min(gi, lm.numberOfGlyphs - 1), effectiveRange: nil)
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

@MainActor
final class BlockEditorCoordinator: NSObject {
    private static let tableVisualBottomInset: CGFloat = 6

    private let highlighter: EditorCoordinator
    private let blockKind: MarkdownBlockKind
    private var lastReportedHeight: CGFloat = 24
    private var heightUpdatePending = false

    var onTextChange: (String) -> Void
    var onHeightChange: (CGFloat) -> Void
    var onSplitBlock: (String, Int, String?, String?, Int?) -> Void
    var onMergeWithPrevious: (String) -> Void
    var onNavigatePrevious: (CursorPlacement) -> Void
    var onNavigateNext: (CursorPlacement) -> Void
    var onSlashQueryChange: (String?) -> Void = { _ in }
    var isLoading = false

    init(
        blockKind: MarkdownBlockKind,
        onTextChange: @escaping (String) -> Void,
        onHeightChange: @escaping (CGFloat) -> Void,
        onSplitBlock: @escaping (String, Int, String?, String?, Int?) -> Void,
        onMergeWithPrevious: @escaping (String) -> Void,
        onNavigatePrevious: @escaping (CursorPlacement) -> Void,
        onNavigateNext: @escaping (CursorPlacement) -> Void
    ) {
        self.blockKind = blockKind
        self.highlighter = EditorCoordinator(onTextChange: { _ in })
        self.onTextChange = onTextChange
        self.onHeightChange = onHeightChange
        self.onSplitBlock = onSplitBlock
        self.onMergeWithPrevious = onMergeWithPrevious
        self.onNavigatePrevious = onNavigatePrevious
        self.onNavigateNext = onNavigateNext
    }

    func applyFullHighlight(to storage: NSTextStorage) {
        highlighter.applyFullHighlight(to: storage)
        removeCodeFenceBackgroundIfNeeded(from: storage)
    }

    func registerTextView(_ tv: NSTextView) {
        highlighter.textView = tv
        tv.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(textViewFrameDidChange(_:)),
            name: NSView.frameDidChangeNotification,
            object: tv
        )
    }

    @objc private func textViewFrameDidChange(_ notification: Notification) {
        guard let tv = notification.object as? NSTextView else { return }
        scheduleHeightUpdate(for: tv)
    }

    func applySearchHighlights(to textView: NSTextView, query: String) {
        highlighter.applySearchHighlights(to: textView, query: query)
    }

    func scheduleHeightUpdate(for textView: NSTextView) {
        guard !heightUpdatePending else { return }
        heightUpdatePending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { [weak self, weak textView] in
            guard let self, let textView else { return }
            self.heightUpdatePending = false
            self.updateHeight(for: textView)
        }
    }

    private func updateHeight(for textView: NSTextView) {
        guard let lm = textView.layoutManager, let tc = textView.textContainer else { return }
        lm.ensureLayout(for: tc)
        let rect = lm.usedRect(for: tc)
        let inset = textView.textContainerInset
        let extraHeight = blockKind == .table ? Self.tableVisualBottomInset : 0
        let newHeight = max(ceil(rect.height) + inset.height * 2 + extraHeight, 24)
        guard abs(newHeight - lastReportedHeight) > 0.5 else { return }
        lastReportedHeight = newHeight

        // Avoid publishing SwiftUI state changes from within AppKit layout/update passes.
        DispatchQueue.main.async { [newHeight, onHeightChange] in
            onHeightChange(newHeight)
        }
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
        highlighter.textStorage(textStorage,
                                didProcessEditing: editedMask,
                                range: editedRange,
                                changeInLength: delta)
        removeCodeFenceBackgroundIfNeeded(from: textStorage)
    }
}

extension BlockEditorCoordinator: NSTextViewDelegate {
    private static var isApplyingAutoPair = false

    func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
        guard !Self.isApplyingAutoPair, !isLoading else { return true }
        guard let typed = replacementString, typed.count == 1 else { return true }
        let ns = textView.string as NSString
        let cursorPos = range.location
        let prevChar = cursorPos > 0 ? ns.substring(with: NSRange(location: cursorPos - 1, length: 1)) : ""
        let nextChar = cursorPos < ns.length ? ns.substring(with: NSRange(location: cursorPos, length: 1)) : ""

        if range.length > 0 {
            let (open, close): (String, String)
            switch typed {
            case "*": (open, close) = ("*", "*")
            case "`": (open, close) = ("`", "`")
            case "_": (open, close) = ("_", "_")
            case "[": (open, close) = ("[", "]")
            default: return true
            }
            let sel = ns.substring(with: range)
            applyAutoPair(in: textView, replace: range,
                          with: open + sel + close,
                          cursorAt: range.location + open.count + sel.count)
            return false
        }

        switch typed {
        case "*":
            if prevChar == "*" && nextChar == "*" {
                applyAutoPair(in: textView, replace: range, with: "**", cursorAt: cursorPos + 1)
                return false
            }
            let starLineRange = ns.lineRange(for: NSRange(location: cursorPos, length: 0))
            let starPrefix = ns.substring(with: NSRange(location: starLineRange.location,
                                                        length: cursorPos - starLineRange.location))
                .trimmingCharacters(in: .whitespaces)
            if !starPrefix.isEmpty && starPrefix.allSatisfy({ $0 == "*" }) { return true }
            applyAutoPair(in: textView, replace: range, with: "**", cursorAt: cursorPos + 1)
            return false

        case "_":
            if prevChar == "_" && nextChar == "_" {
                applyAutoPair(in: textView, replace: range, with: "__", cursorAt: cursorPos + 1)
                return false
            }
            let usLineRange = ns.lineRange(for: NSRange(location: cursorPos, length: 0))
            let usPrefix = ns.substring(with: NSRange(location: usLineRange.location,
                                                      length: cursorPos - usLineRange.location))
                .trimmingCharacters(in: .whitespaces)
            if !usPrefix.isEmpty && usPrefix.allSatisfy({ $0 == "_" }) { return true }
            applyAutoPair(in: textView, replace: range, with: "__", cursorAt: cursorPos + 1)
            return false

        case "`" where prevChar != "`":
            if nextChar == "`" {
                applySkipOver(in: textView, to: cursorPos + 1)
                return false
            }
            applyAutoPair(in: textView, replace: range, with: "``", cursorAt: cursorPos + 1)
            return false

        case "[":
            applyAutoPair(in: textView, replace: range, with: "[]", cursorAt: cursorPos + 1)
            return false

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
        onSlashQueryChange(Self.slashQuery(in: tv.string))
        tv.typingAttributes = Styles.baseAttributes
        Task { [weak self, weak tv] in
            guard let self, let tv else { return }
            self.scheduleHeightUpdate(for: tv)
            scrollCursorToVisible(in: tv)
        }
    }

    private static func slashQuery(in text: String) -> String? {
        guard !text.contains("\n"),
              text.hasPrefix("/"),
              !text.dropFirst().contains(where: { $0.isWhitespace }) else {
            return nil
        }

        return String(text.dropFirst())
    }
}
