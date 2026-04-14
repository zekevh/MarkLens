import SwiftUI
import Combine
import AppKit

enum QuickOpenMatchSource: Hashable {
    case title
    case path
    case content
}

struct QuickOpenResult: Identifiable, Hashable {
    let id: URL
    let url: URL
    let title: String
    let subtitle: String
    let score: Int
    let order: Int
    let matchSource: QuickOpenMatchSource
    let snippet: String?
    let matchLocation: Int?
}

private struct QuickOpenContentEntry {
    let normalizedContent: String
    let originalContent: String
}

private struct QuickOpenContentMatch {
    let snippet: String
    let location: Int
    let score: Int
}

private enum QuickOpenContentIndex {
    static func build(for files: [URL]) async -> [URL: QuickOpenContentEntry] {
        await withTaskGroup(of: (URL, QuickOpenContentEntry?).self) { group in
            for file in files {
                group.addTask {
                    guard let text = try? String(contentsOf: file, encoding: .utf8) else {
                        return (file, nil)
                    }

                    return (
                        file,
                        QuickOpenContentEntry(
                            normalizedContent: QuickOpenStore.normalize(text),
                            originalContent: text
                        )
                    )
                }
            }

            var entries: [URL: QuickOpenContentEntry] = [:]
            for await (file, entry) in group {
                if let entry {
                    entries[file] = entry
                }
            }
            return entries
        }
    }
}

@MainActor
final class QuickOpenStore: ObservableObject {
    @Published var isPresented = false
    @Published var query = "" {
        didSet { refreshResults() }
    }
    @Published private(set) var results: [QuickOpenResult] = []
    @Published var selectedResultID: URL? = nil

    private let workspaceStore: WorkspaceStore
    private let documentStore: DocumentStore
    private let editorUIStore: EditorUIStore
    private var cancellables: Set<AnyCancellable> = []
    private var contentIndex: [URL: QuickOpenContentEntry] = [:]
    private var indexedFiles: [URL] = []
    private var indexGeneration = 0

    init(workspaceStore: WorkspaceStore, documentStore: DocumentStore, editorUIStore: EditorUIStore) {
        self.workspaceStore = workspaceStore
        self.documentStore = documentStore
        self.editorUIStore = editorUIStore

        workspaceStore.$rootNodes
            .sink { [weak self] _ in
                self?.rebuildIndex()
            }
            .store(in: &cancellables)

        workspaceStore.$selectedSidebarURLs
            .sink { [weak self] _ in
                self?.syncSelectionWithWorkspace()
            }
            .store(in: &cancellables)

        documentStore.$documentText
            .sink { [weak self] _ in
                self?.refreshIndexForOpenDocumentIfNeeded()
            }
            .store(in: &cancellables)

        documentStore.$selectedFileURL
            .sink { [weak self] _ in
                self?.refreshIndexForOpenDocumentIfNeeded()
            }
            .store(in: &cancellables)
    }

    var hasResults: Bool {
        !results.isEmpty
    }

    func show() {
        guard !workspaceStore.rootNodes.isEmpty else { return }
        isPresented = true
        query = ""
        refreshResults()
    }

    func hide() {
        isPresented = false
        query = ""
        selectedResultID = nil
    }

    func moveSelection(by offset: Int) {
        guard !results.isEmpty else { return }
        guard let currentSelectionID = selectedResultID,
              let currentIndex = results.firstIndex(where: { $0.id == currentSelectionID }) else {
            selectedResultID = results.first?.id
            return
        }

        let nextIndex = min(max(currentIndex + offset, 0), results.count - 1)
        selectedResultID = results[nextIndex].id
    }

    func openSelection() {
        guard let selectedResult else { return }
        workspaceStore.selectedSidebarURLs = [selectedResult.url]
        if let matchLocation = selectedResult.matchLocation {
            editorUIStore.openFileSearchResult(
                selectedResult.url,
                query: query,
                location: matchLocation
            )
        } else {
            workspaceStore.loadFile(selectedResult.url, syncSidebarSelection: false)
        }
        hide()
    }

    private var selectedResult: QuickOpenResult? {
        guard let selectedResultID else { return results.first }
        return results.first(where: { $0.id == selectedResultID }) ?? results.first
    }

    private func refreshResults() {
        let files = Self.flattenFiles(in: workspaceStore.rootNodes)
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)

        let nextResults = files.enumerated().compactMap { index, url -> QuickOpenResult? in
            let title = url.lastPathComponent
            let subtitle = Self.subtitle(for: url, rootFolderURL: workspaceStore.rootFolderURL)
            let fileMatch = Self.scoreFileMatch(query: trimmedQuery, title: title, subtitle: subtitle, order: index)
            let contentMatch = Self.contentMatch(
                query: trimmedQuery,
                entry: contentIndex[url] ?? Self.loadContentEntry(at: url)
            )
            guard let resolved = Self.resolveMatch(
                fileMatch: fileMatch,
                contentMatch: contentMatch,
                url: url,
                title: title,
                subtitle: subtitle,
                order: index
            ) else {
                return nil
            }

            return resolved
        }
        .sorted { lhs, rhs in
            if lhs.score != rhs.score {
                return lhs.score > rhs.score
            }
            if lhs.title != rhs.title {
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
            return lhs.order < rhs.order
        }

        results = Array(nextResults.prefix(50))
        syncSelectionWithWorkspace()
    }

    private func rebuildIndex() {
        let files = Self.flattenFiles(in: workspaceStore.rootNodes)
        indexedFiles = files
        refreshResults()

        indexGeneration += 1
        let generation = indexGeneration

        Task {
            let index = await QuickOpenContentIndex.build(for: files)
            await MainActor.run {
                guard self.indexGeneration == generation else { return }
                self.contentIndex = index
                self.refreshIndexForOpenDocumentIfNeeded()
                self.refreshResults()
            }
        }
    }

    private func refreshIndexForOpenDocumentIfNeeded() {
        guard let selectedFileURL = documentStore.selectedFileURL,
              indexedFiles.contains(selectedFileURL) else { return }

        contentIndex[selectedFileURL] = QuickOpenContentEntry(
            normalizedContent: Self.normalize(documentStore.documentText),
            originalContent: documentStore.documentText
        )
        refreshResults()
    }

    private func syncSelectionWithWorkspace() {
        guard !results.isEmpty else {
            selectedResultID = nil
            return
        }

        if let selectedFileURL = workspaceStore.selectedSidebarURLs.first,
           results.contains(where: { $0.url == selectedFileURL }) {
            selectedResultID = selectedFileURL
            return
        }

        if let selectedResultID,
           results.contains(where: { $0.id == selectedResultID }) {
            return
        }

        selectedResultID = results.first?.id
    }

    private static func flattenFiles(in nodes: [FileNode]) -> [URL] {
        nodes.flatMap { node in
            if node.isDirectory {
                return flattenFiles(in: node.children ?? [])
            }
            return [node.url]
        }
    }

    private static func subtitle(for url: URL, rootFolderURL: URL?) -> String {
        if let rootFolderURL {
            let rootPath = rootFolderURL.path
            let directoryPath = url.deletingLastPathComponent().path
            if directoryPath == rootPath {
                return rootFolderURL.lastPathComponent
            }
            if directoryPath.hasPrefix(rootPath + "/") {
                let relativePath = String(directoryPath.dropFirst(rootPath.count + 1))
                return relativePath.isEmpty ? rootFolderURL.lastPathComponent : relativePath
            }
        }

        return url.deletingLastPathComponent().path
            .replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    private static func scoreFileMatch(query: String, title: String, subtitle: String, order: Int) -> (score: Int, source: QuickOpenMatchSource)? {
        guard !title.isEmpty else { return nil }
        guard !query.isEmpty else { return (10_000 - order, .title) }

        let normalizedQuery = normalize(query)
        let normalizedTitle = normalize(title)
        let normalizedPath = normalize("\(subtitle)/\(title)")
        let titleStem = normalize((title as NSString).deletingPathExtension)

        var score = 0
        var source: QuickOpenMatchSource = .title

        if normalizedTitle == normalizedQuery || titleStem == normalizedQuery {
            score += 3_000
            source = .title
        }
        if normalizedTitle.hasPrefix(normalizedQuery) || titleStem.hasPrefix(normalizedQuery) {
            score += 2_000
            source = .title
        }
        if normalizedTitle.contains(normalizedQuery) || titleStem.contains(normalizedQuery) {
            score += 1_200
            source = .title
        }
        if normalizedPath.contains(normalizedQuery) {
            score += 700
            if score < 1_200 {
                source = .path
            }
        }

        if let fuzzyTitle = fuzzyScore(query: normalizedQuery, candidate: titleStem) {
            score += 900 + fuzzyTitle
        } else if let fuzzyPath = fuzzyScore(query: normalizedQuery, candidate: normalizedPath) {
            score += 300 + fuzzyPath
            if score < 1_200 {
                source = .path
            }
        }

        guard score > 0 else { return nil }
        return (score - min(order, 200), source)
    }

    private static func resolveMatch(
        fileMatch: (score: Int, source: QuickOpenMatchSource)?,
        contentMatch: QuickOpenContentMatch?,
        url: URL,
        title: String,
        subtitle: String,
        order: Int
    ) -> QuickOpenResult? {
        if let fileMatch, let contentMatch {
            let blendedScore = max(fileMatch.score, contentMatch.score) + min(fileMatch.score / 10, 150)
            return QuickOpenResult(
                id: url,
                url: url,
                title: title,
                subtitle: subtitle,
                score: blendedScore,
                order: order,
                matchSource: fileMatch.score >= contentMatch.score ? fileMatch.source : .content,
                snippet: contentMatch.snippet,
                matchLocation: contentMatch.location
            )
        }

        if let fileMatch {
            return QuickOpenResult(
                id: url,
                url: url,
                title: title,
                subtitle: subtitle,
                score: fileMatch.score,
                order: order,
                matchSource: fileMatch.source,
                snippet: nil,
                matchLocation: nil
            )
        }

        guard let contentMatch else { return nil }
        return QuickOpenResult(
            id: url,
            url: url,
            title: title,
            subtitle: subtitle,
            score: contentMatch.score,
            order: order,
            matchSource: .content,
            snippet: contentMatch.snippet,
            matchLocation: contentMatch.location
        )
    }

    private static func contentMatch(query: String, entry: QuickOpenContentEntry?) -> QuickOpenContentMatch? {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty, let entry else { return nil }

        let normalizedQuery = normalize(trimmedQuery)
        guard let matchRange = entry.normalizedContent.range(of: normalizedQuery) else { return nil }

        let location = entry.normalizedContent.distance(from: entry.normalizedContent.startIndex, to: matchRange.lowerBound)
        let snippet = snippet(for: entry.originalContent, around: location, queryLength: normalizedQuery.count)
        let lengthBonus = max(0, 160 - min(entry.originalContent.count, 160))
        return QuickOpenContentMatch(
            snippet: snippet,
            location: location,
            score: 820 + lengthBonus
        )
    }

    private static func snippet(for content: String, around location: Int, queryLength: Int) -> String {
        let nsContent = content as NSString
        let length = nsContent.length
        guard length > 0 else { return "" }

        let safeLocation = min(max(0, location), max(0, length - 1))
        let start = max(0, safeLocation - 36)
        let end = min(length, safeLocation + max(queryLength, 1) + 44)
        let range = NSRange(location: start, length: end - start)
        let raw = nsContent.substring(with: range)
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = start > 0 ? "…" : ""
        let suffix = end < length ? "…" : ""
        return prefix + raw + suffix
    }

    nonisolated static func normalize(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }

    nonisolated private static func loadContentEntry(at url: URL) -> QuickOpenContentEntry? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return QuickOpenContentEntry(
            normalizedContent: normalize(text),
            originalContent: text
        )
    }

    private static func fuzzyScore(query: String, candidate: String) -> Int? {
        guard !query.isEmpty, !candidate.isEmpty else { return nil }

        var queryIndex = query.startIndex
        var candidateIndex = candidate.startIndex
        var score = 0
        var previousMatchIndex: String.Index? = nil

        while queryIndex < query.endIndex, candidateIndex < candidate.endIndex {
            if query[queryIndex] == candidate[candidateIndex] {
                score += 14
                if let previousMatchIndex,
                   candidate.index(after: previousMatchIndex) == candidateIndex {
                    score += 8
                }
                previousMatchIndex = candidateIndex
                query.formIndex(after: &queryIndex)
            }
            candidate.formIndex(after: &candidateIndex)
        }

        guard queryIndex == query.endIndex else { return nil }
        return score - max(candidate.count - query.count, 0)
    }
}

struct QuickOpenOverlay: View {
    @EnvironmentObject var quickOpenStore: QuickOpenStore
    @FocusState private var isSearchFieldFocused: Bool
    @State private var keyMonitor: Any? = nil
    @State private var shouldScrollSelectionIntoView = false

    var body: some View {
        Group {
            if quickOpenStore.isPresented {
                ZStack {
                    Color.black.opacity(0.14)
                        .ignoresSafeArea()
                        .onTapGesture {
                            quickOpenStore.hide()
                        }

                    VStack(spacing: 0) {
                        HStack(spacing: 10) {
                            Image(systemName: "magnifyingglass")
                                .foregroundStyle(.secondary)

                            TextField("Search files and text", text: $quickOpenStore.query)
                                .textFieldStyle(.plain)
                                .font(.title3)
                                .focused($isSearchFieldFocused)
                                .onSubmit {
                                    quickOpenStore.openSelection()
                                }
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 16)

                        Divider()

                        Group {
                            if quickOpenStore.hasResults {
                                ScrollViewReader { proxy in
                                    ScrollView {
                                        LazyVStack(spacing: 4) {
                                            ForEach(quickOpenStore.results) { result in
                                                QuickOpenResultRow(
                                                    result: result,
                                                    isSelected: quickOpenStore.selectedResultID == result.id
                                                )
                                                .id(result.id)
                                                .contentShape(Rectangle())
                                                .onHover { isHovering in
                                                    guard isHovering else { return }
                                                    shouldScrollSelectionIntoView = false
                                                    quickOpenStore.selectedResultID = result.id
                                                }
                                                .onTapGesture(count: 2) {
                                                    quickOpenStore.selectedResultID = result.id
                                                    quickOpenStore.openSelection()
                                                }
                                                .onTapGesture {
                                                    quickOpenStore.selectedResultID = result.id
                                                    isSearchFieldFocused = true
                                                }
                                            }
                                        }
                                        .padding(8)
                                    }
                                    .onChange(of: quickOpenStore.selectedResultID) { _, selectedID in
                                        guard shouldScrollSelectionIntoView,
                                              let selectedID else { return }
                                        withAnimation(.snappy(duration: 0.12)) {
                                            proxy.scrollTo(selectedID, anchor: .center)
                                        }
                                        shouldScrollSelectionIntoView = false
                                    }
                                }
                            } else {
                                ContentUnavailableView(
                                    "No Matching Results",
                                    systemImage: "doc.text.magnifyingglass",
                                    description: Text("Try a different filename, path, or text fragment.")
                                )
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                            }
                        }
                        .frame(height: 320)

                        Divider()

                        HStack {
                            Spacer()
                            HStack(spacing: 6) {
                                Text("Open")
                                Text("Return")
                                    .foregroundStyle(.secondary)
                            }
                            HStack(spacing: 6) {
                                Text("Close")
                                Text("Esc")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .font(.caption)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                    }
                    .frame(width: 640)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .shadow(color: .black.opacity(0.16), radius: 28, y: 10)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
                .onAppear {
                    isSearchFieldFocused = true
                    installKeyMonitor()
                }
                .onDisappear {
                    removeKeyMonitor()
                }
                .onExitCommand {
                    quickOpenStore.hide()
                }
            }
        }
        .animation(.snappy(duration: 0.18), value: quickOpenStore.isPresented)
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handleKeyEvent(event)
        }
    }

    private func removeKeyMonitor() {
        guard let keyMonitor else { return }
        NSEvent.removeMonitor(keyMonitor)
        self.keyMonitor = nil
    }

    private func handleKeyEvent(_ event: NSEvent) -> NSEvent? {
        guard quickOpenStore.isPresented else { return event }

        switch event.keyCode {
        case 125:
            shouldScrollSelectionIntoView = true
            quickOpenStore.moveSelection(by: 1)
            return nil
        case 126:
            shouldScrollSelectionIntoView = true
            quickOpenStore.moveSelection(by: -1)
            return nil
        case 36, 76:
            quickOpenStore.openSelection()
            return nil
        case 53:
            quickOpenStore.hide()
            return nil
        default:
            return event
        }
    }
}

private struct QuickOpenResultRow: View {
    let result: QuickOpenResult
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(result.title)
                .lineLimit(1)

            Text(result.subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            if let snippet = result.snippet {
                Text(snippet)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(rowBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var rowBackground: some ShapeStyle {
        isSelected ? AnyShapeStyle(.selection.opacity(0.9)) : AnyShapeStyle(.clear)
    }
}
