import SwiftUI

struct EditorStatusBar: View {
    let fileURL: URL
    let rootFolderURL: URL?
    let text: String
    let showsPathBar: Bool
    let showsStatusBar: Bool

    private var breadcrumbs: [String] {
        let baseURL = rootFolderURL ?? fileURL.deletingLastPathComponent()
        let baseComponents = baseURL.standardizedFileURL.pathComponents
        let fileComponents = fileURL.standardizedFileURL.pathComponents
        let relativeComponents = Array(fileComponents.dropFirst(baseComponents.count))

        if rootFolderURL != nil {
            return [baseURL.lastPathComponent] + relativeComponents
        }

        return [baseURL.lastPathComponent, fileURL.lastPathComponent]
    }

    private var wordCount: Int {
        text.split { $0.isWhitespace || $0.isNewline }.count
    }

    private var estimatedTokenCount: Int {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }
        return max(1, Int(ceil(Double(trimmed.count) / 4.0)))
    }

    var body: some View {
        VStack(spacing: 0) {
            Divider()

            if showsPathBar {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(breadcrumbs.enumerated()), id: \.offset) { index, crumb in
                            if index > 0 {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(.tertiary)
                            }

                            Text(crumb)
                                .lineLimit(1)
                                .font(.caption)
                                .foregroundStyle(index == breadcrumbs.count - 1 ? .primary : .secondary)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            if showsPathBar && showsStatusBar {
                Divider()
            }

            if showsStatusBar {
                HStack(spacing: 14) {
                    Spacer(minLength: 0)
                    Text("\(wordCount) \(wordCount == 1 ? "word" : "words")")
                    Text("\(estimatedTokenCount) est. AI tokens")
                    Spacer(minLength: 0)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
        }
        .background(.bar)
    }
}

struct ReplaceSearchBar: View {
    @EnvironmentObject var editorUIStore: EditorUIStore

    private var hasSearch: Bool {
        !editorUIStore.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 10) {
                Text("Replace")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextField("Replace", text: $editorUIStore.replaceText)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 220, maxWidth: 320)

                Text(editorUIStore.searchMatchCount == 0 ? "No matches" : "\(editorUIStore.searchMatchCount) matches")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button("Replace") { editorUIStore.replaceNext() }
                    .disabled(!hasSearch)
                Button("Replace All") { editorUIStore.replaceAll() }
                    .disabled(!hasSearch)

                Spacer(minLength: 0)

                Button {
                    editorUIStore.hideReplaceBar()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.bar)
        }
    }
}
