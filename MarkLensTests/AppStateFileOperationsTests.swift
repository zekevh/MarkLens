import XCTest
@testable import MarkLens

@MainActor
final class AppStateFileOperationsTests: XCTestCase {
    private var tempDirectoryURL: URL!
    private var appState: AppState!

    override func setUpWithError() throws {
        tempDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectoryURL, withIntermediateDirectories: true)
        appState = AppState()
        UserDefaults.standard.removeObject(forKey: "pinnedURLs")
        UserDefaults.standard.removeObject(forKey: "recentURLPaths")
        UserDefaults.standard.removeObject(forKey: "recentBookmarks")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDirectoryURL)
        UserDefaults.standard.removeObject(forKey: "pinnedURLs")
        UserDefaults.standard.removeObject(forKey: "recentURLPaths")
        UserDefaults.standard.removeObject(forKey: "recentBookmarks")
        appState = nil
        tempDirectoryURL = nil
    }

    func testRenameFileUpdatesPinnedRecentAndSelectedState() throws {
        let oldURL = tempDirectoryURL.appendingPathComponent("Old.md")
        try "content".write(to: oldURL, atomically: true, encoding: .utf8)

        appState.loadFile(oldURL)
        appState.pinnedURLs = [oldURL.absoluteString]

        appState.renameFile(oldURL, to: "Renamed.md")

        let newURL = tempDirectoryURL.appendingPathComponent("Renamed.md")
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: newURL.path))
        XCTAssertEqual(appState.selectedFileURL, newURL)
        XCTAssertTrue(appState.pinnedURLs.contains(newURL.absoluteString))
        XCTAssertFalse(appState.pinnedURLs.contains(oldURL.absoluteString))
        XCTAssertEqual(appState.recentURLs.first?.path, newURL.path)
    }

    func testMoveNodeRejectsMovingFolderIntoOwnSubfolder() throws {
        let sourceFolderURL = tempDirectoryURL.appendingPathComponent("Folder", isDirectory: true)
        let nestedFolderURL = sourceFolderURL.appendingPathComponent("Nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedFolderURL, withIntermediateDirectories: true)

        appState.moveNode(sourceFolderURL, into: nestedFolderURL)

        XCTAssertEqual(appState.errorMessage, "Cannot move a folder into one of its own subfolders.")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceFolderURL.path))
    }

    func testCreateFileGeneratesUniqueUntitledNames() throws {
        appState.rootFolderURL = tempDirectoryURL

        appState.createFile()
        appState.createFile()

        XCTAssertTrue(FileManager.default.fileExists(atPath: tempDirectoryURL.appendingPathComponent("Untitled.md").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempDirectoryURL.appendingPathComponent("Untitled 2.md").path))
        XCTAssertEqual(appState.selectedFileURL?.lastPathComponent, "Untitled 2.md")
    }
}
