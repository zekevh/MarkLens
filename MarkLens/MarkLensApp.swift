import SwiftUI
import Combine
import UniformTypeIdentifiers
import AppKit

// MARK: - FileWatcher
// Uses kqueue (O_EVTONLY) to detect writes, renames, and atomic replacements
// (git checkout, most editors) without participating in file-system locking.

@MainActor
final class FileWatcher {
    private var source: DispatchSourceFileSystemObject?
    private var watchedURL: URL?
    private var handler: (() -> Void)?

    func watch(_ url: URL, onChange: @escaping () -> Void) {
        watchedURL = url
        handler    = onChange
        start(at: url)
    }

    func stop() {
        source?.cancel()
        source = nil
    }

    private func start(at url: URL) {
        stop()
        let fd = open(url.path, O_EVTONLY)
        guard fd != -1 else { return }

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )

        src.setEventHandler { [weak self] in
            guard let self else { return }
            let events = src.data
            if events.contains(.rename) || events.contains(.delete) {
                // Atomic replacement (git, most editors write to a temp file then rename).
                // Re-arm after a short delay so the new inode is in place.
                self.stop()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                    guard let self, let url = self.watchedURL else { return }
                    self.start(at: url)
                    self.handler?()
                }
            } else {
                self.handler?()
            }
        }

        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
    }
}

// MARK: - FolderWatcher
// Watches a set of directories with kqueue and fires a debounced callback when
// any of them changes (file created, deleted, or renamed inside them).

@MainActor
final class FolderWatcher {
    private var sources: [URL: DispatchSourceFileSystemObject] = [:]
    private var debounceWork: DispatchWorkItem?
    private var handler: (() -> Void)?

    func watch(directories: [URL], onChange: @escaping () -> Void) {
        handler = onChange
        let newSet = Set(directories)
        let oldSet = Set(sources.keys)

        for url in oldSet.subtracting(newSet) {
            sources[url]?.cancel()
            sources.removeValue(forKey: url)
        }
        for url in newSet.subtracting(oldSet) {
            let fd = open(url.path, O_EVTONLY)
            guard fd != -1 else { continue }
            let src = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main
            )
            src.setEventHandler { [weak self] in self?.schedule() }
            src.setCancelHandler { close(fd) }
            src.resume()
            sources[url] = src
        }
    }

    func stopAll() {
        debounceWork?.cancel()
        debounceWork = nil
        sources.values.forEach { $0.cancel() }
        sources.removeAll()
        handler = nil
    }

    private func schedule() {
        debounceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.handler?() }
        debounceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }
}

// MARK: - FileNode

struct FileNode: Identifiable, Hashable {
    var id: URL { url }
    let url: URL
    let name: String
    let isDirectory: Bool
    var children: [FileNode]?

    var optionalChildren: [FileNode]? { isDirectory ? (children ?? []) : nil }

    static func == (lhs: FileNode, rhs: FileNode) -> Bool { lhs.url == rhs.url }
    func hash(into hasher: inout Hasher) { hasher.combine(url) }
}

// MARK: - GitignoreFilter

/// Parses a single .gitignore file and reports whether a path should be hidden.
struct GitignoreFilter {
    private struct Rule {
        let pattern: String   // cleaned (no leading !, no leading /, no trailing /)
        let isNegated: Bool
        let isDirOnly: Bool
        let anchored: Bool    // pattern contains "/" → matched against full relative path
    }

    private let rules: [Rule]
    private let basePath: String  // directory that owns this .gitignore (no trailing /)

    init(at directoryURL: URL) {
        basePath = directoryURL.path
        let gitignoreURL = directoryURL.appendingPathComponent(".gitignore")
        guard let text = try? String(contentsOf: gitignoreURL, encoding: .utf8) else {
            rules = []
            return
        }
        rules = text.components(separatedBy: .newlines).compactMap { line in
            var s = line.trimmingCharacters(in: .whitespaces)
            guard !s.isEmpty, !s.hasPrefix("#") else { return nil }
            let negated = s.hasPrefix("!"); if negated { s.removeFirst() }
            let dirOnly = s.hasSuffix("/");  if dirOnly  { s.removeLast()  }
            let hadLeadingSlash = s.hasPrefix("/"); if hadLeadingSlash { s.removeFirst() }
            // anchored = path-relative (contains slash, or originally had a leading slash)
            let anchored = hadLeadingSlash || s.contains("/")
            return Rule(pattern: s, isNegated: negated, isDirOnly: dirOnly, anchored: anchored)
        }
    }

    func isIgnored(_ url: URL, isDirectory: Bool) -> Bool {
        guard url.path.hasPrefix(basePath + "/") else { return false }
        let rel  = String(url.path.dropFirst(basePath.count + 1))
        let name = url.lastPathComponent
        var result = false
        for rule in rules {
            if rule.isDirOnly && !isDirectory { continue }
            let hit = rule.anchored
                ? Self.globMatch(pattern: rule.pattern, string: rel)
                : Self.globMatch(pattern: rule.pattern, string: name)
                    || Self.globMatchAnywhere(pattern: rule.pattern, relativePath: rel)
            if hit { result = !rule.isNegated }
        }
        return result
    }

    // MARK: Glob helpers

    private static func globMatch(pattern: String, string: String) -> Bool {
        if pattern.hasPrefix("**/") {
            return globMatchAnywhere(pattern: String(pattern.dropFirst(3)), relativePath: string)
        }
        if pattern.hasSuffix("/**") {
            let dir = String(pattern.dropLast(3))
            return string == dir || string.hasPrefix(dir + "/")
        }
        return fnmatch(pattern, string, FNM_PATHNAME | FNM_PERIOD) == 0
    }

    /// Tries `pattern` against every path suffix of `relativePath` (e.g. `a/b/c` → `b/c`, `c`).
    private static func globMatchAnywhere(pattern: String, relativePath: String) -> Bool {
        let parts = relativePath.components(separatedBy: "/")
        for i in 0..<parts.count {
            let suffix = parts[i...].joined(separator: "/")
            if fnmatch(pattern, suffix, FNM_PATHNAME | FNM_PERIOD) == 0 { return true }
        }
        return false
    }
}

// MARK: - ExternalEditConflict

struct ExternalEditConflict {
    let diskContent: String
    let fileName: String
}

// MARK: - AppState

@MainActor
final class AppState: ObservableObject {
    @Published var rootNodes: [FileNode] = []
    @Published var selectedFileURL: URL? = nil
    @Published var documentText: String = ""
    @Published var pinnedURLs: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "pinnedURLs") ?? [])
    @Published var recentURLs: [URL] = []
    @Published var sidebarVisibility: NavigationSplitViewVisibility = .all
    @Published var searchText: String = ""
    @Published var isSearchFocused: Bool = false
    @Published var errorMessage: String? = nil
    @Published var externalEditConflict: ExternalEditConflict? = nil
    @Published var isRawMode: Bool = false

    private var saveWorkItem: DispatchWorkItem?
    private var lastSavedText: String? = nil
    private var recentBookmarks: [String: Data] = [:]   // url.path → security-scoped bookmark
    private let fileWatcher = FileWatcher()
    let folderWatcher = FolderWatcher()

    var rootFolderURL: URL?

    // MARK: Tree helpers

    /// Rebuild rootNodes from disk and refresh directory watches.
    private func rebuildTree() {
        guard let folder = rootFolderURL else { return }
        rootNodes = buildTree(at: folder)
        refreshFolderWatch()
    }

    /// Update directory watches to match every directory currently in the tree.
    private func refreshFolderWatch() {
        guard let folder = rootFolderURL else { folderWatcher.stopAll(); return }
        let dirs = [folder] + collectDirectories(from: rootNodes)
        folderWatcher.watch(directories: dirs) { [weak self] in self?.rebuildTree() }
    }

    private func collectDirectories(from nodes: [FileNode]) -> [URL] {
        nodes.flatMap { node -> [URL] in
            guard node.isDirectory else { return [] }
            return [node.url] + collectDirectories(from: node.children ?? [])
        }
    }

    // MARK: File loading

    func loadFile(_ url: URL) {
        guard !url.hasDirectoryPath else { return }
        do {
            documentText = try String(contentsOf: url, encoding: .utf8)
        } catch {
            errorMessage = "Could not open \"\(url.lastPathComponent)\": \(error.localizedDescription)"
            return
        }
        lastSavedText = documentText
        selectedFileURL = url
        fileWatcher.watch(url) { [weak self] in self?.reloadIfChangedOnDisk() }
        recordRecent(url)
    }

    /// Handles a link click from the node editor. External URLs (http/https/mailto) are
    /// opened in the default browser; everything else is treated as a path relative to
    /// the currently open file and navigated to inside the editor.
    func handleLinkClick(_ urlString: String) {
        // Try as a full URL with a recognised scheme first.
        if let url = URL(string: urlString),
           let scheme = url.scheme?.lowercased(),
           ["http", "https", "mailto", "ftp"].contains(scheme) {
            NSWorkspace.shared.open(url)
            return
        }
        // Internal link — resolve relative to the directory of the open file.
        guard let base = selectedFileURL?.deletingLastPathComponent() else { return }
        // Strip any fragment (#heading) and query string before resolving.
        let pathPart = urlString.components(separatedBy: CharacterSet(charactersIn: "#?")).first ?? urlString
        guard !pathPart.isEmpty else { return }
        let resolvedURL = URL(fileURLWithPath: pathPart, relativeTo: base).standardized
        guard FileManager.default.fileExists(atPath: resolvedURL.path) else { return }
        loadFile(resolvedURL)
    }

    func clearRecents() {
        recentURLs = []
        recentBookmarks = [:]
        UserDefaults.standard.removeObject(forKey: "recentURLPaths")
        UserDefaults.standard.removeObject(forKey: "recentBookmarks")
        NSDocumentController.shared.clearRecentDocuments(nil)
    }

    private func recordRecent(_ url: URL) {
        var list = recentURLs
        list.removeAll { $0.path == url.path }
        list.insert(url, at: 0)
        recentURLs = Array(list.prefix(10))

        if let bookmark = try? url.bookmarkData(options: .withSecurityScope,
                                                includingResourceValuesForKeys: nil,
                                                relativeTo: nil) {
            recentBookmarks[url.path] = bookmark
            UserDefaults.standard.set(recentBookmarks, forKey: "recentBookmarks")
        }
        UserDefaults.standard.set(recentURLs.map(\.path), forKey: "recentURLPaths")
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
    }

    func openRecent(_ url: URL) {
        guard let bookmarkData = recentBookmarks[url.path] else {
            // No bookmark — file was recorded before sandbox was enabled; ask user to reopen manually
            errorMessage = "Cannot access \"\(url.lastPathComponent)\" — please open it via File > Open."
            recentURLs.removeAll { $0.path == url.path }
            recentBookmarks.removeValue(forKey: url.path)
            UserDefaults.standard.set(recentURLs.map(\.path), forKey: "recentURLPaths")
            UserDefaults.standard.set(recentBookmarks, forKey: "recentBookmarks")
            return
        }
        var isStale = false
        do {
            let scopedURL = try URL(resolvingBookmarkData: bookmarkData,
                                    options: .withSecurityScope,
                                    relativeTo: nil,
                                    bookmarkDataIsStale: &isStale)
            guard scopedURL.startAccessingSecurityScopedResource() else {
                throw CocoaError(.fileReadNoPermission)
            }
            if isStale, let refreshed = try? scopedURL.bookmarkData(options: .withSecurityScope,
                                                                    includingResourceValuesForKeys: nil,
                                                                    relativeTo: nil) {
                recentBookmarks[url.path] = refreshed
                UserDefaults.standard.set(recentBookmarks, forKey: "recentBookmarks")
            }
            loadFile(scopedURL)
        } catch {
            errorMessage = "Cannot access \"\(url.lastPathComponent)\": \(error.localizedDescription)"
        }
    }

    private func reloadIfChangedOnDisk() {
        guard let url = selectedFileURL else { return }
        guard let onDisk = try? String(contentsOf: url, encoding: .utf8) else { return }
        guard onDisk != documentText else { return }
        // Disk matches what we last wrote — our own save fired the watcher; user may have
        // typed more since. Either way, nothing to do.
        guard onDisk != lastSavedText else { return }

        if documentText == lastSavedText {
            // Disk changed, no unsaved edits — silently reload
            documentText = onDisk
            lastSavedText = onDisk
        } else {
            // Disk changed AND user has unsaved edits — surface the conflict
            externalEditConflict = ExternalEditConflict(
                diskContent: onDisk,
                fileName: url.lastPathComponent
            )
        }
    }

    func resolveConflict(keepMine: Bool) {
        guard let conflict = externalEditConflict else { return }
        externalEditConflict = nil
        if !keepMine {
            documentText = conflict.diskContent
            lastSavedText = conflict.diskContent
        }
    }

    private func present(_ error: Error, context: String) {
        errorMessage = "\(context): \(error.localizedDescription)"
    }

    func restoreLastSession() {
        recentBookmarks = (UserDefaults.standard.dictionary(forKey: "recentBookmarks") as? [String: Data]) ?? [:]
        let storedPaths = UserDefaults.standard.stringArray(forKey: "recentURLPaths") ?? []
        // Keep only paths that have a bookmark (sandbox can't verify existence without access)
        recentURLs = storedPaths
            .filter { recentBookmarks[$0] != nil }
            .map { URL(fileURLWithPath: $0) }

        // Restore last opened folder
        if let bookmarkData = UserDefaults.standard.data(forKey: "rootFolderBookmark") {
            var isStale = false
            if let scopedURL = try? URL(resolvingBookmarkData: bookmarkData,
                                        options: .withSecurityScope,
                                        relativeTo: nil,
                                        bookmarkDataIsStale: &isStale),
               scopedURL.startAccessingSecurityScopedResource() {
                if isStale {
                    saveFolderBookmark(scopedURL)
                }
                rootFolderURL = scopedURL
                rebuildTree()
            }
        }
    }

    func saveCurrentFile(text: String) {
        guard let url = selectedFileURL else { return }
        guard FileManager.default.isWritableFile(atPath: url.path) else {
            errorMessage = "Cannot save \"\(url.lastPathComponent)\": file is read-only."
            return
        }
        saveWorkItem?.cancel()
        lastSavedText = text   // mark now so our own write doesn't trigger a conflict
        let item = DispatchWorkItem { [weak self] in
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                DispatchQueue.main.async {
                    self?.present(error, context: "Could not save \"\(url.lastPathComponent)\"")
                }
            }
            DispatchQueue.main.async { self?.saveWorkItem = nil }
        }
        saveWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: item)
    }

    func flushPendingSave() {
        saveWorkItem?.perform()
        saveWorkItem?.cancel()
        saveWorkItem = nil
    }

    // MARK: Close folder / workspace

    func closeFolder() {
        saveWorkItem?.perform()
        saveWorkItem?.cancel()
        saveWorkItem = nil
        fileWatcher.stop()
        folderWatcher.stopAll()
        rootFolderURL = nil
        saveFolderBookmark(nil)
        rootNodes = []
        selectedFileURL = nil
        documentText = ""
    }

    // MARK: New file

    func createFile() {
        let baseURL = rootFolderURL ?? selectedFileURL?.deletingLastPathComponent()
        guard let dir = baseURL else { return }

        var url = dir.appendingPathComponent("Untitled.md")
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("Untitled \(counter).md")
            counter += 1
        }
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            errorMessage = "Could not create \"\(url.lastPathComponent)\". Check folder permissions."
            return
        }
        if rootFolderURL != nil {
            rebuildTree()
        } else {
            rootNodes = [FileNode(url: url, name: url.lastPathComponent, isDirectory: false)]
        }
        loadFile(url)
    }

    // MARK: Open panels

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
            self.saveFolderBookmark(nil)
            self.folderWatcher.stopAll()
            self.rootNodes = [FileNode(url: url, name: url.lastPathComponent, isDirectory: false)]
            self.loadFile(url)
        }
    }

    /// Sets the root folder, saves a security-scoped bookmark, rebuilds the tree.
    func setRootFolder(_ url: URL) {
        rootFolderURL = url
        saveFolderBookmark(url)
        rebuildTree()
        if let first = firstFile(in: rootNodes) {
            loadFile(first.url)
        }
    }

    private func saveFolderBookmark(_ url: URL?) {
        guard let url else {
            UserDefaults.standard.removeObject(forKey: "rootFolderBookmark")
            UserDefaults.standard.removeObject(forKey: "rootFolderPath")
            return
        }
        if let bookmark = try? url.bookmarkData(options: .withSecurityScope,
                                                includingResourceValuesForKeys: nil,
                                                relativeTo: nil) {
            UserDefaults.standard.set(bookmark, forKey: "rootFolderBookmark")
            UserDefaults.standard.set(url.path, forKey: "rootFolderPath")
        }
    }

    // MARK: Tree building

    func buildTree(at url: URL, parentFilters: [GitignoreFilter] = []) -> [FileNode] {
        let fm = FileManager.default
        // Accumulate .gitignore rules defined in this directory.
        var filters = parentFilters
        if fm.fileExists(atPath: url.appendingPathComponent(".gitignore").path) {
            filters.append(GitignoreFilter(at: url))
        }
        guard let contents = try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .nameKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return contents.compactMap { child -> FileNode? in
            let isDir = (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            // Skip entries matched by any active .gitignore.
            if filters.contains(where: { $0.isIgnored(child, isDirectory: isDir) }) { return nil }
            if isDir {
                let children = buildTree(at: child, parentFilters: filters)
                guard !children.isEmpty else { return nil }  // skip folders with no markdown
                return FileNode(url: child, name: child.lastPathComponent,
                               isDirectory: true, children: children)
            }
            let ext = child.pathExtension.lowercased()
            guard ext == "md" || ext == "markdown" else { return nil }
            return FileNode(url: child, name: child.lastPathComponent, isDirectory: false)
        }
        .sorted {
            // Pinned files float to the top, then folders, then alphabetical
            let lPin = pinnedURLs.contains($0.url.absoluteString)
            let rPin = pinnedURLs.contains($1.url.absoluteString)
            if lPin != rPin { return lPin }
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    // MARK: Pin / Delete

    func isPinned(_ url: URL) -> Bool {
        pinnedURLs.contains(url.absoluteString)
    }

    func togglePin(_ url: URL) {
        let key = url.absoluteString
        if pinnedURLs.contains(key) { pinnedURLs.remove(key) } else { pinnedURLs.insert(key) }
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
        if selectedFileURL == url { selectedFileURL = nil; documentText = "" }
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
        // Replace old URL in recents with new URL
        if recentURLs.contains(where: { $0.path == url.path }) {
            recentURLs.removeAll { $0.path == url.path }
            recentBookmarks.removeValue(forKey: url.path)
            recordRecent(newURL)
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
        if selectedFileURL == url { loadFile(newURL) }
    }

    private func firstFile(in nodes: [FileNode]) -> FileNode? {
        for node in nodes {
            if !node.isDirectory { return node }
            if let child = firstFile(in: node.children ?? []) { return child }
        }
        return nil
    }

    // MARK: External file open (Finder double-click / drag)

    /// Opens a file received from outside the app (Finder, CLI, drag). Walks up the
    /// directory tree to find the nearest git root and uses that as the sidebar root
    /// so the project tree is visible. Falls back to a single-file view if the git
    /// root is inaccessible (sandbox) or absent.
    func openExternalFile(_ url: URL) {
        guard !url.hasDirectoryPath else { return }
        if let gitRoot = findGitRoot(for: url) {
            rootFolderURL = gitRoot
            rebuildTree()
            // rebuildTree may come back empty if the sandbox blocks the directory;
            // fall through to single-file mode in that case.
            if !rootNodes.isEmpty {
                loadFile(url)
                return
            }
        }
        // No git root found (or sandbox blocked it) — show just the single file.
        folderWatcher.stopAll()
        rootFolderURL = nil
        rootNodes = [FileNode(url: url, name: url.lastPathComponent, isDirectory: false)]
        loadFile(url)
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

// MARK: - Window Accessor

/// Retrieves the hosting NSWindow for a SwiftUI view so AppDelegate can map
/// windows to their isolated AppState instances.
private struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window { self.onWindow(window) }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - Commands

/// All app-level commands. Uses @FocusedObject so each command targets the
/// frontmost window's own AppState rather than a shared global instance.
private struct AppCommands: Commands {
    @FocusedObject var appState: AppState?
    @Environment(\.openWindow) private var openWindow

    /// @FocusedObject can be nil on first launch before any window interaction.
    /// Fall back to AppDelegate's tracked key window state.
    private var activeState: AppState? {
        appState ?? (NSApp.delegate as? AppDelegate)?.keyAppState
    }

    /// Resolve the same UndoManager the focused editor/view is using so menu state
    /// reflects the frontmost responder chain. Falls back to the key window's manager.
    private var activeUndoManager: UndoManager? {
        NSApp.keyWindow?.firstResponder?.undoManager ?? NSApp.keyWindow?.undoManager
    }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New File") { activeState?.createFile() }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(activeState == nil)
            Button("New Window") { openWindow(id: "main") }
                .keyboardShortcut("n", modifiers: [.command, .option])
        }
        CommandGroup(replacing: .undoRedo) {
            Button(activeUndoManager?.undoMenuItemTitle ?? "Undo") {
                guard let undoManager = activeUndoManager, undoManager.canUndo else { return }
                undoManager.undo()
            }
            .keyboardShortcut("z", modifiers: .command)
            .disabled(!(activeUndoManager?.canUndo ?? false))

            Button(activeUndoManager?.redoMenuItemTitle ?? "Redo") {
                guard let undoManager = activeUndoManager, undoManager.canRedo else { return }
                undoManager.redo()
            }
            .keyboardShortcut("Z", modifiers: [.command, .shift])
            .disabled(!(activeUndoManager?.canRedo ?? false))
        }
        CommandGroup(after: .newItem) {
            Divider()
            Button("Open File…") { activeState?.openFilePanel() }
                .keyboardShortcut("o", modifiers: .command)
            Button("Open Folder…") { activeState?.openFolderPanel() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            Divider()
            Button("Close Folder") { activeState?.closeFolder() }
                .keyboardShortcut("w", modifiers: [.command, .shift])
                .disabled(activeState?.rootNodes.isEmpty ?? true)
        }
        CommandGroup(replacing: .toolbar) {
            Button((activeState?.sidebarVisibility ?? .all) == .all ? "Hide Sidebar" : "Show Sidebar") {
                activeState?.sidebarVisibility = activeState?.sidebarVisibility == .all ? .detailOnly : .all
            }
            .keyboardShortcut("s", modifiers: [.command, .control])

            Button("Enter Full Screen") {
                NSApp.keyWindow?.toggleFullScreen(nil)
            }
            .keyboardShortcut("f", modifiers: [.command, .control])
        }
        CommandGroup(after: .textEditing) {
            Button("Find…") { activeState?.isSearchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(activeState?.selectedFileURL == nil)
        }
        CommandGroup(after: .toolbar) {
            Button((activeState?.isRawMode ?? false) ? "Show Rendered Markdown" : "Show Raw Markdown") {
                activeState?.isRawMode.toggle()
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(activeState?.selectedFileURL == nil)
        }
    }
}

// MARK: - Per-Window Root View

/// Each window instance owns its own AppState. The state is exposed via
/// focusedObject so AppCommands always targets the frontmost window.
private struct WindowView: View {
    @StateObject private var appState = AppState()
    let appDelegate: AppDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ContentView()
            .environmentObject(appState)
            .focusedObject(appState)
            .background(WindowAccessor { window in
                appDelegate.register(window: window, state: appState)
            })
            .onAppear {
                appState.restoreLastSession()
            }
            .onReceive(NotificationCenter.default.publisher(for: .marklensOpenNewWindow)) { _ in
                openWindow(id: "main")
            }
            .frame(minWidth: 600, minHeight: 350)
    }
}

// MARK: - App Entry Point

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Maps each NSWindow (by pointer identity) to the AppState it hosts.
    private var windowStates: [NSValue: AppState] = [:]

    /// The AppState belonging to the currently key (frontmost) window.
    private(set) weak var keyAppState: AppState?

    /// File URL received from Finder (or MCP new_window) before a window state registers.
    /// Applied to the first window that calls register().
    var pendingFileURL: URL?

    private var mcpServer: MCPServer?

    func register(window: NSWindow, state: AppState) {
        windowStates[NSValue(nonretainedObject: window)] = state
        if let url = pendingFileURL {
            pendingFileURL = nil
            state.openExternalFile(url)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        CrashReporter.shared.start()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidBecomeKey),
            name: NSWindow.didBecomeKeyNotification,
            object: nil
        )
        startMCPServer()
    }

    private func startMCPServer() {
        let server = MCPServer(
            openFile: { @MainActor [weak self] url in
                self?.keyAppState?.openExternalFile(url)
                NSApp.activate(ignoringOtherApps: true)
            },
            newWindow: { @MainActor [weak self] url in
                if let url { self?.pendingFileURL = url }
                NotificationCenter.default.post(name: .marklensOpenNewWindow, object: nil)
            },
            activateApp: { @MainActor in
                NSApp.activate(ignoringOtherApps: true)
            }
        )
        mcpServer = server
        Task {
            do { try await server.start() }
            catch { print("[MCPServer] Failed to start on port \(MCPServer.port): \(error)") }
        }
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        open(URL(fileURLWithPath: filename))
        return true
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        filenames.forEach { open(URL(fileURLWithPath: $0)) }
    }

    @MainActor private func open(_ url: URL) {
        guard !url.hasDirectoryPath,
              FileManager.default.fileExists(atPath: url.path) else { return }
        if let state = keyAppState ?? windowStates.values.first {
            state.openExternalFile(url)
        } else {
            // No window registered yet (app just launched via Finder double-click).
            // Store and apply once the first window comes up.
            pendingFileURL = url
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Flush pending debounced saves in every open window before quitting.
        windowStates.values.forEach { $0.flushPendingSave() }
        return .terminateNow
    }

    @objc @MainActor private func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        if window.frameAutosaveName.isEmpty {
            window.setFrameAutosaveName("MainWindow")
        }
        if let state = windowStates[NSValue(nonretainedObject: window)] {
            keyAppState = state
        }
    }
}

@main
struct MarkLensApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup(id: "main") {
            WindowView(appDelegate: appDelegate)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            AppCommands()
        }

        Settings {
            SettingsView()
        }
    }
}
