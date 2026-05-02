import XCTest
@testable import MarkLens

@MainActor
final class BlocksManagerTests: XCTestCase {
    func testLoadCreatesSingleEmptyBlockForEmptyInput() {
        let manager = BlocksManager()

        manager.load(from: "")

        XCTAssertEqual(manager.blocks.count, 1)
        XCTAssertEqual(manager.blocks[0].content, "")
    }

    func testSplitBlockCreatesTwoBlocks() {
        let manager = BlocksManager()
        let block = MarkdownBlock(content: "HelloWorld")
        manager.blocks = [block]

        manager.splitBlock(id: block.id, originalContent: block.content, at: 5)

        XCTAssertEqual(manager.blocks.map(\.content), ["Hello", "World"])
    }

    func testMergeWithPreviousJoinsBlocksWithNewline() {
        let manager = BlocksManager()
        let first = MarkdownBlock(content: "Alpha")
        let second = MarkdownBlock(content: "Beta")
        manager.blocks = [first, second]

        manager.mergeWithPrevious(second.id, trailing: second.content)

        XCTAssertEqual(manager.blocks.map(\.content), ["Alpha\nBeta"])
    }

    func testIndentAndOutdentSelectedBlocks() {
        let manager = BlocksManager()
        let first = MarkdownBlock(content: "Line 1\nLine 2")
        let second = MarkdownBlock(content: "Another")
        manager.blocks = [first, second]

        manager.indentBlocks(ids: [first.id, second.id], outdent: false)
        XCTAssertEqual(manager.blocks.map(\.content), ["    Line 1\n    Line 2", "    Another"])

        manager.indentBlocks(ids: [first.id, second.id], outdent: true)
        XCTAssertEqual(manager.blocks.map(\.content), ["Line 1\nLine 2", "Another"])
    }

    func testMoveBlockReordersBlocks() {
        let manager = BlocksManager()
        manager.blocks = [
            MarkdownBlock(content: "One"),
            MarkdownBlock(content: "Two"),
            MarkdownBlock(content: "Three"),
        ]

        manager.moveBlock(from: 0, to: 3)

        XCTAssertEqual(manager.blocks.map(\.content), ["Two", "Three", "One"])
    }

    func testSynchronizeDocumentMatchesFullSerializationForSingleBlockEdit() {
        let manager = BlocksManager()
        let source = "# Title\n\nParagraph\n\n- Item"
        manager.load(from: source)

        let previous = manager.blocks
        manager.blocks[1].content = "Updated paragraph"

        let synchronized = manager.synchronizeDocument(from: previous)

        XCTAssertEqual(synchronized, serializeMarkdownBlocks(manager.blocks))
    }

    func testSynchronizeDocumentRebuildsAfterStructuralChange() {
        let manager = BlocksManager()
        manager.load(from: "One\n\nTwo")

        let previous = manager.blocks
        manager.blocks.append(MarkdownBlock(content: "Three"))

        let synchronized = manager.synchronizeDocument(from: previous)

        XCTAssertEqual(synchronized, "One\n\nTwo\n\nThree")
    }

    func testApplyFrontMatterSlashCommandReplacesCurrentBlock() {
        let manager = BlocksManager()
        let source = MarkdownBlock(content: "/fr")
        manager.blocks = [source]

        manager.applySlashCommand(.frontMatter, to: source.id)

        XCTAssertEqual(manager.blocks.count, 1)
        XCTAssertEqual(manager.blocks[0].kind, .frontMatter)
        XCTAssertEqual(manager.blocks[0].content, SlashCommandCatalog.starterFrontMatterTemplate)
    }

    func testApplyCodeBlockSlashCommandReplacesCurrentBlock() {
        let manager = BlocksManager()
        let source = MarkdownBlock(content: "/co")
        manager.blocks = [source]

        manager.applySlashCommand(.codeBlock, to: source.id)

        XCTAssertEqual(manager.blocks.count, 1)
        XCTAssertEqual(manager.blocks[0].kind, .codeFence(language: nil))
        XCTAssertEqual(manager.blocks[0].content, SlashCommandCatalog.starterCodeBlockTemplate)
    }

    func testApplyHeadingSlashCommandReplacesCurrentBlock() {
        let manager = BlocksManager()
        let source = MarkdownBlock(content: "/h1")
        manager.blocks = [source]

        manager.applySlashCommand(.heading1, to: source.id)

        XCTAssertEqual(manager.blocks.count, 1)
        XCTAssertEqual(manager.blocks[0].kind, .heading(level: 1))
        XCTAssertEqual(manager.blocks[0].content, SlashCommandCatalog.starterHeading1Template)
    }

    func testApplyTableSlashCommandReplacesCurrentBlock() {
        let manager = BlocksManager()
        let source = MarkdownBlock(content: "/table")
        manager.blocks = [source]

        manager.applySlashCommand(.table, to: source.id)

        XCTAssertEqual(manager.blocks.count, 1)
        XCTAssertEqual(manager.blocks[0].kind, .table)
        XCTAssertEqual(manager.blocks[0].content, SlashCommandCatalog.starterTableTemplate)
    }

    func testApplyFrontMatterSlashCommandMovesBlockToTop() {
        let manager = BlocksManager()
        let first = MarkdownBlock(content: "Intro")
        let second = MarkdownBlock(content: "/fr")
        manager.blocks = [first, second]

        manager.applySlashCommand(.frontMatter, to: second.id)

        XCTAssertEqual(manager.blocks[0].kind, .frontMatter)
        XCTAssertEqual(manager.blocks[0].id, second.id)
        XCTAssertEqual(manager.blocks[1].id, first.id)
    }

    func testAvailableSlashCommandsHideFrontMatterWhenAlreadyPresent() {
        let manager = BlocksManager()
        let frontMatter = MarkdownBlock(kind: .frontMatter, content: SlashCommandCatalog.starterFrontMatterTemplate)
        let empty = MarkdownBlock(content: "")
        manager.blocks = [frontMatter, empty]

        let commands = manager.availableSlashCommands(for: empty.id)

        XCTAssertFalse(commands.contains(where: { $0.id == .frontMatter }))
        XCTAssertTrue(commands.contains(where: { $0.id == .codeBlock }))
        XCTAssertTrue(commands.contains(where: { $0.id == .heading1 }))
        XCTAssertTrue(commands.contains(where: { $0.id == .table }))
    }
}
