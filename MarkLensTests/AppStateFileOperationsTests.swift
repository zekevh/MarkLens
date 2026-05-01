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

        appState.workspaceStore.loadFile(oldURL)
        appState.workspaceStore.pinnedURLs = [oldURL.absoluteString]

        appState.workspaceStore.renameFile(oldURL, to: "Renamed.md")

        let newURL = tempDirectoryURL.appendingPathComponent("Renamed.md")
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: newURL.path))
        XCTAssertEqual(appState.documentStore.selectedFileURL, newURL)
        XCTAssertTrue(appState.workspaceStore.pinnedURLs.contains(newURL.absoluteString))
        XCTAssertFalse(appState.workspaceStore.pinnedURLs.contains(oldURL.absoluteString))
        XCTAssertEqual(appState.documentStore.recentURLs.first?.path, newURL.path)
    }

    func testMoveNodeRejectsMovingFolderIntoOwnSubfolder() throws {
        let sourceFolderURL = tempDirectoryURL.appendingPathComponent("Folder", isDirectory: true)
        let nestedFolderURL = sourceFolderURL.appendingPathComponent("Nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedFolderURL, withIntermediateDirectories: true)

        appState.workspaceStore.moveNode(sourceFolderURL, into: nestedFolderURL)

        XCTAssertEqual(appState.documentStore.errorMessage, "Cannot move a folder into one of its own subfolders.")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceFolderURL.path))
    }

    func testCreateFileGeneratesUniqueUntitledNames() throws {
        appState.workspaceStore.rootFolderURL = tempDirectoryURL

        appState.workspaceStore.createFile()
        appState.workspaceStore.createFile()

        XCTAssertTrue(FileManager.default.fileExists(atPath: tempDirectoryURL.appendingPathComponent("Untitled.md").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempDirectoryURL.appendingPathComponent("Untitled 2.md").path))
        XCTAssertEqual(appState.documentStore.selectedFileURL?.lastPathComponent, "Untitled 2.md")
    }

    func testRenameFileRewritesWorkspaceLinks() throws {
        let sourceURL = tempDirectoryURL.appendingPathComponent("Source.md")
        let targetURL = tempDirectoryURL.appendingPathComponent("Target.md")
        try "[go](./Target.md)\n".write(to: sourceURL, atomically: true, encoding: .utf8)
        try "target\n".write(to: targetURL, atomically: true, encoding: .utf8)
        appState.workspaceStore.rootFolderURL = tempDirectoryURL

        appState.workspaceStore.renameFile(targetURL, to: "Renamed.md")

        let sourceContents = try String(contentsOf: sourceURL, encoding: .utf8)
        XCTAssertEqual(sourceContents, "[go](./Renamed.md)\n")
    }

    func testMoveNodeRewritesInboundAndOutboundWorkspaceLinks() throws {
        let folderURL = tempDirectoryURL.appendingPathComponent("Docs", isDirectory: true)
        let destinationURL = tempDirectoryURL.appendingPathComponent("Archive", isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: true)

        let movedFileURL = folderURL.appendingPathComponent("Moved.md")
        let siblingURL = tempDirectoryURL.appendingPathComponent("Sibling.md")
        let referenceURL = folderURL.appendingPathComponent("Reference.md")

        try "[inside](./Reference.md)\n".write(to: movedFileURL, atomically: true, encoding: .utf8)
        try "reference\n".write(to: referenceURL, atomically: true, encoding: .utf8)
        try "[moved](./Docs/Moved.md#section)\n".write(to: siblingURL, atomically: true, encoding: .utf8)

        appState.workspaceStore.rootFolderURL = tempDirectoryURL
        appState.workspaceStore.moveNode(movedFileURL, into: destinationURL)

        let relocatedURL = destinationURL.appendingPathComponent("Moved.md")
        let siblingContents = try String(contentsOf: siblingURL, encoding: .utf8)
        let movedContents = try String(contentsOf: relocatedURL, encoding: .utf8)

        XCTAssertEqual(siblingContents, "[moved](./Archive/Moved.md#section)\n")
        XCTAssertEqual(movedContents, "[inside](../Docs/Reference.md)\n")
    }

    func testRenameFileKeepsOpenDocumentTextInSyncWhenCurrentNoteIsRewritten() throws {
        let currentURL = tempDirectoryURL.appendingPathComponent("Current.md")
        let targetURL = tempDirectoryURL.appendingPathComponent("Target.md")
        try "[go](./Target.md)\n".write(to: currentURL, atomically: true, encoding: .utf8)
        try "target\n".write(to: targetURL, atomically: true, encoding: .utf8)

        appState.workspaceStore.rootFolderURL = tempDirectoryURL
        appState.workspaceStore.loadFile(currentURL)
        appState.documentStore.saveCurrentFile(text: "[go](./Target.md)\n\nUnsaved")

        appState.workspaceStore.renameFile(targetURL, to: "Renamed.md")

        XCTAssertEqual(appState.documentStore.selectedFileURL, currentURL)
        XCTAssertEqual(appState.documentStore.documentText, "[go](./Renamed.md)\n\nUnsaved")
    }

    func testInternalLinkNavigationUpdatesSidebarSelection() throws {
        let firstURL = tempDirectoryURL.appendingPathComponent("First.md")
        let secondURL = tempDirectoryURL.appendingPathComponent("Second.md")
        try "[next](./Second.md)\n".write(to: firstURL, atomically: true, encoding: .utf8)
        try "second\n".write(to: secondURL, atomically: true, encoding: .utf8)

        appState.workspaceStore.rootFolderURL = tempDirectoryURL
        appState.workspaceStore.loadFile(firstURL)

        appState.workspaceStore.handleLinkClick("./Second.md")

        XCTAssertEqual(appState.documentStore.selectedFileURL, secondURL)
        XCTAssertEqual(appState.workspaceStore.selectedSidebarURLs, [secondURL])
    }

    func testBrokenLinkHealthTracksExternalRenameWithoutRewriting() async throws {
        let sourceURL = tempDirectoryURL.appendingPathComponent("Source.md")
        let targetURL = tempDirectoryURL.appendingPathComponent("Target.md")
        try "[go](./Target.md)\n".write(to: sourceURL, atomically: true, encoding: .utf8)
        try "target\n".write(to: targetURL, atomically: true, encoding: .utf8)

        appState.workspaceStore.rootFolderURL = tempDirectoryURL
        appState.workspaceStore.loadFile(sourceURL)
        appState.workspaceStore.rebuildTree()

        try await waitUntil {
            self.appState.workspaceStore.brokenInternalLinkCount(for: sourceURL) == 0
        }

        let renamedURL = tempDirectoryURL.appendingPathComponent("Renamed.md")
        try FileManager.default.moveItem(at: targetURL, to: renamedURL)
        appState.workspaceStore.rebuildTree()

        try await waitUntil {
            self.appState.workspaceStore.brokenInternalLinkCount(for: sourceURL) == 1
        }

        let sourceContents = try String(contentsOf: sourceURL, encoding: .utf8)
        XCTAssertEqual(sourceContents, "[go](./Target.md)\n")
    }

    func testBrokenLinkHealthClearsAfterManualFixAndUnsavedEditsUpdateSelectedFileState() async throws {
        let sourceURL = tempDirectoryURL.appendingPathComponent("Source.md")
        try "[missing](./Missing.md)\n".write(to: sourceURL, atomically: true, encoding: .utf8)

        appState.workspaceStore.rootFolderURL = tempDirectoryURL
        appState.workspaceStore.loadFile(sourceURL)
        appState.workspaceStore.rebuildTree()

        try await waitUntil {
            self.appState.workspaceStore.selectedFileBrokenInternalLinkCount == 1
        }

        let fixedTargetURL = tempDirectoryURL.appendingPathComponent("Missing.md")
        try "fixed\n".write(to: fixedTargetURL, atomically: true, encoding: .utf8)
        appState.workspaceStore.rebuildTree()

        try await waitUntil {
            self.appState.workspaceStore.brokenInternalLinkCount(for: sourceURL) == 0
        }

        appState.documentStore.saveCurrentFile(text: "[missing](./StillMissing.md)\n")

        try await waitUntil {
            self.appState.workspaceStore.selectedFileBrokenInternalLinkCount == 1
        }
    }

    func testBrokenLinkHealthStaysBoundToOriginalFileWhenSwitchingSelection() async throws {
        let brokenURL = tempDirectoryURL.appendingPathComponent("Broken.md")
        let healthyURL = tempDirectoryURL.appendingPathComponent("Healthy.md")
        try "[missing](./Missing.md)\n".write(to: brokenURL, atomically: true, encoding: .utf8)
        try "all good\n".write(to: healthyURL, atomically: true, encoding: .utf8)

        appState.workspaceStore.rootFolderURL = tempDirectoryURL
        appState.workspaceStore.rebuildTree()
        appState.workspaceStore.loadFile(brokenURL)

        try await waitUntil {
            self.appState.workspaceStore.brokenInternalLinkCount(for: brokenURL) == 1
        }

        appState.workspaceStore.loadFile(healthyURL)

        try await waitUntil {
            self.appState.documentStore.selectedFileURL == healthyURL
        }

        try await waitUntil {
            self.appState.workspaceStore.brokenInternalLinkCount(for: brokenURL) == 1
                && self.appState.workspaceStore.brokenInternalLinkCount(for: healthyURL) == 0
                && self.appState.workspaceStore.selectedFileBrokenInternalLinkCount == 0
        }

        XCTAssertEqual(appState.workspaceStore.brokenInternalLinkCount(for: brokenURL), 1)
        XCTAssertEqual(appState.workspaceStore.brokenInternalLinkCount(for: healthyURL), 0)
        XCTAssertEqual(appState.workspaceStore.selectedFileBrokenInternalLinkCount, 0)
    }

    func testOpeningAndSwitchingFilesWithoutEditsDoesNotRewriteBlankLines() async throws {
        let formattedURL = tempDirectoryURL.appendingPathComponent("Formatted.md")
        let otherURL = tempDirectoryURL.appendingPathComponent("Other.md")
        let original = """
        Alpha



        Beta
        """
        try original.write(to: formattedURL, atomically: true, encoding: .utf8)
        try "Other\n".write(to: otherURL, atomically: true, encoding: .utf8)

        appState.workspaceStore.rootFolderURL = tempDirectoryURL
        appState.workspaceStore.loadFile(formattedURL)

        try await waitUntil {
            self.appState.documentStore.selectedFileURL == formattedURL
        }

        XCTAssertFalse(appState.documentStore.isCurrentDocumentEdited)

        appState.workspaceStore.loadFile(otherURL)

        try await waitUntil {
            self.appState.documentStore.selectedFileURL == otherURL
        }

        let persisted = try String(contentsOf: formattedURL, encoding: .utf8)
        XCTAssertEqual(persisted, original)
        XCTAssertFalse(appState.documentStore.isCurrentDocumentEdited)
    }

    private func waitUntil(
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("Condition timed out", file: file, line: line)
    }
}
