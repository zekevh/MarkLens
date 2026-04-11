import XCTest

@MainActor
final class MarkLensUITests: XCTestCase {
    private let disableRestoreKey = "MARKLENS_UI_TEST_DISABLE_RESTORE"
    private let rootFolderKey = "MARKLENS_UI_TEST_ROOT_FOLDER"
    private let rawModeKey = "MARKLENS_UI_TEST_RAW_MODE"
    private var tempDirectoryURL: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        tempDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarkLensUITests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectoryURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDirectoryURL)
        tempDirectoryURL = nil
    }

    func testLaunchWithFixtureFolderLoadsFirstNote() throws {
        try "# Alpha\n\nFirst note".write(
            to: tempDirectoryURL.appendingPathComponent("Alpha.md"),
            atomically: true,
            encoding: .utf8
        )
        try "# Beta\n\nSecond note".write(
            to: tempDirectoryURL.appendingPathComponent("Beta.md"),
            atomically: true,
            encoding: .utf8
        )

        let app = launchApp(rootFolder: tempDirectoryURL)

        XCTAssertTrue(app.staticTexts["Alpha.md"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Beta.md"].waitForExistence(timeout: 5))
        XCTAssertTrue(rawEditor(in: app).waitForExistence(timeout: 5))
        XCTAssertEqual(rawEditor(in: app).value as? String, "# Alpha\n\nFirst note")
    }

    func testSelectingAnotherSidebarNoteLoadsItsContent() throws {
        try "# Alpha\n\nFirst note".write(
            to: tempDirectoryURL.appendingPathComponent("Alpha.md"),
            atomically: true,
            encoding: .utf8
        )
        try "# Beta\n\nSecond note".write(
            to: tempDirectoryURL.appendingPathComponent("Beta.md"),
            atomically: true,
            encoding: .utf8
        )

        let app = launchApp(rootFolder: tempDirectoryURL)
        let betaRow = app.staticTexts["Beta.md"]
        XCTAssertTrue(betaRow.waitForExistence(timeout: 5))

        betaRow.click()
        XCTAssertEqual(rawEditor(in: app).value as? String, "# Beta\n\nSecond note")
    }

    private func launchApp(rootFolder: URL) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment[disableRestoreKey] = "1"
        app.launchEnvironment[rootFolderKey] = rootFolder.path
        app.launchEnvironment[rawModeKey] = "1"
        app.launch()
        return app
    }

    private func rawEditor(in app: XCUIApplication) -> XCUIElement {
        app.textViews["rawTextEditor"]
    }

}
