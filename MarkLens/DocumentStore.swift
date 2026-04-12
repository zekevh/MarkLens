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

    private var saveWorkItem: DispatchWorkItem?
    private var lastSavedText: String? = nil
    private var recentBookmarks: [String: Data] = [:]
    private let fileWatcher = FileWatcher()

    func loadFile(_ url: URL) {
        guard !url.hasDirectoryPath else { return }
        do {
            documentText = try String(contentsOf: url, encoding: .utf8)
        } catch {
            errorMessage = "Could not open \"\(url.lastPathComponent)\": \(error.localizedDescription)"
            return
        }
        lastSavedText = documentText
        selectedFileURL = url
        fileWatcher.watch(url) { [weak self] in self?.reloadIfChangedOnDisk() }
        recordRecent(url)
    }

    func handleLinkClick(_ urlString: String) {
        if let url = URL(string: urlString),
           let scheme = url.scheme?.lowercased(),
           ["http", "https", "mailto", "ftp"].contains(scheme) {
            NSWorkspace.shared.open(url)
            return
        }

        guard let base = selectedFileURL?.deletingLastPathComponent() else { return }
        let pathPart = urlString.components(separatedBy: CharacterSet(charactersIn: "#?")).first ?? urlString
        guard !pathPart.isEmpty else { return }
        let resolvedURL = URL(fileURLWithPath: pathPart, relativeTo: base).standardized
        guard FileManager.default.fileExists(atPath: resolvedURL.path) else { return }
        loadFile(resolvedURL)
    }

    func clearRecents() {
        recentURLs = []
        recentBookmarks = [:]
        UserDefaults.standard.removeObject(forKey: "recentURLPaths")
        UserDefaults.standard.removeObject(forKey: "recentBookmarks")
        NSDocumentController.shared.clearRecentDocuments(nil)
    }

    func openRecent(_ url: URL) {
        guard let bookmarkData = recentBookmarks[url.path] else {
            errorMessage = "Cannot access \"\(url.lastPathComponent)\" — please open it via File > Open."
            removeRecent(url)
            return
        }

        var isStale = false
        do {
            let scopedURL = try URL(
                resolvingBookmarkData: bookmarkData,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            guard scopedURL.startAccessingSecurityScopedResource() else {
                throw CocoaError(.fileReadNoPermission)
            }
            if isStale,
               let refreshed = try? scopedURL.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
               ) {
                recentBookmarks[url.path] = refreshed
                UserDefaults.standard.set(recentBookmarks, forKey: "recentBookmarks")
            }
            loadFile(scopedURL)
        } catch {
            errorMessage = "Cannot access \"\(url.lastPathComponent)\": \(error.localizedDescription)"
        }
    }

    func restoreRecents() {
        recentBookmarks = (UserDefaults.standard.dictionary(forKey: "recentBookmarks") as? [String: Data]) ?? [:]
        let storedPaths = UserDefaults.standard.stringArray(forKey: "recentURLPaths") ?? []
        recentURLs = storedPaths
            .filter { recentBookmarks[$0] != nil }
            .map { URL(fileURLWithPath: $0) }
    }

    func resolveConflict(keepMine: Bool) {
        guard let conflict = externalEditConflict else { return }
        externalEditConflict = nil
        if !keepMine {
            documentText = conflict.diskContent
            lastSavedText = conflict.diskContent
        }
    }

    func simulateExternalConflict(unsavedText: String, diskText: String) {
        guard let url = selectedFileURL else { return }
        documentText = unsavedText
        do {
            try diskText.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            present(error, context: "Could not simulate external edit for \"\(url.lastPathComponent)\"")
            return
        }
        externalEditConflict = ExternalEditConflict(
            diskContent: diskText,
            fileName: url.lastPathComponent
        )
    }

    func saveCurrentFile(text: String) {
        guard let url = selectedFileURL else { return }
        guard FileManager.default.isWritableFile(atPath: url.path) else {
            errorMessage = "Cannot save \"\(url.lastPathComponent)\": file is read-only."
            return
        }
        saveWorkItem?.cancel()
        lastSavedText = text
        let item = DispatchWorkItem { [weak self] in
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                DispatchQueue.main.async {
                    self?.present(error, context: "Could not save \"\(url.lastPathComponent)\"")
                }
            }
            DispatchQueue.main.async { self?.saveWorkItem = nil }
        }
        saveWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: item)
    }

    func flushPendingSave() {
        saveWorkItem?.perform()
        saveWorkItem?.cancel()
        saveWorkItem = nil
    }

    func closeDocument(shouldClearRecents: Bool = false) {
        flushPendingSave()
        fileWatcher.stop()
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

    func hasRecent(_ url: URL) -> Bool {
        recentURLs.contains(where: { $0.path == url.path })
    }

    func removeRecent(_ url: URL) {
        recentURLs.removeAll { $0.path == url.path }
        recentBookmarks.removeValue(forKey: url.path)
        UserDefaults.standard.set(recentURLs.map(\.path), forKey: "recentURLPaths")
        UserDefaults.standard.set(recentBookmarks, forKey: "recentBookmarks")
    }

    func recordRecent(_ url: URL) {
        var list = recentURLs
        list.removeAll { $0.path == url.path }
        list.insert(url, at: 0)
        recentURLs = Array(list.prefix(10))

        if let bookmark = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) {
            recentBookmarks[url.path] = bookmark
            UserDefaults.standard.set(recentBookmarks, forKey: "recentBookmarks")
        }
        UserDefaults.standard.set(recentURLs.map(\.path), forKey: "recentURLPaths")
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
    }

    private func reloadIfChangedOnDisk() {
        guard let url = selectedFileURL else { return }
        guard let onDisk = try? String(contentsOf: url, encoding: .utf8) else { return }
        guard onDisk != documentText else { return }
        guard onDisk != lastSavedText else { return }

        if documentText == lastSavedText {
            documentText = onDisk
            lastSavedText = onDisk
        } else {
            externalEditConflict = ExternalEditConflict(
                diskContent: onDisk,
                fileName: url.lastPathComponent
            )
        }
    }

    private func present(_ error: Error, context: String) {
        errorMessage = "\(context): \(error.localizedDescription)"
    }
}
