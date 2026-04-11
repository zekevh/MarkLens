import XCTest
@testable import MarkLens

@MainActor
final class MarkdownEngineTests: XCTestCase {
    func testBuildDocumentExtractsFrontMatterAndImageBlock() {
        let source = """
        ---
        title: Test
        ---

        ![Diagram](images/diagram.png "Architecture")
        """

        let document = MarkdownEngine.buildDocument(from: source)

        XCTAssertEqual(document.frontMatter?.raw, """
        ---
        title: Test
        ---
        """)
        XCTAssertEqual(document.bodySource, #"![Diagram](images/diagram.png "Architecture")"#)
        XCTAssertEqual(document.blocks.count, 2)
        XCTAssertEqual(document.blocks[0].kind, .frontMatter)
        XCTAssertEqual(
            document.blocks[1].kind,
            .imageBlock(ImageInfo(alt: "Diagram", destination: "images/diagram.png", title: "Architecture"))
        )
    }

    func testClassifyBlockSourceRecognizesTaskListAndBlockquote() {
        XCTAssertEqual(MarkdownEngine.classifyBlockSource("- [x] Done"), .listItem(task: true))
        XCTAssertEqual(MarkdownEngine.classifyBlockSource("> quoted"), .blockquote)
    }

    func testResolveImageURLHandlesRelativeAndAbsoluteDestinations() {
        let fileURL = URL(fileURLWithPath: "/tmp/project/docs/note.md")

        XCTAssertEqual(
            MarkdownEngine.resolveImageURL("images/diagram.png", relativeTo: fileURL),
            URL(fileURLWithPath: "/tmp/project/docs/images/diagram.png")
        )
        XCTAssertEqual(
            MarkdownEngine.resolveImageURL("https://example.com/image.png", relativeTo: fileURL),
            URL(string: "https://example.com/image.png")
        )
    }
}
