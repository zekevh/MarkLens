import SwiftUI

struct MainEditorShell: View {
    @EnvironmentObject var documentStore: DocumentStore
    @EnvironmentObject var workspaceStore: WorkspaceStore
    @EnvironmentObject var editorUIStore: EditorUIStore
    @State private var isRichEditorReady = false

    var body: some View {
        Group {
            if documentStore.selectedFileURL != nil {
                if documentStore.isRawMode {
                    RawTextEditorView(
                        text: $documentStore.documentText,
                        fileURL: documentStore.selectedFileURL,
                        searchJumpRequest: editorUIStore.searchJumpRequest,
                        onTextChange: { documentStore.saveCurrentFile(text: $0) }
                    )
                    .id(documentStore.selectedFileURL)
                } else {
                    NodeEditorView(
                        text: $documentStore.documentText,
                        searchText: editorUIStore.searchText,
                        searchJumpRequest: editorUIStore.searchJumpRequest,
                        fileURL: documentStore.selectedFileURL,
                        onReadyStateChange: { isReady in
                            isRichEditorReady = isReady
                        },
                        onTextChange: { documentStore.saveCurrentFile(text: $0) },
                        onLinkClick: { documentStore.handleLinkClick($0) }
                    )
                    .id(documentStore.selectedFileURL)
                }
            } else {
                EmptyEditorView()
            }
        }
        .overlay(alignment: .topLeading) {
            if documentStore.selectedFileURL != nil, !documentStore.isRawMode {
                Color.clear
                    .frame(width: 1, height: 1)
                    .accessibilityElement()
                    .accessibilityIdentifier(isRichEditorReady ? "nodeEditorReady" : "nodeEditorLoading")
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
        .onChange(of: documentStore.selectedFileURL) { _, _ in
            isRichEditorReady = false
        }
        .onChange(of: documentStore.isRawMode) { _, isRawMode in
            if isRawMode {
                isRichEditorReady = false
            }
        }
    }
}
