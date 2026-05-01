import SwiftUI
import Combine
import AppKit

enum UITestLaunchEnvironment {
    static let disableRestore = "MARKLENS_UI_TEST_DISABLE_RESTORE"
    static let rootFolder = "MARKLENS_UI_TEST_ROOT_FOLDER"
    static let rawMode = "MARKLENS_UI_TEST_RAW_MODE"
    static let harness = "MARKLENS_UI_TEST_HARNESS"
    static let showOutlinePanel = "MARKLENS_UI_TEST_SHOW_OUTLINE_PANEL"
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

    private func performNewTab() {
        (NSApp.delegate as? AppDelegate)?.performNewTab()
    }

    private func openHelp() {
        guard let url = URL(string: "https://github.com/zekevh/MarkLens") else { return }
        NSWorkspace.shared.open(url)
    }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New File") { performNewFile() }
                .keyboardShortcut("n", modifiers: .command)
            Button("New Tab") { performNewTab() }
                .keyboardShortcut("t", modifiers: .command)
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
            Button((activeState?.editorUIStore.isOutlinePanelVisible ?? false) ? "Hide Outline" : "Show Outline") {
                activeState?.editorUIStore.isOutlinePanelVisible.toggle()
            }
            .keyboardShortcut("o", modifiers: [.command, .control])

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
        CommandGroup(replacing: .help) {
            Button("MarkLens Help") {
                openHelp()
            }
            .keyboardShortcut("/", modifiers: [.command, .shift])
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
                if environment[UITestLaunchEnvironment.showOutlinePanel] == "1" {
                    appState.editorUIStore.isOutlinePanelVisible = true
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
    private var windowIDs: [NSValue: String] = [:]
    private var windowKeysByID: [String: NSValue] = [:]

    /// The AppState belonging to the currently key (frontmost) window.
    private(set) weak var keyAppState: AppState?

    /// File URL received from Finder (or MCP new_window) before a window state registers.
    /// Applied to the first window that calls register().
    var pendingFileURL: URL?
    private var pendingWindowRequests: [PendingWindowRequest] = []

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
        let windowID = windowIDs[key] ?? "editor-\(UUID().uuidString.prefix(8))"
        windowIDs[key] = windowID
        windowKeysByID[windowID] = key

        if !pendingWindowRequests.isEmpty {
            let request = pendingWindowRequests.removeFirst()
            if let url = request.fileURL {
                state.workspaceStore.openExternalFile(url)
            }
            request.resume(with: windowInfo(for: window))
            return
        }

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
        NSWindow.allowsAutomaticWindowTabbing = true
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidBecomeKey),
            name: NSWindow.didBecomeKeyNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowWillClose),
            name: NSWindow.willCloseNotification,
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
            listWindows: { @MainActor [weak self] in
                self?.listMCPWindows() ?? []
            },
            getWindow: { @MainActor [weak self] windowID in
                self?.windowInfo(for: self?.window(forID: windowID))
            },
            openFolder: { @MainActor [weak self] url, windowID in
                let window = self?.openFolder(url, inWindowWithID: windowID)
                NSApp.activate(ignoringOtherApps: true)
                return window
            },
            openFile: { @MainActor [weak self] url, windowID in
                let window = self?.open(url, inWindowWithID: windowID)
                NSApp.activate(ignoringOtherApps: true)
                return window
            },
            newWindow: { @MainActor [weak self] url in
                await self?.createWindow(opening: url)
            },
            setActiveWindow: { @MainActor [weak self] windowID in
                self?.activateWindow(withID: windowID)
            },
            closeWindow: { @MainActor [weak self] windowID in
                self?.closeWindow(withID: windowID) ?? false
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
        _ = open(url, inWindowWithID: nil)
    }

    @MainActor @discardableResult
    private func open(_ url: URL, inWindowWithID windowID: String?) -> MCPWindowInfo? {
        guard !url.hasDirectoryPath,
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        let (targetState, targetWindow) = resolveTargetWindow(windowID: windowID)

        if let state = targetState {
            state.workspaceStore.openExternalFile(url)
            if let targetWindow {
                restoreFocus(for: targetWindow)
                return windowInfo(for: targetWindow)
            }
            return nil
        }

        if windowID == nil {
            // No window registered yet (app just launched via Finder double-click).
            // Store and apply once the first window comes up.
            pendingFileURL = url
            return nil
        }

        return nil
    }

    @MainActor @discardableResult
    private func openFolder(_ url: URL, inWindowWithID windowID: String?) -> MCPWindowInfo? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        let (targetState, targetWindow) = resolveTargetWindow(windowID: windowID)

        guard let state = targetState else { return nil }
        state.workspaceStore.setRootFolder(url)
        if let targetWindow {
            restoreFocus(for: targetWindow)
            return windowInfo(for: targetWindow)
        }
        return nil
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

    func performNewTab() {
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            window.tabbingMode = .preferred
        }

        if NSApp.sendAction(Selector(("newTab:")), to: nil, from: nil) {
            return
        }

        NotificationCenter.default.post(name: .marklensOpenNewWindow, object: nil)
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

    @objc @MainActor private func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        let key = NSValue(nonretainedObject: window)
        let closingState = windowStates[key]
        windowStates.removeValue(forKey: key)
        windowFocusAnchors.removeValue(forKey: key)
        if let windowID = windowIDs.removeValue(forKey: key) {
            windowKeysByID.removeValue(forKey: windowID)
        }
        if keyAppState === closingState {
            keyAppState = nil
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

    private func listMCPWindows() -> [MCPWindowInfo] {
        NSApp.orderedWindows.compactMap(windowInfo(for:))
    }

    private func resolveTargetWindow(windowID: String?) -> (AppState?, NSWindow?) {
        let targetWindow: NSWindow?
        let targetState: AppState?

        if let windowID {
            targetWindow = window(forID: windowID)
            targetState = targetWindow.flatMap(appState(for:))
        } else {
            targetWindow = NSApp.keyWindow ?? NSApp.mainWindow
            targetState = activeAppState
        }

        return (targetState, targetWindow)
    }

    private func window(forID windowID: String) -> NSWindow? {
        guard let key = windowKeysByID[windowID] else { return nil }
        return key.nonretainedObjectValue as? NSWindow
    }

    private func windowInfo(for window: NSWindow?) -> MCPWindowInfo? {
        guard let window else { return nil }
        let key = NSValue(nonretainedObject: window)
        guard let windowID = windowIDs[key],
              let state = windowStates[key] else { return nil }

        return MCPWindowInfo(
            id: windowID,
            title: window.title.isEmpty ? "Untitled" : window.title,
            rootFolderPath: state.workspaceStore.rootFolderURL?.path,
            filePath: state.documentStore.selectedFileURL?.path,
            isActive: window.isKeyWindow
        )
    }

    private func activateWindow(withID windowID: String) -> MCPWindowInfo? {
        guard let window = window(forID: windowID) else { return nil }
        NSApp.activate(ignoringOtherApps: true)
        restoreFocus(for: window)
        return windowInfo(for: window)
    }

    private func closeWindow(withID windowID: String) -> Bool {
        guard let window = window(forID: windowID) else { return false }
        window.close()
        return true
    }

    private func createWindow(opening fileURL: URL?) async -> MCPWindowInfo? {
        await withCheckedContinuation { continuation in
            pendingWindowRequests.append(
                PendingWindowRequest(fileURL: fileURL) { window in
                    continuation.resume(returning: window)
                }
            )
            NotificationCenter.default.post(name: .marklensOpenNewWindow, object: nil)
        }
    }

}

private final class WeakViewBox {
    weak var view: NSView?

    init(view: NSView) {
        self.view = view
    }
}

private final class PendingWindowRequest {
    let fileURL: URL?
    private let completion: (MCPWindowInfo?) -> Void

    init(fileURL: URL?, completion: @escaping (MCPWindowInfo?) -> Void) {
        self.fileURL = fileURL
        self.completion = completion
    }

    func resume(with window: MCPWindowInfo?) {
        completion(window)
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
