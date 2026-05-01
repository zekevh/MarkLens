import SwiftUI
import AppKit

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
                        DispatchQueue.main.async {
                            workspaceStore.updateSidebarSelection(urls)
                        }
                    }
                )) {
                    if !workspaceStore.pinnedFileNodes.isEmpty {
                        Section("Pinned") {
                            ForEach(workspaceStore.pinnedFileNodes) { node in
                                sidebarNodeRow(node)
                            }
                        }
                    }

                    Section {
                        OutlineGroup(workspaceStore.rootNodes, children: \.optionalChildren) { node in
                            sidebarNodeRow(node)
                        }
                    } header: {
                        HStack(spacing: 6) {
                            Text("Files")
                            Text("\(workspaceStore.markdownFileCount)")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .listStyle(.sidebar)
                .accessibilityIdentifier("sidebarList")
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    SidebarGitFooter()
                }
            }
        }
        .alert("Rename File", isPresented: Binding(
            get: { renamingURL != nil },
            set: { if !$0 { renamingURL = nil } }
        )) {
            TextField("File name", text: $renameText)
            Button("Rename") {
                if let url = renamingURL {
                    workspaceStore.renameFile(url, to: renameText)
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

private struct SidebarGitFooter: View {
    @EnvironmentObject var workspaceStore: WorkspaceStore

    var body: some View {
        VStack(spacing: 0) {
            Divider()

            if let repo = workspaceStore.gitRepositoryInfo {
                HStack(spacing: 8) {
                    HStack(spacing: 6) {
                        Text(repo.remoteName)
                        Text(repo.branchName)
                            .foregroundStyle(.secondary)
                    }
                    .lineLimit(1)

                    Spacer(minLength: 8)

                    HStack(spacing: 10) {
                        Text("+\(repo.diffSummary.added)")
                            .foregroundStyle(.green)
                        Text("-\(repo.diffSummary.deleted)")
                            .foregroundStyle(.red)
                    }
                    .monospacedDigit()
                }
                .font(.caption)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.bar)
            }
        }
    }
}

struct RecentFilesView: View {
    @EnvironmentObject var documentStore: DocumentStore
    @EnvironmentObject var workspaceStore: WorkspaceStore

    var body: some View {
        List(documentStore.recentURLs, id: \.path, selection: Binding(
            get: { documentStore.selectedFileURL },
            set: { url in
                guard let url else { return }
                DispatchQueue.main.async {
                    documentStore.openRecent(url)
                }
            }
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

struct SidebarRow: View {
    @EnvironmentObject var workspaceStore: WorkspaceStore
    let node: FileNode

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: node.isDirectory ? "folder" : "doc.text")
                .frame(width: 16, alignment: .center)

            Text(node.name)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 8)

            HStack(spacing: 4) {
                if !node.isDirectory && workspaceStore.isPinned(node.url) {
                    Image(systemName: "pin.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .fixedSize()
                }
                if !node.isDirectory, let gitChange = workspaceStore.gitChange(for: node.url) {
                    GitChangeBadge(change: gitChange)
                }
            }
            .frame(minWidth: 28, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("sidebarRow-\(node.name)")
    }
}

private struct GitChangeBadge: View {
    let change: GitFileChange

    private var label: String {
        switch change {
        case .new:
            return "N"
        case .modified:
            return "M"
        }
    }

    private var tint: Color {
        switch change {
        case .new:
            return .green
        case .modified:
            return .orange
        }
    }

    var body: some View {
        Text(label)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(tint.opacity(0.12), in: Capsule())
            .fixedSize()
            .accessibilityLabel(change == .new ? "New file" : "Modified file")
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
