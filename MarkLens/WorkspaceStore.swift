import SwiftUI
import UniformTypeIdentifiers
import Combine

@MainActor
final class WorkspaceStore: ObservableObject {
    @Published var rootNodes: [FileNode] = []
    @Published var selectedSidebarURLs: Set<URL> = []
    @Published var pinnedURLs: Set<String>

    let folderWatcher = FolderWatcher()

    private let documentStore: DocumentStore
    private let fileOperations: WorkspaceFileOperations
    private let persistence: WorkspacePersistence
    private var treeRebuildGeneration = 0
    private var workspaceSnapshot: WorkspaceSnapshot?

    var rootFolderURL: URL?

    init(
        documentStore: DocumentStore,
        fileOperations: WorkspaceFileOperations = WorkspaceFileOperations(),
        persistence: WorkspacePersistence = WorkspacePersistence()
    ) {
        self.documentStore = documentStore
        self.fileOperations = fileOperations
        self.persistence = persistence
        self.pinnedURLs = persistence.loadPinnedURLs()
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

    func normalizedRenameTarget(for url: URL, requestedName: String) -> String {
        let trimmedName = requestedName.trimmingCharacters(in: .whitespacesAndNewlines)
        let ext = url.pathExtension
        guard !trimmedName.isEmpty, !ext.isEmpty else { return trimmedName }
        return trimmedName.lowercased().hasSuffix(".\(ext)") ? trimmedName : "\(trimmedName).\(ext)"
    }

    func createFile(named fileName: String, contents: String = "") {
        let trimmedName = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        let baseURL = rootFolderURL ?? documentStore.selectedFileURL?.deletingLastPathComponent()
        guard let dir = baseURL else { return }

        let url: URL
        do {
            url = try fileOperations.createMarkdownFile(named: trimmedName, contents: contents, in: dir)
        } catch {
            present(error, context: "Could not create file")
            return
        }

        handleCreatedFile(at: url)
    }

    func restoreLastSession() {
        documentStore.restoreRecents()
        guard let scopedURL = persistence.restoreRootFolderURL() else { return }
        rootFolderURL = scopedURL
        rebuildTree()
    }

    func closeFolder() {
        documentStore.closeDocument()
        folderWatcher.stopAll()
        treeRebuildGeneration += 1
        rootFolderURL = nil
        workspaceSnapshot = nil
        persistence.saveRootFolderURL(nil)
        rootNodes = []
        selectedSidebarURLs = []
    }

    func createFile() {
        let baseURL = rootFolderURL ?? documentStore.selectedFileURL?.deletingLastPathComponent()
        guard let dir = baseURL else { return }

        let url: URL
        do {
            url = try fileOperations.createUntitledMarkdownFile(in: dir)
        } catch {
            documentStore.errorMessage = error.localizedDescription
            return
        }
        handleCreatedFile(at: url)
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
            self.persistence.saveRootFolderURL(nil)
            self.folderWatcher.stopAll()
            self.rootNodes = [FileNode(url: url, name: url.lastPathComponent, isDirectory: false)]
            self.documentStore.loadFile(url)
        }
    }

    func setRootFolder(_ url: URL) {
        rootFolderURL = url
        persistence.saveRootFolderURL(url)
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
        persistence.savePinnedURLs(pinnedURLs)
        rebuildTree()
    }

    func deleteFile(_ url: URL) {
        do {
            try fileOperations.trashItem(at: url)
        } catch {
            present(error, context: "Could not move \"\(url.lastPathComponent)\" to Trash")
            return
        }
        handleDeletedFile(at: url)
    }

    func renameFile(_ url: URL, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let normalizedName = normalizedRenameTarget(for: url, requestedName: trimmed)
        let newURL: URL
        guard url.deletingLastPathComponent().appendingPathComponent(normalizedName).path != url.path else { return }
        do {
            newURL = try fileOperations.renameItem(at: url, to: normalizedName)
        } catch {
            present(error, context: "Could not rename \"\(url.lastPathComponent)\"")
            return
        }
        handleRenamedFile(from: url, to: newURL)
    }

    func moveNode(_ sourceURL: URL, into destinationFolderURL: URL) {
        moveNodes([sourceURL], into: destinationFolderURL)
    }

    func moveNodes(_ sourceURLs: [URL], into destinationFolderURL: URL) {
        guard destinationFolderURL.hasDirectoryPath else { return }

        let filteredSourceURLs: [URL]
        do {
            filteredSourceURLs = try fileOperations.validatedMoveSources(sourceURLs, into: destinationFolderURL)
        } catch {
            documentStore.errorMessage = error.localizedDescription
            return
        }
        guard !filteredSourceURLs.isEmpty else { return }

        var movedURLsBySource: [URL: URL] = [:]

        for sourceURL in filteredSourceURLs {
            let targetURL: URL

            do {
                targetURL = try fileOperations.moveItem(at: sourceURL, into: destinationFolderURL)
            } catch {
                present(error, context: "Could not move \"\(sourceURL.lastPathComponent)\"")
                return
            }
            movedURLsBySource[sourceURL] = targetURL
        }

        handleMovedFiles(movedURLsBySource)
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

    private func present(_ error: Error, context: String) {
        documentStore.errorMessage = "\(context): \(error.localizedDescription)"
    }

    private func handleCreatedFile(at url: URL) {
        if rootFolderURL != nil {
            rebuildTree()
        } else {
            rootNodes = [FileNode(url: url, name: url.lastPathComponent, isDirectory: false)]
        }
        loadFile(url)
    }

    private func handleDeletedFile(at url: URL) {
        selectedSidebarURLs.remove(url)
        documentStore.clearSelectionIfSelectedFileMatches(url)
        if rootFolderURL != nil {
            rebuildTree()
        } else {
            rootNodes = rootNodes.filter { $0.url != url }
        }
    }

    private func handleRenamedFile(from oldURL: URL, to newURL: URL) {
        syncPinnedURLs([oldURL: newURL])
        syncRecentDocuments([oldURL: newURL])

        if rootFolderURL != nil {
            rebuildTree()
        } else {
            rootNodes = rootNodes.map { node in
                node.url == oldURL
                    ? FileNode(url: newURL, name: newURL.lastPathComponent, isDirectory: false)
                    : node
            }
        }

        selectedSidebarURLs = remappedSelection(selectedSidebarURLs, with: [oldURL: newURL])

        if documentStore.selectedFileURL == oldURL {
            loadFile(newURL)
        }
    }

    private func handleMovedFiles(_ movedURLsBySource: [URL: URL]) {
        syncPinnedURLs(movedURLsBySource)
        syncRecentDocuments(movedURLsBySource)
        selectedSidebarURLs = remappedSelection(selectedSidebarURLs, with: movedURLsBySource)

        if rootFolderURL != nil {
            rebuildTree()
        }

        if let selectedFileURL = documentStore.selectedFileURL,
           let reloadedURL = movedURLsBySource[selectedFileURL] {
            loadFile(reloadedURL, syncSidebarSelection: false)
        }
    }

    private func syncPinnedURLs(_ remappedURLs: [URL: URL]) {
        var updatedPinned = pinnedURLs
        var didChange = false

        for (oldURL, newURL) in remappedURLs where updatedPinned.contains(oldURL.absoluteString) {
            updatedPinned.remove(oldURL.absoluteString)
            updatedPinned.insert(newURL.absoluteString)
            didChange = true
        }

        guard didChange else { return }
        pinnedURLs = updatedPinned
        persistence.savePinnedURLs(pinnedURLs)
    }

    private func syncRecentDocuments(_ remappedURLs: [URL: URL]) {
        for (oldURL, newURL) in remappedURLs where documentStore.hasRecent(oldURL) {
            documentStore.removeRecent(oldURL)
            documentStore.recordRecent(newURL)
        }
    }

    private func remappedSelection(_ selection: Set<URL>, with remappedURLs: [URL: URL]) -> Set<URL> {
        Set(selection.map { remappedURLs[$0] ?? $0 })
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
