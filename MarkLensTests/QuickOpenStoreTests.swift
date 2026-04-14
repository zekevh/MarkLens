import XCTest
@testable import MarkLens

@MainActor
final class QuickOpenStoreTests: XCTestCase {
    private var tempDirectoryURL: URL!
    private var documentStore: DocumentStore!
    private var workspaceStore: WorkspaceStore!
    private var editorUIStore: EditorUIStore!
    private var quickOpenStore: QuickOpenStore!

    override func setUpWithError() throws {
        tempDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectoryURL, withIntermediateDirectories: true)

        documentStore = DocumentStore()
        workspaceStore = WorkspaceStore(documentStore: documentStore)
        editorUIStore = EditorUIStore(documentStore: documentStore)
        quickOpenStore = QuickOpenStore(
            workspaceStore: workspaceStore,
            documentStore: documentStore,
            editorUIStore: editorUIStore
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDirectoryURL)
        quickOpenStore = nil
        editorUIStore = nil
        workspaceStore = nil
        documentStore = nil
        tempDirectoryURL = nil
    }

    func testShowPopulatesResultsAndPrefersSelectedFile() throws {
        let firstURL = try makeFile(named: "Alpha.md")
        let secondURL = try makeFile(named: "Bravo.md")

        workspaceStore.rootFolderURL = tempDirectoryURL
        workspaceStore.rootNodes = [
            FileNode(url: firstURL, name: firstURL.lastPathComponent, isDirectory: false),
            FileNode(url: secondURL, name: secondURL.lastPathComponent, isDirectory: false)
        ]
        workspaceStore.loadFile(secondURL)

        quickOpenStore.show()

        XCTAssertTrue(quickOpenStore.isPresented)
        XCTAssertEqual(quickOpenStore.results.map(\.url), [firstURL, secondURL])
        XCTAssertEqual(quickOpenStore.selectedResultID, secondURL)
    }

    func testQueryRanksFilenamePrefixAheadOfPathOnlyMatches() throws {
        let prefixURL = try makeFile(named: "Meeting Notes.md")
        let folderURL = tempDirectoryURL.appendingPathComponent("Notes", isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        let pathURL = folderURL.appendingPathComponent("Archive.md")
        try "archive".write(to: pathURL, atomically: true, encoding: .utf8)

        workspaceStore.rootFolderURL = tempDirectoryURL
        workspaceStore.rootNodes = [
            FileNode(url: prefixURL, name: prefixURL.lastPathComponent, isDirectory: false),
            FileNode(
                url: folderURL,
                name: folderURL.lastPathComponent,
                isDirectory: true,
                children: [
                    FileNode(url: pathURL, name: pathURL.lastPathComponent, isDirectory: false)
                ]
            )
        ]

        quickOpenStore.show()
        quickOpenStore.query = "note"

        XCTAssertEqual(quickOpenStore.results.first?.url, prefixURL)
    }

    func testQueryFindsContentMatchesAndReturnsSnippet() throws {
        let alphaURL = try makeFile(named: "Alpha.md", contents: "roadmap draft")
        let betaURL = try makeFile(named: "Beta.md", contents: "target needle inside body text")

        workspaceStore.rootFolderURL = tempDirectoryURL
        workspaceStore.rootNodes = [
            FileNode(url: alphaURL, name: alphaURL.lastPathComponent, isDirectory: false),
            FileNode(url: betaURL, name: betaURL.lastPathComponent, isDirectory: false)
        ]

        quickOpenStore.show()
        quickOpenStore.query = "needle"
        waitForIndexedResults()

        XCTAssertEqual(quickOpenStore.results.first?.url, betaURL)
        XCTAssertEqual(quickOpenStore.results.first?.matchSource, .content)
        XCTAssertTrue(quickOpenStore.results.first?.snippet?.contains("needle") == true)
    }

    func testQueryKeepsOneResultPerFileWhenTitleAndContentBothMatch() throws {
        let matchingURL = try makeFile(named: "Needle Notes.md", contents: "needle in the body too")

        workspaceStore.rootFolderURL = tempDirectoryURL
        workspaceStore.rootNodes = [
            FileNode(url: matchingURL, name: matchingURL.lastPathComponent, isDirectory: false)
        ]

        quickOpenStore.show()
        quickOpenStore.query = "needle"
        waitForIndexedResults()

        XCTAssertEqual(quickOpenStore.results.count, 1)
        XCTAssertEqual(quickOpenStore.results.first?.url, matchingURL)
        XCTAssertNotNil(quickOpenStore.results.first?.snippet)
    }

    func testOpenSelectionLoadsChosenFileIntoEditor() throws {
        let firstURL = try makeFile(named: "Alpha.md")
        let secondURL = try makeFile(named: "Beta.md")

        workspaceStore.rootFolderURL = tempDirectoryURL
        workspaceStore.rootNodes = [
            FileNode(url: firstURL, name: firstURL.lastPathComponent, isDirectory: false),
            FileNode(url: secondURL, name: secondURL.lastPathComponent, isDirectory: false)
        ]

        quickOpenStore.show()
        quickOpenStore.query = "beta"

        XCTAssertEqual(quickOpenStore.selectedResultID, secondURL)

        quickOpenStore.openSelection()

        XCTAssertFalse(quickOpenStore.isPresented)
        XCTAssertEqual(documentStore.selectedFileURL, secondURL)
        XCTAssertEqual(workspaceStore.selectedSidebarURLs, [secondURL])
    }

    func testOpenSelectionFromContentMatchSetsEditorSearchState() throws {
        let targetURL = try makeFile(named: "Gamma.md", contents: "prefix target needle suffix")

        workspaceStore.rootFolderURL = tempDirectoryURL
        workspaceStore.rootNodes = [
            FileNode(url: targetURL, name: targetURL.lastPathComponent, isDirectory: false)
        ]

        quickOpenStore.show()
        quickOpenStore.query = "needle"
        waitForIndexedResults()
        quickOpenStore.openSelection()

        XCTAssertEqual(documentStore.selectedFileURL, targetURL)
        XCTAssertEqual(editorUIStore.searchText, "needle")
        XCTAssertEqual(editorUIStore.searchJumpRequest?.fileURL, targetURL)
        XCTAssertNotNil(editorUIStore.searchJumpRequest)
    }

    private func makeFile(named name: String, contents: String = "content") throws -> URL {
        let url = tempDirectoryURL.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func waitForIndexedResults(timeout: TimeInterval = 1.0) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !quickOpenStore.results.isEmpty,
               quickOpenStore.results.contains(where: { $0.matchSource == .content || $0.snippet != nil }) {
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
    }
}
