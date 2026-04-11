import SwiftUI
import AppKit

// MARK: - Custom Attribute Keys

nonisolated(unsafe) private let markdownHRKey = NSAttributedString.Key("md.hr")
nonisolated(unsafe) private let markdownCheckboxKey = NSAttributedString.Key("md.checkbox") // Bool: true = checked
nonisolated(unsafe) private let markdownTableRowKey = NSAttributedString.Key("md.tableRow")  // marks a table row for border drawing
nonisolated(unsafe) private let markdownTablePipeKey = NSAttributedString.Key("md.tablePipe") // marks a | for vertical line drawing

// MARK: - MarkdownLayoutManager
// Draws horizontal rule lines and task-list checkboxes.

final class MarkdownLayoutManager: NSLayoutManager {

    nonisolated override init() { super.init() }
    nonisolated required init?(coder: NSCoder) { super.init(coder: coder) }

    nonisolated override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage else { return }
        let charRange = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }

        storage.enumerateAttribute(markdownHRKey, in: charRange, options: []) { val, rng, _ in
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

        storage.enumerateAttribute(markdownCheckboxKey, in: charRange, options: []) { val, rng, _ in
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

        // Draw vertical column dividers at each hidden | character
        storage.enumerateAttribute(markdownTablePipeKey, in: charRange, options: []) { val, rng, _ in
            guard val != nil else { return }
            let gr = self.glyphRange(forCharacterRange: rng, actualCharacterRange: nil)
            guard gr.length > 0 else { return }
            let lineRect = self.lineFragmentRect(forGlyphAt: gr.location, effectiveRange: nil)
                               .offsetBy(dx: origin.x, dy: origin.y)
            let glyphOff = self.location(forGlyphAt: gr.location)
            let x = floor(lineRect.minX + glyphOff.x) + 0.5
            let path = NSBezierPath()
            path.move(to: NSPoint(x: x, y: lineRect.minY))
            path.line(to: NSPoint(x: x, y: lineRect.maxY))
            path.lineWidth = 0.5
            NSColor.separatorColor.withAlphaComponent(0.6).setStroke()
            path.stroke()
        }

        // Draw horizontal borders for each table row, bounded by the outer pipes.
        // Top border only on the first row; all rows get a bottom border — avoids
        // drawing two lines between adjacent rows.
        storage.enumerateAttribute(markdownTableRowKey, in: charRange, options: []) { val, rng, _ in
            guard val != nil else { return }
            let gr = self.glyphRange(forCharacterRange: rng, actualCharacterRange: nil)
            guard gr.length > 0 else { return }
            var glyphPos = gr.location
            var isFirstRow = true
            while glyphPos < NSMaxRange(gr) {
                var lineGlyphRange = NSRange()
                let lineRect = self.lineFragmentRect(forGlyphAt: glyphPos, effectiveRange: &lineGlyphRange)
                                   .offsetBy(dx: origin.x, dy: origin.y)
                let lcr = self.characterRange(forGlyphRange: lineGlyphRange, actualGlyphRange: nil)
                var minX: CGFloat = .infinity, maxX: CGFloat = -.infinity
                storage.enumerateAttribute(markdownTablePipeKey, in: lcr, options: []) { pv, pr, _ in
                    guard pv != nil else { return }
                    let pgr = self.glyphRange(forCharacterRange: pr, actualCharacterRange: nil)
                    guard pgr.length > 0 else { return }
                    let px = floor(lineRect.minX + self.location(forGlyphAt: pgr.location).x) + 0.5
                    if px < minX { minX = px }
                    if px > maxX { maxX = px }
                }
                if minX != .infinity {
                    NSColor.separatorColor.withAlphaComponent(0.6).setStroke()
                    var ys: [CGFloat] = [floor(lineRect.maxY) - 0.5]
                    if isFirstRow { ys.insert(floor(lineRect.minY) + 0.5, at: 0) }
                    for y in ys {
                        let p = NSBezierPath(); p.lineWidth = 0.5
                        p.move(to: NSPoint(x: minX, y: y))
                        p.line(to: NSPoint(x: maxX, y: y))
                        p.stroke()
                    }
                    isFirstRow = false
                }
                glyphPos = NSMaxRange(lineGlyphRange)
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
    weak var textView: NSTextView?

    init(onTextChange: @escaping (String) -> Void) {
        self.onTextChange = onTextChange
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSettingsChange),
            name: .appSettingsDidChange,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func handleSettingsChange() {
        guard let tv = textView, let storage = tv.textStorage else { return }
        applyFullHighlight(to: storage)
        tv.typingAttributes = Styles.baseAttributes
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
                storage.addAttribute(markdownCheckboxKey, value: isChecked,     range: checkboxRange)
            }
            if isChecked && contentRange.length > 0 {
                storage.addAttribute(.foregroundColor,    value: NSColor.tertiaryLabelColor,       range: contentRange)
                storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: contentRange)
                storage.addAttribute(.strikethroughColor, value: NSColor.secondaryLabelColor,      range: contentRange)
            }
        }

        // Links — foreground + underline on visible text; .link attribute stores the URL
        // so BlockNSTextView can open it on click and NSTextView shows a pointer cursor.
        Patterns.link.enumerateMatches(in: storage.string, range: range) { m, _, _ in
            guard let m else { return }
            let textRange = m.range(at: 2)
            let urlRange  = m.range(at: 4)
            if textRange.length > 0 {
                storage.addAttribute(.foregroundColor, value: NSColor.linkColor, range: textRange)
                storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: textRange)
                // Store raw URL/path so clicks can open the link without re-parsing the regex.
                if urlRange.length > 0, let r = Range(urlRange, in: storage.string) {
                    storage.addAttribute(.link, value: String(storage.string[r]), range: textRange)
                }
            }
            [m.range(at: 1), m.range(at: 3), m.range(at: 4), m.range(at: 5)].forEach { r in
                if r.length > 0 { storage.addAttribute(.foregroundColor, value: Styles.syntaxColor, range: r) }
            }
        }

        // Horizontal rule — hide the syntax, draw a line via MarkdownLayoutManager
        Patterns.horizontalRule.enumerateMatches(in: storage.string, range: range) { m, _, _ in
            guard let m else { return }
            storage.addAttribute(.foregroundColor, value: NSColor.clear, range: m.range)
            storage.addAttribute(markdownHRKey, value: true, range: m.range)
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
        let font = Styles.tableFont
        // In a monospace font every glyph has the same advance width; measure one char.
        let charWidth = ("W" as NSString).size(withAttributes: [.font: font]).width

        var pos = range.location
        while pos < NSMaxRange(range) {
            let firstLine = ns.lineRange(for: NSRange(location: pos, length: 0))
            let trimmed = ns.substring(with: firstLine).trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("|") && trimmed.hasSuffix("|") else {
                pos = NSMaxRange(firstLine); continue
            }

            // Collect all consecutive table rows into a block
            var rows: [(lineRange: NSRange, cells: [NSRange])] = []
            var scanPos = pos
            while scanPos < NSMaxRange(range) {
                let lr = ns.lineRange(for: NSRange(location: scanPos, length: 0))
                let t  = ns.substring(with: lr).trimmingCharacters(in: .whitespacesAndNewlines)
                guard t.hasPrefix("|") && t.hasSuffix("|") else { break }

                // Find all | positions in this line to extract cell ranges
                var pipes: [Int] = []
                for i in lr.location..<NSMaxRange(lr) {
                    if ns.character(at: i) == 0x7C { pipes.append(i) }
                }
                var cells: [NSRange] = []
                for i in 0..<max(0, pipes.count - 1) {
                    let s = pipes[i] + 1, e = pipes[i + 1]
                    if e > s { cells.append(NSRange(location: s, length: e - s)) }
                }
                rows.append((lineRange: lr, cells: cells))
                scanPos = NSMaxRange(lr)
            }

            // Identify header (row 0) and separator (row 1 if it only contains - : |)
            let boldFont = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
            var separatorIndex: Int? = nil
            if rows.count >= 2 {
                let sepLine = ns.substring(with: rows[1].lineRange)
                if sepLine.unicodeScalars.allSatisfy({ "-:| \t\r\n".unicodeScalars.contains($0) }) {
                    separatorIndex = 1
                }
            }

            // Apply monospace font to all rows (bold for header)
            for (idx, row) in rows.enumerated() {
                storage.addAttribute(.font, value: idx == 0 ? boldFont : font, range: row.lineRange)
            }

            // Compute max cell width per column (exclude separator — its --- cells are short)
            let contentRows = rows.indices.filter { $0 != separatorIndex }.map { rows[$0] }
            let colCount = contentRows.map { $0.cells.count }.max() ?? 0
            var maxWidths = [Int](repeating: 0, count: colCount)
            for row in contentRows {
                for (i, cell) in row.cells.enumerated() where i < colCount {
                    maxWidths[i] = max(maxWidths[i], cell.length)
                }
            }

            // Right-pad content rows so columns align
            for row in contentRows {
                for (i, cell) in row.cells.enumerated() where i < colCount {
                    let pad = maxWidths[i] - cell.length
                    guard pad > 0, cell.length > 0 else { continue }
                    let lastChar = NSRange(location: NSMaxRange(cell) - 1, length: 1)
                    storage.addAttribute(.kern, value: CGFloat(pad) * charWidth as NSNumber, range: lastChar)
                }
            }

            // Center-pad separator cells: split the extra width equally left and right
            if let si = separatorIndex, si < rows.count {
                for (i, cell) in rows[si].cells.enumerated() where i < colCount {
                    let total = maxWidths[i] - cell.length
                    guard total > 0, cell.length > 0 else { continue }
                    let leftPad  = total / 2
                    let rightPad = total - leftPad
                    if leftPad > 0 {
                        let firstChar = NSRange(location: cell.location, length: 1)
                        storage.addAttribute(.kern, value: CGFloat(leftPad) * charWidth as NSNumber, range: firstChar)
                    }
                    if rightPad > 0 {
                        let lastChar = NSRange(location: NSMaxRange(cell) - 1, length: 1)
                        storage.addAttribute(.kern, value: CGFloat(rightPad) * charWidth as NSNumber, range: lastChar)
                    }
                }
            }

            // Uniform paragraph spacing for all rows (prevents last-row spacing drift)
            let tablePS = NSMutableParagraphStyle()
            tablePS.paragraphSpacing     = 4
            tablePS.paragraphSpacingBefore = 0
            tablePS.lineSpacing          = 0
            for row in rows {
                storage.addAttribute(.paragraphStyle, value: tablePS, range: row.lineRange)
            }

            // Tag all rows for top + bottom border drawing; hide | chars for vertical line drawing
            for row in rows {
                storage.addAttribute(markdownTableRowKey, value: true, range: row.lineRange)
                for i in row.lineRange.location..<NSMaxRange(row.lineRange) {
                    guard ns.character(at: i) == 0x7C else { continue }
                    let r = NSRange(location: i, length: 1)
                    storage.addAttribute(.foregroundColor,   value: NSColor.clear, range: r)
                    storage.addAttribute(markdownTablePipeKey, value: true,          range: r)
                }
            }

            pos = scanPos
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
        let full = NSRange(location: 0, length: textStorage.length)
        textStorage.beginEditing()
        applyBase(to: paraRange, storage: textStorage)
        applyInline(to: paraRange, storage: textStorage)
        // Apply tables immediately so pipes/separator never flash as raw text while typing
        if textStorage.string.contains("|") { applyTables(to: full, storage: textStorage) }
        textStorage.endEditing()

        fullScanWorkItem?.cancel()
        let item = DispatchWorkItem { [weak textStorage] in
            guard let ts = textStorage, ts.length > 0 else { return }
            let docFull = NSRange(location: 0, length: ts.length)
            ts.beginEditing()
            if ts.string.contains("```") { self.applyFenced(to: docFull, storage: ts) }
            ts.endEditing()
        }
        fullScanWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: item)
    }
}

// MARK: - Styles

enum Styles {
    static var bodyFont:  NSFont { AppSettings.shared.bodyNSFont  }
    static var monoFont:  NSFont { AppSettings.shared.monoNSFont  }
    static var tableFont: NSFont { AppSettings.shared.tableNSFont }

    static var baseAttributes: [NSAttributedString.Key: Any] {
        [.font:            bodyFont,
         .foregroundColor: NSColor.labelColor,
         .paragraphStyle:  defaultParagraphStyle,
         .ligature:        AppSettings.shared.ligatures ? 2 : 0]
    }

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
    static let listItem      = try! NSRegularExpression(pattern: #"^([-*+][ \t]|\d+\.[ \t]|[a-zA-Z]\.[ \t])(.*)"#, options: .anchorsMatchLines)
    static let taskListItem  = try! NSRegularExpression(pattern: #"^([-*][ \t])(\[[ xX]\])([ \t])(.*)"#, options: .anchorsMatchLines)
    static let link          = try! NSRegularExpression(pattern: #"(\[)([^\]\n]+)(\]\()([^\)\n]+)(\))"#)
    static let horizontalRule = try! NSRegularExpression(pattern: #"^(\-{3,}|\*{3,}|_{3,})[ \t]*$"#, options: .anchorsMatchLines)
    static let tableSeparator = try! NSRegularExpression(pattern: #"^\|[-:| \t]+$"#, options: .anchorsMatchLines)
    static let tableRow      = try! NSRegularExpression(pattern: #"^\|[^\n]+"#, options: .anchorsMatchLines)
    static let pipe          = try! NSRegularExpression(pattern: #"\|"#)
}
