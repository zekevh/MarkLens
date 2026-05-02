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

    func testCodeHighlighterHighlightsYAMLKeysAndKeywords() {
        let storage = NSTextStorage(string: """
        title: MarkLens
        draft: true
        tags:
          - notes
        """)

        let fullRange = NSRange(location: 0, length: storage.length)
        CodeHighlighter.apply(to: storage, codeRange: fullRange, language: "yaml")

        let titleRange = (storage.string as NSString).range(of: "title")
        let draftValueRange = (storage.string as NSString).range(of: "true")

        XCTAssertNotNil(storage.attribute(.foregroundColor, at: titleRange.location, effectiveRange: nil))
        XCTAssertNotNil(storage.attribute(.foregroundColor, at: draftValueRange.location, effectiveRange: nil))
    }

    func testBlockPaddingSuppressesH1TopSpacingAfterFrontMatter() {
        let frontMatter = MarkdownBlock(kind: .frontMatter, content: """
        ---
        title: Note
        ---
        """)
        let heading = MarkdownBlock(kind: .heading(level: 1), content: "# Note")

        XCTAssertEqual(rowPadding(for: frontMatter).top, 0)
        XCTAssertEqual(rowPadding(for: heading, suppressHeadingTopSpacing: false).top, 40)
        XCTAssertEqual(rowPadding(for: heading, suppressHeadingTopSpacing: true).top, 0)
    }

    func testSlashCommandCodeBlockTemplateClassifiesAsCodeFence() {
        XCTAssertEqual(
            MarkdownEngine.classifyBlockSource(SlashCommandCatalog.starterCodeBlockTemplate),
            .codeFence(language: nil)
        )
    }

    func testSlashCommandHeadingTemplateClassifiesAsHeading() {
        XCTAssertEqual(
            MarkdownEngine.classifyBlockSource(SlashCommandCatalog.starterHeading2Template + "Section"),
            .heading(level: 2)
        )
    }

    func testSlashCommandTableTemplateClassifiesAsTable() {
        XCTAssertEqual(
            MarkdownEngine.classifyBlockSource(SlashCommandCatalog.starterTableTemplate),
            .table
        )
    }

    func testSlashCommandImageTemplateClassifiesAsImageBlock() {
        XCTAssertEqual(
            MarkdownEngine.classifyBlockSource(SlashCommandCatalog.starterImageTemplate),
            .imageBlock(ImageInfo(alt: "Alt text", destination: "path/to/image.png", title: nil))
        )
    }

    func testSerializeBlocksKeepsFrontMatterAheadOfBody() {
        let blocks = [
            MarkdownBlock(kind: .paragraph, content: "Body"),
            MarkdownBlock(kind: .frontMatter, content: SlashCommandCatalog.starterFrontMatterTemplate),
        ]

        XCTAssertEqual(
            MarkdownEngine.serialize(blocks: blocks),
            SlashCommandCatalog.starterFrontMatterTemplate + "\n\nBody"
        )
    }
}
