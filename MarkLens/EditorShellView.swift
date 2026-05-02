import SwiftUI
import AppKit

struct MainEditorShell: View {
    @EnvironmentObject var documentStore: DocumentStore
    @EnvironmentObject var workspaceStore: WorkspaceStore
    @EnvironmentObject var editorUIStore: EditorUIStore
    @State private var isRichEditorReady = false
    @AppStorage("outlinePanelWidth") private var outlinePanelWidth: Double = 180

    var body: some View {
        HStack(spacing: 0) {
            editorContent

            if editorUIStore.isOutlinePanelVisible, documentStore.selectedFileURL != nil {
                OutlineDivider(panelWidth: $outlinePanelWidth)

                OutlinePanelView(
                    entries: editorUIStore.outlineEntries,
                    historyState: workspaceStore.selectedFileHistoryState,
                    isLoadingHistory: workspaceStore.isLoadingSelectedFileHistory,
                    hasLocalChanges: workspaceStore.selectedFileHasLocalChanges,
                    onSelectEntry: { editorUIStore.jumpToOutlineEntry($0) }
                )
                .frame(width: CGFloat(outlinePanelWidth))
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
                    brokenInternalLinkCount: workspaceStore.selectedFileBrokenInternalLinkCount,
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

    @ViewBuilder
    private var editorContent: some View {
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
                    onLinkClick: { workspaceStore.handleLinkClick($0) }
                )
                .id(documentStore.selectedFileURL)
            }
        } else {
            EmptyEditorView()
        }
    }
}

// MARK: - Resize Handle

private struct OutlineDivider: View {
    @Binding var panelWidth: Double
    /// Width captured at the start of each drag gesture; nil when not dragging.
    @State private var baseWidth: Double? = nil

    private let minWidth: Double = 140
    private let maxWidth: Double = 360

    var body: some View {
        Color(nsColor: .separatorColor)
            .frame(width: 1)
            // Widen the hit area without changing the visual width
            .contentShape(Rectangle().inset(by: -3))
            .onHover { hovering in
                if hovering { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        // Capture the width once at the start of each drag.
                        let base = baseWidth ?? { baseWidth = panelWidth; return panelWidth }()
                        panelWidth = clamp(base - value.translation.width)
                    }
                    .onEnded { value in
                        let base = baseWidth ?? panelWidth
                        panelWidth = clamp(base - value.translation.width)
                        baseWidth = nil
                    }
            )
    }

    private func clamp(_ value: Double) -> Double {
        max(minWidth, min(value, maxWidth))
    }
}
