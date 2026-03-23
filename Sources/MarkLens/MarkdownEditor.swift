import SwiftUI
import AppKit

// MARK: - MarkLensTextView

private final class MarkLensTextView: NSTextView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let ch = event.charactersIgnoringModifiers?.lowercased()
        if ch == "o" && (flags == .command || flags == [.command, .shift]) { return false }
        return super.performKeyEquivalent(with: event)
    }
}

// MARK: - MarkdownEditor

struct MarkdownEditor: NSViewRepresentable {
    @Binding var text: String
    var onTextChange: (String) -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let textView = MarkLensTextView()
        configure(textView)
        textView.delegate = context.coordinator
        textView.textStorage?.delegate = context.coordinator

        if !text.isEmpty {
            // isLoading prevents textDidChange from flagging hasUnsavedEdits
            context.coordinator.isLoading = true
            textView.string = text
            context.coordinator.isLoading = false
            // Full synchronous highlight — overrides the debounced scan
            context.coordinator.fullScanWorkItem?.cancel()
            context.coordinator.applyFullHighlight(to: textView.textStorage!)
        }

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.backgroundColor = NSColor.textBackgroundColor
        scroll.documentView = textView
        textView.autoresizingMask = [.width]
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView else { return }
        // Never replace content while the user is editing — cursor would jump.
        // File switches use .id(selectedFileURL) to recreate the view entirely,
        // giving a fresh coordinator with hasUnsavedEdits = false.
        guard !context.coordinator.hasUnsavedEdits else { return }
        guard textView.string != text else { return }

        context.coordinator.isLoading = true
        textView.string = text
        context.coordinator.isLoading = false
        context.coordinator.fullScanWorkItem?.cancel()
        if let storage = textView.textStorage {
            context.coordinator.applyFullHighlight(to: storage)
        }
    }

    func makeCoordinator() -> EditorCoordinator {
        EditorCoordinator(onTextChange: onTextChange)
    }

    private func configure(_ tv: NSTextView) {
        tv.isEditable = true
        tv.isSelectable = true
        tv.allowsUndo = true
        tv.isRichText = false
        tv.importsGraphics = false
        tv.font = Styles.bodyFont
        tv.textColor = NSColor.labelColor
        tv.backgroundColor = NSColor.textBackgroundColor
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.minSize = .zero
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.textContainerInset = NSSize(width: 48, height: 40)
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.lineFragmentPadding = 0
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticLinkDetectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.isGrammarCheckingEnabled = false
        tv.typingAttributes = Styles.baseAttributes
    }
}

// MARK: - EditorCoordinator

final class EditorCoordinator: NSObject {
    var onTextChange: (String) -> Void
    var hasUnsavedEdits = false
    var isLoading = false
    var fullScanWorkItem: DispatchWorkItem?

    init(onTextChange: @escaping (String) -> Void) {
        self.onTextChange = onTextChange
    }

    // MARK: Full highlight (used on file load)

    func applyFullHighlight(to storage: NSTextStorage) {
        let full = NSRange(location: 0, length: storage.length)
        guard full.length > 0 else { return }
        storage.beginEditing()
        applyBase(to: full, storage: storage)
        applyInline(to: full, storage: storage)
        applyFenced(to: full, storage: storage)
        applyTables(to: full, storage: storage)
        storage.endEditing()
    }

    // MARK: Highlighting primitives

    private func applyBase(to range: NSRange, storage: NSTextStorage) {
        storage.setAttributes(Styles.baseAttributes, range: range)
    }

    private func applyInline(to range: NSRange, storage: NSTextStorage) {
        let ns = storage.string as NSString

        // Headings
        Patterns.heading.enumerateMatches(in: storage.string, range: range) { m, _, _ in
            guard let m else { return }
            let syntax = m.range(at: 1), content = m.range(at: 2)
            let level = ns.substring(with: syntax).filter { $0 == "#" }.count
            storage.addAttribute(.font, value: Styles.headingFont(level: level), range: m.range)
            storage.addAttribute(.paragraphStyle, value: Styles.headingParagraphStyle(level: level), range: m.range)
            if syntax.length > 0 { storage.addAttribute(.foregroundColor, value: Styles.syntaxColor, range: syntax) }
            if content.length > 0 { storage.addAttribute(.foregroundColor, value: NSColor.labelColor, range: content) }
        }

        // Bold
        Patterns.bold.enumerateMatches(in: storage.string, range: range) { m, _, _ in
            guard let m else { return }
            let full = m.range; guard full.length > 4 else { return }
            let dlen = m.range(at: 1).length
            let bold = NSFontManager.shared.convert(Styles.bodyFont, toHaveTrait: .boldFontMask)
            let content = NSRange(location: full.location + dlen, length: full.length - dlen * 2)
            if content.length > 0 { storage.addAttribute(.font, value: bold, range: content) }
            storage.addAttribute(.foregroundColor, value: Styles.syntaxColor, range: NSRange(location: full.location, length: dlen))
            storage.addAttribute(.foregroundColor, value: Styles.syntaxColor, range: NSRange(location: NSMaxRange(full) - dlen, length: dlen))
        }

        // Italic
        Patterns.italic.enumerateMatches(in: storage.string, range: range) { m, _, _ in
            guard let m else { return }
            let full = m.range; guard full.length > 2 else { return }
            let italic = NSFontManager.shared.convert(Styles.bodyFont, toHaveTrait: .italicFontMask)
            let content = NSRange(location: full.location + 1, length: full.length - 2)
            if content.length > 0 { storage.addAttribute(.font, value: italic, range: content) }
            storage.addAttribute(.foregroundColor, value: Styles.syntaxColor, range: NSRange(location: full.location, length: 1))
            storage.addAttribute(.foregroundColor, value: Styles.syntaxColor, range: NSRange(location: NSMaxRange(full) - 1, length: 1))
        }

        // Strikethrough
        Patterns.strikethrough.enumerateMatches(in: storage.string, range: range) { m, _, _ in
            guard let m else { return }
            let full = m.range; guard full.length > 4 else { return }
            let content = NSRange(location: full.location + 2, length: full.length - 4)
            if content.length > 0 {
                storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: content)
                storage.addAttribute(.strikethroughColor, value: NSColor.secondaryLabelColor, range: content)
            }
            storage.addAttribute(.foregroundColor, value: Styles.syntaxColor, range: NSRange(location: full.location, length: 2))
            storage.addAttribute(.foregroundColor, value: Styles.syntaxColor, range: NSRange(location: NSMaxRange(full) - 2, length: 2))
        }

        // Inline code
        Patterns.inlineCode.enumerateMatches(in: storage.string, range: range) { m, _, _ in
            guard let m else { return }
            let full = m.range; let ticks = m.range(at: 1).length
            guard full.length > ticks * 2 else { return }
            storage.addAttribute(.font, value: Styles.monoFont, range: full)
            storage.addAttribute(.backgroundColor, value: Styles.codeBackground, range: full)
            storage.addAttribute(.foregroundColor, value: Styles.syntaxColor, range: NSRange(location: full.location, length: ticks))
            storage.addAttribute(.foregroundColor, value: Styles.syntaxColor, range: NSRange(location: NSMaxRange(full) - ticks, length: ticks))
        }

        // Blockquote
        Patterns.blockquote.enumerateMatches(in: storage.string, range: range) { m, _, _ in
            guard let m else { return }
            storage.addAttribute(.paragraphStyle, value: Styles.blockquoteParagraphStyle, range: m.range)
            storage.addAttribute(.foregroundColor, value: Styles.syntaxColor, range: m.range(at: 1))
            if m.range(at: 2).length > 0 { storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: m.range(at: 2)) }
        }

        // List markers
        Patterns.listItem.enumerateMatches(in: storage.string, range: range) { m, _, _ in
            guard let m else { return }
            storage.addAttribute(.foregroundColor, value: Styles.syntaxColor, range: m.range(at: 1))
        }

        // Links
        Patterns.link.enumerateMatches(in: storage.string, range: range) { m, _, _ in
            guard let m else { return }
            let textRange = m.range(at: 2)
            if textRange.length > 0 {
                storage.addAttribute(.foregroundColor, value: NSColor.linkColor, range: textRange)
                storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: textRange)
            }
            [m.range(at: 1), m.range(at: 3), m.range(at: 4), m.range(at: 5)].forEach { r in
                if r.length > 0 { storage.addAttribute(.foregroundColor, value: Styles.syntaxColor, range: r) }
            }
        }

        // Horizontal rule
        Patterns.horizontalRule.enumerateMatches(in: storage.string, range: range) { m, _, _ in
            guard let m else { return }
            storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: m.range)
            storage.addAttribute(.font, value: NSFont.systemFont(ofSize: 8), range: m.range)
            storage.addAttribute(.paragraphStyle, value: Styles.hrParagraphStyle, range: m.range)
        }
    }

    private func applyFenced(to range: NSRange, storage: NSTextStorage) {
        Patterns.fencedCode.enumerateMatches(in: storage.string, options: [], range: range) { m, _, _ in
            guard let m else { return }
            storage.addAttribute(.font, value: Styles.monoFont, range: m.range)
            storage.addAttribute(.backgroundColor, value: Styles.codeBackground, range: m.range)
            storage.addAttribute(.paragraphStyle, value: Styles.codeParagraphStyle, range: m.range)
            if m.range(at: 1).length > 0 { storage.addAttribute(.foregroundColor, value: Styles.syntaxColor, range: m.range(at: 1)) }
            if m.range(at: 2).length > 0 { storage.addAttribute(.foregroundColor, value: NSColor.labelColor, range: m.range(at: 2)) }
            if m.range(at: 3).length > 0 { storage.addAttribute(.foregroundColor, value: Styles.syntaxColor, range: m.range(at: 3)) }
        }
    }

    private func applyTables(to range: NSRange, storage: NSTextStorage) {
        let ns = storage.string as NSString
        let bold = NSFontManager.shared.convert(Styles.bodyFont, toHaveTrait: .boldFontMask)

        Patterns.tableSeparator.enumerateMatches(in: storage.string, options: [], range: range) { m, _, _ in
            guard let m else { return }
            storage.addAttribute(.foregroundColor, value: Styles.syntaxColor, range: m.range)
            let sepStart = m.range.location
            guard sepStart > 0 else { return }
            let headerRange = ns.lineRange(for: NSRange(location: sepStart - 1, length: 0))
            if headerRange.length > 0 { storage.addAttribute(.font, value: bold, range: headerRange) }
        }

        Patterns.tableRow.enumerateMatches(in: storage.string, options: [], range: range) { m, _, _ in
            guard let m else { return }
            Patterns.pipe.enumerateMatches(in: storage.string, options: [], range: m.range) { pm, _, _ in
                guard let pm else { return }
                storage.addAttribute(.foregroundColor, value: Styles.syntaxColor, range: pm.range)
            }
        }
    }
}

// MARK: NSTextViewDelegate

extension EditorCoordinator: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) {
        guard !isLoading, let tv = notification.object as? NSTextView else { return }
        hasUnsavedEdits = true
        onTextChange(tv.string)
        tv.typingAttributes = Styles.baseAttributes
    }
}

// MARK: NSTextStorageDelegate

extension EditorCoordinator: NSTextStorageDelegate {
    func textStorage(_ textStorage: NSTextStorage,
                     didProcessEditing editedMask: NSTextStorageEditActions,
                     range editedRange: NSRange,
                     changeInLength delta: Int) {
        // Only react to character changes — attribute-only edits are from our
        // own highlighting and must be ignored to prevent infinite recursion.
        guard editedMask.contains(.editedCharacters) else { return }
        let len = textStorage.length
        guard len > 0 else { return }

        // Immediate: re-style the edited paragraph
        let paraRange = (textStorage.string as NSString).paragraphRange(for: editedRange)
        textStorage.beginEditing()
        applyBase(to: paraRange, storage: textStorage)
        applyInline(to: paraRange, storage: textStorage)
        textStorage.endEditing()

        // Debounced: full-doc scan for fenced blocks and tables (expensive)
        fullScanWorkItem?.cancel()
        let item = DispatchWorkItem { [weak textStorage] in
            guard let ts = textStorage, ts.length > 0 else { return }
            let full = NSRange(location: 0, length: ts.length)
            ts.beginEditing()
            if ts.string.contains("```") { self.applyFenced(to: full, storage: ts) }
            if ts.string.contains("|")   { self.applyTables(to: full, storage: ts) }
            ts.endEditing()
        }
        fullScanWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: item)
    }
}

// MARK: - Styles

enum Styles {
    static let bodyFont  = NSFont.systemFont(ofSize: 15, weight: .regular)
    static let monoFont  = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

    static let baseAttributes: [NSAttributedString.Key: Any] = [
        .font: bodyFont,
        .foregroundColor: NSColor.labelColor,
        .paragraphStyle: defaultParagraphStyle
    ]

    static var defaultParagraphStyle: NSParagraphStyle {
        let ps = NSMutableParagraphStyle(); ps.lineSpacing = 4; ps.paragraphSpacing = 2; return ps
    }

    static func headingFont(level: Int) -> NSFont {
        switch level {
        case 1: return NSFont.boldSystemFont(ofSize: 32)
        case 2: return NSFont.boldSystemFont(ofSize: 24)
        case 3: return NSFont.boldSystemFont(ofSize: 20)
        default: return NSFont.systemFont(ofSize: 17, weight: .semibold)
        }
    }

    static func headingParagraphStyle(level: Int) -> NSParagraphStyle {
        let ps = NSMutableParagraphStyle()
        ps.lineSpacing = 2
        ps.paragraphSpacingBefore = level <= 2 ? 16 : 10
        ps.paragraphSpacing = level <= 2 ? 6 : 4
        return ps
    }

    static var blockquoteParagraphStyle: NSParagraphStyle {
        let ps = NSMutableParagraphStyle(); ps.headIndent = 20; ps.firstLineHeadIndent = 20; ps.lineSpacing = 3; return ps
    }

    static var codeParagraphStyle: NSParagraphStyle {
        let ps = NSMutableParagraphStyle(); ps.lineSpacing = 2; ps.paragraphSpacing = 0; return ps
    }

    static var hrParagraphStyle: NSParagraphStyle {
        let ps = NSMutableParagraphStyle(); ps.paragraphSpacingBefore = 10; ps.paragraphSpacing = 10; return ps
    }

    static let syntaxColor   = NSColor.tertiaryLabelColor
    static let codeBackground = NSColor.quaternaryLabelColor
}

// MARK: - Patterns

private enum Patterns {
    static let heading       = try! NSRegularExpression(pattern: #"^(#{1,6} )(.*)"#, options: .anchorsMatchLines)
    static let bold          = try! NSRegularExpression(pattern: #"(\*\*|__)(?!\s)(.+?)(?<!\s)\1"#)
    static let italic        = try! NSRegularExpression(pattern: #"(?<!\*)\*(?!\*)(.+?)(?<!\*)\*(?!\*)|(?<!_)_(?!_)(.+?)(?<!_)_(?!_)"#)
    static let strikethrough = try! NSRegularExpression(pattern: #"(~~)(.+?)(~~)"#)
    static let inlineCode    = try! NSRegularExpression(pattern: #"(`+)(.+?)\1"#)
    static let fencedCode    = try! NSRegularExpression(pattern: #"^(`{3,}[^\n]*\n)([\s\S]*?)(^`{3,}[ \t]*$)"#, options: .anchorsMatchLines)
    static let blockquote    = try! NSRegularExpression(pattern: #"^(>[ \t]?)(.*)"#, options: .anchorsMatchLines)
    static let listItem      = try! NSRegularExpression(pattern: #"^([-\*][ \t])(.*)"#, options: .anchorsMatchLines)
    static let link          = try! NSRegularExpression(pattern: #"(\[)([^\]\n]+)(\]\()([^\)\n]+)(\))"#)
    static let horizontalRule = try! NSRegularExpression(pattern: #"^(\-{3,}|\*{3,}|_{3,})[ \t]*$"#, options: .anchorsMatchLines)
    static let tableSeparator = try! NSRegularExpression(pattern: #"^\|[-:| \t]+$"#, options: .anchorsMatchLines)
    static let tableRow      = try! NSRegularExpression(pattern: #"^\|[^\n]+"#, options: .anchorsMatchLines)
    static let pipe          = try! NSRegularExpression(pattern: #"\|"#)
}
