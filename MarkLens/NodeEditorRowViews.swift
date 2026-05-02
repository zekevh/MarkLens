import SwiftUI
import AppKit

func rowPadding(for block: MarkdownBlock, suppressHeadingTopSpacing: Bool = false) -> (top: CGFloat, bottom: CGFloat) {
    if block.kind == .frontMatter { return (top: 0, bottom: 18) }

    switch block.kind {
    case .heading(level: 1):
        return (top: suppressHeadingTopSpacing ? 0 : 40, bottom: 8)
    case .heading(level: 2):
        return (top: 32, bottom: 6)
    case .heading(level: 3):
        return (top: 24, bottom: 4)
    case .heading(level: 4):
        return (top: 20, bottom: 4)
    default:
        return (top: 0, bottom: 0)
    }
}

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

struct BlockRowView: View {
    @Binding var block: MarkdownBlock
    var index: Int
    var previousBlockKind: MarkdownBlockKind?
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
    var onInitialLayout: () -> Void

    @State private var height: CGFloat = 32
    @State private var isFrontMatterExpanded = false
    @State private var isHTMLEditing = false
    @State private var hasReportedInitialLayout = false

    private var blockPadding: (top: CGFloat, bottom: CGFloat) {
        rowPadding(
            for: block,
            suppressHeadingTopSpacing: index == 0 || previousBlockKind == .frontMatter
        )
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
                            editorView
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

                            editorView
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

                            editorView
                                .frame(height: max(height, 24))
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
                        editorView
                            .frame(height: max(height, 24))
                    }
                }
            }
        }
        .overlay(alignment: .top) {
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
        .onAppear {
            reportInitialLayoutIfNeeded()
        }
        .onChange(of: isFrontMatterExpanded) { _, _ in
            reportInitialLayoutIfNeeded()
        }
        .onChange(of: isHTMLEditing) { _, _ in
            reportInitialLayoutIfNeeded()
        }
    }

    private var editorView: some View {
        BlockEditorView(
            blockID: block.id,
            blockKind: block.kind,
            content: $block.content,
            searchText: searchText,
            registry: registry,
            onHeightChange: { h in
                height = h
                guard !hasReportedInitialLayout else { return }
                hasReportedInitialLayout = true
                onInitialLayout()
            },
            onSplitBlock: onSplitBlock,
            onMergeWithPrevious: onMergeWithPrevious,
            onNavigatePrevious: onNavigatePrevious,
            onNavigateNext: onNavigateNext
        )
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

    private var waitsForEditorMeasurement: Bool {
        if block.kind == .frontMatter && !isFrontMatterExpanded { return false }
        if htmlSource != nil && !isHTMLEditing { return false }
        return true
    }

    private func reportInitialLayoutIfNeeded() {
        guard !hasReportedInitialLayout else { return }
        guard !waitsForEditorMeasurement else { return }
        hasReportedInitialLayout = true
        onInitialLayout()
    }
}

private struct FrontMatterSummaryLabel: View {
    @State private var measuredWidths: [String: CGFloat] = [:]

    let content: String
    private static let yamlListItemPattern = try! NSRegularExpression(pattern: #"^\s*-\s+(.+?)\s*$"#)
    private static let chipFont = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
    private static let titleMaxWidth: CGFloat = 280
    private static let titleMinWidth: CGFloat = 110
    private static let updatedMaxWidth: CGFloat = 96

    private var title: String? {
        frontMatterScalarValue(for: "title")
    }

    private var updated: String? {
        frontMatterScalarValue(for: "updated")
    }

    private var tags: [String] {
        frontMatterListValue(for: "tags")
    }

    var body: some View {
        let layout = summaryLayout(for: measuredWidths["container"] ?? 0)

        HStack(spacing: 10) {
            Text("Front Matter")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: true, vertical: false)

            if let title, !title.isEmpty {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: layout.titleWidth, alignment: .leading)
            }

            if !layout.visibleTags.isEmpty || layout.hiddenTagCount > 0 {
                HStack(spacing: 10) {
                    ForEach(layout.visibleTags, id: \.self) { tag in
                        tagChip(tag)
                    }

                    if layout.hiddenTagCount > 0 {
                        tagChip("+\(layout.hiddenTagCount)")
                    }
                }
            }

            Spacer(minLength: 0)

            if let updated, !updated.isEmpty {
                Text(updated)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(maxWidth: Self.updatedMaxWidth, alignment: .trailing)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(widthReader(id: "container"))
        .background(intrinsicWidthReaders)
        .onPreferenceChange(FrontMatterSummaryWidthPreferenceKey.self) { widths in
            measuredWidths.merge(widths) { _, new in new }
        }
    }

    @ViewBuilder
    private var intrinsicWidthReaders: some View {
        HStack(spacing: 0) {
            Text("Front Matter")
                .font(.caption.weight(.semibold))
                .fixedSize(horizontal: true, vertical: false)
                .background(widthReader(id: "label"))
                .hidden()

            if let title, !title.isEmpty {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .fixedSize(horizontal: true, vertical: false)
                    .background(widthReader(id: "title"))
                    .hidden()
            }

            if let updated, !updated.isEmpty {
                Text(updated)
                    .font(.caption)
                    .fixedSize(horizontal: true, vertical: false)
                    .background(widthReader(id: "updated"))
                    .hidden()
            }
        }
    }

    private func tagChip(_ label: String) -> some View {
        Text(label)
            .font(.caption.weight(.medium))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Color.accentColor.opacity(0.12), in: Capsule())
    }

    private func summaryLayout(for containerWidth: CGFloat) -> FrontMatterSummaryLayout {
        let titleIntrinsicWidth = measuredWidths["title"] ?? 0
        let labelWidth = measuredWidths["label"] ?? 0
        let updatedWidth = min(measuredWidths["updated"] ?? 0, Self.updatedMaxWidth)

        let reservedSpacing: CGFloat = 30
        let reservedWidth = labelWidth + updatedWidth + reservedSpacing
        let remainingWidth = max(0, containerWidth - reservedWidth)
        let titleWidth = min(titleIntrinsicWidth, max(Self.titleMinWidth, min(Self.titleMaxWidth, remainingWidth * 0.5)))
        let tagWidthBudget = max(0, containerWidth - reservedWidth - titleWidth - 10)
        let tagLayout = fittedTags(for: tagWidthBudget)

        return FrontMatterSummaryLayout(
            titleWidth: titleWidth,
            visibleTags: tagLayout.visibleTags,
            hiddenTagCount: tagLayout.hiddenTagCount
        )
    }

    private func fittedTags(for availableWidth: CGFloat) -> FrontMatterTagLayout {
        let chipSpacing: CGFloat = 10

        guard availableWidth > 0, !tags.isEmpty else {
            return FrontMatterTagLayout(visibleTags: [], hiddenTagCount: tags.count)
        }

        var visible: [String] = []
        var usedWidth: CGFloat = 0

        for (index, tag) in tags.enumerated() {
            let chipWidth = tagChipWidth(tag)
            let spacingBefore: CGFloat = visible.isEmpty ? 0 : chipSpacing
            let remainingCount = tags.count - (index + 1)
            let overflowReserve = remainingCount > 0 ? (spacingBefore + tagChipWidth("+\(remainingCount)")) : 0

            if usedWidth + spacingBefore + chipWidth + overflowReserve <= availableWidth {
                visible.append(tag)
                usedWidth += spacingBefore + chipWidth
            } else {
                break
            }
        }

        var hiddenCount = tags.count - visible.count
        while hiddenCount > 0 {
            let overflowWidth = tagChipWidth("+\(hiddenCount)")
            let spacingBeforeOverflow: CGFloat = visible.isEmpty ? 0 : chipSpacing
            if usedWidth + spacingBeforeOverflow + overflowWidth <= availableWidth {
                break
            }
            guard let removed = visible.popLast() else { break }
            hiddenCount += 1
            usedWidth -= tagChipWidth(removed)
            if !visible.isEmpty {
                usedWidth -= chipSpacing
            }
        }

        if visible.isEmpty, hiddenCount == tags.count, tagChipWidth("+\(hiddenCount)") > availableWidth {
            return FrontMatterTagLayout(visibleTags: [], hiddenTagCount: 0)
        }

        return FrontMatterTagLayout(visibleTags: visible, hiddenTagCount: hiddenCount)
    }

    private func tagChipWidth(_ label: String) -> CGFloat {
        let textWidth = (label as NSString).size(withAttributes: [.font: Self.chipFont]).width
        return ceil(textWidth) + 18 + 18
    }

    private func widthReader(id: String) -> some View {
        GeometryReader { proxy in
            Color.clear.preference(
                key: FrontMatterSummaryWidthPreferenceKey.self,
                value: [id: proxy.size.width]
            )
        }
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
        let prefix = "\(key):"

        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(prefix) else { continue }

            let inlineValue = trimmed.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            if !inlineValue.isEmpty {
                return parseInlineYAMLList(String(inlineValue))
            }

            var result: [String] = []
            for nestedLine in lines.dropFirst(index + 1) {
                if nestedLine.trimmingCharacters(in: .whitespaces).isEmpty { continue }
                guard let unquoted = parseYAMLListItem(from: nestedLine) else { break }
                if !unquoted.isEmpty { result.append(unquoted) }
            }
            return result
        }
        return []
    }

    private func parseInlineYAMLList(_ value: String) -> [String] {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard trimmed.first == "[", trimmed.last == "]" else { return [] }

        let inner = String(trimmed.dropFirst().dropLast())
        guard !inner.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }

        return inner
            .split(separator: ",", omittingEmptySubsequences: false)
            .map { stripMatchingQuotes(from: String($0).trimmingCharacters(in: .whitespaces)) }
            .filter { !$0.isEmpty }
    }

    private func stripMatchingQuotes(from value: String) -> String {
        guard value.count >= 2 else { return value }
        if (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
            (value.hasPrefix("'") && value.hasSuffix("'")) {
            return String(value.dropFirst().dropLast())
        }
        return value
    }

    private func parseYAMLListItem(from line: String) -> String? {
        let nsLine = line as NSString
        let range = NSRange(location: 0, length: nsLine.length)
        guard let match = Self.yamlListItemPattern.firstMatch(in: line, range: range),
              let valueRange = Range(match.range(at: 1), in: line) else {
            return nil
        }
        return stripMatchingQuotes(from: String(line[valueRange]).trimmingCharacters(in: .whitespaces))
    }
}

private struct FrontMatterSummaryLayout {
    let titleWidth: CGFloat
    let visibleTags: [String]
    let hiddenTagCount: Int
}

private struct FrontMatterTagLayout {
    let visibleTags: [String]
    let hiddenTagCount: Int
}

private struct FrontMatterSummaryWidthPreferenceKey: PreferenceKey {
    static var defaultValue: [String: CGFloat] = [:]

    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue()) { _, new in new }
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

private struct BlockDebugOverlay: View {
    let block: MarkdownBlock
    let index: Int

    var blockType: (label: String, color: Color) {
        if block.kind == .frontMatter { return ("yaml", .brown) }
        let t = block.content.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("######") { return ("H6", .purple) }
        if t.hasPrefix("#####") { return ("H5", .purple) }
        if t.hasPrefix("####") { return ("H4", .purple) }
        if t.hasPrefix("###") { return ("H3", .purple) }
        if t.hasPrefix("##") { return ("H2", .purple) }
        if t.hasPrefix("# ") { return ("H1", .purple) }
        if t.hasPrefix("```") { return ("code", .orange) }
        if t.hasPrefix("|") { return ("table", .teal) }
        if t.hasPrefix(">") { return ("quote", .indigo) }
        if t.hasPrefix("- ") || t.hasPrefix("* ") || t.hasPrefix("+ ") { return ("ul", .green) }
        if t.first?.isNumber == true && t.dropFirst().hasPrefix(". ") { return ("ol", .green) }
        if t == "---" || t == "***" || t == "___" { return ("hr", .gray) }
        if t.isEmpty { return ("empty", .gray) }
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
