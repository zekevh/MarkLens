import XCTest
@testable import MarkLens

final class WorkspaceBrokenLinkScannerTests: XCTestCase {
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

    func testScanFileIgnoresExternalLinksAndResolvesAnchorQuerySuffixes() throws {
        let sourceURL = tempDirectoryURL.appendingPathComponent("Source.md")
        let targetURL = tempDirectoryURL.appendingPathComponent("Target.md")
        try "target\n".write(to: targetURL, atomically: true, encoding: .utf8)

        let text = """
        [web](https://example.com)
        [ok](./Target.md#section)
        [still-ok](./Target.md?query=1)
        [missing](./Missing.md#section)
        """

        let brokenLinkCount = WorkspaceBrokenLinkScanner.scanFile(text, at: sourceURL)

        XCTAssertEqual(brokenLinkCount, 1)
    }
}
