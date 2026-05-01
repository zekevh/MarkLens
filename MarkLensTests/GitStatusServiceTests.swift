import XCTest
@testable import MarkLens

@MainActor
final class GitStatusServiceTests: XCTestCase {
    private var tempDirectoryURL: URL!
    private var appState: AppState!

    override func setUpWithError() throws {
        tempDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectoryURL, withIntermediateDirectories: true)
        appState = AppState()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDirectoryURL)
        appState = nil
        tempDirectoryURL = nil
    }

    func testParseFileHistorySkipsMalformedLines() {
        let output = """
        aaaaa\(separator)aaaaa\(separator)1714521600\(separator)Initial commit
        malformed line
        bbbbb\(separator)bbbbb\(separator)bad-date\(separator)Skipped
        """

        let entries = GitStatusService.parseFileHistory(output)

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.fullHash, "aaaaa")
        XCTAssertEqual(entries.first?.subject, "Initial commit")
    }

    func testLoadHistoryFollowsRenamesForSelectedFile() async throws {
        try initializeGitRepository(at: tempDirectoryURL)

        let alphaURL = tempDirectoryURL.appendingPathComponent("Alpha.md")
        let betaURL = tempDirectoryURL.appendingPathComponent("Beta.md")

        try "# Alpha\n".write(to: alphaURL, atomically: true, encoding: .utf8)
        try commitAll(in: tempDirectoryURL, message: "Add alpha")

        try FileManager.default.moveItem(at: alphaURL, to: betaURL)
        try commitAll(in: tempDirectoryURL, message: "Rename alpha to beta")

        try "# Beta\n\nUpdated\n".write(to: betaURL, atomically: true, encoding: .utf8)
        try commitAll(in: tempDirectoryURL, message: "Update beta")

        let entries = try XCTUnwrap(await GitStatusService.loadHistory(for: betaURL))

        XCTAssertEqual(entries.map(\.subject), ["Update beta", "Rename alpha to beta", "Add alpha"])
        XCTAssertTrue(entries.allSatisfy { !$0.shortHash.isEmpty })
    }

    func testWorkspaceStoreTracksSelectedFileHistoryAndLocalChanges() async throws {
        try initializeGitRepository(at: tempDirectoryURL)

        let trackedURL = tempDirectoryURL.appendingPathComponent("Tracked.md")
        let dirtyURL = tempDirectoryURL.appendingPathComponent("Dirty.md")

        try "# Tracked\n".write(to: trackedURL, atomically: true, encoding: .utf8)
        try commitAll(in: tempDirectoryURL, message: "Add tracked file")
        try "# Dirty\n".write(to: dirtyURL, atomically: true, encoding: .utf8)

        appState.workspaceStore.setRootFolder(tempDirectoryURL)

        try await waitUntil {
            self.appState.documentStore.selectedFileURL == dirtyURL
        }

        try await waitUntil {
            if case let .loaded(entries) = self.appState.workspaceStore.selectedFileHistoryState {
                return entries.isEmpty
            }
            return false
        }

        try await waitUntil {
            self.appState.workspaceStore.selectedFileHasLocalChanges
        }

        XCTAssertFalse(appState.workspaceStore.isLoadingSelectedFileHistory)
        XCTAssertEqual(appState.workspaceStore.gitChange(for: dirtyURL), .new)
    }

    private var separator: String { "\u{1F}" }

    private func initializeGitRepository(at url: URL) throws {
        try runGit(["init"], at: url)
        try runGit(["config", "user.name", "MarkLens Tests"], at: url)
        try runGit(["config", "user.email", "tests@example.com"], at: url)
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

    private func waitUntil(
        timeout: TimeInterval = 5,
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
