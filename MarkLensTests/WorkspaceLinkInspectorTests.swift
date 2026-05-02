import XCTest
@testable import MarkLens

final class WorkspaceLinkInspectorTests: XCTestCase {
    private var tempDirectoryURL: URL!

    override func setUpWithError() throws {
        tempDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectoryURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDirectoryURL)
        tempDirectoryURL = nil
    }

    func testLinksInFileReportResolvedAndBrokenDestinations() throws {
        let sourceURL = tempDirectoryURL.appendingPathComponent("Source.md")
        let targetURL = tempDirectoryURL.appendingPathComponent("Target.md")
        try "target\n".write(to: targetURL, atomically: true, encoding: .utf8)
        try """
        [good](./Target.md)
        [broken](./Missing.md#frag)
        [external](https://example.com)
        """.write(to: sourceURL, atomically: true, encoding: .utf8)

        let links = try WorkspaceLinkInspector.links(inFileAt: sourceURL)

        XCTAssertEqual(links.count, 3)
        XCTAssertEqual(links[0].resolvedPath, targetURL.path)
        XCTAssertTrue(links[0].exists)
        XCTAssertEqual(links[0].line, 1)
        XCTAssertEqual(links[1].resolvedPath, tempDirectoryURL.appendingPathComponent("Missing.md").path)
        XCTAssertFalse(links[1].exists)
        XCTAssertEqual(links[1].line, 2)
        XCTAssertTrue(links[2].isExternal)
        XCTAssertTrue(links[2].exists)
        XCTAssertNil(links[2].resolvedPath)
    }

    func testBacklinksReturnIncomingLinksForTarget() throws {
        let docsURL = tempDirectoryURL.appendingPathComponent("Docs", isDirectory: true)
        try FileManager.default.createDirectory(at: docsURL, withIntermediateDirectories: true)

        let targetURL = docsURL.appendingPathComponent("Target.md")
        let sourceOneURL = tempDirectoryURL.appendingPathComponent("One.md")
        let sourceTwoURL = docsURL.appendingPathComponent("Two.md")

        try "target\n".write(to: targetURL, atomically: true, encoding: .utf8)
        try "[one](./Docs/Target.md)\n".write(to: sourceOneURL, atomically: true, encoding: .utf8)
        try "[two](./Target.md)\n".write(to: sourceTwoURL, atomically: true, encoding: .utf8)

        let backlinks = WorkspaceLinkInspector.backlinks(to: targetURL, inWorkspace: tempDirectoryURL)

        XCTAssertEqual(backlinks.count, 2)
        XCTAssertEqual(backlinks[0].sourcePath, sourceOneURL.path)
        XCTAssertEqual(backlinks[0].targetPath, targetURL.path)
        XCTAssertEqual(backlinks[1].sourcePath, sourceTwoURL.path)
    }

    func testHealthReturnsBrokenLinksGroupedByFile() throws {
        let sourceURL = tempDirectoryURL.appendingPathComponent("Source.md")
        let healthyURL = tempDirectoryURL.appendingPathComponent("Healthy.md")

        try "[broken](./Missing.md)\n".write(to: sourceURL, atomically: true, encoding: .utf8)
        try "[ok](https://example.com)\n".write(to: healthyURL, atomically: true, encoding: .utf8)

        let report = WorkspaceLinkInspector.health(inWorkspace: tempDirectoryURL)

        XCTAssertEqual(report.count, 1)
        XCTAssertEqual(report[0].path, sourceURL.path)
        XCTAssertEqual(report[0].brokenLinks.count, 1)
        XCTAssertEqual(report[0].brokenLinks[0].destination, "./Missing.md")
    }
}
