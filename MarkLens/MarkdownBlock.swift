import Foundation

// MARK: - MarkdownBlock

struct MarkdownBlock: Identifiable, Equatable {
    var id = UUID()
    var kind: MarkdownBlockKind = .unknown
    var content: String  // raw markdown for this block, no surrounding blank lines

    /// True when Enter should insert a newline rather than split the block.
    var preventsEnterSplit: Bool {
        switch kind {
        case .codeFence, .table, .htmlBlock, .frontMatter:
            return true
        default:
            let t = content.trimmingCharacters(in: .whitespaces)
            return t.hasPrefix("```") || t.hasPrefix("|")
        }
    }
}

func parseMarkdownBlocks(_ text: String) -> [MarkdownBlock] {
    MarkdownEngine.buildDocument(from: text).blocks
}

func serializeMarkdownBlocks(_ blocks: [MarkdownBlock]) -> String {
    MarkdownEngine.serialize(blocks: blocks)
}
