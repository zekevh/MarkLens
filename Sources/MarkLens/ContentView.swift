import SwiftUI

// MARK: - ContentView

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
        } detail: {
            Group {
                if appState.selectedFileURL != nil {
                    MarkdownEditor(
                        text: $appState.documentText,
                        searchText: appState.searchText,
                        onTextChange: { appState.saveCurrentFile(text: $0) }
                    )
                    .id(appState.selectedFileURL)
                    .ignoresSafeArea()
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
        .searchable(text: $appState.searchText, placement: .toolbar, prompt: "Search")
        .searchFocused($isSearchFocused)
        .onChange(of: appState.isSearchFocused) { _, focused in
            if focused {
                isSearchFocused = true
                appState.isSearchFocused = false
            }
        }
    }
}

// MARK: - SidebarView

struct SidebarView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Group {
            if appState.rootNodes.isEmpty {
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
