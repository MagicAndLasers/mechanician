import Foundation

/// Bounded, display-safe metadata and provider text derived from an RFC 822 message.
///
/// This is intentionally not a transcript model. The canonical attachment remains the untouched
/// `.eml` file in conversation-owned storage; this value is derived on demand for naming and at the
/// provider boundary so a model can read ordinary message text without discarding MIME attachments.
struct RFC822ReadableContext: Codable, Equatable, Sendable {
    let subject: String?
    let sender: String?
    let date: String?
    let readableText: String?
    let canonicalContentNote: String
}

enum RFC822MessageParser {
    static let maximumHeaderBytes = 256 * 1024
    static let maximumProviderInputBytes = 2 * 1024 * 1024
    static let maximumReadableCharacters = 64 * 1024
    private static let maximumMIMEDepth = 8

    struct Metadata: Equatable, Sendable {
        let subject: String?
        let sender: String?
        let date: String?

        func safeDisplayName(fallback: String) -> String {
            let fallbackStem = URL(fileURLWithPath: fallback)
                .deletingPathExtension()
                .lastPathComponent
            let source = subject ?? fallbackStem
            var safe = source.unicodeScalars.map { scalar -> Character in
                if scalar.value < 0x20 || scalar.value == 0x7F
                    || scalar == "/" || scalar == ":" || scalar == "\\" {
                    return " "
                }
                return Character(scalar)
            }
            .reduce(into: "") { $0.append($1) }
            safe = collapseWhitespace(safe)
                .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
            if safe.isEmpty { safe = "Mail message" }
            if safe.count > 100 { safe = String(safe.prefix(100)) }
            return safe + ".eml"
        }
    }

    static func isRFC822File(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "eml"
    }

    static func metadata(at url: URL) -> Metadata? {
        guard isRFC822File(url),
              let data = readPrefix(at: url, maximumBytes: maximumHeaderBytes),
              let split = splitHeaderAndBody(data) else { return nil }
        let headers = parseHeaders(split.header)
        return Metadata(
            subject: safeHeader(headers["subject"]),
            sender: safeHeader(headers["from"]),
            date: safeHeader(headers["date"]))
    }

    static func readableContext(at url: URL) -> RFC822ReadableContext? {
        guard isRFC822File(url),
              let data = readPrefix(at: url, maximumBytes: maximumProviderInputBytes),
              let split = splitHeaderAndBody(data) else { return nil }
        let headers = parseHeaders(split.header)
        let metadata = Metadata(
            subject: safeHeader(headers["subject"]),
            sender: safeHeader(headers["from"]),
            date: safeHeader(headers["date"]))
        let candidates = textCandidates(
            headers: headers,
            body: split.body,
            depth: 0)
        let readable = candidates
            .sorted {
                if $0.priority != $1.priority { return $0.priority < $1.priority }
                return $0.order < $1.order
            }
            .first?
            .text
        return RFC822ReadableContext(
            subject: metadata.subject,
            sender: metadata.sender,
            date: metadata.date,
            readableText: readable.map {
                String($0.prefix(maximumReadableCharacters))
            },
            canonicalContentNote:
                "The original RFC 822 file at path remains canonical and retains MIME attachments. "
                + "readableText is a bounded convenience rendering, not a replacement for that file.")
    }

    /// Internal data entry point keeps parser fixtures independent of filesystem behavior.
    static func readableContext(from data: Data) -> RFC822ReadableContext? {
        guard data.count <= maximumProviderInputBytes,
              let split = splitHeaderAndBody(data) else { return nil }
        let headers = parseHeaders(split.header)
        let metadata = Metadata(
            subject: safeHeader(headers["subject"]),
            sender: safeHeader(headers["from"]),
            date: safeHeader(headers["date"]))
        let readable = textCandidates(headers: headers, body: split.body, depth: 0)
            .sorted {
                if $0.priority != $1.priority { return $0.priority < $1.priority }
                return $0.order < $1.order
            }
            .first?
            .text
        return RFC822ReadableContext(
            subject: metadata.subject,
            sender: metadata.sender,
            date: metadata.date,
            readableText: readable.map { String($0.prefix(maximumReadableCharacters)) },
            canonicalContentNote:
                "The original RFC 822 file at path remains canonical and retains MIME attachments. "
                + "readableText is a bounded convenience rendering, not a replacement for that file.")
    }

    private struct TextCandidate {
        let priority: Int
        let order: Int
        let text: String
    }

    private static func textCandidates(
        headers: [String: String],
        body: Data,
        depth: Int
    ) -> [TextCandidate] {
        guard depth < maximumMIMEDepth else { return [] }
        let contentDisposition = headers["content-disposition"]?.lowercased() ?? ""
        if contentDisposition.contains("attachment")
            || contentDisposition.contains("filename=") {
            return []
        }

        let contentType = parsedHeaderValue(
            headers["content-type"] ?? "text/plain; charset=utf-8")
        let mediaType = contentType.value.lowercased()
        if mediaType.hasPrefix("multipart/"),
           let boundary = contentType.parameters["boundary"],
           !boundary.isEmpty,
           boundary.count <= 200 {
            var candidates: [TextCandidate] = []
            var order = 0
            for part in multipartParts(body, boundary: boundary) {
                guard let split = splitHeaderAndBody(part) else { continue }
                for candidate in textCandidates(
                    headers: parseHeaders(split.header),
                    body: split.body,
                    depth: depth + 1) {
                    candidates.append(TextCandidate(
                        priority: candidate.priority,
                        order: order,
                        text: candidate.text))
                    order += 1
                }
            }
            return candidates
        }

        guard mediaType == "text/plain" || mediaType == "text/html" else { return [] }
        let decodedBytes = decodeTransferEncoding(
            body,
            encoding: headers["content-transfer-encoding"])
        guard var text = decodeText(
            decodedBytes,
            charset: contentType.parameters["charset"]) else { return [] }
        if mediaType == "text/html" {
            text = plainText(fromHTML: text)
        }
        text = normalizeReadableText(text)
        guard !text.isEmpty else { return [] }
        return [TextCandidate(
            priority: mediaType == "text/plain" ? 0 : 1,
            order: 0,
            text: String(text.prefix(maximumReadableCharacters)))]
    }

    private static func readPrefix(at url: URL, maximumBytes: Int) -> Data? {
        guard maximumBytes > 0,
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return try? handle.read(upToCount: maximumBytes)
    }

    private static func splitHeaderAndBody(_ data: Data) -> (header: Data, body: Data)? {
        let delimiters = [Data([13, 10, 13, 10]), Data([10, 10])]
        let match = delimiters.compactMap { delimiter -> (Range<Data.Index>, Int)? in
            data.range(of: delimiter).map { ($0, delimiter.count) }
        }
        .min { $0.0.lowerBound < $1.0.lowerBound }
        guard let (range, _) = match,
              range.lowerBound <= maximumHeaderBytes else { return nil }
        return (
            Data(data[..<range.lowerBound]),
            Data(data[range.upperBound...]))
    }

    private static func parseHeaders(_ data: Data) -> [String: String] {
        guard let raw = String(data: data, encoding: .isoLatin1) else { return [:] }
        let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n")
        var unfolded: [String] = []
        for line in normalized.components(separatedBy: "\n") {
            if (line.first == " " || line.first == "\t"), !unfolded.isEmpty {
                unfolded[unfolded.count - 1] += " " + line
                    .trimmingCharacters(in: .whitespaces)
            } else {
                unfolded.append(line)
            }
        }
        var headers: [String: String] = [:]
        for line in unfolded {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].lowercased()
                .trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, name.count <= 80 else { continue }
            let value = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
            if let prior = headers[name], !prior.isEmpty {
                headers[name] = prior + ", " + value
            } else {
                headers[name] = value
            }
        }
        return headers
    }

    private static func safeHeader(_ value: String?) -> String? {
        guard let value else { return nil }
        let decoded = decodeEncodedWords(value)
        let safeScalars = decoded.unicodeScalars.map { scalar -> Character in
            if scalar.value < 0x20 || scalar.value == 0x7F { return " " }
            return Character(scalar)
        }
        let safe = collapseWhitespace(
            safeScalars.reduce(into: "") { $0.append($1) })
        guard !safe.isEmpty else { return nil }
        return String(safe.prefix(300))
    }

    private static func decodeEncodedWords(_ input: String) -> String {
        let pattern = #"=\?([^?]+)\?([bBqQ])\?([^?]*)\?="#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return input }
        let source = input as NSString
        let matches = regex.matches(
            in: input,
            range: NSRange(location: 0, length: source.length))
        guard !matches.isEmpty else { return input }
        let output = NSMutableString(string: input)
        for match in matches.reversed() {
            guard match.numberOfRanges == 4 else { continue }
            let charset = source.substring(with: match.range(at: 1))
            let mode = source.substring(with: match.range(at: 2)).lowercased()
            let payload = source.substring(with: match.range(at: 3))
            let data: Data?
            if mode == "b" {
                data = Data(base64Encoded: payload, options: [.ignoreUnknownCharacters])
            } else {
                data = decodeQuotedPrintable(
                    Data(payload.replacingOccurrences(of: "_", with: " ").utf8),
                    underscoreIsSpace: false)
            }
            guard let data,
                  let decoded = decodeText(data, charset: charset) else { continue }
            output.replaceCharacters(in: match.range, with: decoded)
        }
        return output as String
    }

    private static func parsedHeaderValue(
        _ raw: String
    ) -> (value: String, parameters: [String: String]) {
        let components = raw.split(separator: ";", omittingEmptySubsequences: false)
        let value = components.first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        var parameters: [String: String] = [:]
        for component in components.dropFirst() {
            guard let equals = component.firstIndex(of: "=") else { continue }
            let name = component[..<equals].lowercased()
                .trimmingCharacters(in: .whitespaces)
            var value = component[component.index(after: equals)...]
                .trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.first == "\"", value.last == "\"" {
                value.removeFirst()
                value.removeLast()
            }
            parameters[name] = value
        }
        return (value, parameters)
    }

    private static func multipartParts(_ data: Data, boundary: String) -> [Data] {
        let bytes = [UInt8](data)
        let marker = [UInt8](("--" + boundary).utf8)
        let closingMarker = marker + [0x2D, 0x2D]
        var parts: [Data] = []
        var partStart: Int?
        var lineStart = 0

        while lineStart <= bytes.count {
            let newline = bytes[lineStart...].firstIndex(of: 0x0A)
            let nextLineStart = newline.map { $0 + 1 } ?? bytes.count
            var contentEnd = newline ?? bytes.count
            if contentEnd > lineStart, bytes[contentEnd - 1] == 0x0D {
                contentEnd -= 1
            }
            while contentEnd > lineStart,
                  bytes[contentEnd - 1] == 0x20 || bytes[contentEnd - 1] == 0x09 {
                contentEnd -= 1
            }
            let line = Array(bytes[lineStart..<contentEnd])
            let isOpening = line == marker
            let isClosing = line == closingMarker
            if isOpening || isClosing {
                if let start = partStart {
                    var end = lineStart
                    if end > start, bytes[end - 1] == 0x0A { end -= 1 }
                    if end > start, bytes[end - 1] == 0x0D { end -= 1 }
                    if end > start {
                        parts.append(Data(bytes[start..<end]))
                    }
                }
                if isClosing { break }
                partStart = nextLineStart
            }
            guard newline != nil else { break }
            lineStart = nextLineStart
        }
        return parts
    }

    private static func decodeTransferEncoding(
        _ data: Data,
        encoding: String?
    ) -> Data {
        switch encoding?.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines) {
        case "base64":
            let compact = data.filter {
                !$0.isASCIIWhitespace
            }
            return Data(base64Encoded: Data(compact), options: [.ignoreUnknownCharacters])
                ?? data
        case "quoted-printable":
            return decodeQuotedPrintable(data, underscoreIsSpace: false) ?? data
        default:
            return data
        }
    }

    private static func decodeQuotedPrintable(
        _ data: Data,
        underscoreIsSpace: Bool
    ) -> Data? {
        let bytes = [UInt8](data)
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if underscoreIsSpace, byte == 0x5F {
                output.append(0x20)
                index += 1
                continue
            }
            guard byte == 0x3D else {
                output.append(byte)
                index += 1
                continue
            }
            if index + 1 < bytes.count, bytes[index + 1] == 0x0A {
                index += 2
                continue
            }
            if index + 2 < bytes.count,
               bytes[index + 1] == 0x0D,
               bytes[index + 2] == 0x0A {
                index += 3
                continue
            }
            guard index + 2 < bytes.count,
                  let high = hexValue(bytes[index + 1]),
                  let low = hexValue(bytes[index + 2]) else {
                output.append(byte)
                index += 1
                continue
            }
            output.append(high << 4 | low)
            index += 3
        }
        return Data(output)
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48...57: return byte - 48
        case 65...70: return byte - 55
        case 97...102: return byte - 87
        default: return nil
        }
    }

    private static func decodeText(_ data: Data, charset: String?) -> String? {
        let normalized = charset?
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
            .lowercased()
        let encodings: [String.Encoding] = {
            switch normalized {
            case "us-ascii", "ascii": return [.ascii, .utf8]
            case "iso-8859-1", "latin1", "latin-1": return [.isoLatin1, .utf8]
            case "windows-1252", "cp1252": return [.windowsCP1252, .isoLatin1, .utf8]
            case "utf-16": return [.utf16, .utf8]
            case "utf-16le": return [.utf16LittleEndian, .utf8]
            case "utf-16be": return [.utf16BigEndian, .utf8]
            default: return [.utf8, .isoLatin1]
            }
        }()
        for encoding in encodings {
            if let decoded = String(data: data, encoding: encoding) { return decoded }
        }
        return nil
    }

    private static func plainText(fromHTML html: String) -> String {
        var text = html
        for pattern in [
            #"(?is)<script\b[^>]*>.*?</script>"#,
            #"(?is)<style\b[^>]*>.*?</style>"#,
            #"(?i)<br\s*/?>"#,
            #"(?i)</(p|div|li|tr|h[1-6])\s*>"#,
        ] {
            text = text.replacingOccurrences(
                of: pattern,
                with: pattern.contains("script") || pattern.contains("style") ? "" : "\n",
                options: .regularExpression)
        }
        text = text.replacingOccurrences(
            of: #"(?is)<[^>]+>"#,
            with: "",
            options: .regularExpression)
        for (entity, replacement) in [
            ("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
            ("&quot;", "\""), ("&#39;", "'"),
        ] {
            text = text.replacingOccurrences(of: entity, with: replacement)
        }
        return text
    }

    private static func normalizeReadableText(_ value: String) -> String {
        var lines: [String] = []
        var previousBlank = false
        for rawLine in value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n") {
            let line = rawLine
                .replacingOccurrences(of: "\0", with: "")
                .trimmingCharacters(in: .whitespaces)
            let blank = line.isEmpty
            if blank, previousBlank { continue }
            lines.append(line)
            previousBlank = blank
        }
        return lines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func collapseWhitespace(_ value: String) -> String {
        value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

private extension UInt8 {
    var isASCIIWhitespace: Bool {
        self == 0x20 || self == 0x09 || self == 0x0A || self == 0x0D
    }
}
