import SwiftUI
import AppKit

// MARK: - ContentView

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var documentStore: DocumentStore
    @EnvironmentObject var workspaceStore: WorkspaceStore
    @FocusState private var isSearchFocused: Bool
    private let environment = ProcessInfo.processInfo.environment
    private var isUITestHarnessEnabled: Bool {
        environment[UITestLaunchEnvironment.harness] == "1"
    }
    var body: some View {
        NavigationSplitView(columnVisibility: $appState.sidebarVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 180, ideal: 240, max: 320)
        } detail: {
            Group {
                if documentStore.selectedFileURL != nil {
                    if documentStore.isRawMode {
                        RawTextEditorView(
                            text: $documentStore.documentText,
                            onTextChange: { documentStore.saveCurrentFile(text: $0) }
                        )
                        .id(documentStore.selectedFileURL)
                        .ignoresSafeArea(.container, edges: .bottom)
                    } else {
                        NodeEditorView(
                            text: $documentStore.documentText,
                            searchText: appState.searchText,
                            fileURL: documentStore.selectedFileURL,
                            onTextChange: { documentStore.saveCurrentFile(text: $0) },
                            onLinkClick: { documentStore.handleLinkClick($0) }
                        )
                        .id(documentStore.selectedFileURL)
                        .ignoresSafeArea(.container, edges: .bottom)
                    }
                } else {
                    EmptyEditorView()
                        .ignoresSafeArea(.container, edges: .bottom)
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if documentStore.selectedFileURL != nil, appState.isReplaceVisible {
                    ReplaceBar(
                        searchText: appState.searchText,
                        replaceText: $appState.replaceText,
                        matchCount: appState.searchMatchCount,
                        onReplaceNext: { appState.replaceNext() },
                        onReplaceAll: { appState.replaceAll() },
                        onClose: { appState.hideReplaceBar() }
                    )
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let selectedFileURL = documentStore.selectedFileURL,
                   appState.isPathBarVisible || appState.isStatusBarVisible {
                    EditorStatusBar(
                        fileURL: selectedFileURL,
                        rootFolderURL: workspaceStore.rootFolderURL,
                        text: documentStore.documentText,
                        showsPathBar: appState.isPathBarVisible,
                        showsStatusBar: appState.isStatusBarVisible
                    )
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: { workspaceStore.createFile() }) {
                    Label("New Note", systemImage: "square.and.pencil")
                }
                .accessibilityIdentifier("newNoteButton")
                .help("New Note (⌘N)")
                .disabled(workspaceStore.rootNodes.isEmpty)
            }

            ToolbarItem(placement: .primaryAction) {
                if let url = documentStore.selectedFileURL {
                    ShareLink(item: url) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    .help("Share Note")
                }
            }

            if isUITestHarnessEnabled {
                ToolbarItemGroup(placement: .automatic) {
                    Button("Create Harness Note") {
                        workspaceStore.createFile(named: "Harness Note")
                    }
                    .accessibilityIdentifier("uiTestCreateButton")

                    Button("Rename Selected") {
                        guard let selectedURL = documentStore.selectedFileURL else { return }
                        let ext = selectedURL.pathExtension
                        workspaceStore.renameFile(selectedURL, to: "Renamed Alpha.\(ext)")
                    }
                    .accessibilityIdentifier("uiTestRenameButton")
                    .disabled(documentStore.selectedFileURL == nil)

                    Button("Inject Conflict") {
                        documentStore.simulateExternalConflict(
                            unsavedText: "Local unsaved edit",
                            diskText: "Disk version from test"
                        )
                    }
                    .accessibilityIdentifier("uiTestConflictButton")
                    .disabled(documentStore.selectedFileURL == nil)
                }
            }
        }
        .toolbarBackground(.hidden, for: .windowToolbar)
        .alert("Error", isPresented: Binding(
            get: { documentStore.errorMessage != nil },
            set: { if !$0 { documentStore.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { documentStore.errorMessage = nil }
        } message: {
            Text(documentStore.errorMessage ?? "")
        }
        .alert(
            "File Changed on Disk",
            isPresented: Binding(
                get: { documentStore.externalEditConflict != nil },
                set: { if !$0 { documentStore.resolveConflict(keepMine: true) } }
            )
        ) {
            Button("Keep My Changes", role: .cancel) { documentStore.resolveConflict(keepMine: true) }
            Button("Use Disk Version", role: .destructive) { documentStore.resolveConflict(keepMine: false) }
        } message: {
            Text("\"\(documentStore.externalEditConflict?.fileName ?? "")\" was modified by another app while you had unsaved changes.")
        }
        .if(documentStore.selectedFileURL != nil) { view in
            view
                .searchable(text: $appState.searchText, placement: .toolbar, prompt: "Search")
                .searchFocused($isSearchFocused)
                .onChange(of: appState.isSearchFocused) { _, focused in
                    guard focused else { return }
                    Task { @MainActor in
                        isSearchFocused = true
                        appState.isSearchFocused = false
                    }
                }
        }
    }
}

private struct EditorStatusBar: View {
    let fileURL: URL
    let rootFolderURL: URL?
    let text: String
    let showsPathBar: Bool
    let showsStatusBar: Bool

    private var breadcrumbs: [String] {
        let baseURL = rootFolderURL ?? fileURL.deletingLastPathComponent()
        let baseComponents = baseURL.standardizedFileURL.pathComponents
        let fileComponents = fileURL.standardizedFileURL.pathComponents
        let relativeComponents = Array(fileComponents.dropFirst(baseComponents.count))

        if rootFolderURL != nil {
            return [baseURL.lastPathComponent] + relativeComponents
        }

        return [baseURL.lastPathComponent, fileURL.lastPathComponent]
    }

    private var wordCount: Int {
        text.split { $0.isWhitespace || $0.isNewline }.count
    }

    private var estimatedTokenCount: Int {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }
        return max(1, Int(ceil(Double(trimmed.count) / 4.0)))
    }

    var body: some View {
        VStack(spacing: 0) {
            Divider()

            if showsPathBar {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(breadcrumbs.enumerated()), id: \.offset) { index, crumb in
                            if index > 0 {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(.tertiary)
                            }

                            Text(crumb)
                                .lineLimit(1)
                                .font(.caption)
                                .foregroundStyle(index == breadcrumbs.count - 1 ? .primary : .secondary)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            if showsPathBar && showsStatusBar {
                Divider()
            }

            if showsStatusBar {
                HStack(spacing: 14) {
                    Spacer(minLength: 0)
                    Text("\(wordCount) \(wordCount == 1 ? "word" : "words")")
                    Text("\(estimatedTokenCount) est. AI tokens")
                    Spacer(minLength: 0)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
        }
        .background(.bar)
    }
}

private struct ReplaceBar: View {
    let searchText: String
    @Binding var replaceText: String
    let matchCount: Int
    let onReplaceNext: () -> Void
    let onReplaceAll: () -> Void
    let onClose: () -> Void

    private var hasSearch: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 10) {
                Text("Replace")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextField("Replace", text: $replaceText)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 220, maxWidth: 320)

                Text(matchCount == 0 ? "No matches" : "\(matchCount) matches")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button("Replace") { onReplaceNext() }
                    .disabled(!hasSearch)
                Button("Replace All") { onReplaceAll() }
                    .disabled(!hasSearch)

                Spacer(minLength: 0)

                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.bar)
        }
    }
}

// MARK: - SidebarView

struct SidebarView: View {
    @EnvironmentObject var documentStore: DocumentStore
    @EnvironmentObject var workspaceStore: WorkspaceStore
    @State private var renamingURL: URL? = nil
    @State private var renameText: String = ""

    var body: some View {
        Group {
            if workspaceStore.rootNodes.isEmpty {
                if documentStore.recentURLs.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "folder.badge.plus")
                            .font(.system(size: 32))
                            .foregroundStyle(.tertiary)
                        Text("Open a folder or file")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Button("Open Folder…") { workspaceStore.openFolderPanel() }
                            .buttonStyle(.borderless)
                            .foregroundStyle(Color.accentColor)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    RecentFilesView()
                }
            } else {
                List(selection: Binding(
                    get: { workspaceStore.selectedSidebarURLs },
                    set: { urls in
                        workspaceStore.updateSidebarSelection(urls)
                    }
                )) {
                    if !workspaceStore.pinnedFileNodes.isEmpty {
                        Section("Pinned") {
                            ForEach(workspaceStore.pinnedFileNodes) { node in
                                sidebarNodeRow(node)
                            }
                        }
                    }

                    Section("Files") {
                        OutlineGroup(workspaceStore.rootNodes, children: \.optionalChildren) { node in
                            sidebarNodeRow(node)
                        }
                    }
                }
                .listStyle(.sidebar)
                .accessibilityIdentifier("sidebarList")
            }
        }
        .alert("Rename File", isPresented: Binding(
            get: { renamingURL != nil },
            set: { if !$0 { renamingURL = nil } }
        )) {
            TextField("File name", text: $renameText)
            Button("Rename") {
                if let url = renamingURL {
                    let ext = url.pathExtension
                    let newName = renameText.trimmingCharacters(in: .whitespaces)
                    let finalName = newName.lowercased().hasSuffix(".\(ext)") ? newName : "\(newName).\(ext)"
                    workspaceStore.renameFile(url, to: finalName)
                }
                renamingURL = nil
            }
            .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) { renamingURL = nil }
        }
    }

    @ViewBuilder
    private func sidebarNodeRow(_ node: FileNode) -> some View {
        SidebarRow(node: node)
            .tag(node.url)
            .draggable(node.url.path) {
                SidebarDragPreview(
                    node: node,
                    selectedCount: workspaceStore.selectedSidebarURLs.contains(node.url)
                        ? workspaceStore.selectedSidebarURLs.count
                        : 1
                )
            }
            .dropDestination(for: String.self) { items, _ in
                guard node.isDirectory,
                      !items.isEmpty
                else { return false }
                let sourceURLs = items.map { URL(fileURLWithPath: $0) }
                workspaceStore.moveNodes(sourceURLs, into: node.url)
                return true
            }
            .contextMenu {
                if !node.isDirectory {
                    Button {
                        renameText = node.url.deletingPathExtension().lastPathComponent
                        renamingURL = node.url
                    } label: {
                        Label("Rename File", systemImage: "pencil")
                    }

                    Divider()

                    Button { workspaceStore.togglePin(node.url) } label: {
                        Label(
                            workspaceStore.isPinned(node.url) ? "Unpin" : "Pin",
                            systemImage: workspaceStore.isPinned(node.url) ? "pin.slash" : "pin"
                        )
                    }

                    Divider()

                    ShareLink(item: node.url) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }

                    Divider()

                    Button(role: .destructive) {
                        workspaceStore.deleteFile(node.url)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                if !node.isDirectory {
                    Button(role: .destructive) {
                        workspaceStore.deleteFile(node.url)
                    } label: {
                        Image(systemName: "trash")
                    }
                    ShareLink(item: node.url) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .tint(.blue)
                }
            }
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                if !node.isDirectory {
                    Button { workspaceStore.togglePin(node.url) } label: {
                        Image(systemName: workspaceStore.isPinned(node.url) ? "pin.slash" : "pin")
                    }
                    .tint(.orange)
                }
            }
    }
}

// MARK: - RecentFilesView

struct RecentFilesView: View {
    @EnvironmentObject var documentStore: DocumentStore
    @EnvironmentObject var workspaceStore: WorkspaceStore

    var body: some View {
        List(documentStore.recentURLs, id: \.path, selection: Binding(
            get: { documentStore.selectedFileURL },
            set: { url in if let url { documentStore.openRecent(url) } }
        )) { url in
            VStack(alignment: .leading, spacing: 2) {
                Text(url.lastPathComponent)
                    .lineLimit(1)
                Text(url.deletingLastPathComponent().path
                        .replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            .tag(url)
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                Divider()
                HStack {
                    Button("Open Folder…") { workspaceStore.openFolderPanel() }
                    Spacer()
                    Button("Clear") { documentStore.clearRecents() }
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Color.accentColor)
                .font(.callout)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(.bar)
            }
        }
    }
}

// MARK: - SidebarRow

struct SidebarRow: View {
    @EnvironmentObject var workspaceStore: WorkspaceStore
    let node: FileNode

    var body: some View {
        Label {
            HStack(spacing: 4) {
                Text(node.name).lineLimit(1).truncationMode(.middle)
                if !node.isDirectory && workspaceStore.isPinned(node.url) {
                    Image(systemName: "pin.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
        } icon: {
            Image(systemName: node.isDirectory ? "folder" : "doc.text")
        }
        .accessibilityIdentifier("sidebarRow-\(node.name)")
    }
}

private struct SidebarDragPreview: View {
    let node: FileNode
    let selectedCount: Int

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: node.isDirectory ? "folder" : "doc.text")
                .foregroundStyle(.secondary)
            Text(node.name)
                .lineLimit(1)
                .foregroundStyle(.primary)
            if selectedCount > 1 {
                Text("\(selectedCount)")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.thinMaterial, in: Capsule())
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .frame(maxWidth: 220, alignment: .leading)
    }
}

// MARK: - RawTextEditorView

struct RawTextEditorView: NSViewRepresentable {
    @Binding var text: String
    var onTextChange: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true

        let textView = NSTextView()
        textView.isEditable = true
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = true
        textView.isContinuousSpellCheckingEnabled = true
        textView.isGrammarCheckingEnabled = true
        textView.isAutomaticTextReplacementEnabled = false
        textView.setAccessibilityIdentifier("rawTextEditor")
        textView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textColor = NSColor.labelColor
        textView.backgroundColor = NSColor.textBackgroundColor
        textView.textContainerInset = NSSize(width: 40, height: 72)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.string = text
        textView.delegate = context.coordinator

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != text {
            textView.string = text
        }
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: RawTextEditorView
        init(_ parent: RawTextEditorView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            let newText = textView.string
            parent.text = newText
            parent.onTextChange(newText)
        }
    }
}

// MARK: - EmptyEditorView

struct EmptyEditorView: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "text.alignleft")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("No file selected")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("Open a folder or file to start editing")
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
        .accessibilityIdentifier("emptyEditorView")
    }
}

// MARK: - View Helpers

private extension View {
    @ViewBuilder
    func `if`<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
        if condition { transform(self) } else { self }
    }
}
