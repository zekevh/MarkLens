import SwiftUI
import UniformTypeIdentifiers
import Combine

@MainActor
final class WorkspaceStore: ObservableObject {
    @Published var rootNodes: [FileNode] = []
    @Published var selectedSidebarURLs: Set<URL> = []
    @Published var pinnedURLs: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "pinnedURLs") ?? [])

    let folderWatcher = FolderWatcher()

    private let documentStore: DocumentStore
    private var treeRebuildGeneration = 0
    private var workspaceSnapshot: WorkspaceSnapshot?

    var rootFolderURL: URL?

    init(documentStore: DocumentStore) {
        self.documentStore = documentStore
    }

    func rebuildTree(onComplete: (@MainActor ([FileNode]) -> Void)? = nil) {
        guard let folder = rootFolderURL else { return }

        treeRebuildGeneration += 1
        let generation = treeRebuildGeneration
        let pinnedURLs = pinnedURLs

        Task { @MainActor [weak self] in
            let snapshot = await WorkspaceRefreshService.buildSnapshot(at: folder, pinnedURLs: pinnedURLs)
            guard let self else { return }
            guard self.treeRebuildGeneration == generation, self.rootFolderURL == snapshot.rootFolder else { return }
            self.workspaceSnapshot = snapshot
            self.rootNodes = snapshot.nodes
            self.applyFolderWatch(snapshot)
            onComplete?(snapshot.nodes)
        }
    }

    func loadFile(_ url: URL, syncSidebarSelection: Bool = true) {
        documentStore.loadFile(url)
        if syncSidebarSelection {
            selectedSidebarURLs = [url]
        }
    }

    func updateSidebarSelection(_ newSelection: Set<URL>) {
        let previousSelection = selectedSidebarURLs
        selectedSidebarURLs = newSelection

        guard let candidate = preferredSidebarFileSelection(
            oldSelection: previousSelection,
            newSelection: newSelection
        ) else { return }

        if documentStore.selectedFileURL != candidate {
            loadFile(candidate, syncSidebarSelection: false)
        }
    }

    var pinnedFileNodes: [FileNode] {
        pinnedFileNodes(from: rootNodes)
    }

    func createFile(named fileName: String, contents: String = "") {
        let trimmedName = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        let normalizedName = trimmedName.lowercased().hasSuffix(".md") ? trimmedName : "\(trimmedName).md"
        let baseURL = rootFolderURL ?? documentStore.selectedFileURL?.deletingLastPathComponent()
        guard let dir = baseURL else { return }

        let url = dir.appendingPathComponent(normalizedName)
        guard !FileManager.default.fileExists(atPath: url.path) else {
            documentStore.errorMessage = "\"\(url.lastPathComponent)\" already exists."
            return
        }

        do {
            try contents.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            present(error, context: "Could not create \"\(url.lastPathComponent)\"")
            return
        }

        if rootFolderURL != nil {
            rebuildTree()
        } else {
            rootNodes = [FileNode(url: url, name: url.lastPathComponent, isDirectory: false)]
        }
        loadFile(url)
    }

    func restoreLastSession() {
        documentStore.restoreRecents()

        guard let bookmarkData = UserDefaults.standard.data(forKey: "rootFolderBookmark") else { return }

        var isStale = false
        if let scopedURL = try? URL(
            resolvingBookmarkData: bookmarkData,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ), scopedURL.startAccessingSecurityScopedResource() {
            if isStale {
                saveFolderBookmark(scopedURL)
            }
            rootFolderURL = scopedURL
            rebuildTree()
        }
    }

    func closeFolder() {
        documentStore.closeDocument()
        folderWatcher.stopAll()
        treeRebuildGeneration += 1
        rootFolderURL = nil
        workspaceSnapshot = nil
        saveFolderBookmark(nil)
        rootNodes = []
        selectedSidebarURLs = []
    }

    func createFile() {
        let baseURL = rootFolderURL ?? documentStore.selectedFileURL?.deletingLastPathComponent()
        guard let dir = baseURL else { return }

        var url = dir.appendingPathComponent("Untitled.md")
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("Untitled \(counter).md")
            counter += 1
        }
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            documentStore.errorMessage = "Could not create \"\(url.lastPathComponent)\". Check folder permissions."
            return
        }
        if rootFolderURL != nil {
            rebuildTree()
        } else {
            rootNodes = [FileNode(url: url, name: url.lastPathComponent, isDirectory: false)]
        }
        loadFile(url)
    }

    func openFolderPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Open Folder"
        panel.begin { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            self.setRootFolder(url)
        }
    }

    func openFilePanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [
            UTType(filenameExtension: "md") ?? .plainText,
            UTType(filenameExtension: "markdown") ?? .plainText
        ]
        panel.prompt = "Open"
        panel.begin { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            self.rootFolderURL = nil
            self.workspaceSnapshot = nil
            self.saveFolderBookmark(nil)
            self.folderWatcher.stopAll()
            self.rootNodes = [FileNode(url: url, name: url.lastPathComponent, isDirectory: false)]
            self.documentStore.loadFile(url)
        }
    }

    func setRootFolder(_ url: URL) {
        rootFolderURL = url
        saveFolderBookmark(url)
        rebuildTree { [weak self] nodes in
            guard let self, let first = self.firstFile(in: nodes) else { return }
            self.loadFile(first.url)
        }
    }

    func buildTree(at url: URL, parentFilters: [GitignoreFilter] = []) -> [FileNode] {
        WorkspaceTreeBuilder.buildTree(at: url, pinnedURLs: pinnedURLs, parentFilters: parentFilters)
    }

    func isPinned(_ url: URL) -> Bool {
        pinnedURLs.contains(url.absoluteString)
    }

    func togglePin(_ url: URL) {
        let key = url.absoluteString
        if pinnedURLs.contains(key) {
            pinnedURLs.remove(key)
        } else {
            pinnedURLs.insert(key)
        }
        UserDefaults.standard.set(Array(pinnedURLs), forKey: "pinnedURLs")
        rebuildTree()
    }

    func deleteFile(_ url: URL) {
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        } catch {
            present(error, context: "Could not move \"\(url.lastPathComponent)\" to Trash")
            return
        }
        selectedSidebarURLs.remove(url)
        documentStore.clearSelectionIfSelectedFileMatches(url)
        if rootFolderURL != nil {
            rebuildTree()
        } else {
            rootNodes = rootNodes.filter { $0.url != url }
        }
    }

    func renameFile(_ url: URL, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let newURL = url.deletingLastPathComponent().appendingPathComponent(trimmed)
        guard newURL.path != url.path else { return }
        do {
            try FileManager.default.moveItem(at: url, to: newURL)
        } catch {
            present(error, context: "Could not rename \"\(url.lastPathComponent)\"")
            return
        }
        if pinnedURLs.contains(url.absoluteString) {
            pinnedURLs.remove(url.absoluteString)
            pinnedURLs.insert(newURL.absoluteString)
            UserDefaults.standard.set(Array(pinnedURLs), forKey: "pinnedURLs")
        }
        if documentStore.hasRecent(url) {
            documentStore.removeRecent(url)
            documentStore.recordRecent(newURL)
        }
        if rootFolderURL != nil {
            rebuildTree()
        } else {
            rootNodes = rootNodes.map { node in
                node.url == url
                    ? FileNode(url: newURL, name: newURL.lastPathComponent, isDirectory: false)
                    : node
            }
        }
        if selectedSidebarURLs.contains(url) {
            selectedSidebarURLs.remove(url)
            selectedSidebarURLs.insert(newURL)
        }
        if documentStore.selectedFileURL == url {
            loadFile(newURL)
        }
    }

    func moveNode(_ sourceURL: URL, into destinationFolderURL: URL) {
        moveNodes([sourceURL], into: destinationFolderURL)
    }

    func moveNodes(_ sourceURLs: [URL], into destinationFolderURL: URL) {
        guard destinationFolderURL.hasDirectoryPath else { return }

        let uniqueSourceURLs = Array(Set(sourceURLs)).sorted { $0.path < $1.path }
        guard !uniqueSourceURLs.isEmpty else { return }

        let filteredSourceURLs = uniqueSourceURLs.filter { sourceURL in
            let standardizedSourcePath = sourceURL.standardizedFileURL.path
            return !uniqueSourceURLs.contains(where: {
                $0 != sourceURL &&
                standardizedSourcePath.hasPrefix($0.standardizedFileURL.path + "/")
            })
        }
        guard !filteredSourceURLs.isEmpty else { return }

        for sourceURL in filteredSourceURLs {
            guard sourceURL != destinationFolderURL else { continue }
            guard sourceURL.deletingLastPathComponent() != destinationFolderURL else { continue }

            let sourcePath = sourceURL.standardizedFileURL.path
            let destinationPath = destinationFolderURL.standardizedFileURL.path
            if destinationPath.hasPrefix(sourcePath + "/") {
                documentStore.errorMessage = "Cannot move a folder into one of its own subfolders."
                return
            }

            let targetURL = destinationFolderURL.appendingPathComponent(sourceURL.lastPathComponent)
            guard !FileManager.default.fileExists(atPath: targetURL.path) else {
                documentStore.errorMessage = "\"\(targetURL.lastPathComponent)\" already exists in \"\(destinationFolderURL.lastPathComponent)\"."
                return
            }
        }

        var movedSelections: Set<URL> = []
        var reloadedURL: URL? = nil
        var updatedPinned = pinnedURLs

        for sourceURL in filteredSourceURLs {
            let targetURL = destinationFolderURL.appendingPathComponent(sourceURL.lastPathComponent)

            do {
                try FileManager.default.moveItem(at: sourceURL, to: targetURL)
            } catch {
                present(error, context: "Could not move \"\(sourceURL.lastPathComponent)\"")
                return
            }

            if updatedPinned.contains(sourceURL.absoluteString) {
                updatedPinned.remove(sourceURL.absoluteString)
                updatedPinned.insert(targetURL.absoluteString)
            }

            if documentStore.hasRecent(sourceURL) {
                documentStore.removeRecent(sourceURL)
                documentStore.recordRecent(targetURL)
            }

            if selectedSidebarURLs.contains(sourceURL) {
                movedSelections.insert(targetURL)
            }

            if documentStore.selectedFileURL == sourceURL {
                reloadedURL = targetURL
            }
        }

        pinnedURLs = updatedPinned
        UserDefaults.standard.set(Array(pinnedURLs), forKey: "pinnedURLs")

        selectedSidebarURLs.subtract(filteredSourceURLs)
        selectedSidebarURLs.formUnion(movedSelections)

        if rootFolderURL != nil {
            rebuildTree()
        }

        if let reloadedURL {
            loadFile(reloadedURL, syncSidebarSelection: false)
        }
    }

    func openExternalFile(_ url: URL) {
        guard !url.hasDirectoryPath else { return }
        if let gitRoot = findGitRoot(for: url) {
            rootFolderURL = gitRoot
            rebuildTree { [weak self] nodes in
                guard let self else { return }
                if !nodes.isEmpty {
                    self.loadFile(url)
                    return
                }
                self.folderWatcher.stopAll()
                self.rootFolderURL = nil
                self.rootNodes = [FileNode(url: url, name: url.lastPathComponent, isDirectory: false)]
                self.loadFile(url)
            }
            return
        }
        folderWatcher.stopAll()
        rootFolderURL = nil
        rootNodes = [FileNode(url: url, name: url.lastPathComponent, isDirectory: false)]
        loadFile(url)
    }

    private func applyFolderWatch(_ snapshot: WorkspaceSnapshot) {
        WorkspaceRefreshService.applyWatch(snapshot, using: folderWatcher) { [weak self] changedDirectories in
            self?.refreshWorkspace(changedDirectories: changedDirectories)
        }
    }

    private func refreshWorkspace(changedDirectories: Set<URL>) {
        guard let snapshot = workspaceSnapshot, let rootFolderURL else {
            rebuildTree()
            return
        }

        guard changedDirectories.count == 1, let changedDirectory = changedDirectories.first else {
            rebuildTree()
            return
        }

        treeRebuildGeneration += 1
        let generation = treeRebuildGeneration
        let pinnedURLs = pinnedURLs

        Task { @MainActor [weak self] in
            let refreshedSnapshot = await WorkspaceRefreshService.refreshSnapshot(
                from: snapshot,
                changedDirectory: changedDirectory,
                pinnedURLs: pinnedURLs
            )
            guard let self else { return }
            guard self.treeRebuildGeneration == generation, self.rootFolderURL == rootFolderURL else { return }
            self.workspaceSnapshot = refreshedSnapshot
            self.rootNodes = refreshedSnapshot.nodes
            self.applyFolderWatch(refreshedSnapshot)
        }
    }

    private func preferredSidebarFileSelection(oldSelection: Set<URL>, newSelection: Set<URL>) -> URL? {
        if let current = documentStore.selectedFileURL,
           newSelection.contains(current),
           !current.hasDirectoryPath {
            return current
        }

        let orderedURLs = visibleSidebarURLs(from: rootNodes)
        let addedURLs = newSelection.subtracting(oldSelection)
        let candidateSet = addedURLs.isEmpty ? newSelection : addedURLs

        return orderedURLs.last(where: { candidateSet.contains($0) && !$0.hasDirectoryPath })
    }

    private func visibleSidebarURLs(from nodes: [FileNode]) -> [URL] {
        nodes.flatMap { node in
            [node.url] + visibleSidebarURLs(from: node.children ?? [])
        }
    }

    private func pinnedFileNodes(from nodes: [FileNode]) -> [FileNode] {
        nodes.flatMap { node in
            if node.isDirectory {
                return pinnedFileNodes(from: node.children ?? [])
            }

            return isPinned(node.url) ? [node] : []
        }
    }

    private func saveFolderBookmark(_ url: URL?) {
        guard let url else {
            UserDefaults.standard.removeObject(forKey: "rootFolderBookmark")
            UserDefaults.standard.removeObject(forKey: "rootFolderPath")
            return
        }
        if let bookmark = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) {
            UserDefaults.standard.set(bookmark, forKey: "rootFolderBookmark")
            UserDefaults.standard.set(url.path, forKey: "rootFolderPath")
        }
    }

    private func present(_ error: Error, context: String) {
        documentStore.errorMessage = "\(context): \(error.localizedDescription)"
    }

    private func firstFile(in nodes: [FileNode]) -> FileNode? {
        for node in nodes {
            if !node.isDirectory {
                return node
            }
            if let child = firstFile(in: node.children ?? []) {
                return child
            }
        }
        return nil
    }

    private func findGitRoot(for url: URL) -> URL? {
        var dir = url.deletingLastPathComponent()
        while dir.pathComponents.count > 1 {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent(".git").path) {
                return dir
            }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }
}
