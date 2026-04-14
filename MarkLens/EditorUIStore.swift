import SwiftUI
import Combine
import AppKit

struct DocumentSearchJumpRequest: Equatable {
    let id: UUID
    let fileURL: URL
    let query: String
    let location: Int
}

@MainActor
final class EditorUIStore: ObservableObject {
    @Published var searchText: String = "" {
        didSet { syncSearchResults() }
    }
    @Published var isSearchFocused: Bool = false
    @Published var replaceText: String = ""
    @Published var isReplaceVisible: Bool = false
    @Published var isPathBarVisible: Bool = true
    @Published var isStatusBarVisible: Bool = true
    @Published var isOutlinePanelVisible: Bool = false
    @Published private(set) var searchMatchCount: Int = 0
    @Published private(set) var searchJumpRequest: DocumentSearchJumpRequest? = nil
    @Published private(set) var outlineEntries: [OutlineEntry] = []

    private let documentStore: DocumentStore
    private let search = DocumentSearch()
    private var cancellables: Set<AnyCancellable> = []

    init(documentStore: DocumentStore) {
        self.documentStore = documentStore
        documentStore.$documentText
            .sink { [weak self] newText in
                self?.syncSearchResults()
                self?.outlineEntries = parseOutlineEntries(from: newText)
            }
            .store(in: &cancellables)
    }

    private var activeUndoManager: UndoManager? {
        NSApp.keyWindow?.firstResponder?.undoManager ?? NSApp.keyWindow?.undoManager
    }

    func showFindBar(showReplace: Bool = false) {
        guard documentStore.selectedFileURL != nil else { return }
        if showReplace {
            isReplaceVisible.toggle()
            if !isReplaceVisible {
                replaceText = ""
            }
        }
        isSearchFocused = true
    }

    func hideReplaceBar() {
        replaceText = ""
        isReplaceVisible = false
    }

    func replaceNext() {
        let originalText = documentStore.documentText
        guard let updatedText = search.replaceNext(in: originalText, with: replaceText) else { return }
        applyReplaceResult(updatedText, originalText: originalText, actionName: "Replace")
    }

    func replaceAll() {
        let originalText = documentStore.documentText
        guard let updatedText = search.replaceAll(in: originalText, with: replaceText) else { return }
        applyReplaceResult(updatedText, originalText: originalText, actionName: "Replace All")
    }

    func jumpToOutlineEntry(_ entry: OutlineEntry) {
        guard let fileURL = documentStore.selectedFileURL else { return }
        searchJumpRequest = DocumentSearchJumpRequest(
            id: UUID(),
            fileURL: fileURL,
            query: "",
            location: entry.characterOffset
        )
    }

    func openFileSearchResult(_ fileURL: URL, query: String, location: Int?) {
        documentStore.loadFile(fileURL)
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        searchText = trimmedQuery

        guard let location else {
            searchJumpRequest = nil
            return
        }

        searchJumpRequest = DocumentSearchJumpRequest(
            id: UUID(),
            fileURL: fileURL,
            query: trimmedQuery,
            location: max(0, location)
        )
    }

    private func applyReplaceResult(_ updatedText: String, originalText: String, actionName: String) {
        guard updatedText != originalText else { return }

        let undoManager = activeUndoManager
        undoManager?.registerUndo(withTarget: self) { store in
            MainActor.assumeIsolated {
                store.applyReplaceResult(originalText, originalText: updatedText, actionName: actionName)
            }
        }
        undoManager?.setActionName(actionName)

        documentStore.documentText = updatedText
        documentStore.saveCurrentFile(text: updatedText)
    }

    private func syncSearchResults() {
        search.update(documentText: documentStore.documentText, query: searchText)
        searchMatchCount = search.matchCount
    }
}
