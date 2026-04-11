import Foundation
import Markdown

struct MarkdownFrontMatter: Equatable {
    let raw: String
}

enum MarkdownBlockKind: Equatable {
    case frontMatter
    case heading(level: Int)
    case paragraph
    case listItem(task: Bool)
    case codeFence(language: String?)
    case table
    case blockquote
    case thematicBreak
    case htmlBlock
    case imageBlock(ImageInfo)
    case unknown
}

struct ImageInfo: Equatable {
    let alt: String
    let destination: String
    let title: String?
}

struct MarkdownDocumentModel {
    let source: String
    let frontMatter: MarkdownFrontMatter?
    let bodySource: String
    let ast: Document
    let blocks: [MarkdownBlock]
}

enum MarkdownEngine {
    static func classifyBlockSource(_ source: String) -> MarkdownBlockKind {
        classifyBlock(source)
    }

    static func buildDocument(from source: String) -> MarkdownDocumentModel {
        let (frontMatter, bodySource) = splitFrontMatter(from: source)
        let ast = Document(parsing: bodySource)
        var blocks: [MarkdownBlock] = []

        if let frontMatter {
            blocks.append(MarkdownBlock(kind: .frontMatter, content: frontMatter.raw))
        }

        blocks.append(contentsOf: splitBodyBlocks(bodySource).map { bodyBlock in
            MarkdownBlock(kind: classifyBlock(bodyBlock), content: bodyBlock)
        })

        return MarkdownDocumentModel(
            source: source,
            frontMatter: frontMatter,
            bodySource: bodySource,
            ast: ast,
            blocks: blocks
        )
    }

    static func serialize(blocks: [MarkdownBlock]) -> String {
        let frontMatter = blocks.first(where: { $0.kind == .frontMatter })?.content
        let bodyBlocks = blocks.filter { $0.kind != .frontMatter }.map(\.content)

        switch (frontMatter, bodyBlocks.isEmpty) {
        case let (.some(frontMatter), false):
            return frontMatter + "\n\n" + bodyBlocks.joined(separator: "\n\n")
        case let (.some(frontMatter), true):
            return frontMatter
        case (.none, false):
            return bodyBlocks.joined(separator: "\n\n")
        case (.none, true):
            return ""
        }
    }

    static func resolveImageURL(_ destination: String, relativeTo fileURL: URL?) -> URL? {
        if let absoluteURL = URL(string: destination),
           let scheme = absoluteURL.scheme,
           !scheme.isEmpty {
            return absoluteURL
        }

        guard let baseURL = fileURL?.deletingLastPathComponent() else { return nil }
        return URL(fileURLWithPath: destination, relativeTo: baseURL).standardizedFileURL
    }

    private static func classifyBlock(_ source: String) -> MarkdownBlockKind {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .unknown }

        if looksLikeTable(trimmed) {
            return .table
        }
        if looksLikeHTMLBlock(trimmed) {
            return .htmlBlock
        }

        let document = Document(parsing: source)
        guard let child = document.child(at: 0) else { return .paragraph }

        switch child {
        case let heading as Heading:
            return .heading(level: heading.level)
        case is BlockQuote:
            return .blockquote
        case is ThematicBreak:
            return .thematicBreak
        case let codeBlock as CodeBlock:
            let language = codeBlock.language?.isEmpty == false ? codeBlock.language : nil
            return .codeFence(language: language)
        case is HTMLBlock:
            return .htmlBlock
        case let unordered as UnorderedList:
            return .listItem(task: containsTaskListMarkup(in: unordered))
        case let ordered as OrderedList:
            return .listItem(task: containsTaskListMarkup(in: ordered))
        case let paragraph as Paragraph:
            if let image = standaloneImage(in: paragraph) {
                return .imageBlock(image)
            }
            return .paragraph
        default:
            return .unknown
        }
    }

    private static func standaloneImage(in paragraph: Paragraph) -> ImageInfo? {
        guard paragraph.childCount == 1,
              let image = paragraph.child(at: 0) as? Image else { return nil }
        return ImageInfo(
            alt: image.plainText,
            destination: image.source ?? "",
            title: image.title
        )
    }

    private static func containsTaskListMarkup(in markup: Markup) -> Bool {
        let formatted = markup.format()
        return formatted.contains("[ ]") || formatted.lowercased().contains("[x]")
    }

    private static func looksLikeTable(_ trimmed: String) -> Bool {
        trimmed.hasPrefix("|") && trimmed.hasSuffix("|")
    }

    private static func looksLikeHTMLBlock(_ trimmed: String) -> Bool {
        trimmed.hasPrefix("<") && trimmed.hasSuffix(">")
    }

    private static func splitFrontMatter(from source: String) -> (MarkdownFrontMatter?, String) {
        let normalized = source.replacingOccurrences(of: "\r\n", with: "\n")
        guard normalized.hasPrefix("---\n") else { return (nil, source) }

        let lines = normalized.components(separatedBy: "\n")
        guard lines.count > 1 else { return (nil, source) }

        var endIndex: Int?
        for index in 1..<lines.count {
            if lines[index] == "---" || lines[index] == "..." {
                endIndex = index
                break
            }
        }

        guard let endIndex else { return (nil, source) }
        let frontMatterLines = Array(lines[0...endIndex])
        let bodyLines = Array(lines.dropFirst(endIndex + 1))
        let frontMatter = frontMatterLines.joined(separator: "\n")
        let bodySource = bodyLines.joined(separator: "\n")
            .trimmingCharacters(in: CharacterSet(charactersIn: "\n"))

        return (MarkdownFrontMatter(raw: frontMatter), bodySource)
    }

    private static func splitBodyBlocks(_ text: String) -> [String] {
        var blocks: [String] = []
        var currentLines: [String] = []
        var inFencedCode = false

        func flush() {
            var lines = currentLines
            while lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeFirst() }
            while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
            let joined = lines.joined(separator: "\n")
            if !joined.isEmpty {
                blocks.append(joined)
            }
            currentLines = []
        }

        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

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

            if inFencedCode {
                currentLines.append(line)
                continue
            }

            if trimmed.hasPrefix("|") {
                let prevIsTable = currentLines.last?.trimmingCharacters(in: .whitespaces).hasPrefix("|") == true
                    || currentLines.isEmpty
                if !prevIsTable && !currentLines.isEmpty {
                    flush()
                }
                currentLines.append(line)
                continue
            }

            if let last = currentLines.last,
               last.trimmingCharacters(in: .whitespaces).hasPrefix("|"),
               !trimmed.hasPrefix("|") {
                flush()
            }

            if trimmed.isEmpty {
                flush()
            } else {
                currentLines.append(line)
            }
        }

        flush()
        return blocks
    }
}
