import Foundation

@MainActor
final class DocumentSearch {
    private(set) var query = ""
    private(set) var documentText = ""
    private(set) var matches: [NSRange] = []

    var matchCount: Int { matches.count }

    func update(documentText: String, query: String) {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedQuery != self.query || documentText != self.documentText else { return }

        self.query = trimmedQuery
        self.documentText = documentText
        matches = Self.findMatches(in: documentText, query: trimmedQuery)
    }

    func replaceNext(in documentText: String, with replacement: String) -> String? {
        guard let firstMatch = matches.first else { return nil }
        let content = documentText as NSString
        return content.replacingCharacters(in: firstMatch, with: replacement)
    }

    func replaceAll(in documentText: String, with replacement: String) -> String? {
        guard !matches.isEmpty else { return nil }

        let mutable = NSMutableString(string: documentText)
        for range in matches.reversed() {
            mutable.replaceCharacters(in: range, with: replacement)
        }
        return mutable as String
    }

    private static func findMatches(in documentText: String, query: String) -> [NSRange] {
        guard !query.isEmpty else { return [] }

        let content = documentText as NSString
        var searchRange = NSRange(location: 0, length: content.length)
        var ranges: [NSRange] = []

        while searchRange.location < content.length {
            let foundRange = content.range(of: query, options: .caseInsensitive, range: searchRange)
            if foundRange.location == NSNotFound { break }
            ranges.append(foundRange)
            searchRange.location = NSMaxRange(foundRange)
            searchRange.length = content.length - searchRange.location
        }

        return ranges
    }
}
