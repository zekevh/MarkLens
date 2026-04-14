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

    let documentStore = DocumentStore()
    let workspaceStore: WorkspaceStore
    let editorUIStore: EditorUIStore
    let quickOpenStore: QuickOpenStore

    var searchText: String {
        get { editorUIStore.searchText }
        set { editorUIStore.searchText = newValue }
    }

    var replaceText: String {
        get { editorUIStore.replaceText }
        set { editorUIStore.replaceText = newValue }
    }

    var searchMatchCount: Int {
        editorUIStore.searchMatchCount
    }

    init() {
        workspaceStore = WorkspaceStore(documentStore: documentStore)
        editorUIStore = EditorUIStore(documentStore: documentStore)
        quickOpenStore = QuickOpenStore(
            workspaceStore: workspaceStore,
            documentStore: documentStore,
            editorUIStore: editorUIStore
        )
    }

    func restoreLastSession() {
        workspaceStore.restoreLastSession()
    }

    func flushPendingSave() {
        documentStore.flushPendingSave()
    }

    func replaceNext() {
        editorUIStore.replaceNext()
    }

    func replaceAll() {
        editorUIStore.replaceAll()
    }
}

// MARK: - Window Accessor

/// Retrieves the hosting NSWindow for a SwiftUI view so AppDelegate can map
/// windows to their isolated AppState instances.
private struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow, NSView) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = WindowFocusAnchorView()
        DispatchQueue.main.async {
            if let window = view.window { self.onWindow(window, view) }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class WindowFocusAnchorView: NSView {
    override var acceptsFirstResponder: Bool { true }
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
        appState ?? (NSApp.delegate as? AppDelegate)?.activeAppState
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

    private func performNewFile() {
        (NSApp.delegate as? AppDelegate)?.performNewFile()
    }

    private func performQuickOpen() {
        (NSApp.delegate as? AppDelegate)?.performQuickOpen()
    }

    private func performOpenFile() {
        (NSApp.delegate as? AppDelegate)?.performOpenFile()
    }

    private func performOpenFolder() {
        (NSApp.delegate as? AppDelegate)?.performOpenFolder()
    }

    private func performCloseFolder() {
        (NSApp.delegate as? AppDelegate)?.performCloseFolder()
    }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New File") { performNewFile() }
                .keyboardShortcut("n", modifiers: .command)
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
            Button("Open File…") { performOpenFile() }
                .keyboardShortcut("o", modifiers: .command)
            Button("Open Folder…") { performOpenFolder() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            Button("Go to File…") { performQuickOpen() }
                .keyboardShortcut("p", modifiers: .command)
            Divider()
            Button("Close Folder") { performCloseFolder() }
                .keyboardShortcut("w", modifiers: [.command, .shift])
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
            Button("Find…") { activeState?.editorUIStore.showFindBar() }
                .keyboardShortcut("f", modifiers: .command)
            Button("Replace…") { activeState?.editorUIStore.showFindBar(showReplace: true) }
                .keyboardShortcut("f", modifiers: [.command, .option])
        }
        CommandGroup(after: .toolbar) {
            Button((activeState?.editorUIStore.isPathBarVisible ?? true) ? "Hide Path Bar" : "Show Path Bar") {
                activeState?.editorUIStore.isPathBarVisible.toggle()
            }
            .keyboardShortcut("p", modifiers: [.command, .option])

            Button((activeState?.editorUIStore.isStatusBarVisible ?? true) ? "Hide Status Bar" : "Show Status Bar") {
                activeState?.editorUIStore.isStatusBarVisible.toggle()
            }
            .keyboardShortcut("'", modifiers: .command)

            Divider()

            Button((activeState?.documentStore.isRawMode ?? false) ? "Show Rendered Markdown" : "Show Raw Markdown") {
                guard let state = activeState else { return }
                state.documentStore.isRawMode.toggle()
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
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
            .environmentObject(appState.editorUIStore)
            .environmentObject(appState.workspaceStore)
            .environmentObject(appState.quickOpenStore)
            .focusedObject(appState)
            .background(WindowAccessor { window, anchorView in
                appDelegate.register(window: window, state: appState, focusAnchor: anchorView)
            })
            .onAppear {
                let shouldRestore = environment[UITestLaunchEnvironment.disableRestore] != "1"
                if shouldRestore {
                    appState.restoreLastSession()
                    // Show the welcome screen if there is nothing to restore.
                    let hasFolder = appState.workspaceStore.rootFolderURL != nil
                    let hasRecents = !appState.documentStore.recentURLs.isEmpty
                    if !hasFolder && !hasRecents {
                        openWindow(id: "welcome")
                    }
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
    private var windowFocusAnchors: [NSValue: WeakViewBox] = [:]

    /// The AppState belonging to the currently key (frontmost) window.
    private(set) weak var keyAppState: AppState?

    /// File URL received from Finder (or MCP new_window) before a window state registers.
    /// Applied to the first window that calls register().
    var pendingFileURL: URL?

    private var mcpServer: MCPServer?
    private var appHotkeyMonitor: Any?

    var activeAppState: AppState? {
        appState(for: NSApp.keyWindow)
            ?? appState(for: NSApp.mainWindow)
            ?? keyAppState
            ?? windowStates.values.first
    }

    func register(window: NSWindow, state: AppState, focusAnchor: NSView) {
        let key = NSValue(nonretainedObject: window)
        windowStates[key] = state
        windowFocusAnchors[key] = WeakViewBox(view: focusAnchor)
        if let url = pendingFileURL {
            pendingFileURL = nil
            state.workspaceStore.openExternalFile(url)
        }
    }

    func appState(for window: NSWindow?) -> AppState? {
        guard let window else { return nil }
        return windowStates[NSValue(nonretainedObject: window)]
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
        installAppHotkeyMonitor()
        startMCPServer()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        if let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.orderedWindows.first {
            restoreFocus(for: window)
        }
    }

    private func startMCPServer() {
        guard !isRunningInAppSandbox else {
            AppLogger.info("MCP server disabled because the app is running inside the App Sandbox", category: "MCP")
            return
        }

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
            catch { AppLogger.error("Failed to start MCP server on port \(MCPServer.port): \(error)", category: "MCP") }
        }
    }

    private var isRunningInAppSandbox: Bool {
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
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
        removeAppHotkeyMonitor()
        windowStates.values.forEach { $0.flushPendingSave() }
        return .terminateNow
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    func performNewFile() {
        activeAppState?.workspaceStore.createFile()
    }

    func performQuickOpen() {
        activeAppState?.quickOpenStore.show()
    }

    func performOpenFile() {
        activeAppState?.workspaceStore.openFilePanel()
    }

    func performOpenFolder() {
        activeAppState?.workspaceStore.openFolderPanel()
    }

    func performCloseFolder() {
        activeAppState?.workspaceStore.closeFolder()
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
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window else { return }
            self.restoreFocus(for: window, forceKeyWindow: false)
        }
    }

    private func restoreFocus(for window: NSWindow, forceKeyWindow: Bool = true) {
        if forceKeyWindow, !window.isKeyWindow {
            window.makeKeyAndOrderFront(nil)
        }
        keyAppState = appState(for: window) ?? keyAppState

        guard let anchorView = windowFocusAnchors[NSValue(nonretainedObject: window)]?.view else { return }
        let responderNeedsRepair =
            window.firstResponder == nil ||
            window.firstResponder === window ||
            window.firstResponder === window.contentView

        if responderNeedsRepair {
            window.makeFirstResponder(anchorView)
        }
    }

    private func installAppHotkeyMonitor() {
        guard appHotkeyMonitor == nil else { return }
        appHotkeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handleAppHotkey(event)
        }
    }

    private func removeAppHotkeyMonitor() {
        guard let appHotkeyMonitor else { return }
        NSEvent.removeMonitor(appHotkeyMonitor)
        self.appHotkeyMonitor = nil
    }

    private func handleAppHotkey(_ event: NSEvent) -> NSEvent? {
        guard NSApp.isActive else { return event }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard let characters = event.charactersIgnoringModifiers?.lowercased() else {
            return event
        }

        switch (flags, characters) {
        case (.command, "n"):
            performNewFile()
            return nil
        case (.command, "p"):
            performQuickOpen()
            return nil
        case (.command, "o"):
            performOpenFile()
            return nil
        case ([.command, .shift], "o"):
            performOpenFolder()
            return nil
        case ([.command, .option], "n"):
            NotificationCenter.default.post(name: .marklensOpenNewWindow, object: nil)
            return nil
        case ([.command, .shift], "w"):
            performCloseFolder()
            return nil
        default:
            return event
        }
    }

}

private final class WeakViewBox {
    weak var view: NSView?

    init(view: NSView) {
        self.view = view
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

        Window("Welcome to MarkLens", id: "welcome") {
            WelcomeView()
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .defaultPosition(.center)

        Settings {
            SettingsView()
        }
    }
}
