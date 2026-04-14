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
/// order. Headings inside front matter and fenced code blocks are skipped.
func parseOutlineEntries(from text: String) -> [OutlineEntry] {
    var entries: [OutlineEntry] = []
    var utf16Offset = 0
    var isFirstLine = true
    var inFrontMatter = false
    var inCodeFence = false

    for line in text.components(separatedBy: "\n") {
        let lineUTF16Length = (line as NSString).length
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        // Front-matter
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

        // Code fences
        if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
            inCodeFence.toggle()
            utf16Offset += lineUTF16Length + 1
            continue
        }

        // ATX headings
        if !inCodeFence,
           let matchRange = trimmed.range(of: #"^#{1,6}(?:\s|$)"#, options: .regularExpression) {
            let level = trimmed[trimmed.startIndex ..< matchRange.upperBound].filter { $0 == "#" }.count
            var title = String(trimmed[matchRange.upperBound...]).trimmingCharacters(in: .whitespaces)
            if let trailing = title.range(of: #"\s+#+\s*$"#, options: .regularExpression) {
                title = String(title[..<trailing.lowerBound])
            }
            if !title.isEmpty {
                entries.append(OutlineEntry(level: level, title: title, characterOffset: utf16Offset))
            }
        }

        utf16Offset += lineUTF16Length + 1
    }

    return entries
}

// MARK: - View

struct OutlinePanelView: View {
    let entries: [OutlineEntry]
    let onSelectEntry: (OutlineEntry) -> Void

    @State private var selectedID: UUID? = nil

    var body: some View {
        Group {
            if entries.isEmpty {
                List {
                    Section("Outline") {
                        Text("No headings")
                            .foregroundStyle(.tertiary)
                            .font(.callout)
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
            } else {
                List(selection: $selectedID) {
                    Section("Outline") {
                        ForEach(entries) { entry in
                            OutlineEntryRow(entry: entry)
                                .tag(entry.id)
                        }
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
            }
        }
        .onChange(of: selectedID) { _, newID in
            guard let newID,
                  let entry = entries.first(where: { $0.id == newID }) else { return }
            onSelectEntry(entry)
            Task { @MainActor in selectedID = nil }
        }
    }
}

private struct OutlineEntryRow: View {
    let entry: OutlineEntry

    var body: some View {
        Text(entry.title)
            .font(rowFont)
            .foregroundStyle(entry.level == 1 ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .lineLimit(1)
            .padding(.leading, CGFloat((entry.level - 1) * 10))
    }

    private var rowFont: Font {
        switch entry.level {
        case 1:  return .system(size: 12, weight: .semibold)
        case 2:  return .system(size: 11, weight: .medium)
        default: return .system(size: 11, weight: .regular)
        }
    }
}
