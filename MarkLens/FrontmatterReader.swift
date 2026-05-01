import Foundation

enum FrontmatterReaderError: LocalizedError {
    case relativePathRequiresBase
    case fileNotFound(String)
    case notAFile(String)
    case invalidFrontmatter(String)

    var errorDescription: String? {
        switch self {
        case .relativePathRequiresBase:
            return "Relative paths require an active MarkLens window with an open folder or file."
        case .fileNotFound(let path):
            return "File not found: \(path)"
        case .notAFile(let path):
            return "Expected a file path but found something else: \(path)"
        case .invalidFrontmatter(let message):
            return message
        }
    }
}

enum FrontmatterReadResponse: Equatable, Sendable {
    case single([String: FrontmatterValue]?)
    case bulk([FrontmatterFileMatch])
}

struct FrontmatterFileMatch: Codable, Equatable, Sendable {
    let path: String
    let frontmatter: [String: FrontmatterValue]?
}

enum FrontmatterValue: Codable, Equatable, Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case array([FrontmatterValue])
    case object([String: FrontmatterValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode([String: FrontmatterValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([FrontmatterValue].self) {
            self = .array(value)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .int(let value):
            try container.encode(value)
        case .double(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }
}

enum FrontmatterReader {
    nonisolated static func readFrontmatter(at inputPath: String, relativeTo baseURL: URL?) throws -> FrontmatterReadResponse {
        if containsGlob(in: inputPath) {
            let matches = try resolveGlob(inputPath, relativeTo: baseURL)
            let results = try matches.map { url in
                FrontmatterFileMatch(
                    path: url.path,
                    frontmatter: try extractFrontmatter(fromFileAt: url)
                )
            }
            return .bulk(results)
        }

        let url = try resolveConcretePath(inputPath, relativeTo: baseURL)
        return .single(try extractFrontmatter(fromFileAt: url))
    }

    nonisolated static func extractFrontmatter(fromFileAt url: URL) throws -> [String: FrontmatterValue]? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw FrontmatterReaderError.fileNotFound(url.path)
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            throw FrontmatterReaderError.notAFile(url.path)
        }

        let text = try String(contentsOf: url, encoding: .utf8)
        return try extractFrontmatter(from: text)
    }

    nonisolated static func extractFrontmatter(from markdown: String) throws -> [String: FrontmatterValue]? {
        guard let block = try frontmatterBlock(in: markdown) else {
            return nil
        }

        var parser = SimpleYAMLParser(text: block)
        let value = try parser.parse()
        guard case .object(let object) = value else {
            throw FrontmatterReaderError.invalidFrontmatter("Frontmatter must decode to a key/value object.")
        }
        return object
    }

    nonisolated private static func frontmatterBlock(in markdown: String) throws -> String? {
        let normalized = markdown.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else {
            return nil
        }

        var body: [String] = []
        for line in lines.dropFirst() {
            if line.trimmingCharacters(in: .whitespaces) == "---" {
                return body.joined(separator: "\n")
            }
            body.append(line)
        }

        throw FrontmatterReaderError.invalidFrontmatter("Frontmatter opening delimiter is missing a closing --- delimiter.")
    }

    nonisolated private static func resolveConcretePath(_ inputPath: String, relativeTo baseURL: URL?) throws -> URL {
        let url = try resolvePath(inputPath, relativeTo: baseURL)
        return url.standardizedFileURL
    }

    nonisolated private static func resolveGlob(_ inputPath: String, relativeTo baseURL: URL?) throws -> [URL] {
        let (searchRoot, relativePattern, basenameOnly) = try globSearchRoot(for: inputPath, relativeTo: baseURL)
        guard FileManager.default.fileExists(atPath: searchRoot.path) else {
            return []
        }

        let enumerator = FileManager.default.enumerator(
            at: searchRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )

        var matches: [URL] = []
        while let candidate = enumerator?.nextObject() as? URL {
            let values = try candidate.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }

            let relativePath = candidate.path.replacingOccurrences(of: searchRoot.path + "/", with: "")
            let target = basenameOnly ? candidate.lastPathComponent : relativePath
            if globMatches(target, pattern: relativePattern, basenameOnly: basenameOnly) {
                matches.append(candidate.standardizedFileURL)
            }
        }

        return matches.sorted { $0.path < $1.path }
    }

    nonisolated private static func globSearchRoot(for inputPath: String, relativeTo baseURL: URL?) throws -> (URL, String, Bool) {
        let absolute = inputPath.hasPrefix("/")
        let normalized = inputPath.replacingOccurrences(of: "\\", with: "/")
        let components = normalized.split(separator: "/", omittingEmptySubsequences: false).map(String.init)

        var firstGlobIndex: Int?
        for (index, component) in components.enumerated() where containsGlob(in: component) {
            firstGlobIndex = index
            break
        }

        let globIndex = firstGlobIndex ?? 0
        let prefixComponents = Array(components.prefix(globIndex))
        let patternComponents = Array(components.dropFirst(globIndex)).filter { !$0.isEmpty }
        let pattern = patternComponents.joined(separator: "/")

        let searchRoot: URL
        if absolute {
            let prefixPath = "/" + prefixComponents.filter { !$0.isEmpty }.joined(separator: "/")
            searchRoot = URL(fileURLWithPath: prefixPath.isEmpty ? "/" : prefixPath, isDirectory: true)
        } else {
            let base = try baseDirectory(for: baseURL)
            if prefixComponents.isEmpty {
                searchRoot = base
            } else {
                searchRoot = prefixComponents.reduce(base) { partial, component in
                    partial.appendingPathComponent(component, isDirectory: true)
                }
            }
        }

        let basenameOnly = !pattern.contains("/")
        return (searchRoot.standardizedFileURL, pattern, basenameOnly)
    }

    nonisolated private static func resolvePath(_ inputPath: String, relativeTo baseURL: URL?) throws -> URL {
        if inputPath.hasPrefix("/") {
            return URL(fileURLWithPath: inputPath)
        }

        let base = try baseDirectory(for: baseURL)
        return base.appendingPathComponent(inputPath)
    }

    nonisolated private static func baseDirectory(for baseURL: URL?) throws -> URL {
        if let baseURL {
            return baseURL.standardizedFileURL
        }
        throw FrontmatterReaderError.relativePathRequiresBase
    }

    nonisolated private static func containsGlob(in text: String) -> Bool {
        text.contains("*") || text.contains("?") || text.contains("[")
    }

    nonisolated private static func globMatches(_ text: String, pattern: String, basenameOnly: Bool) -> Bool {
        let regex = globRegex(for: pattern, basenameOnly: basenameOnly)
        return text.range(of: regex, options: .regularExpression) != nil
    }

    nonisolated private static func globRegex(for pattern: String, basenameOnly: Bool) -> String {
        var result = "^"
        let chars = Array(pattern)
        var index = 0

        while index < chars.count {
            let char = chars[index]
            switch char {
            case "*":
                let isDoubleStar = index + 1 < chars.count && chars[index + 1] == "*"
                if isDoubleStar {
                    result += ".*"
                    index += 1
                } else {
                    result += basenameOnly ? ".*" : "[^/]*"
                }
            case "?":
                result += basenameOnly ? "." : "[^/]"
            case ".":
                result += "\\."
            case "\\":
                result += "\\\\"
            case "+", "(", ")", "{", "}", "^", "$", "|":
                result += "\\\(char)"
            case "[":
                if let closing = chars[index...].firstIndex(of: "]"), closing > index {
                    let range = chars[index...closing]
                    result += String(range)
                    index = closing
                } else {
                    result += "\\["
                }
            default:
                result.append(char)
            }
            index += 1
        }

        result += "$"
        return result
    }
}

private struct YAMLLine {
    let indent: Int
    let text: String
}

private struct SimpleYAMLParser {
    private let lines: [YAMLLine]
    private var index = 0

    nonisolated init(text: String) {
        self.lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
            .compactMap { rawLine in
                let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }

                let indent = rawLine.prefix { $0 == " " }.count
                return YAMLLine(indent: indent, text: String(rawLine.dropFirst(indent)))
            }
    }

    nonisolated mutating func parse() throws -> FrontmatterValue {
        guard !lines.isEmpty else {
            return .object([:])
        }
        let value = try parseBlock(expectedIndent: lines[0].indent)
        guard index == lines.count else {
            throw FrontmatterReaderError.invalidFrontmatter("Unexpected trailing YAML content in frontmatter.")
        }
        return value
    }

    nonisolated private mutating func parseBlock(expectedIndent: Int) throws -> FrontmatterValue {
        guard index < lines.count else {
            return .null
        }

        if lines[index].indent < expectedIndent {
            return .null
        }

        if lines[index].text.hasPrefix("-") {
            return try parseSequence(expectedIndent: expectedIndent)
        }
        return try parseMapping(expectedIndent: expectedIndent)
    }

    nonisolated private mutating func parseMapping(expectedIndent: Int) throws -> FrontmatterValue {
        var object: [String: FrontmatterValue] = [:]

        while index < lines.count {
            let line = lines[index]
            if line.indent < expectedIndent { break }
            if line.indent > expectedIndent {
                throw FrontmatterReaderError.invalidFrontmatter("Invalid indentation in frontmatter mapping.")
            }
            if line.text.hasPrefix("-") { break }

            guard let (key, remainder) = splitKeyValue(line.text) else {
                throw FrontmatterReaderError.invalidFrontmatter("Invalid YAML mapping line: \(line.text)")
            }

            index += 1
            if remainder.isEmpty {
                if index < lines.count, lines[index].indent > expectedIndent {
                    object[key] = try parseBlock(expectedIndent: lines[index].indent)
                } else {
                    object[key] = .null
                }
            } else {
                object[key] = try parseInlineValue(remainder)
            }
        }

        return .object(object)
    }

    nonisolated private mutating func parseSequence(expectedIndent: Int) throws -> FrontmatterValue {
        var array: [FrontmatterValue] = []

        while index < lines.count {
            let line = lines[index]
            if line.indent < expectedIndent { break }
            if line.indent > expectedIndent {
                throw FrontmatterReaderError.invalidFrontmatter("Invalid indentation in frontmatter sequence.")
            }
            guard line.text.hasPrefix("-") else { break }

            let remainder = String(line.text.dropFirst()).trimmingCharacters(in: .whitespaces)
            index += 1

            if remainder.isEmpty {
                if index < lines.count, lines[index].indent > expectedIndent {
                    array.append(try parseBlock(expectedIndent: lines[index].indent))
                } else {
                    array.append(.null)
                }
                continue
            }

            if let (key, valueText) = splitKeyValue(remainder) {
                var object: [String: FrontmatterValue] = [:]
                object[key] = valueText.isEmpty ? .null : (try parseInlineValue(valueText))

                if valueText.isEmpty, index < lines.count, lines[index].indent > expectedIndent {
                    object[key] = try parseBlock(expectedIndent: lines[index].indent)
                }

                if index < lines.count, lines[index].indent > expectedIndent {
                    let nested = try parseBlock(expectedIndent: lines[index].indent)
                    guard case .object(let nestedObject) = nested else {
                        throw FrontmatterReaderError.invalidFrontmatter("List item mappings must continue as objects.")
                    }
                    for (nestedKey, nestedValue) in nestedObject {
                        object[nestedKey] = nestedValue
                    }
                }

                array.append(.object(object))
                continue
            }

            array.append(try parseInlineValue(remainder))
        }

        return .array(array)
    }

    nonisolated private func parseInlineValue(_ text: String) throws -> FrontmatterValue {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            return .null
        }

        if trimmed == "null" || trimmed == "~" {
            return .null
        }
        if trimmed == "true" {
            return .bool(true)
        }
        if trimmed == "false" {
            return .bool(false)
        }
        if let intValue = Int(trimmed) {
            return .int(intValue)
        }
        if let doubleValue = Double(trimmed), trimmed.contains(".") {
            return .double(doubleValue)
        }
        if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
            return .array(try parseInlineArray(String(trimmed.dropFirst().dropLast())))
        }
        if trimmed.hasPrefix("{") && trimmed.hasSuffix("}") {
            return .object(try parseInlineObject(String(trimmed.dropFirst().dropLast())))
        }
        if (trimmed.hasPrefix("\"") && trimmed.hasSuffix("\"")) || (trimmed.hasPrefix("'") && trimmed.hasSuffix("'")) {
            return .string(unquote(trimmed))
        }
        return .string(trimmed)
    }

    nonisolated private func parseInlineArray(_ text: String) throws -> [FrontmatterValue] {
        let parts = splitTopLevel(text, separator: ",")
        return try parts.map { part in
            try parseInlineValue(part)
        }
    }

    nonisolated private func parseInlineObject(_ text: String) throws -> [String: FrontmatterValue] {
        var object: [String: FrontmatterValue] = [:]
        for part in splitTopLevel(text, separator: ",") {
            guard let (key, value) = splitKeyValue(part) else {
                throw FrontmatterReaderError.invalidFrontmatter("Invalid inline object entry: \(part)")
            }
            object[key] = try parseInlineValue(value)
        }
        return object
    }

    nonisolated private func splitTopLevel(_ text: String, separator: Character) -> [String] {
        var result: [String] = []
        var current = ""
        var squareDepth = 0
        var curlyDepth = 0
        var quote: Character?
        var previous: Character?

        for char in text {
            if let activeQuote = quote {
                current.append(char)
                if char == activeQuote, previous != "\\" {
                    quote = nil
                }
                previous = char
                continue
            }

            switch char {
            case "\"", "'":
                quote = char
                current.append(char)
            case "[":
                squareDepth += 1
                current.append(char)
            case "]":
                squareDepth = max(0, squareDepth - 1)
                current.append(char)
            case "{":
                curlyDepth += 1
                current.append(char)
            case "}":
                curlyDepth = max(0, curlyDepth - 1)
                current.append(char)
            default:
                if char == separator && squareDepth == 0 && curlyDepth == 0 {
                    result.append(current.trimmingCharacters(in: .whitespaces))
                    current = ""
                } else {
                    current.append(char)
                }
            }
            previous = char
        }

        let trimmed = current.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            result.append(trimmed)
        }
        return result
    }

    nonisolated private func splitKeyValue(_ text: String) -> (String, String)? {
        var squareDepth = 0
        var curlyDepth = 0
        var quote: Character?
        let characters = Array(text)

        for (idx, char) in characters.enumerated() {
            if let activeQuote = quote {
                if char == activeQuote, (idx == 0 || characters[idx - 1] != "\\") {
                    quote = nil
                }
                continue
            }

            switch char {
            case "\"", "'":
                quote = char
            case "[":
                squareDepth += 1
            case "]":
                squareDepth = max(0, squareDepth - 1)
            case "{":
                curlyDepth += 1
            case "}":
                curlyDepth = max(0, curlyDepth - 1)
            case ":" where squareDepth == 0 && curlyDepth == 0:
                let key = String(characters[..<idx]).trimmingCharacters(in: .whitespaces)
                let valueStart = idx + 1
                let value = valueStart < characters.count
                    ? String(characters[valueStart...]).trimmingCharacters(in: .whitespaces)
                    : ""
                guard !key.isEmpty else { return nil }
                return (key, value)
            default:
                break
            }
        }

        return nil
    }

    nonisolated private func unquote(_ text: String) -> String {
        let body = String(text.dropFirst().dropLast())
        if text.hasPrefix("'") {
            return body.replacingOccurrences(of: "''", with: "'")
        }

        var result = ""
        var escaped = false
        for char in body {
            if escaped {
                switch char {
                case "n":
                    result.append("\n")
                case "t":
                    result.append("\t")
                case "\"":
                    result.append("\"")
                case "\\":
                    result.append("\\")
                default:
                    result.append(char)
                }
                escaped = false
                continue
            }

            if char == "\\" {
                escaped = true
            } else {
                result.append(char)
            }
        }
        if escaped {
            result.append("\\")
        }
        return result
    }
}
