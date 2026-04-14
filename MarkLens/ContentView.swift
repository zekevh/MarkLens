import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var documentStore: DocumentStore
    @EnvironmentObject var workspaceStore: WorkspaceStore
    @EnvironmentObject var editorUIStore: EditorUIStore
    @EnvironmentObject var quickOpenStore: QuickOpenStore
    @FocusState private var isSearchFocused: Bool
    private let environment = ProcessInfo.processInfo.environment

    private var isUITestHarnessEnabled: Bool {
        environment[UITestLaunchEnvironment.harness] == "1"
    }

    var body: some View {
        ZStack {
            NavigationSplitView(columnVisibility: $appState.sidebarVisibility) {
                SidebarView()
                    .navigationSplitViewColumnWidth(min: 180, ideal: 240, max: 320)
            } detail: {
                MainEditorShell()
            }
            .disabled(quickOpenStore.isPresented)

            QuickOpenOverlay()
                .zIndex(1)
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar { contentToolbar }
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
                .searchable(text: $editorUIStore.searchText, placement: .toolbar, prompt: "Search")
                .searchFocused($isSearchFocused)
                .onChange(of: editorUIStore.isSearchFocused) { _, focused in
                    guard focused else { return }
                    Task { @MainActor in
                        isSearchFocused = true
                        editorUIStore.isSearchFocused = false
                    }
                }
        }
    }

    @ToolbarContentBuilder
    private var contentToolbar: some ToolbarContent {
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
}

private extension View {
    @ViewBuilder
    func `if`<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
        if condition { transform(self) } else { self }
    }
}
