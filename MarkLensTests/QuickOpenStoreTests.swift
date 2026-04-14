import XCTest
@testable import MarkLens

@MainActor
final class QuickOpenStoreTests: XCTestCase {
    private var tempDirectoryURL: URL!
    private var documentStore: DocumentStore!
    private var workspaceStore: WorkspaceStore!
    private var quickOpenStore: QuickOpenStore!

    override func setUpWithError() throws {
        tempDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectoryURL, withIntermediateDirectories: true)

        documentStore = DocumentStore()
        workspaceStore = WorkspaceStore(documentStore: documentStore)
        quickOpenStore = QuickOpenStore(workspaceStore: workspaceStore)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDirectoryURL)
        quickOpenStore = nil
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

    private func makeFile(named name: String, contents: String = "content") throws -> URL {
        let url = tempDirectoryURL.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
