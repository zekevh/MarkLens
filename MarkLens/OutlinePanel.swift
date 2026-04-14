import SwiftUI

// MARK: - Model

struct OutlineEntry: Identifiable {
    let id = UUID()
    let level: Int
    let title: String
    /// UTF-16 offset of the heading line in the document text.
    let characterOffset: Int
}

/// Scans `text` for ATX-style headings (`# …`) and returns them in document
/// order.  Headings inside front matter blocks and fenced code blocks are
/// skipped.
func parseOutlineEntries(from text: String) -> [OutlineEntry] {
    var entries: [OutlineEntry] = []
    var utf16Offset = 0
    var isFirstLine = true
    var inFrontMatter = false
    var inCodeFence = false

    for line in text.components(separatedBy: "\n") {
        let lineUTF16Length = (line as NSString).length

        // ── Front-matter detection ────────────────────────────────────────────
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if isFirstLine {
            isFirstLine = false
            if trimmed == "---" {
                inFrontMatter = true
                utf16Offset += lineUTF16Length + 1
                continue
            }
        }

        if inFrontMatter {
            if trimmed == "---" || trimmed == "..." { inFrontMatter = false }
            utf16Offset += lineUTF16Length + 1
            continue
        }

        // ── Code-fence detection ──────────────────────────────────────────────
        if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
            inCodeFence.toggle()
            utf16Offset += lineUTF16Length + 1
            continue
        }

        // ── Heading detection ─────────────────────────────────────────────────
        if !inCodeFence,
           let matchRange = trimmed.range(of: #"^#{1,6}(?:\s|$)"#, options: .regularExpression) {
            let hashCount = trimmed[trimmed.startIndex ..< matchRange.upperBound].filter { $0 == "#" }.count
            var title = String(trimmed[matchRange.upperBound...]).trimmingCharacters(in: .whitespaces)
            // Strip optional trailing `###` (closing ATX syntax)
            if let trailingHashes = title.range(of: #"\s+#+\s*$"#, options: .regularExpression) {
                title = String(title[..<trailingHashes.lowerBound])
            }
            if !title.isEmpty {
                entries.append(OutlineEntry(level: hashCount, title: title, characterOffset: utf16Offset))
            }
        }

        utf16Offset += lineUTF16Length + 1  // +1 for the '\n' separator
    }

    return entries
}

// MARK: - Views

struct OutlinePanelView: View {
    let entries: [OutlineEntry]
    let onSelectEntry: (OutlineEntry) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Outline")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)

            Divider()

            if entries.isEmpty {
                Spacer()
                Text("No headings")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(entries) { entry in
                            OutlineEntryRow(entry: entry) { onSelectEntry(entry) }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

private struct OutlineEntryRow: View {
    let entry: OutlineEntry
    let onTap: () -> Void
    @State private var isHovered = false

    private var leadingPad: CGFloat { CGFloat((entry.level - 1) * 10) + 10 }

    private var labelFont: Font {
        switch entry.level {
        case 1:  return .system(size: 12, weight: .semibold)
        case 2:  return .system(size: 11, weight: .medium)
        default: return .system(size: 11, weight: .regular)
        }
    }

    private var labelStyle: some ShapeStyle {
        entry.level == 1 ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary)
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 0) {
                Color.clear.frame(width: leadingPad)
                Text(entry.title)
                    .font(labelFont)
                    .foregroundStyle(labelStyle)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.trailing, 10)
            }
            .padding(.vertical, 3)
            .background(
                isHovered
                    ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.35)
                    : Color.clear
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
