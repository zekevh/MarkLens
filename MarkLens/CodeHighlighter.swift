import AppKit

// MARK: - CodeHighlighter
//
// Applies syntax highlighting to a fenced code block range within an NSTextStorage.
// Applied in ascending priority order so comments always win over strings, which win over keywords.

@MainActor
enum CodeHighlighter {

    static func apply(to storage: NSTextStorage, codeRange: NSRange, language: String) {
        guard codeRange.length > 0 else { return }
        applyKeywords(storage, codeRange, language)
        applyNumbers(storage, codeRange)
        applyStrings(storage, codeRange, language)
        applyComments(storage, codeRange, language)
    }

    // MARK: - Token colors

    private enum Colors {
        static let keyword = NSColor.systemPurple
        static let string  = NSColor.systemOrange
        static let comment: NSColor = {
            NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                    ? NSColor(red: 0.38, green: 0.72, blue: 0.40, alpha: 1)
                    : NSColor(red: 0.15, green: 0.52, blue: 0.18, alpha: 1)
            }
        }()
        static let number  = NSColor.systemBlue
    }

    // MARK: - Appliers

    private static func applyKeywords(_ storage: NSTextStorage, _ range: NSRange, _ language: String) {
        let words = keywords(for: language)
        guard !words.isEmpty else { return }
        let pattern = #"\b("# + words.joined(separator: "|") + #")\b"#
        run(pattern, storage, range, Colors.keyword)
    }

    private static func applyNumbers(_ storage: NSTextStorage, _ range: NSRange) {
        run(#"\b0x[0-9a-fA-F]+\b"#, storage, range, Colors.number)
        run(#"\b\d+\.?\d*([eE][+-]?\d+)?\b"#, storage, range, Colors.number)
    }

    private static func applyStrings(_ storage: NSTextStorage, _ range: NSRange, _ language: String) {
        run(#""(?:[^"\\]|\\.)*""#, storage, range, Colors.string)
        if !["swift"].contains(language) {
            run(#"'(?:[^'\\]|\\.)*'"#, storage, range, Colors.string)
        }
        if ["javascript", "js", "typescript", "ts", "jsx", "tsx"].contains(language) {
            run(#"`[^`]*`"#, storage, range, Colors.string)
        }
    }

    private static func applyComments(_ storage: NSTextStorage, _ range: NSRange, _ language: String) {
        switch language {
        case "python", "py", "bash", "sh", "shell", "zsh", "ruby", "rb", "yaml", "yml", "toml":
            run(#"#[^\n]*"#, storage, range, Colors.comment)
        case "html", "xml":
            run(#"<!--[\s\S]*?-->"#, storage, range, Colors.comment)
        case "sql":
            run(#"--[^\n]*"#, storage, range, Colors.comment)
            run(#"/\*[\s\S]*?\*/"#, storage, range, Colors.comment)
        default: // C-like: //, /* */
            run(#"//[^\n]*"#, storage, range, Colors.comment)
            run(#"/\*[\s\S]*?\*/"#, storage, range, Colors.comment)
        }
    }

    // MARK: - Helpers

    @MainActor private static var regexCache: [String: NSRegularExpression] = [:]

    private static func run(_ pattern: String, _ storage: NSTextStorage, _ range: NSRange, _ color: NSColor) {
        let regex: NSRegularExpression
        if let cached = regexCache[pattern] {
            regex = cached
        } else {
            guard let r = try? NSRegularExpression(pattern: pattern) else { return }
            regexCache[pattern] = r
            regex = r
        }
        regex.enumerateMatches(in: storage.string, range: range) { m, _, _ in
            guard let m else { return }
            storage.addAttribute(.foregroundColor, value: color, range: m.range)
        }
    }

    // MARK: - Keyword lists

    private static func keywords(for language: String) -> [String] {
        switch language {
        case "swift":
            return ["class","struct","enum","protocol","extension","func","var","let",
                    "if","else","guard","switch","case","default","for","while","repeat",
                    "return","throw","throws","rethrows","try","catch","async","await","actor",
                    "import","typealias","associatedtype","where","in","is","as","nil",
                    "true","false","self","Self","super","init","deinit","subscript",
                    "get","set","willSet","didSet","lazy","static","final","override",
                    "private","public","internal","fileprivate","open","mutating","inout",
                    "weak","unowned","some","any","nonisolated","isolated","consuming","borrowing"]
        case "python", "py":
            return ["def","class","if","elif","else","for","while","return","import",
                    "from","as","with","try","except","finally","raise","pass","break",
                    "continue","lambda","yield","async","await","and","or","not","in",
                    "is","True","False","None","global","nonlocal","del","assert","print","type"]
        case "javascript", "js", "typescript", "ts", "jsx", "tsx":
            return ["const","let","var","function","class","extends","return","if","else",
                    "for","while","do","switch","case","default","break","continue",
                    "import","export","from","async","await","try","catch","finally",
                    "throw","new","delete","typeof","instanceof","in","of","true","false",
                    "null","undefined","this","super","void","yield","interface","type",
                    "enum","implements","abstract","readonly","static","public","private","protected","satisfies"]
        case "go":
            return ["func","var","const","type","struct","interface","map","chan","range",
                    "for","if","else","switch","case","default","return","break","continue",
                    "goto","import","package","defer","go","select","fallthrough",
                    "true","false","nil","new","make","len","cap","append","delete","error","any"]
        case "rust", "rs":
            return ["fn","let","mut","const","static","struct","enum","trait","impl","use",
                    "mod","pub","crate","self","Self","super","if","else","match","for",
                    "while","loop","return","break","continue","where","async","await",
                    "move","ref","in","as","true","false","type","dyn","extern","unsafe"]
        case "java":
            return ["class","interface","enum","extends","implements","new","return","if",
                    "else","for","while","do","switch","case","default","break","continue",
                    "try","catch","finally","throw","throws","import","package","public",
                    "private","protected","static","final","abstract","void","null","true","false","this","super","record","sealed","permits"]
        case "kotlin", "kt":
            return ["fun","class","interface","object","val","var","if","else","when","for",
                    "while","do","return","break","continue","try","catch","finally","throw",
                    "import","package","is","as","in","null","true","false","this","super",
                    "override","open","abstract","sealed","data","companion","suspend","inline","reified"]
        case "bash", "sh", "shell", "zsh":
            return ["if","then","else","elif","fi","for","while","do","done","case","in",
                    "esac","function","return","export","local","echo","exit","source","alias","cd","true","false"]
        case "sql":
            return ["select","from","where","and","or","not","insert","into","values","update",
                    "set","delete","create","table","drop","alter","add","index","join","left",
                    "right","inner","outer","on","group","by","order","having","distinct","as",
                    "null","is","in","like","between","exists","union","all","limit","offset",
                    "primary","key","foreign","references","constraint","default","unique","with",
                    "SELECT","FROM","WHERE","AND","OR","NOT","INSERT","INTO","VALUES","UPDATE",
                    "SET","DELETE","CREATE","TABLE","DROP","ALTER","ADD","INDEX","JOIN","LEFT",
                    "RIGHT","INNER","OUTER","ON","GROUP","BY","ORDER","HAVING","DISTINCT","AS",
                    "NULL","IS","IN","LIKE","BETWEEN","EXISTS","UNION","ALL","LIMIT","OFFSET",
                    "PRIMARY","KEY","FOREIGN","REFERENCES","CONSTRAINT","DEFAULT","UNIQUE","WITH"]
        case "json":
            return ["true","false","null"]
        case "css", "scss", "less":
            return []
        default:
            return ["if","else","for","while","do","return","break","continue",
                    "switch","case","default","true","false","null","void","new","class","import"]
        }
    }
}
