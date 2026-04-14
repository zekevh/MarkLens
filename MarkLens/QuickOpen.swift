import SwiftUI
import Combine
import AppKit

struct QuickOpenResult: Identifiable, Hashable {
    let id: URL
    let url: URL
    let title: String
    let subtitle: String
    let score: Int
    let order: Int
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
    private var cancellables: Set<AnyCancellable> = []

    init(workspaceStore: WorkspaceStore) {
        self.workspaceStore = workspaceStore

        workspaceStore.$rootNodes
            .sink { [weak self] _ in
                self?.refreshResults()
            }
            .store(in: &cancellables)

        workspaceStore.$selectedSidebarURLs
            .sink { [weak self] _ in
                self?.syncSelectionWithWorkspace()
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
        workspaceStore.loadFile(selectedResult.url)
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
            guard let score = Self.scoreMatch(query: trimmedQuery, title: title, subtitle: subtitle, order: index) else {
                return nil
            }

            return QuickOpenResult(
                id: url,
                url: url,
                title: title,
                subtitle: subtitle,
                score: score,
                order: index
            )
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

    private static func scoreMatch(query: String, title: String, subtitle: String, order: Int) -> Int? {
        guard !title.isEmpty else { return nil }
        guard !query.isEmpty else { return 10_000 - order }

        let normalizedQuery = normalize(query)
        let normalizedTitle = normalize(title)
        let normalizedPath = normalize("\(subtitle)/\(title)")
        let titleStem = normalize((title as NSString).deletingPathExtension)

        var score = 0

        if normalizedTitle == normalizedQuery || titleStem == normalizedQuery {
            score += 3_000
        }
        if normalizedTitle.hasPrefix(normalizedQuery) || titleStem.hasPrefix(normalizedQuery) {
            score += 2_000
        }
        if normalizedTitle.contains(normalizedQuery) || titleStem.contains(normalizedQuery) {
            score += 1_200
        }
        if normalizedPath.contains(normalizedQuery) {
            score += 700
        }

        if let fuzzyTitle = fuzzyScore(query: normalizedQuery, candidate: titleStem) {
            score += 900 + fuzzyTitle
        } else if let fuzzyPath = fuzzyScore(query: normalizedQuery, candidate: normalizedPath) {
            score += 300 + fuzzyPath
        }

        guard score > 0 else { return nil }
        return score - min(order, 200)
    }

    private static func normalize(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
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

                            TextField("Search files", text: $quickOpenStore.query)
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
                                    "No Matching Files",
                                    systemImage: "doc.text.magnifyingglass",
                                    description: Text("Try a different filename or path fragment.")
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
