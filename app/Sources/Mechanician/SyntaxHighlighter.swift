import SwiftUI
import AppKit

private func adaptiveSyntaxColor(light: NSColor, dark: NSColor) -> NSColor {
    NSColor(name: nil) { appearance in
        appearance.mechanicianIsDark ? dark : light
    }
}

/// Source and diff colors are content, not decorative system accents. Each Light value clears
/// 4.5:1 on white and on both diff-row tints; Dark values clear the same threshold on the raised
/// code surface and tinted rows. Keeping the underlying NSColors visible to tests prevents a
/// pleasant Dark palette from silently turning into pastel-on-white again.
enum SyntaxHighlightPalette {
    private static func rgb(_ r: Int, _ g: Int, _ b: Int) -> NSColor {
        NSColor(
            srgbRed: CGFloat(r) / 255,
            green: CGFloat(g) / 255,
            blue: CGFloat(b) / 255,
            alpha: 1)
    }

    static let comment = adaptiveSyntaxColor(
        light: rgb(0x59, 0x63, 0x6F),
        dark: rgb(0xA6, 0xAD, 0xB8))
    static let string = adaptiveSyntaxColor(
        light: rgb(0x24, 0x6B, 0x2A),
        dark: rgb(0x86, 0xD6, 0x82))
    static let number = adaptiveSyntaxColor(
        light: rgb(0x98, 0x50, 0x00),
        dark: rgb(0xF0, 0xB4, 0x5F))
    static let keyword = adaptiveSyntaxColor(
        light: rgb(0x78, 0x3C, 0x99),
        dark: rgb(0xDA, 0x8E, 0xE2))
    static let base = NSColor.labelColor

    static let additionMarker = adaptiveSyntaxColor(
        light: rgb(0x21, 0x6B, 0x27),
        dark: rgb(0x8D, 0xDE, 0x88))
    static let deletionMarker = adaptiveSyntaxColor(
        light: rgb(0xB3, 0x26, 0x1E),
        dark: rgb(0xFF, 0x8A, 0x80))
    static let hunk = adaptiveSyntaxColor(
        light: rgb(0x17, 0x4E, 0xA6),
        dark: rgb(0x8A, 0xB4, 0xFF))
    static let header = adaptiveSyntaxColor(
        light: rgb(0x5E, 0x65, 0x70),
        dark: rgb(0xB5, 0xBB, 0xC4))
    static let additionBackground = adaptiveSyntaxColor(
        light: rgb(0xE1, 0xF3, 0xE2),
        dark: rgb(0x18, 0x36, 0x1C))
    static let deletionBackground = adaptiveSyntaxColor(
        light: rgb(0xFB, 0xE2, 0xDF),
        dark: rgb(0x43, 0x24, 0x21))
}

/// Dependency-free, Nord-themed syntax highlighting. A single-pass scanner colours
/// comments, strings, numbers, and language keywords — enough to make code blocks and
/// file previews readable without pulling in a highlighting engine. Unknown languages
/// fall back to a generic profile; non-code content should pass `language == nil`
/// upstream so prose isn't tinted.
enum SyntaxHighlighter {
    private static let cComment = Color(nsColor: SyntaxHighlightPalette.comment)
    private static let cString = Color(nsColor: SyntaxHighlightPalette.string)
    private static let cNumber = Color(nsColor: SyntaxHighlightPalette.number)
    private static let cKeyword = Color(nsColor: SyntaxHighlightPalette.keyword)
    private static let cBase = Color(nsColor: SyntaxHighlightPalette.base)

    /// Above this size, skip tokenizing (mid-stream a huge block re-highlights per delta).
    private static let maxHighlightChars = 20_000

    static func highlight(_ code: String, language: String?, fontSize: CGFloat) -> AttributedString {
        let font = Font.system(size: fontSize, design: .monospaced)
        func plainAll() -> AttributedString {
            var a = AttributedString(code); a.font = font; a.foregroundColor = cBase; return a
        }
        guard code.count <= maxHighlightChars else { return plainAll() }
        let p = profile(for: language)

        var out = AttributedString()
        var plain = ""
        func flush() {
            guard !plain.isEmpty else { return }
            var a = AttributedString(plain); a.font = font; a.foregroundColor = cBase
            out.append(a); plain = ""
        }
        func emit(_ s: String, _ color: Color) {
            flush()
            var a = AttributedString(s); a.font = font; a.foregroundColor = color
            out.append(a)
        }

        let chars = Array(code)
        let lineCommentTokens = p.lineComment.map(Array.init)
        let n = chars.count
        var i = 0
        while i < n {
            let c = chars[i]

            // Line comment (//, #, --, …).
            if lineCommentTokens.contains(where: { startsWith(chars, i, $0) }) {
                let start = i
                while i < n && chars[i] != "\n" { i += 1 }
                emit(String(chars[start..<i]), cComment); continue
            }
            // Block comment (/* … */).
            if p.blockComment, c == "/", i + 1 < n, chars[i + 1] == "*" {
                let start = i; i += 2
                while i < n && !(chars[i] == "*" && i + 1 < n && chars[i + 1] == "/") { i += 1 }
                i = min(i + 2, n)
                emit(String(chars[start..<i]), cComment); continue
            }
            // String literal (won't run past a newline if unterminated).
            if p.strings.contains(c) {
                let quote = c; let start = i; i += 1
                while i < n {
                    if chars[i] == "\\" { i += 2; continue }
                    if chars[i] == quote { i += 1; break }
                    if chars[i] == "\n" { break }
                    i += 1
                }
                emit(String(chars[min(start, n)..<min(i, n)]), cString); continue
            }
            // Identifier / keyword.
            if c.isLetter || c == "_" {
                let start = i
                while i < n && (chars[i].isLetter || chars[i].isNumber || chars[i] == "_") { i += 1 }
                let word = String(chars[start..<i])
                let key = p.caseInsensitive ? word.lowercased() : word
                if p.keywords.contains(key) { emit(word, cKeyword) } else { plain += word }
                continue
            }
            // Number literal (decimal or 0x…). Identifiers are matched first, so this
            // never fires inside a name like `x2`.
            if c.isNumber {
                let start = i
                if c == "0", i + 1 < n, chars[i + 1] == "x" || chars[i + 1] == "X" {
                    i += 2
                    while i < n && chars[i].isHexDigit { i += 1 }
                } else {
                    while i < n && (chars[i].isNumber || chars[i] == "." || chars[i] == "_") { i += 1 }
                }
                emit(String(chars[start..<i]), cNumber); continue
            }
            plain.append(c); i += 1
        }
        flush()
        return out
    }

    /// A diff line with syntax highlighting layered under the add/remove signal (GitHub style): a
    /// colored +/- marker plus the returned background tint convey added/removed, while the
    /// code keeps its language colors instead of flat monochrome red/green. Per-line highlighting.
    static func diffLine(_ line: String, language: String?, fontSize: CGFloat) -> (text: AttributedString, background: Color) {
        let mono = Font.system(size: fontSize, design: .monospaced)
        func run(_ s: String, _ color: Color) -> AttributedString {
            var a = AttributedString(s); a.font = mono; a.foregroundColor = color; return a
        }
        if line.hasPrefix("@@") {
            return (run(line, Color(nsColor: SyntaxHighlightPalette.hunk)), .clear)
        }
        if line.hasPrefix("+++") || line.hasPrefix("---")
            || line.hasPrefix("diff ") || line.hasPrefix("index ") {                 // file headers
            return (run(line, Color(nsColor: SyntaxHighlightPalette.header)), .clear)
        }
        if line.hasPrefix("+") {
            var a = run("+", Color(nsColor: SyntaxHighlightPalette.additionMarker))
            a.append(highlight(String(line.dropFirst()), language: language, fontSize: fontSize))
            return (a, Color(nsColor: SyntaxHighlightPalette.additionBackground))
        }
        if line.hasPrefix("-") {
            var a = run("-", Color(nsColor: SyntaxHighlightPalette.deletionMarker))
            a.append(highlight(String(line.dropFirst()), language: language, fontSize: fontSize))
            return (a, Color(nsColor: SyntaxHighlightPalette.deletionBackground))
        }
        return (highlight(line, language: language, fontSize: fontSize), .clear)     // context
    }

    private static func startsWith(
        _ chars: [Character],
        _ i: Int,
        _ token: [Character]
    ) -> Bool {
        guard i + token.count <= chars.count else { return false }
        for k in 0..<token.count where chars[i + k] != token[k] { return false }
        return true
    }

    // MARK: Language profiles

    private struct Profile {
        var lineComment: [String]
        var blockComment: Bool
        var strings: Set<Character>
        var keywords: Set<String>
        var caseInsensitive = false
    }

    /// Map a fence tag or file extension to a canonical language key, or nil for
    /// content that shouldn't be highlighted as code (plain text, markdown, logs).
    static func canonicalLanguage(_ raw: String?) -> String? {
        guard let r = raw?.lowercased().trimmingCharacters(in: .whitespaces), !r.isEmpty else { return nil }
        switch r {
        case "swift": return "swift"
        case "js", "javascript", "mjs", "cjs", "jsx", "node": return "javascript"
        case "ts", "typescript", "tsx": return "typescript"
        case "py", "python", "python3": return "python"
        case "rb", "ruby": return "ruby"
        case "go", "golang": return "go"
        case "rs", "rust": return "rust"
        case "java": return "java"
        case "kt", "kotlin", "scala", "cs", "csharp", "php": return "default" // code, generic set
        case "c", "h": return "c"
        case "cpp", "cc", "cxx", "hpp", "hxx", "c++", "objc", "objcpp", "m", "mm": return "cpp"
        case "sh", "bash", "zsh", "shell", "shellscript", "console", "fish": return "shell"
        case "sql", "postgres", "postgresql", "mysql": return "sql"
        case "json", "json5", "jsonc": return "json"
        case "yaml", "yml": return "yaml"
        case "toml", "ini", "cfg": return "toml"
        // Not treated as code for highlighting purposes.
        case "txt", "text", "md", "markdown", "log", "csv", "tsv", "diff", "patch", "plaintext":
            return nil
        default:
            // Unknown fence tag: highlight generically rather than as prose.
            return "default"
        }
    }

    private static func profile(for language: String?) -> Profile {
        switch canonicalLanguage(language) ?? "default" {
        case "swift":
            return Profile(lineComment: ["//"], blockComment: true, strings: ["\""], keywords: kwSwift)
        case "javascript", "typescript":
            return Profile(lineComment: ["//"], blockComment: true, strings: ["\"", "'", "`"], keywords: kwJS)
        case "python":
            return Profile(lineComment: ["#"], blockComment: false, strings: ["\"", "'"], keywords: kwPython)
        case "ruby":
            return Profile(lineComment: ["#"], blockComment: false, strings: ["\"", "'"], keywords: kwRuby)
        case "go":
            return Profile(lineComment: ["//"], blockComment: true, strings: ["\"", "`"], keywords: kwGo)
        case "rust":
            return Profile(lineComment: ["//"], blockComment: true, strings: ["\""], keywords: kwRust)
        case "java":
            return Profile(lineComment: ["//"], blockComment: true, strings: ["\"", "'"], keywords: kwJava)
        case "c":
            return Profile(lineComment: ["//"], blockComment: true, strings: ["\"", "'"], keywords: kwC)
        case "cpp":
            return Profile(lineComment: ["//"], blockComment: true, strings: ["\"", "'"], keywords: kwCpp)
        case "shell":
            return Profile(lineComment: ["#"], blockComment: false, strings: ["\"", "'"], keywords: kwShell)
        case "sql":
            return Profile(lineComment: ["--"], blockComment: true, strings: ["'", "\""], keywords: kwSQL, caseInsensitive: true)
        case "json":
            return Profile(lineComment: [], blockComment: false, strings: ["\""], keywords: ["true", "false", "null"])
        case "yaml":
            return Profile(lineComment: ["#"], blockComment: false, strings: ["\"", "'"], keywords: ["true", "false", "null", "yes", "no", "on", "off"])
        case "toml":
            return Profile(lineComment: ["#"], blockComment: false, strings: ["\"", "'"], keywords: ["true", "false"])
        default:
            return Profile(lineComment: ["//", "#"], blockComment: true, strings: ["\"", "'", "`"], keywords: kwGeneric)
        }
    }

    // MARK: Keyword sets

    private static let kwSwift: Set<String> = ["let", "var", "func", "class", "struct", "enum", "protocol", "extension", "if", "else", "guard", "switch", "case", "default", "for", "while", "repeat", "in", "return", "break", "continue", "do", "try", "catch", "throw", "throws", "rethrows", "defer", "self", "Self", "super", "init", "deinit", "static", "final", "public", "private", "internal", "fileprivate", "open", "lazy", "weak", "unowned", "mutating", "nonmutating", "override", "convenience", "required", "associatedtype", "typealias", "where", "as", "is", "nil", "true", "false", "import", "some", "any", "await", "async", "actor", "inout", "subscript", "willSet", "didSet", "get", "set"]

    private static let kwJS: Set<String> = ["const", "let", "var", "function", "class", "extends", "implements", "interface", "type", "enum", "if", "else", "for", "while", "do", "switch", "case", "default", "break", "continue", "return", "try", "catch", "finally", "throw", "new", "delete", "typeof", "instanceof", "in", "of", "void", "this", "super", "null", "undefined", "true", "false", "async", "await", "yield", "import", "export", "from", "as", "static", "get", "set", "public", "private", "protected", "readonly", "abstract", "namespace", "declare", "keyof", "satisfies"]

    private static let kwPython: Set<String> = ["def", "class", "if", "elif", "else", "for", "while", "break", "continue", "return", "try", "except", "finally", "raise", "with", "as", "import", "from", "pass", "lambda", "yield", "global", "nonlocal", "del", "in", "is", "not", "and", "or", "None", "True", "False", "async", "await", "assert", "self", "match", "case"]

    private static let kwRuby: Set<String> = ["def", "class", "module", "if", "elsif", "else", "unless", "case", "when", "then", "for", "while", "until", "do", "begin", "rescue", "ensure", "raise", "return", "yield", "break", "next", "end", "self", "nil", "true", "false", "and", "or", "not", "require", "require_relative", "attr_accessor", "attr_reader", "attr_writer", "new", "super", "in"]

    private static let kwGo: Set<String> = ["func", "package", "import", "var", "const", "type", "struct", "interface", "map", "chan", "go", "defer", "if", "else", "for", "range", "switch", "case", "default", "break", "continue", "return", "select", "fallthrough", "nil", "true", "false", "iota", "make", "new", "len", "cap", "append", "error", "string", "int", "bool", "byte", "rune"]

    private static let kwRust: Set<String> = ["fn", "let", "mut", "const", "static", "struct", "enum", "trait", "impl", "for", "while", "loop", "if", "else", "match", "return", "break", "continue", "mod", "use", "pub", "crate", "self", "Self", "super", "as", "where", "move", "ref", "type", "dyn", "async", "await", "unsafe", "true", "false", "Some", "None", "Ok", "Err", "in"]

    private static let kwJava: Set<String> = ["class", "interface", "enum", "extends", "implements", "public", "private", "protected", "static", "final", "abstract", "void", "int", "long", "double", "float", "boolean", "char", "byte", "short", "if", "else", "for", "while", "do", "switch", "case", "default", "break", "continue", "return", "try", "catch", "finally", "throw", "throws", "new", "this", "super", "import", "package", "null", "true", "false", "instanceof", "synchronized", "volatile", "transient", "var", "record"]

    private static let kwC: Set<String> = ["int", "long", "short", "char", "float", "double", "void", "unsigned", "signed", "struct", "union", "enum", "typedef", "const", "static", "extern", "register", "volatile", "if", "else", "for", "while", "do", "switch", "case", "default", "break", "continue", "return", "goto", "sizeof", "true", "false", "NULL", "auto", "inline", "restrict"]

    private static let kwCpp: Set<String> = ["int", "long", "short", "char", "float", "double", "void", "bool", "unsigned", "signed", "struct", "union", "enum", "typedef", "const", "constexpr", "static", "extern", "volatile", "if", "else", "for", "while", "do", "switch", "case", "default", "break", "continue", "return", "goto", "sizeof", "new", "delete", "class", "public", "private", "protected", "virtual", "template", "typename", "namespace", "using", "nullptr", "true", "false", "auto", "this", "operator", "friend", "inline", "override", "final", "mutable", "explicit"]

    private static let kwShell: Set<String> = ["if", "then", "else", "elif", "fi", "for", "in", "do", "done", "while", "until", "case", "esac", "function", "return", "echo", "export", "local", "readonly", "set", "unset", "source", "alias", "cd", "exit", "shift", "eval", "trap"]

    private static let kwSQL: Set<String> = ["select", "from", "where", "insert", "into", "values", "update", "set", "delete", "create", "table", "drop", "alter", "add", "index", "view", "join", "inner", "left", "right", "outer", "full", "cross", "on", "using", "group", "by", "order", "having", "limit", "offset", "as", "and", "or", "not", "null", "is", "in", "like", "between", "distinct", "count", "sum", "avg", "min", "max", "primary", "key", "foreign", "references", "default", "union", "all", "case", "when", "then", "else", "end", "with", "returning"]

    private static let kwGeneric: Set<String> = ["let", "var", "const", "function", "func", "def", "fn", "class", "struct", "enum", "interface", "trait", "impl", "type", "if", "else", "elif", "for", "while", "do", "switch", "case", "match", "when", "default", "break", "continue", "return", "try", "catch", "finally", "except", "throw", "raise", "import", "export", "from", "use", "package", "module", "as", "in", "is", "new", "delete", "void", "null", "nil", "None", "true", "false", "True", "False", "self", "this", "super", "public", "private", "protected", "static", "async", "await", "and", "or", "not", "pub", "mut", "end", "then"]
}
