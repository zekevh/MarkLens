import SwiftUI

struct MainEditorShell: View {
    @EnvironmentObject var documentStore: DocumentStore
    @EnvironmentObject var workspaceStore: WorkspaceStore
    @EnvironmentObject var editorUIStore: EditorUIStore

    var body: some View {
        Group {
            if documentStore.selectedFileURL != nil {
                if documentStore.isRawMode {
                    RawTextEditorView(
                        text: $documentStore.documentText,
                        onTextChange: { documentStore.saveCurrentFile(text: $0) }
                    )
                    .id(documentStore.selectedFileURL)
                } else {
                    NodeEditorView(
                        text: $documentStore.documentText,
                        searchText: editorUIStore.searchText,
                        fileURL: documentStore.selectedFileURL,
                        onTextChange: { documentStore.saveCurrentFile(text: $0) },
                        onLinkClick: { documentStore.handleLinkClick($0) }
                    )
                    .id(documentStore.selectedFileURL)
                }
            } else {
                EmptyEditorView()
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if documentStore.selectedFileURL != nil, editorUIStore.isReplaceVisible {
                ReplaceSearchBar()
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let selectedFileURL = documentStore.selectedFileURL,
               editorUIStore.isPathBarVisible || editorUIStore.isStatusBarVisible {
                EditorStatusBar(
                    fileURL: selectedFileURL,
                    rootFolderURL: workspaceStore.rootFolderURL,
                    text: documentStore.documentText,
                    showsPathBar: editorUIStore.isPathBarVisible,
                    showsStatusBar: editorUIStore.isStatusBarVisible
                )
            }
        }
    }
}
