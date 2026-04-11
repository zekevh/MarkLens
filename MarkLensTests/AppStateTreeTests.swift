import XCTest
@testable import MarkLens

@MainActor
final class AppStateTreeTests: XCTestCase {
    private var tempDirectoryURL: URL!
    private var appState: AppState!

    override func setUpWithError() throws {
        tempDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectoryURL, withIntermediateDirectories: true)
        appState = AppState()
        UserDefaults.standard.removeObject(forKey: "pinnedURLs")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDirectoryURL)
        UserDefaults.standard.removeObject(forKey: "pinnedURLs")
        appState = nil
        tempDirectoryURL = nil
    }

    func testBuildTreeShowsOnlyMarkdownFilesAndRespectsGitignore() throws {
        let docsURL = tempDirectoryURL.appendingPathComponent("Docs", isDirectory: true)
        let ignoredURL = tempDirectoryURL.appendingPathComponent("Ignored", isDirectory: true)
        let emptyURL = tempDirectoryURL.appendingPathComponent("Empty", isDirectory: true)

        try FileManager.default.createDirectory(at: docsURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: ignoredURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: emptyURL, withIntermediateDirectories: true)

        try "Ignored/\n".write(to: tempDirectoryURL.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        try "# readme".write(to: tempDirectoryURL.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try "not markdown".write(to: tempDirectoryURL.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        try "# doc".write(to: docsURL.appendingPathComponent("Guide.markdown"), atomically: true, encoding: .utf8)
        try "# hidden".write(to: ignoredURL.appendingPathComponent("Skip.md"), atomically: true, encoding: .utf8)

        let nodes = appState.buildTree(at: tempDirectoryURL)

        XCTAssertEqual(nodes.map(\.name), ["Docs", "README.md"])
        XCTAssertEqual(nodes.first?.children?.map(\.name), ["Guide.markdown"])
        XCTAssertFalse(nodes.contains(where: { $0.name == "Ignored" || $0.name == "Empty" || $0.name == "notes.txt" }))
    }

    func testBuildTreeSortsPinnedFilesAheadOfOtherEntries() throws {
        let alphaURL = tempDirectoryURL.appendingPathComponent("Alpha.md")
        let zetaURL = tempDirectoryURL.appendingPathComponent("Zeta.md")
        let folderURL = tempDirectoryURL.appendingPathComponent("Folder", isDirectory: true)

        try "# alpha".write(to: alphaURL, atomically: true, encoding: .utf8)
        try "# zeta".write(to: zetaURL, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        try "# child".write(to: folderURL.appendingPathComponent("Child.md"), atomically: true, encoding: .utf8)

        appState.pinnedURLs = [zetaURL.absoluteString]

        let nodes = appState.buildTree(at: tempDirectoryURL)

        XCTAssertEqual(nodes.map(\.name), ["Zeta.md", "Folder", "Alpha.md"])
    }
}
