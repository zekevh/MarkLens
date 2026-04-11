import XCTest

@MainActor
final class MarkLensUITests: XCTestCase {
    private let disableRestoreKey = "MARKLENS_UI_TEST_DISABLE_RESTORE"
    private let rootFolderKey = "MARKLENS_UI_TEST_ROOT_FOLDER"
    private let rawModeKey = "MARKLENS_UI_TEST_RAW_MODE"
    private let harnessKey = "MARKLENS_UI_TEST_HARNESS"
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

    func testHarnessCanCreateNamedNote() throws {
        try "# Alpha\n\nFirst note".write(
            to: tempDirectoryURL.appendingPathComponent("Alpha.md"),
            atomically: true,
            encoding: .utf8
        )

        let app = launchApp(rootFolder: tempDirectoryURL)
        let createButton = app.buttons["uiTestCreateButton"]
        XCTAssertTrue(createButton.waitForExistence(timeout: 5))
        createButton.click()

        XCTAssertTrue(app.staticTexts["Harness Note.md"].waitForExistence(timeout: 5))
        XCTAssertEqual(rawEditor(in: app).value as? String, "")
    }

    func testHarnessCanRenameSelectedNote() throws {
        try "# Alpha\n\nFirst note".write(
            to: tempDirectoryURL.appendingPathComponent("Alpha.md"),
            atomically: true,
            encoding: .utf8
        )

        let app = launchApp(rootFolder: tempDirectoryURL)
        let renameButton = app.buttons["uiTestRenameButton"]
        XCTAssertTrue(renameButton.waitForExistence(timeout: 5))
        renameButton.click()

        XCTAssertTrue(app.staticTexts["Renamed Alpha.md"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Alpha.md"].exists)
        XCTAssertEqual(rawEditor(in: app).value as? String, "# Alpha\n\nFirst note")
    }

    func testHarnessCanTriggerConflictAndUseDiskVersion() throws {
        try "# Alpha\n\nFirst note".write(
            to: tempDirectoryURL.appendingPathComponent("Alpha.md"),
            atomically: true,
            encoding: .utf8
        )

        let app = launchApp(rootFolder: tempDirectoryURL)
        let conflictButton = app.buttons["uiTestConflictButton"]
        XCTAssertTrue(conflictButton.waitForExistence(timeout: 5))
        conflictButton.click()

        XCTAssertTrue(app.staticTexts["File Changed on Disk"].waitForExistence(timeout: 5))
        app.sheets.buttons["Use Disk Version"].click()
        XCTAssertEqual(rawEditor(in: app).value as? String, "Disk version from test")
    }

    private func launchApp(rootFolder: URL) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment[disableRestoreKey] = "1"
        app.launchEnvironment[rootFolderKey] = rootFolder.path
        app.launchEnvironment[rawModeKey] = "1"
        app.launchEnvironment[harnessKey] = "1"
        app.launch()
        return app
    }

    private func rawEditor(in app: XCUIApplication) -> XCUIElement {
        app.textViews["rawTextEditor"]
    }

}
