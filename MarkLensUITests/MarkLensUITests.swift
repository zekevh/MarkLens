import XCTest
import AppKit

@MainActor
final class MarkLensUITests: XCTestCase {
    private let clock = ContinuousClock()
    private let disableRestoreKey = "MARKLENS_UI_TEST_DISABLE_RESTORE"
    private let rootFolderKey = "MARKLENS_UI_TEST_ROOT_FOLDER"
    private let rawModeKey = "MARKLENS_UI_TEST_RAW_MODE"
    private let harnessKey = "MARKLENS_UI_TEST_HARNESS"
    private let showOutlinePanelKey = "MARKLENS_UI_TEST_SHOW_OUTLINE_PANEL"
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

    func testRenameUpdatesMarkdownLinkInAnotherNote() throws {
        try "[beta](./Beta.md)\n".write(
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

        let renameButton = app.buttons["uiTestRenameButton"]
        XCTAssertTrue(renameButton.waitForExistence(timeout: 5))
        renameButton.click()

        let alphaRow = app.staticTexts["Alpha.md"]
        XCTAssertTrue(alphaRow.waitForExistence(timeout: 5))
        alphaRow.click()
        XCTAssertEqual(rawEditor(in: app).value as? String, "[beta](./Renamed Alpha.md)\n")
    }

    func testOutlinePanelShowsFileHistoryAndLocalChanges() throws {
        try initializeGitRepository(at: tempDirectoryURL)

        try "Tracked file\n".write(
            to: tempDirectoryURL.appendingPathComponent("Tracked.md"),
            atomically: true,
            encoding: .utf8
        )
        try commitAll(in: tempDirectoryURL, message: "Add tracked note")
        try "Dirty file\n".write(
            to: tempDirectoryURL.appendingPathComponent("Dirty.md"),
            atomically: true,
            encoding: .utf8
        )

        let app = XCUIApplication()
        configureLaunchEnvironment(for: app, rootFolder: tempDirectoryURL, rawMode: true, showOutlinePanel: true)
        app.launch()

        XCTAssertTrue(app.staticTexts["History"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["No headings"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Local changes"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["No commits for this file"].waitForExistence(timeout: 5))

        app.staticTexts["Tracked.md"].click()

        XCTAssertTrue(app.staticTexts["Add tracked note"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(identifier: "fileHistoryLocalChanges").count == 0)
    }

    func testColdLaunchBenchmark_rawEditorFirstNote() throws {
        try makeBenchmarkFixture()
        let app = XCUIApplication()
        configureLaunchEnvironment(for: app, rootFolder: tempDirectoryURL, rawMode: true)

        let start = clock.now
        app.launch()
        XCTAssertTrue(rawEditor(in: app).waitForExistence(timeout: 5))
        let elapsed = start.duration(to: clock.now)
        print("BENCHMARK\tui_cold_launch_raw_editor_first_note\tms=\(formatMilliseconds(elapsed))")
    }

    func testColdLaunchBenchmark_richEditorFirstNote() throws {
        try makeBenchmarkFixture()
        let app = XCUIApplication()
        configureLaunchEnvironment(for: app, rootFolder: tempDirectoryURL, rawMode: false)

        let start = clock.now
        app.launch()
        XCTAssertTrue(richEditorReady(in: app).waitForExistence(timeout: 5))
        let elapsed = start.duration(to: clock.now)
        print("BENCHMARK\tui_cold_launch_rich_editor_first_note\tms=\(formatMilliseconds(elapsed))")
    }

    private func launchApp(rootFolder: URL) -> XCUIApplication {
        let app = XCUIApplication()
        configureLaunchEnvironment(for: app, rootFolder: rootFolder, rawMode: true)
        app.launch()
        return app
    }

    private func configureLaunchEnvironment(
        for app: XCUIApplication,
        rootFolder: URL,
        rawMode: Bool,
        showOutlinePanel: Bool = false
    ) {
        terminateRunningMarkLensApps()
        app.launchEnvironment[disableRestoreKey] = "1"
        app.launchEnvironment[rootFolderKey] = rootFolder.path
        if rawMode {
            app.launchEnvironment[rawModeKey] = "1"
        } else {
            app.launchEnvironment.removeValue(forKey: rawModeKey)
        }
        app.launchEnvironment[harnessKey] = "1"
        if showOutlinePanel {
            app.launchEnvironment[showOutlinePanelKey] = "1"
        } else {
            app.launchEnvironment.removeValue(forKey: showOutlinePanelKey)
        }
    }

    private func rawEditor(in app: XCUIApplication) -> XCUIElement {
        app.textViews["rawTextEditor"]
    }

    private func richEditorReady(in app: XCUIApplication) -> XCUIElement {
        app.otherElements["nodeEditorReady"]
    }

    private func terminateRunningMarkLensApps() {
        let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: "io.zvh.marklens")
        for app in runningApps {
            if !app.terminate() {
                app.forceTerminate()
            }
        }
    }

    private func makeBenchmarkFixture() throws {
        try """
        ---
        title: Launch Benchmark
        tags:
          - perf
        ---

        # Launch Benchmark

        This fixture tries to exercise headings, paragraphs, code, and tables.

        ## Section Two

        - [ ] first item
        - [x] second item

        ```swift
        let values = [1, 2, 3]
        print(values.reduce(0, +))
        ```

        | Name | Value |
        | --- | --- |
        | Alpha | 1 |
        | Beta | 2 |

        Final paragraph to force another block and some inline `code`.
        """.write(
            to: tempDirectoryURL.appendingPathComponent("Alpha.md"),
            atomically: true,
            encoding: .utf8
        )
    }

    private func initializeGitRepository(at url: URL) throws {
        try runGit(["init"], at: url)
        try runGit(["config", "user.name", "MarkLens UITests"], at: url)
        try runGit(["config", "user.email", "ui-tests@example.com"], at: url)
    }

    private func commitAll(in url: URL, message: String) throws {
        try runGit(["add", "-A"], at: url)
        try runGit(["commit", "-m", message], at: url)
    }

    private func runGit(_ arguments: [String], at url: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        process.currentDirectoryURL = url

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let data = stderr.fileHandleForReading.readDataToEndOfFile()
            let error = String(data: data, encoding: .utf8) ?? "Unknown git error"
            XCTFail("git \(arguments.joined(separator: " ")) failed: \(error)")
            return
        }
    }

    private func formatMilliseconds(_ duration: Duration) -> String {
        let ms = Double(duration.components.seconds) * 1_000
            + Double(duration.components.attoseconds) / 1_000_000_000_000_000
        return String(format: "%.3f", ms)
    }
}
