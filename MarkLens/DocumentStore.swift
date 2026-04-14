import Foundation
import AppKit
import Combine

@MainActor
final class DocumentStore: ObservableObject {
    private static let autosaveDelay: TimeInterval = 1.0

    @Published var selectedFileURL: URL? = nil
    @Published var documentText: String = ""
    @Published var recentURLs: [URL] = []
    @Published var errorMessage: String? = nil
    @Published var externalEditConflict: ExternalEditConflict? = nil
    @Published var isRawMode: Bool = false

    private var saveWorkItem: DispatchWorkItem?
    private var lastWrittenText: String? = nil
    private var pendingSaveText: String? = nil
    private var scheduledSaveID: Int = 0
    private var recentBookmarks: [String: Data] = [:]
    private let fileWatcher = FileWatcher()
    private let recentDocumentsPersistence = RecentDocumentsPersistence()
    private let saveQueue = DispatchQueue(label: "MarkLens.DocumentStore.SaveQueue", qos: .utility)

    func loadFile(_ url: URL) {
        guard !url.hasDirectoryPath else { return }
        saveWorkItem?.cancel()
        saveWorkItem = nil
        pendingSaveText = nil
        do {
            documentText = try String(contentsOf: url, encoding: .utf8)
        } catch {
            errorMessage = "Could not open \"\(url.lastPathComponent)\": \(error.localizedDescription)"
            return
        }
        lastWrittenText = documentText
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
        recentDocumentsPersistence.clear()
    }

    func openRecent(_ url: URL) {
        guard recentBookmarks[url.path] != nil else {
            errorMessage = "Cannot access \"\(url.lastPathComponent)\" — please open it via File > Open."
            removeRecent(url)
            return
        }

        do {
            let scopedURL = try recentDocumentsPersistence.resolveRecentURL(url, bookmarks: &recentBookmarks)
            loadFile(scopedURL)
        } catch {
            errorMessage = "Cannot access \"\(url.lastPathComponent)\": \(error.localizedDescription)"
        }
    }

    func restoreRecents() {
        let state = recentDocumentsPersistence.restore()
        recentURLs = state.recentURLs
        recentBookmarks = state.bookmarks
    }

    func resolveConflict(keepMine: Bool) {
        guard let conflict = externalEditConflict else { return }
        externalEditConflict = nil
        if !keepMine {
            documentText = conflict.diskContent
            lastWrittenText = conflict.diskContent
            pendingSaveText = nil
            saveWorkItem?.cancel()
            saveWorkItem = nil
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
        pendingSaveText = text
        scheduledSaveID += 1
        let saveID = scheduledSaveID
        let item = DispatchWorkItem { [weak self] in
            self?.saveQueue.async { [weak self] in
                do {
                    try text.write(to: url, atomically: true, encoding: .utf8)
                    DispatchQueue.main.async {
                        guard let self else { return }
                        self.lastWrittenText = text
                        if self.scheduledSaveID == saveID {
                            self.pendingSaveText = nil
                            self.saveWorkItem = nil
                        }
                    }
                } catch {
                DispatchQueue.main.async {
                        guard let self else { return }
                        if self.scheduledSaveID == saveID {
                            self.saveWorkItem = nil
                        }
                        self.present(error, context: "Could not save \"\(url.lastPathComponent)\"")
                    }
                }
            }
        }
        saveWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.autosaveDelay, execute: item)
    }

    func flushPendingSave() {
        guard let url = selectedFileURL,
              let pendingSaveText else {
            saveWorkItem?.cancel()
            saveWorkItem = nil
            return
        }
        saveWorkItem?.cancel()
        saveWorkItem = nil
        do {
            try saveQueue.sync {
                try pendingSaveText.write(to: url, atomically: true, encoding: .utf8)
            }
            lastWrittenText = pendingSaveText
            self.pendingSaveText = nil
        } catch {
            present(error, context: "Could not save \"\(url.lastPathComponent)\"")
        }
    }

    func closeDocument(shouldClearRecents: Bool = false) {
        flushPendingSave()
        fileWatcher.stop()
        selectedFileURL = nil
        documentText = ""
        lastWrittenText = nil
        pendingSaveText = nil
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
        recentDocumentsPersistence.remove(url, recentURLs: &recentURLs, bookmarks: &recentBookmarks)
    }

    func recordRecent(_ url: URL) {
        recentDocumentsPersistence.record(url, recentURLs: &recentURLs, bookmarks: &recentBookmarks)
    }

    private func reloadIfChangedOnDisk() {
        guard let url = selectedFileURL else { return }
        guard let onDisk = try? String(contentsOf: url, encoding: .utf8) else { return }
        guard onDisk != documentText else { return }
        guard onDisk != lastWrittenText else { return }

        if documentText == lastWrittenText {
            documentText = onDisk
            lastWrittenText = onDisk
            pendingSaveText = nil
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
