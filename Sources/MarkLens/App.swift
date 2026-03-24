import SwiftUI
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

// MARK: - FileNode

struct FileNode: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    let name: String
    let isDirectory: Bool
    var children: [FileNode]?

    var optionalChildren: [FileNode]? { isDirectory ? (children ?? []) : nil }

    static func == (lhs: FileNode, rhs: FileNode) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
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

    private var saveWorkItem: DispatchWorkItem?
    private var lastSavedText: String? = nil
    private var recentBookmarks: [String: Data] = [:]   // url.path → security-scoped bookmark
    private let fileWatcher = FileWatcher()

    var rootFolderURL: URL?

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
        rootFolderURL = nil
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
        if let folder = rootFolderURL {
            rootNodes = buildTree(at: folder)
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
        guard panel.runModal() == .OK, let url = panel.url else { return }
        rootFolderURL = url
        rootNodes = buildTree(at: url)
        if let first = firstFile(in: rootNodes) {
            loadFile(first.url)
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
        guard panel.runModal() == .OK, let url = panel.url else { return }
        rootFolderURL = nil
        rootNodes = [FileNode(url: url, name: url.lastPathComponent, isDirectory: false)]
        loadFile(url)
    }

    // MARK: Tree building

    func buildTree(at url: URL) -> [FileNode] {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .nameKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return contents.compactMap { child -> FileNode? in
            let isDir = (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDir {
                let children = buildTree(at: child)
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
        if let folder = rootFolderURL { rootNodes = buildTree(at: folder) }
    }

    func deleteFile(_ url: URL) {
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        } catch {
            present(error, context: "Could not move \"\(url.lastPathComponent)\" to Trash")
            return
        }
        if selectedFileURL == url { selectedFileURL = nil; documentText = "" }
        if let folder = rootFolderURL {
            rootNodes = buildTree(at: folder)
        } else {
            rootNodes = rootNodes.filter { $0.url != url }
        }
    }

    private func firstFile(in nodes: [FileNode]) -> FileNode? {
        for node in nodes {
            if !node.isDirectory { return node }
            if let child = firstFile(in: node.children ?? []) { return child }
        }
        return nil
    }
}

// MARK: - App Entry Point

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var appState: AppState?

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
        appState?.rootFolderURL = nil
        appState?.rootNodes = [FileNode(url: url, name: url.lastPathComponent, isDirectory: false)]
        appState?.loadFile(url)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Flush any pending debounced save before quitting so no edits are lost
        appState?.flushPendingSave()
        return .terminateNow
    }

    @objc @MainActor private func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        if window.frameAutosaveName.isEmpty {
            window.setFrameAutosaveName("MainWindow")
        }
    }
}

@main
struct MarkLensApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .onAppear {
                    appDelegate.appState = appState
                    appState.restoreLastSession()
                }
                .frame(minWidth: 800, minHeight: 520)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New File") { appState.createFile() }
                    .keyboardShortcut("n", modifiers: .command)
            }
            CommandGroup(after: .newItem) {
                Divider()
                Button("Open File…") { appState.openFilePanel() }
                    .keyboardShortcut("o", modifiers: .command)
                Button("Open Folder…") { appState.openFolderPanel() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                Divider()
                Button("Close Folder") { appState.closeFolder() }
                    .keyboardShortcut("w", modifiers: [.command, .shift])
                    .disabled(appState.rootNodes.isEmpty)
            }
            CommandGroup(replacing: .toolbar) {
                Button(appState.sidebarVisibility == .all ? "Hide Sidebar" : "Show Sidebar") {
                    appState.sidebarVisibility = appState.sidebarVisibility == .all ? .detailOnly : .all
                }
                .keyboardShortcut("s", modifiers: [.command, .control])
            }
            CommandGroup(after: .textEditing) {
                Button("Find…") { appState.isSearchFocused = true }
                    .keyboardShortcut("k", modifiers: .command)
                    .disabled(appState.selectedFileURL == nil)
            }
        }
    }
}
