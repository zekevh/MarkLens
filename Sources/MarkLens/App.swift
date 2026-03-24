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

    private var saveWorkItem: DispatchWorkItem?
    private let fileWatcher = FileWatcher()

    var rootFolderURL: URL? {
        didSet { UserDefaults.standard.set(rootFolderURL?.path, forKey: "lastRootFolderPath") }
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
        selectedFileURL = url
        UserDefaults.standard.set(url.path, forKey: "lastSelectedFilePath")
        fileWatcher.watch(url) { [weak self] in self?.reloadIfChangedOnDisk() }
        recordRecent(url)
    }

    private func recordRecent(_ url: URL) {
        var list = recentURLs
        list.removeAll { $0.path == url.path }
        list.insert(url, at: 0)
        recentURLs = Array(list.prefix(10))
        UserDefaults.standard.set(recentURLs.map(\.path), forKey: "recentURLPaths")
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
    }

    private func reloadIfChangedOnDisk() {
        guard let url = selectedFileURL else { return }
        guard let onDisk = try? String(contentsOf: url, encoding: .utf8) else { return }
        guard onDisk != documentText else { return }
        documentText = onDisk
    }

    private func present(_ error: Error, context: String) {
        errorMessage = "\(context): \(error.localizedDescription)"
    }

    func restoreLastSession() {
        let storedPaths = UserDefaults.standard.stringArray(forKey: "recentURLPaths") ?? []
        recentURLs = storedPaths
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }

        if let folderPath = UserDefaults.standard.string(forKey: "lastRootFolderPath") {
            let folderURL = URL(fileURLWithPath: folderPath)
            guard FileManager.default.fileExists(atPath: folderPath) else { return }
            rootFolderURL = folderURL
            rootNodes = buildTree(at: folderURL)
        }
        if let filePath = UserDefaults.standard.string(forKey: "lastSelectedFilePath") {
            let fileURL = URL(fileURLWithPath: filePath)
            guard FileManager.default.fileExists(atPath: filePath) else { return }
            loadFile(fileURL)
        } else if let first = firstFile(in: rootNodes) {
            loadFile(first.url)
        }
    }

    func saveCurrentFile(text: String) {
        guard let url = selectedFileURL else { return }
        guard FileManager.default.isWritableFile(atPath: url.path) else {
            errorMessage = "Cannot save \"\(url.lastPathComponent)\": file is read-only."
            return
        }
        saveWorkItem?.cancel()
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
        UserDefaults.standard.removeObject(forKey: "lastRootFolderPath")
        UserDefaults.standard.removeObject(forKey: "lastSelectedFilePath")
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
        let url = URL(fileURLWithPath: filename)
        guard FileManager.default.fileExists(atPath: filename) else { return false }
        appState?.rootFolderURL = nil
        appState?.rootNodes = [FileNode(url: url, name: url.lastPathComponent, isDirectory: false)]
        appState?.loadFile(url)
        return true
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
