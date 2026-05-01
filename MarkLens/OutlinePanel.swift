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
    let historyState: SelectedFileHistoryState
    let isLoadingHistory: Bool
    let hasLocalChanges: Bool
    let onSelectEntry: (OutlineEntry) -> Void

    var body: some View {
        List {
            Section("Outline") {
                if entries.isEmpty {
                    Text("No headings")
                        .foregroundStyle(.tertiary)
                        .font(.callout)
                } else {
                    ForEach(entries) { entry in
                        Button {
                            onSelectEntry(entry)
                        } label: {
                            OutlineEntryRow(entry: entry)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Section("History") {
                historySectionContent
            }
            .accessibilityIdentifier("fileHistorySection")
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder
    private var historySectionContent: some View {
        if hasLocalChanges {
            LocalChangesRow()
                .accessibilityIdentifier("fileHistoryLocalChanges")
        }

        if isLoadingHistory {
            Text("Loading history…")
                .foregroundStyle(.tertiary)
                .font(.callout)
                .accessibilityIdentifier("fileHistoryLoading")
        } else {
            switch historyState {
            case .unavailable:
                Text("Not in a git repository")
                    .foregroundStyle(.tertiary)
                    .font(.callout)
                    .accessibilityIdentifier("fileHistoryUnavailable")
            case .failed:
                Text("Could not load history")
                    .foregroundStyle(.tertiary)
                    .font(.callout)
                    .accessibilityIdentifier("fileHistoryError")
            case let .loaded(entries):
                if entries.isEmpty {
                    Text("No commits for this file")
                        .foregroundStyle(.tertiary)
                        .font(.callout)
                        .accessibilityIdentifier("fileHistoryEmpty")
                } else {
                    ForEach(entries) { entry in
                        FileHistoryRow(entry: entry)
                            .accessibilityIdentifier("fileHistoryRow-\(entry.shortHash)")
                    }
                }
            }
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

private struct LocalChangesRow: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "circle.fill")
                .font(.system(size: 7))
                .foregroundStyle(.orange)
            Text("Local changes")
                .font(.system(size: 11, weight: .medium))
            Spacer(minLength: 0)
        }
    }
}

private struct FileHistoryRow: View {
    let entry: GitFileHistoryEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(entry.subject)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(2)
                .foregroundStyle(.primary)

            HStack(spacing: 6) {
                Text(entry.shortHash)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)

                Text(entry.authorDate, format: .dateTime.year().month(.abbreviated).day())
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 1)
    }
}
