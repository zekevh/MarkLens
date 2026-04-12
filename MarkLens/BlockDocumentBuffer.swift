import Foundation

struct BlockDocumentBuffer {
    private(set) var text = ""
    private var contentRanges: [NSRange] = []

    mutating func load(blocks: [MarkdownBlock]) -> String {
        rebuild(blocks: blocks)
    }

    mutating func sync(from previous: [MarkdownBlock], to current: [MarkdownBlock]) -> String {
        guard !current.isEmpty else {
            text = ""
            contentRanges = []
            return text
        }

        let idsAreStable =
            previous.count == current.count &&
            previous.count == contentRanges.count &&
            zip(previous, current).allSatisfy { $0.id == $1.id }

        guard idsAreStable else {
            return rebuild(blocks: current)
        }

        let dirtyIndexes = previous.indices.filter { previous[$0].content != current[$0].content }
        guard !dirtyIndexes.isEmpty else { return text }

        let mutable = NSMutableString(string: text)

        for index in dirtyIndexes.sorted() {
            let originalRange = contentRanges[index]
            let replacement = current[index].content
            mutable.replaceCharacters(in: originalRange, with: replacement)

            let newLength = (replacement as NSString).length
            let delta = newLength - originalRange.length
            contentRanges[index].length = newLength

            guard delta != 0 else { continue }
            for nextIndex in contentRanges.indices.dropFirst(index + 1) {
                contentRanges[nextIndex].location += delta
            }
        }

        text = mutable as String
        return text
    }

    @discardableResult
    private mutating func rebuild(blocks: [MarkdownBlock]) -> String {
        var newText = ""
        var newRanges: [NSRange] = []
        newRanges.reserveCapacity(blocks.count)

        for (index, block) in blocks.enumerated() {
            if index > 0 {
                newText += "\n\n"
            }

            let start = (newText as NSString).length
            newText += block.content
            let length = (block.content as NSString).length
            newRanges.append(NSRange(location: start, length: length))
        }

        text = newText
        contentRanges = newRanges
        return newText
    }
}
