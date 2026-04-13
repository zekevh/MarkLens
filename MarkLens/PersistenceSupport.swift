import Foundation
import AppKit

final class RecentDocumentsPersistence {
    struct State {
        var recentURLs: [URL]
        var bookmarks: [String: Data]
    }

    private enum Keys {
        static let paths = "recentURLPaths"
        static let bookmarks = "recentBookmarks"
    }

    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    func restore() -> State {
        let bookmarks = (userDefaults.dictionary(forKey: Keys.bookmarks) as? [String: Data]) ?? [:]
        let storedPaths = userDefaults.stringArray(forKey: Keys.paths) ?? []
        let recentURLs = storedPaths
            .filter { bookmarks[$0] != nil }
            .map { URL(fileURLWithPath: $0) }
        return State(recentURLs: recentURLs, bookmarks: bookmarks)
    }

    func clear() {
        userDefaults.removeObject(forKey: Keys.paths)
        userDefaults.removeObject(forKey: Keys.bookmarks)
        NSDocumentController.shared.clearRecentDocuments(nil)
    }

    func resolveRecentURL(_ url: URL, bookmarks: inout [String: Data]) throws -> URL {
        guard let bookmarkData = bookmarks[url.path] else {
            throw CocoaError(.fileReadNoPermission)
        }

        var isStale = false
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
            bookmarks[url.path] = refreshed
            userDefaults.set(bookmarks, forKey: Keys.bookmarks)
        }

        return scopedURL
    }

    func remove(_ url: URL, recentURLs: inout [URL], bookmarks: inout [String: Data]) {
        recentURLs.removeAll { $0.path == url.path }
        bookmarks.removeValue(forKey: url.path)
        persist(recentURLs: recentURLs, bookmarks: bookmarks)
    }

    func record(_ url: URL, recentURLs: inout [URL], bookmarks: inout [String: Data]) {
        recentURLs.removeAll { $0.path == url.path }
        recentURLs.insert(url, at: 0)
        recentURLs = Array(recentURLs.prefix(10))

        if let bookmark = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) {
            bookmarks[url.path] = bookmark
            userDefaults.set(bookmarks, forKey: Keys.bookmarks)
        }

        userDefaults.set(recentURLs.map(\.path), forKey: Keys.paths)
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
    }

    private func persist(recentURLs: [URL], bookmarks: [String: Data]) {
        userDefaults.set(recentURLs.map(\.path), forKey: Keys.paths)
        userDefaults.set(bookmarks, forKey: Keys.bookmarks)
    }
}

final class WorkspacePersistence {
    private enum Keys {
        static let pinnedURLs = "pinnedURLs"
        static let rootFolderBookmark = "rootFolderBookmark"
        static let rootFolderPath = "rootFolderPath"
    }

    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    func loadPinnedURLs() -> Set<String> {
        Set(userDefaults.stringArray(forKey: Keys.pinnedURLs) ?? [])
    }

    func savePinnedURLs(_ pinnedURLs: Set<String>) {
        userDefaults.set(Array(pinnedURLs), forKey: Keys.pinnedURLs)
    }

    func restoreRootFolderURL() -> URL? {
        guard let bookmarkData = userDefaults.data(forKey: Keys.rootFolderBookmark) else { return nil }

        var isStale = false
        guard let scopedURL = try? URL(
            resolvingBookmarkData: bookmarkData,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ), scopedURL.startAccessingSecurityScopedResource() else {
            return nil
        }

        if isStale {
            saveRootFolderURL(scopedURL)
        }

        return scopedURL
    }

    func saveRootFolderURL(_ url: URL?) {
        guard let url else {
            userDefaults.removeObject(forKey: Keys.rootFolderBookmark)
            userDefaults.removeObject(forKey: Keys.rootFolderPath)
            return
        }

        if let bookmark = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) {
            userDefaults.set(bookmark, forKey: Keys.rootFolderBookmark)
            userDefaults.set(url.path, forKey: Keys.rootFolderPath)
        }
    }
}
