import SwiftUI
import AppKit

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
        if block.kind == .frontMatter { return (top: 0, bottom: 18) }
        let t = block.content.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("# ") { return (top: 40, bottom: 8) }
        if t.hasPrefix("## ") { return (top: 32, bottom: 6) }
        if t.hasPrefix("### ") { return (top: 24, bottom: 4) }
        if t.hasPrefix("####") { return (top: 20, bottom: 4) }
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
