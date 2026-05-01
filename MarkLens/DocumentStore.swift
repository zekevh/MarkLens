import Foundation
import AppKit
import Combine

@MainActor
final class DocumentStore: ObservableObject {
    @Published var selectedFileURL: URL? = nil
    @Published var documentText: String = ""
    @Published var recentURLs: [URL] = []
    @Published var errorMessage: String? = nil
    @Published var externalEditConflict: ExternalEditConflict? = nil
    @Published var isRawMode: Bool = false

    private var currentDocument: MarkdownDocument?

    // Security-scoped bookmarks so sandboxed re-access to recents works across launches.
    private var recentBookmarks: [String: Data] = [:]
    private let bookmarksKey = "documentStoreRecentBookmarks"

    // MARK: - File I/O

    func loadFile(_ url: URL) {
        guard !url.hasDirectoryPath else { return }
        closeCurrentDocument()

        let doc: MarkdownDocument
        do {
            doc = try MarkdownDocument(contentsOf: url, ofType: "net.daringfireball.markdown")
        } catch {
            errorMessage = "Could not open \"\(url.lastPathComponent)\": \(error.localizedDescription)"
            return
        }

        doc.onContentUpdated = { [weak self] newText in
            self?.handleExternalContentUpdate(newText)
        }

        currentDocument = doc
        documentText = doc.text
        selectedFileURL = url

        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        storeBookmark(for: url)
        syncRecentsFromSystem()
    }

    /// Called by editors on every keystroke. Marks the document dirty;
    /// NSDocument's autosaveInPlace handles the actual write to disk.
    func saveCurrentFile(text: String) {
        currentDocument?.update(text: text)
        documentText = text
    }

    func applyInternalFileRewrite(at url: URL, text: String) {
        guard selectedFileURL == url else { return }
        externalEditConflict = nil
        documentText = text
        currentDocument?.applyInternalRewrite(text: text)
    }

    /// Synchronous flush called on app quit. With autosaveInPlace this is a
    /// safety net for the rare case the autosave timer hasn't fired yet.
    func flushPendingSave() {
        guard let doc = currentDocument,
              doc.isDocumentEdited,
              let url = doc.fileURL else { return }
        try? doc.writeSafely(
            to: url,
            ofType: "net.daringfireball.markdown",
            for: .saveOperation
        )
    }

    func closeDocument(shouldClearRecents: Bool = false) {
        closeCurrentDocument()
        selectedFileURL = nil
        documentText = ""
        externalEditConflict = nil
        if shouldClearRecents {
            clearRecents()
        }
    }

    func clearSelectionIfSelectedFileMatches(_ url: URL) {
        guard selectedFileURL == url else { return }
        selectedFileURL = nil
        documentText = ""
    }

    // MARK: - Recent Documents

    func restoreRecents() {
        loadStoredBookmarks()
        syncRecentsFromSystem()
    }

    func recordRecent(_ url: URL) {
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        storeBookmark(for: url)
        syncRecentsFromSystem()
    }

    func openRecent(_ url: URL) {
        // Prefer a stored security-scoped bookmark for sandbox access.
        if let bookmarkData = recentBookmarks[url.path] {
            var isStale = false
            if let scopedURL = try? URL(
                resolvingBookmarkData: bookmarkData,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ), scopedURL.startAccessingSecurityScopedResource() {
                if isStale { storeBookmark(for: scopedURL) }
                loadFile(scopedURL)
                return
            }
        }
        // Fallback: direct read (works outside sandbox or for accessible paths).
        if FileManager.default.isReadableFile(atPath: url.path) {
            loadFile(url)
        } else {
            errorMessage = "Cannot access \"\(url.lastPathComponent)\" — please open it via File > Open."
            removeRecent(url)
        }
    }

    func hasRecent(_ url: URL) -> Bool {
        recentURLs.contains(where: { $0.path == url.path })
    }

    func removeRecent(_ url: URL) {
        recentURLs.removeAll { $0.path == url.path }
        recentBookmarks.removeValue(forKey: url.path)
        persistBookmarks()
    }

    func clearRecents() {
        NSDocumentController.shared.clearRecentDocuments(nil)
        recentURLs = []
        recentBookmarks = [:]
        UserDefaults.standard.removeObject(forKey: bookmarksKey)
    }

    // MARK: - Conflict Resolution

    func resolveConflict(keepMine: Bool) {
        guard let conflict = externalEditConflict else { return }
        externalEditConflict = nil
        if !keepMine {
            documentText = conflict.diskContent
            currentDocument?.update(text: conflict.diskContent)
        }
        // If keepMine: the next autosave will overwrite the disk version with our text.
    }

    // MARK: - Link Navigation

    func openExternalLinkIfNeeded(_ urlString: String) -> Bool {
        if let url = URL(string: urlString),
           let scheme = url.scheme?.lowercased(),
           ["http", "https", "mailto", "ftp"].contains(scheme) {
            NSWorkspace.shared.open(url)
            return true
        }
        return false
    }

    func resolveInternalLinkTarget(_ urlString: String) -> URL? {
        guard let base = selectedFileURL?.deletingLastPathComponent() else { return nil }
        let pathPart = urlString.components(separatedBy: CharacterSet(charactersIn: "#?")).first ?? urlString
        guard !pathPart.isEmpty else { return nil }
        let resolvedURL = URL(fileURLWithPath: pathPart, relativeTo: base).standardized
        guard FileManager.default.fileExists(atPath: resolvedURL.path) else { return nil }
        return resolvedURL
    }

    // MARK: - Testing Support

    func simulateExternalConflict(unsavedText: String, diskText: String) {
        guard let url = selectedFileURL else { return }
        documentText = unsavedText
        currentDocument?.update(text: unsavedText)
        do {
            try diskText.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            errorMessage = "Could not simulate external edit for \"\(url.lastPathComponent)\""
            return
        }
        externalEditConflict = ExternalEditConflict(
            diskContent: diskText,
            fileName: url.lastPathComponent
        )
    }

    // MARK: - Internals

    private func closeCurrentDocument() {
        guard let doc = currentDocument else { return }
        if doc.isDocumentEdited, let url = doc.fileURL {
            try? doc.writeSafely(
                to: url,
                ofType: "net.daringfireball.markdown",
                for: .saveOperation
            )
        }
        doc.onContentUpdated = nil
        doc.close()
        currentDocument = nil
    }

    private func handleExternalContentUpdate(_ newText: String) {
        guard newText != documentText else { return }
        if currentDocument?.isDocumentEdited == true {
            externalEditConflict = ExternalEditConflict(
                diskContent: newText,
                fileName: selectedFileURL?.lastPathComponent ?? ""
            )
        } else {
            documentText = newText
        }
    }

    private func syncRecentsFromSystem() {
        recentURLs = NSDocumentController.shared.recentDocumentURLs
    }

    private func storeBookmark(for url: URL) {
        guard let data = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else { return }
        recentBookmarks[url.path] = data
        persistBookmarks()
    }

    private func persistBookmarks() {
        UserDefaults.standard.set(recentBookmarks, forKey: bookmarksKey)
    }

    private func loadStoredBookmarks() {
        recentBookmarks = (UserDefaults.standard.dictionary(forKey: bookmarksKey) as? [String: Data]) ?? [:]
    }
}
