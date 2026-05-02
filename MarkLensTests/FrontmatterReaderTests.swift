import XCTest
@testable import MarkLens

final class FrontmatterReaderTests: XCTestCase {
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

    func testExtractFrontmatterParsesStructuredValues() throws {
        let markdown = """
        ---
        title: Market Cybersecurity
        draft: false
        priority: 3
        score: 9.5
        tags:
          - security
          - markets
        seo:
          slug: market-cybersecurity
          aliases: [cyber, risk]
        ---
        Body content
        """

        let frontmatter = try XCTUnwrap(FrontmatterReader.extractFrontmatter(from: markdown))
        XCTAssertEqual(frontmatter["title"], .string("Market Cybersecurity"))
        XCTAssertEqual(frontmatter["draft"], .bool(false))
        XCTAssertEqual(frontmatter["priority"], .int(3))
        XCTAssertEqual(frontmatter["score"], .double(9.5))
        XCTAssertEqual(frontmatter["tags"], .array([.string("security"), .string("markets")]))
        XCTAssertEqual(
            frontmatter["seo"],
            .object([
                "slug": .string("market-cybersecurity"),
                "aliases": .array([.string("cyber"), .string("risk")])
            ])
        )
    }

    func testReadFrontmatterSingleFileReturnsSingleMatch() throws {
        let fileURL = tempDirectoryURL.appendingPathComponent("market-cybersecurity.md")
        try """
        ---
        title: Market Cybersecurity
        category: research
        ---
        Notes
        """.write(to: fileURL, atomically: true, encoding: .utf8)

        let result = try FrontmatterReader.readFrontmatter(at: "market-cybersecurity.md", relativeTo: tempDirectoryURL)
        XCTAssertEqual(
            result,
            [
                FrontmatterFileMatch(
                    path: fileURL.path,
                    frontmatter: [
                        "title": .string("Market Cybersecurity"),
                        "category": .string("research")
                    ]
                )
            ]
        )
    }

    func testReadFrontmatterGlobReturnsPathAndFrontmatterPairs() throws {
        let docsURL = tempDirectoryURL.appendingPathComponent("docs", isDirectory: true)
        try FileManager.default.createDirectory(at: docsURL, withIntermediateDirectories: true)

        let firstURL = docsURL.appendingPathComponent("one.md")
        let secondURL = docsURL.appendingPathComponent("two.md")
        let thirdURL = docsURL.appendingPathComponent("ignore.txt")

        try """
        ---
        title: One
        ---
        """.write(to: firstURL, atomically: true, encoding: .utf8)

        try """
        ---
        title: Two
        tags: [a, b]
        ---
        """.write(to: secondURL, atomically: true, encoding: .utf8)

        try """
        ---
        title: Ignored
        ---
        """.write(to: thirdURL, atomically: true, encoding: .utf8)

        let result = try FrontmatterReader.readFrontmatter(at: "*.md", relativeTo: tempDirectoryURL)
        XCTAssertEqual(
            result,
            [
                FrontmatterFileMatch(
                    path: firstURL.path,
                    frontmatter: ["title": .string("One")]
                ),
                FrontmatterFileMatch(
                    path: secondURL.path,
                    frontmatter: [
                        "title": .string("Two"),
                        "tags": .array([.string("a"), .string("b")])
                    ]
                )
            ]
        )
    }

    func testReadFrontmatterReturnsNilWhenFileHasNoFrontmatter() throws {
        let fileURL = tempDirectoryURL.appendingPathComponent("plain.md")
        try "Body only".write(to: fileURL, atomically: true, encoding: .utf8)

        let result = try FrontmatterReader.readFrontmatter(at: "plain.md", relativeTo: tempDirectoryURL)
        XCTAssertEqual(
            result,
            [
                FrontmatterFileMatch(
                    path: fileURL.path,
                    frontmatter: nil
                )
            ]
        )
    }
}
