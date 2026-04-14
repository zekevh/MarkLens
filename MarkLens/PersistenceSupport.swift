import Foundation
import AppKit

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
