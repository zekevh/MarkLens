import SwiftUI
import AppKit

// MARK: - Custom Attribute Keys

extension NSAttributedString.Key {
    nonisolated(unsafe) static let markdownHR       = NSAttributedString.Key("md.hr")
    nonisolated(unsafe) static let markdownCheckbox = NSAttributedString.Key("md.checkbox") // Bool: true = checked
}

// MARK: - MarkdownLayoutManager
// Used only to draw horizontal rule lines; table styling is handled via NSTextBlock.

final class MarkdownLayoutManager: NSLayoutManager {

    nonisolated override init() { super.init() }
    nonisolated required init?(coder: NSCoder) { super.init(coder: coder) }

    nonisolated override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage else { return }
        let charRange = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }

        storage.enumerateAttribute(.markdownHR, in: charRange, options: []) { val, rng, _ in
            guard val != nil else { return }
            let gr = self.glyphRange(forCharacterRange: rng, actualCharacterRange: nil)
            guard gr.length > 0 else { return }
            let lineRect = self.lineFragmentRect(forGlyphAt: gr.location, effectiveRange: nil)
                               .offsetBy(dx: origin.x, dy: origin.y)
            let y = floor(lineRect.midY) + 0.5
            let path = NSBezierPath()
            path.move(to: NSPoint(x: lineRect.minX, y: y))
            path.line(to: NSPoint(x: lineRect.maxX, y: y))
            path.lineWidth = 1
            NSColor.separatorColor.setStroke()
            path.stroke()
        }

        storage.enumerateAttribute(.markdownCheckbox, in: charRange, options: []) { val, rng, _ in
            guard let isChecked = val as? Bool else { return }
            let gr = self.glyphRange(forCharacterRange: rng, actualCharacterRange: nil)
            guard gr.length > 0 else { return }
            let lineRect    = self.lineFragmentRect(forGlyphAt: gr.location, effectiveRange: nil)
                                  .offsetBy(dx: origin.x, dy: origin.y)
            let glyphOffset = self.location(forGlyphAt: gr.location)
            let side: CGFloat = 13
            let squareRect = CGRect(
                x: lineRect.minX + glyphOffset.x,
                y: lineRect.midY - side / 2,
                width: side, height: side
            ).insetBy(dx: 0.5, dy: 0.5)
            let box = NSBezierPath(roundedRect: squareRect, xRadius: 2.5, yRadius: 2.5)
            box.lineWidth = 1.5
            NSColor.secondaryLabelColor.setStroke()
            box.stroke()

            if isChecked {
                let symConfig = NSImage.SymbolConfiguration(pointSize: 8.5, weight: .semibold)
                    .applying(NSImage.SymbolConfiguration(paletteColors: [.secondaryLabelColor]))
                if let img = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
                                 .withSymbolConfiguration(symConfig) {
                    let s = img.size
                    let drawRect = CGRect(
                        x: squareRect.midX - s.width  / 2,
                        y: squareRect.midY - s.height / 2,
                        width: s.width, height: s.height
                    )
                    img.draw(in: drawRect)
                }
            }
        }
    }
}


// MARK: - EditorCoordinator

@MainActor
class EditorCoordinator: NSObject {
    var onTextChange: (String) -> Void
    var hasUnsavedEdits = false
    var isLoading = false
    var fullScanWorkItem: DispatchWorkItem?
    private var lastSearchQuery = ""

    init(onTextChange: @escaping (String) -> Void) {
        self.onTextChange = onTextChange
    }

    // MARK: Search highlighting

    func applySearchHighlights(to textView: NSTextView, query: String) {
        guard query != lastSearchQuery else { return }
        lastSearchQuery = query

        guard let layoutManager = textView.layoutManager, let storage = textView.textStorage else { return }
        let fullRange = NSRange(location: 0, length: storage.length)

        // Always clear previous search highlights
        layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: fullRange)

        guard !query.isEmpty else { return }

        let content = storage.string as NSString
        var searchRange = NSRange(location: 0, length: content.length)

        while searchRange.location < content.length {
            let foundRange = content.range(of: query, options: .caseInsensitive, range: searchRange)
            if foundRange.location == NSNotFound { break }

            layoutManager.addTemporaryAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.3), forCharacterRange: foundRange)
            searchRange.location = NSMaxRange(foundRange)
            searchRange.length = content.length - searchRange.location
        }
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

        // Task list checkboxes — hide [ ]/[x] text and draw a square via MarkdownLayoutManager
        Patterns.taskListItem.enumerateMatches(in: storage.string, range: range) { m, _, _ in
            guard let m else { return }
            let checkboxRange = m.range(at: 2)
            let contentRange  = m.range(at: 4)
            let isChecked = checkboxRange.length > 0 &&
                            ns.substring(with: checkboxRange).lowercased() == "[x]"
            if checkboxRange.length > 0 {
                storage.addAttribute(.foregroundColor,    value: NSColor.clear, range: checkboxRange)
                storage.addAttribute(.markdownCheckbox,   value: isChecked,     range: checkboxRange)
            }
            if isChecked && contentRange.length > 0 {
                storage.addAttribute(.foregroundColor,    value: NSColor.tertiaryLabelColor,       range: contentRange)
                storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: contentRange)
                storage.addAttribute(.strikethroughColor, value: NSColor.secondaryLabelColor,      range: contentRange)
            }
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

        // Horizontal rule — hide the syntax, draw a line via MarkdownLayoutManager
        Patterns.horizontalRule.enumerateMatches(in: storage.string, range: range) { m, _, _ in
            guard let m else { return }
            storage.addAttribute(.foregroundColor, value: NSColor.clear, range: m.range)
            storage.addAttribute(.markdownHR, value: true, range: m.range)
            storage.addAttribute(.paragraphStyle, value: Styles.hrParagraphStyle, range: m.range)
        }
    }

    private func applyFenced(to range: NSRange, storage: NSTextStorage) {
        let ns = storage.string as NSString
        Patterns.fencedCode.enumerateMatches(in: storage.string, options: [], range: range) { m, _, _ in
            guard let m else { return }
            storage.addAttribute(.font, value: Styles.monoFont, range: m.range)
            storage.addAttribute(.backgroundColor, value: Styles.codeBackground, range: m.range)
            storage.addAttribute(.paragraphStyle, value: Styles.codeParagraphStyle, range: m.range)

            let openFence  = m.range(at: 1)
            let codeBody   = m.range(at: 2)
            let closeFence = m.range(at: 3)

            if openFence.length > 0  { storage.addAttribute(.foregroundColor, value: Styles.syntaxColor, range: openFence) }
            if codeBody.length > 0   { storage.addAttribute(.foregroundColor, value: NSColor.labelColor, range: codeBody) }
            if closeFence.length > 0 { storage.addAttribute(.foregroundColor, value: Styles.syntaxColor, range: closeFence) }

            // Code syntax highlighting — extract language from opening fence line
            if codeBody.length > 0 {
                let fenceLine = ns.substring(with: openFence)
                let language = fenceLine
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .drop(while: { $0 == "`" })
                    .trimmingCharacters(in: .whitespaces)
                    .lowercased()
                if !language.isEmpty {
                    CodeHighlighter.apply(to: storage, codeRange: codeBody, language: language)
                }
            }
        }
    }

    private func applyTables(to range: NSRange, storage: NSTextStorage) {
        let ns = storage.string as NSString
        let boldTableFont = NSFontManager.shared.convert(Styles.tableFont, toHaveTrait: .boldFontMask)
        let border     = NSColor.separatorColor.withAlphaComponent(0.45)
        let bodyBorder = NSColor.separatorColor.withAlphaComponent(0.2)

        Patterns.tableSeparator.enumerateMatches(in: storage.string, options: [], range: range) { m, _, _ in
            guard let m else { return }
            let sepRange = m.range

            // Collapse the |---|---| separator row to near-zero height, invisible text
            storage.addAttribute(.foregroundColor, value: NSColor.clear, range: sepRange)
            storage.addAttribute(.font, value: NSFont.systemFont(ofSize: 0.01), range: sepRange)
            storage.addAttribute(.paragraphStyle, value: Styles.collapsedRowParagraphStyle, range: sepRange)

            // ── Header row (line immediately before separator) ────────────
            guard sepRange.location > 0 else { return }
            let headerRange = ns.lineRange(for: NSRange(location: sepRange.location - 1, length: 0))
            guard headerRange.length > 0 else { return }

            let headerBlock = NSTextBlock()
            headerBlock.backgroundColor = (NSColor(white: 1, alpha: 0.07))
            // Top edge = table outer border
            headerBlock.setBorderColor(border, for: .minY)
            headerBlock.setWidth(0.5, type: .absoluteValueType, for: .border, edge: .minY)
            // Bottom edge = header/body divider (heavier)
            headerBlock.setBorderColor(border, for: .maxY)
            headerBlock.setWidth(1.5, type: .absoluteValueType, for: .border, edge: .maxY)
            // Vertical padding so text doesn't sit flush against the border
            headerBlock.setWidth(5, type: .absoluteValueType, for: .padding, edge: .minY)
            headerBlock.setWidth(5, type: .absoluteValueType, for: .padding, edge: .maxY)

            let headerPS = NSMutableParagraphStyle()
            headerPS.textBlocks = [headerBlock]
            storage.addAttribute(.font, value: boldTableFont, range: headerRange)
            storage.addAttribute(.paragraphStyle, value: headerPS, range: headerRange)

            // ── Body rows ─────────────────────────────────────────────────
            var rowIndex = 0
            var pos = NSMaxRange(sepRange)
            while pos < storage.length {
                let lineRange = ns.lineRange(for: NSRange(location: pos, length: 0))
                let trimmed = ns.substring(with: lineRange).trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.hasPrefix("|") else { break }

                let bodyBlock = NSTextBlock()
                if rowIndex % 2 == 1 {
                    bodyBlock.backgroundColor = (NSColor(white: 1, alpha: 0.04))
                }
                // Bottom border as row separator; last row closes the table box
                bodyBlock.setBorderColor(bodyBorder, for: .maxY)
                bodyBlock.setWidth(0.5, type: .absoluteValueType, for: .border, edge: .maxY)
                bodyBlock.setWidth(4, type: .absoluteValueType, for: .padding, edge: .minY)
                bodyBlock.setWidth(4, type: .absoluteValueType, for: .padding, edge: .maxY)

                let bodyPS = NSMutableParagraphStyle()
                bodyPS.textBlocks = [bodyBlock]
                storage.addAttribute(.font, value: Styles.tableFont, range: lineRange)
                storage.addAttribute(.paragraphStyle, value: bodyPS, range: lineRange)

                rowIndex += 1
                pos = NSMaxRange(lineRange)
            }
        }

        // Style | as visible column dividers across all table rows
        Patterns.tableRow.enumerateMatches(in: storage.string, options: [], range: range) { m, _, _ in
            guard let m else { return }
            Patterns.pipe.enumerateMatches(in: storage.string, options: [], range: m.range) { pm, _, _ in
                guard let pm else { return }
                storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: pm.range)
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

extension EditorCoordinator: @preconcurrency NSTextStorageDelegate {
    func textStorage(_ textStorage: NSTextStorage,
                     didProcessEditing editedMask: NSTextStorageEditActions,
                     range editedRange: NSRange,
                     changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters) else { return }
        let len = textStorage.length
        guard len > 0 else { return }

        let paraRange = (textStorage.string as NSString).paragraphRange(for: editedRange)
        textStorage.beginEditing()
        applyBase(to: paraRange, storage: textStorage)
        applyInline(to: paraRange, storage: textStorage)
        textStorage.endEditing()

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
    nonisolated(unsafe) static let bodyFont  = NSFont.systemFont(ofSize: 15, weight: .regular)
    nonisolated(unsafe) static let monoFont  = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    nonisolated(unsafe) static let tableFont = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)

    nonisolated(unsafe) static let baseAttributes: [NSAttributedString.Key: Any] = [
        .font: bodyFont,
        .foregroundColor: NSColor.labelColor,
        .paragraphStyle: defaultParagraphStyle
    ]

    nonisolated static var defaultParagraphStyle: NSParagraphStyle {
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
        ps.paragraphSpacingBefore = level == 1 ? 40 : level == 2 ? 32 : 24
        ps.paragraphSpacing      = level == 1 ? 16 : level == 2 ? 12 : 8
        return ps
    }

    static var blockquoteParagraphStyle: NSParagraphStyle {
        let ps = NSMutableParagraphStyle(); ps.headIndent = 20; ps.firstLineHeadIndent = 20; ps.lineSpacing = 3; return ps
    }

    static var codeParagraphStyle: NSParagraphStyle {
        let ps = NSMutableParagraphStyle(); ps.lineSpacing = 2; ps.paragraphSpacing = 0; return ps
    }

    static var hrParagraphStyle: NSParagraphStyle {
        let ps = NSMutableParagraphStyle()
        ps.paragraphSpacingBefore = 10
        ps.paragraphSpacing = 10
        return ps
    }

    /// Collapses the `|---|---|` separator row to near-zero height.
    static var collapsedRowParagraphStyle: NSParagraphStyle {
        let ps = NSMutableParagraphStyle()
        ps.minimumLineHeight = 1
        ps.maximumLineHeight = 1
        ps.paragraphSpacing = 0
        ps.paragraphSpacingBefore = 0
        ps.lineSpacing = 0
        return ps
    }

    static let syntaxColor    = NSColor.tertiaryLabelColor
    static let codeBackground = NSColor.quaternaryLabelColor
}

// MARK: - Patterns

enum Patterns {
    static let heading       = try! NSRegularExpression(pattern: #"^(#{1,6} )(.*)"#, options: .anchorsMatchLines)
    static let bold          = try! NSRegularExpression(pattern: #"(\*\*|__)(?!\s)(.+?)(?<!\s)\1"#)
    static let italic        = try! NSRegularExpression(pattern: #"(?<!\*)\*(?!\*)(.+?)(?<!\*)\*(?!\*)|(?<!_)_(?!_)(.+?)(?<!_)_(?!_)"#)
    static let strikethrough = try! NSRegularExpression(pattern: #"(~~)(.+?)(~~)"#)
    static let inlineCode    = try! NSRegularExpression(pattern: #"(`+)(.+?)\1"#)
    static let fencedCode    = try! NSRegularExpression(pattern: #"^(`{3,}[^\n]*\n)([\s\S]*?)(^`{3,}[ \t]*$)"#, options: .anchorsMatchLines)
    static let blockquote    = try! NSRegularExpression(pattern: #"^(>[ \t]?)(.*)"#, options: .anchorsMatchLines)
    static let listItem      = try! NSRegularExpression(pattern: #"^([-\*][ \t])(.*)"#, options: .anchorsMatchLines)
    static let taskListItem  = try! NSRegularExpression(pattern: #"^([-*][ \t])(\[[ xX]\])([ \t])(.*)"#, options: .anchorsMatchLines)
    static let link          = try! NSRegularExpression(pattern: #"(\[)([^\]\n]+)(\]\()([^\)\n]+)(\))"#)
    static let horizontalRule = try! NSRegularExpression(pattern: #"^(\-{3,}|\*{3,}|_{3,})[ \t]*$"#, options: .anchorsMatchLines)
    static let tableSeparator = try! NSRegularExpression(pattern: #"^\|[-:| \t]+$"#, options: .anchorsMatchLines)
    static let tableRow      = try! NSRegularExpression(pattern: #"^\|[^\n]+"#, options: .anchorsMatchLines)
    static let pipe          = try! NSRegularExpression(pattern: #"\|"#)
}
