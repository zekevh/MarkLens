import SwiftUI
import Combine
import AppKit

enum UITestLaunchEnvironment {
    static let disableRestore = "MARKLENS_UI_TEST_DISABLE_RESTORE"
    static let rootFolder = "MARKLENS_UI_TEST_ROOT_FOLDER"
    static let rawMode = "MARKLENS_UI_TEST_RAW_MODE"
    static let harness = "MARKLENS_UI_TEST_HARNESS"
}

// MARK: - AppState

@MainActor
final class AppState: ObservableObject {
    @Published var sidebarVisibility: NavigationSplitViewVisibility = .all
    @Published var searchText: String = "" {
        didSet { syncSearchResults() }
    }
    @Published var isSearchFocused: Bool = false
    @Published var replaceText: String = ""
    @Published var isReplaceVisible: Bool = false
    @Published var isPathBarVisible: Bool = true
    @Published var isStatusBarVisible: Bool = true
    @Published private(set) var searchMatchCount: Int = 0

    let documentStore = DocumentStore()
    let workspaceStore: WorkspaceStore
    private let search = DocumentSearch()
    private var cancellables: Set<AnyCancellable> = []

    init() {
        workspaceStore = WorkspaceStore(documentStore: documentStore)
        documentStore.$documentText
            .sink { [weak self] _ in
                self?.syncSearchResults()
            }
            .store(in: &cancellables)
    }

    private var activeUndoManager: UndoManager? {
        NSApp.keyWindow?.firstResponder?.undoManager ?? NSApp.keyWindow?.undoManager
    }

    func showFindBar(showReplace: Bool = false) {
        guard documentStore.selectedFileURL != nil else { return }
        if showReplace {
            isReplaceVisible.toggle()
            if !isReplaceVisible {
                replaceText = ""
            }
        }
        isSearchFocused = true
    }

    func hideReplaceBar() {
        replaceText = ""
        isReplaceVisible = false
    }

    func replaceNext() {
        let originalText = documentStore.documentText
        guard let updatedText = search.replaceNext(in: originalText, with: replaceText) else { return }
        applyReplaceResult(updatedText, originalText: originalText, actionName: "Replace")
    }

    func replaceAll() {
        let originalText = documentStore.documentText
        guard let updatedText = search.replaceAll(in: originalText, with: replaceText) else { return }
        applyReplaceResult(updatedText, originalText: originalText, actionName: "Replace All")
    }

    private func applyReplaceResult(_ updatedText: String, originalText: String, actionName: String) {
        guard updatedText != originalText else { return }

        let undoManager = activeUndoManager
        undoManager?.registerUndo(withTarget: self) { state in
            MainActor.assumeIsolated {
                state.applyReplaceResult(originalText, originalText: updatedText, actionName: actionName)
            }
        }
        undoManager?.setActionName(actionName)

        documentStore.documentText = updatedText
        documentStore.saveCurrentFile(text: updatedText)
    }

    private func syncSearchResults() {
        search.update(documentText: documentStore.documentText, query: searchText)
        searchMatchCount = search.matchCount
    }

    func restoreLastSession() {
        workspaceStore.restoreLastSession()
    }

    func flushPendingSave() {
        documentStore.flushPendingSave()
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

    private func performUndo() {
        guard activeUndoManager?.canUndo == true else { return }
        NSApp.sendAction(Selector(("undo:")), to: nil, from: nil)
    }

    private func performRedo() {
        guard activeUndoManager?.canRedo == true else { return }
        NSApp.sendAction(Selector(("redo:")), to: nil, from: nil)
    }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New File") { activeState?.workspaceStore.createFile() }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(activeState == nil)
            Button("New Window") { openWindow(id: "main") }
                .keyboardShortcut("n", modifiers: [.command, .option])
        }
        CommandGroup(replacing: .undoRedo) {
            Button(activeUndoManager?.undoMenuItemTitle ?? "Undo") {
                performUndo()
            }
            .keyboardShortcut("z", modifiers: .command)

            Button(activeUndoManager?.redoMenuItemTitle ?? "Redo") {
                performRedo()
            }
            .keyboardShortcut("z", modifiers: [.command, .shift])
        }
        CommandGroup(after: .newItem) {
            Divider()
            Button("Open File…") { activeState?.workspaceStore.openFilePanel() }
                .keyboardShortcut("o", modifiers: .command)
            Button("Open Folder…") { activeState?.workspaceStore.openFolderPanel() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            Divider()
            Button("Close Folder") { activeState?.workspaceStore.closeFolder() }
                .keyboardShortcut("w", modifiers: [.command, .shift])
                .disabled(activeState?.workspaceStore.rootNodes.isEmpty ?? true)
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
            Button("Find…") { activeState?.showFindBar() }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(activeState?.documentStore.selectedFileURL == nil)
            Button("Replace…") { activeState?.showFindBar(showReplace: true) }
                .keyboardShortcut("f", modifiers: [.command, .option])
                .disabled(activeState?.documentStore.selectedFileURL == nil)
        }
        CommandGroup(after: .toolbar) {
            Button((activeState?.isPathBarVisible ?? true) ? "Hide Path Bar" : "Show Path Bar") {
                activeState?.isPathBarVisible.toggle()
            }
            .keyboardShortcut("p", modifiers: [.command, .option])

            Button((activeState?.isStatusBarVisible ?? true) ? "Hide Status Bar" : "Show Status Bar") {
                activeState?.isStatusBarVisible.toggle()
            }
            .keyboardShortcut("'", modifiers: .command)

            Divider()

            Button((activeState?.documentStore.isRawMode ?? false) ? "Show Rendered Markdown" : "Show Raw Markdown") {
                guard let state = activeState else { return }
                state.documentStore.isRawMode.toggle()
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(activeState?.documentStore.selectedFileURL == nil)
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
    private let environment = ProcessInfo.processInfo.environment

    var body: some View {
        ContentView()
            .environmentObject(appState)
            .environmentObject(appState.documentStore)
            .environmentObject(appState.workspaceStore)
            .focusedObject(appState)
            .background(WindowAccessor { window in
                appDelegate.register(window: window, state: appState)
            })
            .onAppear {
                let shouldRestore = environment[UITestLaunchEnvironment.disableRestore] != "1"
                if shouldRestore {
                    appState.restoreLastSession()
                }
                if let rootFolderPath = environment[UITestLaunchEnvironment.rootFolder], !rootFolderPath.isEmpty {
                    let sourceURL = URL(fileURLWithPath: rootFolderPath, isDirectory: true)
                    let url = uiTestWorkspaceURL(for: sourceURL) ?? sourceURL
                    appState.workspaceStore.setRootFolder(url)
                }
                if environment[UITestLaunchEnvironment.rawMode] == "1" {
                    appState.documentStore.isRawMode = true
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .marklensOpenNewWindow)) { _ in
                openWindow(id: "main")
            }
            .frame(minWidth: 600, minHeight: 350)
    }

    private func uiTestWorkspaceURL(for sourceURL: URL) -> URL? {
        guard environment[UITestLaunchEnvironment.harness] == "1" else { return nil }

        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarkLens-UITest-Workspace", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
            let destinationURL = tempRoot.appendingPathComponent(sourceURL.lastPathComponent, isDirectory: true)
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
            return destinationURL
        } catch {
            return nil
        }
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
            state.workspaceStore.openExternalFile(url)
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
                self?.keyAppState?.workspaceStore.openExternalFile(url)
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
            state.workspaceStore.openExternalFile(url)
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
