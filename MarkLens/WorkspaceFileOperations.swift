import Foundation

enum WorkspaceFileOperationError: LocalizedError {
    case fileAlreadyExists(String)
    case fileCreationFailed(String)
    case invalidMoveIntoOwnSubfolder
    case destinationAlreadyContainsItem(itemName: String, folderName: String)

    var errorDescription: String? {
        switch self {
        case let .fileAlreadyExists(name):
            "\"\(name)\" already exists."
        case let .fileCreationFailed(name):
            "Could not create \"\(name)\". Check folder permissions."
        case .invalidMoveIntoOwnSubfolder:
            "Cannot move a folder into one of its own subfolders."
        case let .destinationAlreadyContainsItem(itemName, folderName):
            "\"\(itemName)\" already exists in \"\(folderName)\"."
        }
    }
}

final class WorkspaceFileOperations {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func createMarkdownFile(named fileName: String, contents: String, in directoryURL: URL) throws -> URL {
        let normalizedName = normalizedMarkdownFileName(fileName)
        let url = directoryURL.appendingPathComponent(normalizedName)
        guard !fileManager.fileExists(atPath: url.path) else {
            throw WorkspaceFileOperationError.fileAlreadyExists(url.lastPathComponent)
        }

        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func createUntitledMarkdownFile(in directoryURL: URL) throws -> URL {
        var url = directoryURL.appendingPathComponent("Untitled.md")
        var counter = 2
        while fileManager.fileExists(atPath: url.path) {
            url = directoryURL.appendingPathComponent("Untitled \(counter).md")
            counter += 1
        }

        guard fileManager.createFile(atPath: url.path, contents: nil) else {
            throw WorkspaceFileOperationError.fileCreationFailed(url.lastPathComponent)
        }

        return url
    }

    func trashItem(at url: URL) throws {
        try fileManager.trashItem(at: url, resultingItemURL: nil)
    }

    func renameItem(at url: URL, to newName: String) throws -> URL {
        let newURL = url.deletingLastPathComponent().appendingPathComponent(newName)
        try fileManager.moveItem(at: url, to: newURL)
        return newURL
    }

    func validatedMoveSources(_ sourceURLs: [URL], into destinationFolderURL: URL) throws -> [URL] {
        let uniqueSourceURLs = Array(Set(sourceURLs)).sorted { $0.path < $1.path }
        let filteredSourceURLs = uniqueSourceURLs.filter { sourceURL in
            let standardizedSourcePath = sourceURL.standardizedFileURL.path
            return !uniqueSourceURLs.contains(where: {
                $0 != sourceURL &&
                standardizedSourcePath.hasPrefix($0.standardizedFileURL.path + "/")
            })
        }

        for sourceURL in filteredSourceURLs {
            guard sourceURL != destinationFolderURL else { continue }
            guard sourceURL.deletingLastPathComponent() != destinationFolderURL else { continue }

            let sourcePath = sourceURL.standardizedFileURL.path
            let destinationPath = destinationFolderURL.standardizedFileURL.path
            if destinationPath.hasPrefix(sourcePath + "/") {
                throw WorkspaceFileOperationError.invalidMoveIntoOwnSubfolder
            }

            let targetURL = destinationFolderURL.appendingPathComponent(sourceURL.lastPathComponent)
            guard !fileManager.fileExists(atPath: targetURL.path) else {
                throw WorkspaceFileOperationError.destinationAlreadyContainsItem(
                    itemName: targetURL.lastPathComponent,
                    folderName: destinationFolderURL.lastPathComponent
                )
            }
        }

        return filteredSourceURLs
    }

    func moveItem(at sourceURL: URL, into destinationFolderURL: URL) throws -> URL {
        let targetURL = destinationFolderURL.appendingPathComponent(sourceURL.lastPathComponent)
        try fileManager.moveItem(at: sourceURL, to: targetURL)
        return targetURL
    }

    func moveItem(at sourceURL: URL, to destinationURL: URL) throws -> URL {
        try fileManager.moveItem(at: sourceURL, to: destinationURL)
        return destinationURL
    }

    private func normalizedMarkdownFileName(_ fileName: String) -> String {
        let trimmedName = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedName.lowercased().hasSuffix(".md") ? trimmedName : "\(trimmedName).md"
    }
}
