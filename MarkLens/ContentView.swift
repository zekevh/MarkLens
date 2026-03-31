import SwiftUI
import AppKit

// MARK: - ContentView

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @FocusState private var isSearchFocused: Bool
    var body: some View {
        NavigationSplitView(columnVisibility: $appState.sidebarVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
        } detail: {
            Group {
                if appState.selectedFileURL != nil {
                    if appState.isRawMode {
                        RawTextEditorView(
                            text: $appState.documentText,
                            onTextChange: { appState.saveCurrentFile(text: $0) }
                        )
                        .id(appState.selectedFileURL)
                        .ignoresSafeArea()
                    } else {
                        NodeEditorView(
                            text: $appState.documentText,
                            searchText: appState.searchText,
                            onTextChange: { appState.saveCurrentFile(text: $0) }
                        )
                        .id(appState.selectedFileURL)
                        .ignoresSafeArea()
                    }
                } else {
                    EmptyEditorView()
                        .ignoresSafeArea()
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: { appState.createFile() }) {
                    Label("New Note", systemImage: "square.and.pencil")
                }
                .help("New Note (⌘N)")
                .disabled(appState.rootNodes.isEmpty)
            }

            ToolbarItem(placement: .primaryAction) {
                if let url = appState.selectedFileURL {
                    ShareLink(item: url) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    .help("Share Note")
                }
            }
        }
        .toolbarBackground(.hidden, for: .windowToolbar)
        .alert("Error", isPresented: Binding(
            get: { appState.errorMessage != nil },
            set: { if !$0 { appState.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { appState.errorMessage = nil }
        } message: {
            Text(appState.errorMessage ?? "")
        }
        .alert(
            "File Changed on Disk",
            isPresented: Binding(
                get: { appState.externalEditConflict != nil },
                set: { if !$0 { appState.resolveConflict(keepMine: true) } }
            )
        ) {
            Button("Keep My Changes", role: .cancel) { appState.resolveConflict(keepMine: true) }
            Button("Use Disk Version", role: .destructive) { appState.resolveConflict(keepMine: false) }
        } message: {
            Text("\"\(appState.externalEditConflict?.fileName ?? "")\" was modified by another app while you had unsaved changes.")
        }
        .if(appState.selectedFileURL != nil) { view in
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

// MARK: - SidebarView

struct SidebarView: View {
    @EnvironmentObject var appState: AppState
    @State private var renamingURL: URL? = nil
    @State private var renameText: String = ""

    var body: some View {
        Group {
            if appState.rootNodes.isEmpty {
                if appState.recentURLs.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "folder.badge.plus")
                            .font(.system(size: 32))
                            .foregroundStyle(.tertiary)
                        Text("Open a folder or file")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Button("Open Folder…") { appState.openFolderPanel() }
                            .buttonStyle(.borderless)
                            .foregroundStyle(Color.accentColor)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    RecentFilesView()
                }
            } else {
                List(appState.rootNodes, children: \.optionalChildren,

                     selection: Binding(
                        get: { appState.selectedFileURL },
                        set: { url in
                            if let url, !url.hasDirectoryPath {
                                appState.loadFile(url)
                            }
                        }
                     )
                ) { node in
                    SidebarRow(node: node)
                        .tag(node.url)
                        .contextMenu {
                            if !node.isDirectory {
                                Button {
                                    renameText = node.url.deletingPathExtension().lastPathComponent
                                    renamingURL = node.url
                                } label: {
                                    Label("Rename File", systemImage: "pencil")
                                }

                                Divider()

                                Button { appState.togglePin(node.url) } label: {
                                    Label(
                                        appState.isPinned(node.url) ? "Unpin" : "Pin",
                                        systemImage: appState.isPinned(node.url) ? "pin.slash" : "pin"
                                    )
                                }

                                Divider()

                                ShareLink(item: node.url) {
                                    Label("Share", systemImage: "square.and.arrow.up")
                                }

                                Divider()

                                Button(role: .destructive) {
                                    appState.deleteFile(node.url)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if !node.isDirectory {
                                Button(role: .destructive) {
                                    appState.deleteFile(node.url)
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
                                Button { appState.togglePin(node.url) } label: {
                                    Image(systemName: appState.isPinned(node.url) ? "pin.slash" : "pin")
                                }
                                .tint(.orange)
                            }
                        }
                }
                .listStyle(.sidebar)
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
                    appState.renameFile(url, to: finalName)
                }
                renamingURL = nil
            }
            .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) { renamingURL = nil }
        }
    }
}

// MARK: - RecentFilesView

struct RecentFilesView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        List(appState.recentURLs, id: \.path, selection: Binding(
            get: { appState.selectedFileURL },
            set: { url in if let url { appState.openRecent(url) } }
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
                    Button("Open Folder…") { appState.openFolderPanel() }
                    Spacer()
                    Button("Clear") { appState.clearRecents() }
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
    @EnvironmentObject var appState: AppState
    let node: FileNode

    var body: some View {
        Label {
            HStack(spacing: 4) {
                Text(node.name).lineLimit(1).truncationMode(.middle)
                if !node.isDirectory && appState.isPinned(node.url) {
                    Image(systemName: "pin.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
        } icon: {
            Image(systemName: node.isDirectory ? "folder" : "doc.text")
        }
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
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
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
    }
}

// MARK: - View Helpers

private extension View {
    @ViewBuilder
    func `if`<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
        if condition { transform(self) } else { self }
    }
}
