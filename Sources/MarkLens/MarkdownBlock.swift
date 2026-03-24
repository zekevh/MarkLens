import Foundation

// MARK: - MarkdownBlock

struct MarkdownBlock: Identifiable, Equatable {
    var id = UUID()
    var content: String  // raw markdown for this block, no surrounding blank lines

    /// True when Enter should insert a newline rather than split the block.
    var preventsEnterSplit: Bool {
        let t = content.trimmingCharacters(in: .whitespaces)
        return t.hasPrefix("```") || t.hasPrefix("|")
    }
}

// MARK: - Parser

/// Splits a markdown document into logical blocks.
/// Blank lines between blocks are consumed (restored as "\n\n" on serialisation).
/// Fenced code blocks and tables are kept as a single block regardless of blank lines.
func parseMarkdownBlocks(_ text: String) -> [MarkdownBlock] {
    var blocks: [MarkdownBlock] = []
    var currentLines: [String] = []
    var inFencedCode = false

    func flush() {
        // Trim surrounding blank lines inside the accumulated content
        var lines = currentLines
        while lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeFirst() }
        while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true  { lines.removeLast() }
        let joined = lines.joined(separator: "\n")
        if !joined.isEmpty {
            blocks.append(MarkdownBlock(content: joined))
        }
        currentLines = []
    }

    for line in text.components(separatedBy: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        // Fenced code fence toggle
        if trimmed.hasPrefix("```") {
            if inFencedCode {
                currentLines.append(line)
                inFencedCode = false
                flush()
            } else {
                flush()
                inFencedCode = true
                currentLines.append(line)
            }
            continue
        }

        // Inside a code fence — accumulate verbatim
        if inFencedCode {
            currentLines.append(line)
            continue
        }

        // Table rows (starts with |) stay together
        if trimmed.hasPrefix("|") {
            // If we were in a non-table block, flush it first
            let prevIsTable = currentLines.last?.trimmingCharacters(in: .whitespaces).hasPrefix("|") == true
                           || currentLines.isEmpty
            if !prevIsTable && !currentLines.isEmpty {
                flush()
            }
            currentLines.append(line)
            continue
        }

        // If previous line was a table row and this one isn't, flush the table
        if let last = currentLines.last,
           last.trimmingCharacters(in: .whitespaces).hasPrefix("|"),
           !trimmed.hasPrefix("|") {
            flush()
        }

        // Blank line = block boundary
        if trimmed.isEmpty {
            flush()
        } else {
            currentLines.append(line)
        }
    }
    flush()

    return blocks
}

// MARK: - Serializer

func serializeMarkdownBlocks(_ blocks: [MarkdownBlock]) -> String {
    blocks.map(\.content).joined(separator: "\n\n")
}
