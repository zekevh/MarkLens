import XCTest
@testable import MarkLens

final class MarkdownParserTests: XCTestCase {

    // MARK: - parseMarkdownBlocks

    @MainActor func testEmptyString() {
        XCTAssertTrue(parseMarkdownBlocks("").isEmpty)
    }

    @MainActor func testOnlyBlankLines() {
        XCTAssertTrue(parseMarkdownBlocks("\n\n\n").isEmpty)
    }

    @MainActor func testSingleParagraph() {
        let blocks = parseMarkdownBlocks("Hello, world!")
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].content, "Hello, world!")
    }

    @MainActor func testTwoParagraphs() {
        let blocks = parseMarkdownBlocks("First\n\nSecond")
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks[0].content, "First")
        XCTAssertEqual(blocks[1].content, "Second")
    }

    @MainActor func testThreeParagraphs() {
        let blocks = parseMarkdownBlocks("A\n\nB\n\nC")
        XCTAssertEqual(blocks.count, 3)
        XCTAssertEqual(blocks[0].content, "A")
        XCTAssertEqual(blocks[1].content, "B")
        XCTAssertEqual(blocks[2].content, "C")
    }

    @MainActor func testExtraSpacingBetweenBlocksPreservesEmptyBlock() {
        let blocks = parseMarkdownBlocks("A\n\n\n\nB")
        XCTAssertEqual(blocks.map(\.content), ["A", "", "B"])
    }

    @MainActor func testLeadingAndTrailingBlankLinesStripped() {
        let blocks = parseMarkdownBlocks("\n\nHello\n\n")
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].content, "Hello")
    }

    @MainActor func testMultilineBlock() {
        let blocks = parseMarkdownBlocks("Line one\nLine two\nLine three")
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].content, "Line one\nLine two\nLine three")
    }

    @MainActor func testHeadingAndParagraph() {
        let blocks = parseMarkdownBlocks("# Title\n\nSome text.")
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks[0].content, "# Title")
        XCTAssertEqual(blocks[1].content, "Some text.")
    }

    // MARK: - Fenced code blocks

    @MainActor func testFencedCodeBlockIsSingleBlock() {
        let code = "```swift\nlet x = 1\n\nlet y = 2\n```"
        let blocks = parseMarkdownBlocks(code)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].content, code)
    }

    @MainActor func testCodeBlockWithLanguageTag() {
        let code = "```python\nprint('hi')\n```"
        let blocks = parseMarkdownBlocks(code)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].content, code)
    }

    @MainActor func testCodeBlockFollowedByParagraph() {
        let markdown = "```\ncode here\n```\n\nNormal text."
        let blocks = parseMarkdownBlocks(markdown)
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks[0].content, "```\ncode here\n```")
        XCTAssertEqual(blocks[1].content, "Normal text.")
    }

    @MainActor func testParagraphFollowedByCodeBlock() {
        let markdown = "Normal text.\n\n```\ncode here\n```"
        let blocks = parseMarkdownBlocks(markdown)
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks[0].content, "Normal text.")
        XCTAssertEqual(blocks[1].content, "```\ncode here\n```")
    }

    @MainActor func testCodeBlockBlankLinesInsidePreserved() {
        let code = "```\nfirst\n\nsecond\n```"
        let blocks = parseMarkdownBlocks(code)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].content, code)
    }

    // MARK: - Tables

    @MainActor func testTableIsSingleBlock() {
        let table = "| A | B |\n|---|---|\n| 1 | 2 |"
        let blocks = parseMarkdownBlocks(table)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].content, table)
    }

    @MainActor func testTableFollowedByParagraph() {
        let markdown = "| A | B |\n|---|---|\n| 1 | 2 |\n\nText after."
        let blocks = parseMarkdownBlocks(markdown)
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks[0].content, "| A | B |\n|---|---|\n| 1 | 2 |")
        XCTAssertEqual(blocks[1].content, "Text after.")
    }

    @MainActor func testParagraphFollowedByTable() {
        let markdown = "Text before.\n\n| A | B |\n|---|---|\n| 1 | 2 |"
        let blocks = parseMarkdownBlocks(markdown)
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks[0].content, "Text before.")
        XCTAssertEqual(blocks[1].content, "| A | B |\n|---|---|\n| 1 | 2 |")
    }

    // MARK: - Mixed content

    @MainActor func testHeadingCodeBlockParagraph() {
        let markdown = "# Heading\n\n```swift\nlet x = 1\n```\n\nParagraph."
        let blocks = parseMarkdownBlocks(markdown)
        XCTAssertEqual(blocks.count, 3)
        XCTAssertEqual(blocks[0].content, "# Heading")
        XCTAssertEqual(blocks[1].content, "```swift\nlet x = 1\n```")
        XCTAssertEqual(blocks[2].content, "Paragraph.")
    }

    // MARK: - serializeMarkdownBlocks

    @MainActor func testSerializeEmpty() {
        XCTAssertEqual(serializeMarkdownBlocks([]), "")
    }

    @MainActor func testSerializeSingleBlock() {
        let blocks = [MarkdownBlock(content: "Hello")]
        XCTAssertEqual(serializeMarkdownBlocks(blocks), "Hello")
    }

    @MainActor func testSerializeTwoBlocks() {
        let blocks = [MarkdownBlock(content: "First"), MarkdownBlock(content: "Second")]
        XCTAssertEqual(serializeMarkdownBlocks(blocks), "First\n\nSecond")
    }

    @MainActor func testSerializeThreeBlocks() {
        let blocks = [
            MarkdownBlock(content: "A"),
            MarkdownBlock(content: "B"),
            MarkdownBlock(content: "C"),
        ]
        XCTAssertEqual(serializeMarkdownBlocks(blocks), "A\n\nB\n\nC")
    }

    @MainActor func testSerializePreservesEmptyMiddleBlock() {
        let blocks = [
            MarkdownBlock(content: "A"),
            MarkdownBlock(content: ""),
            MarkdownBlock(content: "B"),
        ]
        XCTAssertEqual(serializeMarkdownBlocks(blocks), "A\n\n\n\nB")
    }

    // MARK: - Round-trip

    @MainActor func testRoundTripSimple() {
        let original = "# Title\n\nParagraph one.\n\nParagraph two."
        XCTAssertEqual(serializeMarkdownBlocks(parseMarkdownBlocks(original)), original)
    }

    @MainActor func testRoundTripWithCodeBlock() {
        let original = "```swift\nlet x = 1\n```\n\nSome text."
        XCTAssertEqual(serializeMarkdownBlocks(parseMarkdownBlocks(original)), original)
    }

    @MainActor func testRoundTripWithTable() {
        let original = "Intro.\n\n| A | B |\n|---|---|\n| 1 | 2 |\n\nOutro."
        XCTAssertEqual(serializeMarkdownBlocks(parseMarkdownBlocks(original)), original)
    }

    @MainActor func testRoundTripWithIntentionalEmptyBlock() {
        let original = "Intro\n\n\n\nOutro"
        XCTAssertEqual(serializeMarkdownBlocks(parseMarkdownBlocks(original)), original)
    }

    // MARK: - MarkdownBlock.preventsEnterSplit

    @MainActor func testCodeFencePreventsSplit() {
        XCTAssertTrue(MarkdownBlock(content: "```swift\nlet x = 1\n```").preventsEnterSplit)
    }

    @MainActor func testEmptyCodeFencePreventsSplit() {
        XCTAssertTrue(MarkdownBlock(content: "```\n```").preventsEnterSplit)
    }

    @MainActor func testTablePreventsSplit() {
        XCTAssertTrue(MarkdownBlock(content: "| A | B |\n|---|---|").preventsEnterSplit)
    }

    @MainActor func testParagraphAllowsSplit() {
        XCTAssertFalse(MarkdownBlock(content: "Just some text.").preventsEnterSplit)
    }

    @MainActor func testHeadingAllowsSplit() {
        XCTAssertFalse(MarkdownBlock(content: "# My Heading").preventsEnterSplit)
    }

    @MainActor func testBoldTextAllowsSplit() {
        XCTAssertFalse(MarkdownBlock(content: "**bold** text").preventsEnterSplit)
    }

    @MainActor func testEmptyContentAllowsSplit() {
        XCTAssertFalse(MarkdownBlock(content: "").preventsEnterSplit)
    }
}
