import XCTest
@testable import MarkLens

@MainActor
final class AppStateSearchReplaceTests: XCTestCase {
    private var tempDirectoryURL: URL!
    private var fileURL: URL!
    private var appState: AppState!

    override func setUpWithError() throws {
        tempDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectoryURL, withIntermediateDirectories: true)
        fileURL = tempDirectoryURL.appendingPathComponent("Note.md")
        try "".write(to: fileURL, atomically: true, encoding: .utf8)

        appState = AppState()
        appState.documentStore.errorMessage = nil
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDirectoryURL)
        appState = nil
        fileURL = nil
        tempDirectoryURL = nil
    }

    func testSearchMatchCountCountsAllCaseInsensitiveOccurrences() {
        appState.documentStore.documentText = "Alpha beta ALPHA gamma alpha"
        appState.searchText = "alpha"

        XCTAssertEqual(appState.searchMatchCount, 3)
    }

    func testReplaceNextReplacesOnlyFirstMatch() throws {
        try "Alpha beta alpha".write(to: fileURL, atomically: true, encoding: .utf8)
        appState.documentStore.loadFile(fileURL)
        appState.searchText = "alpha"
        appState.replaceText = "note"

        appState.replaceNext()
        appState.flushPendingSave()

        XCTAssertEqual(appState.documentStore.documentText, "note beta alpha")
        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), "note beta alpha")
    }

    func testReplaceAllReplacesEveryMatchAndPersistsToDisk() throws {
        try "Alpha beta ALPHA gamma alpha".write(to: fileURL, atomically: true, encoding: .utf8)
        appState.documentStore.loadFile(fileURL)
        appState.searchText = "alpha"
        appState.replaceText = "note"

        appState.replaceAll()
        appState.flushPendingSave()

        XCTAssertEqual(appState.documentStore.documentText, "note beta note gamma note")
        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), "note beta note gamma note")
    }
}
