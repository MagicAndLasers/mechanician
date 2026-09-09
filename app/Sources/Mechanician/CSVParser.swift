import Foundation

/// RFC 4180 CSV parsing, because splitting on commas is not parsing (FR-336).
///
/// The renderer this replaces used `source.split(separator: ",")` inside
/// `source.split(separator: "\n")`, which got four ordinary cases wrong. The worst was not the
/// obvious one: `split(separator: "\n")` never matches a CRLF file at all, because in Swift
/// `"\r\n"` is a *single* `Character` — one grapheme cluster, not equal to `"\n"`. A CSV saved by
/// Excel on Windows therefore arrived as one enormous row. Quoted commas, escaped `""` quotes, and
/// newlines inside quoted fields were the other three.
///
/// This is a character scanner rather than a regular expression: quoting in CSV is stateful — a
/// comma means "next field" outside quotes and "literal comma" inside them — and that is exactly
/// the kind of thing a regex cannot express without lying about it.
enum CSVParser {
    /// Rows of fields, in file order. An empty document yields no rows.
    ///
    /// Deliberately lenient, because a preview must show something rather than refuse: an unclosed
    /// quote runs to end of input as one field, and a stray quote inside an unquoted field is kept
    /// verbatim. Malformed input renders as best it can instead of throwing.
    ///
    /// `maximumRows` stops the scan early for a preview that only shows the first N rows, so a huge
    /// export costs the rows displayed rather than the whole file.
    static func rows(from source: String, maximumRows: Int? = nil) -> [[String]] {
        // Scalars, not Characters: as a grapheme cluster "\r\n" is one Character and cannot be
        // compared against "\n", which is the bug this parser exists to fix.
        let scalars = Array(source.unicodeScalars)
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var index = 0

        func endRow() {
            row.append(field)
            field = ""
            // A trailing newline should not manufacture an empty final row.
            if !(row.count == 1 && row[0].isEmpty) {
                rows.append(row)
            }
            row = []
        }

        while index < scalars.count {
            let scalar = scalars[index]

            if inQuotes {
                if scalar == "\"" {
                    // `""` inside a quoted field is one literal quote; a lone `"` closes the field.
                    if index + 1 < scalars.count, scalars[index + 1] == "\"" {
                        field.unicodeScalars.append("\"")
                        index += 2
                    } else {
                        inQuotes = false
                        index += 1
                    }
                } else {
                    field.unicodeScalars.append(scalar)
                    index += 1
                }
                continue
            }

            switch scalar {
            case "\"":
                inQuotes = true
                index += 1
            case ",":
                row.append(field)
                field = ""
                index += 1
            case "\r":
                // CR, CRLF and LF all end a row. Consume the LF of a CRLF pair with it.
                index += (index + 1 < scalars.count && scalars[index + 1] == "\n") ? 2 : 1
                endRow()
                if let maximumRows, rows.count >= maximumRows { return rows }
            case "\n":
                index += 1
                endRow()
                if let maximumRows, rows.count >= maximumRows { return rows }
            default:
                field.unicodeScalars.append(scalar)
                index += 1
            }
        }

        // Whatever is still in hand is the last row, which a file with no trailing newline has.
        if !field.isEmpty || !row.isEmpty {
            endRow()
        }
        return rows
    }

    /// Pads every row to the widest, so the table draws a rectangle even when the file is ragged.
    /// A short row is a real thing in exported CSV, and a jagged grid reads as corruption.
    static func rectangular(_ rows: [[String]]) -> [[String]] {
        let width = rows.map(\.count).max() ?? 0
        guard width > 0 else { return rows }
        return rows.map { $0 + Array(repeating: "", count: width - $0.count) }
    }
}
