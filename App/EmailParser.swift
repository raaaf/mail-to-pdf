import Foundation

/// A parsed email message, independent of any AppKit/UIKit APIs so it stays unit-testable.
struct EmailMessage: Sendable {
    var subject: String
    var from: String
    var date: Date?
    var htmlBody: String?
    var plainBody: String?
    var pdfAttachments: [PDFAttachment]
}

/// A PDF file extracted from a MIME part.
struct PDFAttachment: Sendable {
    var filename: String
    var data: Data
}

enum EmailParserError: Error {
    case invalidData
}

/// Filename sanitization shared by attachment names (EmailParser) and suggested PDF names (ConvertModel).
enum FilenameSanitizer {
    /// Strips path separators and control characters, collapses whitespace, and caps length.
    static func sanitize(_ raw: String, maxLength: Int = 255, fallback: String = "Datei") -> String {
        var cleaned = raw
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        cleaned = cleaned
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        cleaned = String(cleaned.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
        if cleaned.count > maxLength {
            cleaned = String(cleaned.prefix(maxLength)).trimmingCharacters(in: .whitespaces)
        }
        return cleaned.isEmpty ? fallback : cleaned
    }
}

/// Pure MIME parsing: header/body splitting, RFC 2047 decoding, multipart recursion, quoted-printable
/// and base64 transfer decoding, charset conversion. No AppKit/WebKit dependency, fully unit-testable.
enum EmailParser {

    static func parse(data: Data) throws -> EmailMessage {
        guard !data.isEmpty else { throw EmailParserError.invalidData }

        let (headerData, _) = splitHeaderAndBody(data)
        let headers = parseHeaders(headerData)
        let subject = decodeEncodedWords(headerValue(headers, "Subject") ?? "")
        let from = decodeEncodedWords(headerValue(headers, "From") ?? "")
        let date = parseDate(headerValue(headers, "Date"))

        var result = ParseResult()
        walk(partData: data, into: &result)

        return EmailMessage(subject: subject, from: from, date: date,
                             htmlBody: result.htmlBody, plainBody: result.plainBody,
                             pdfAttachments: result.pdfAttachments)
    }

    static func parse(fileURL: URL) throws -> EmailMessage {
        try parse(data: Data(contentsOf: fileURL))
    }

    // MARK: - Recursive MIME walk

    private struct ParseResult {
        var htmlBody: String?
        var plainBody: String?
        var pdfAttachments: [PDFAttachment] = []
    }

    /// Walks one MIME part (headers + body). Recurses into multipart containers, collects the first
    /// text/html and text/plain leaf bodies found (depth-first) and any PDF attachments.
    private static func walk(partData: Data, into result: inout ParseResult) {
        let (headerData, bodyData) = splitHeaderAndBody(partData)
        let headers = parseHeaders(headerData)
        let contentType = parseContentType(headerValue(headers, "Content-Type"))
        let transferEncoding = headerValue(headers, "Content-Transfer-Encoding")?.lowercased() ?? "7bit"
        let disposition = headerValue(headers, "Content-Disposition").map(splitParams)

        if contentType.type.hasPrefix("multipart/"), let boundary = contentType.params["boundary"] {
            for sub in splitMultipart(body: bodyData, boundary: boundary) {
                walk(partData: sub, into: &result)
            }
            return
        }

        var filename: String?
        if let raw = disposition?.params["filename"] {
            filename = decodeEncodedWords(raw)
        } else if let rawStar = disposition?.params["filename*"] {
            filename = decodeRFC2231(rawStar)
        } else if let nameParam = contentType.params["name"] {
            filename = decodeEncodedWords(nameParam)
        }

        let isPDF = contentType.type == "application/pdf" || (filename?.lowercased().hasSuffix(".pdf") ?? false)
        if isPDF {
            let data = decodeBody(bodyData, transferEncoding: transferEncoding)
            let name = FilenameSanitizer.sanitize(filename ?? "attachment.pdf", fallback: "attachment.pdf")
            result.pdfAttachments.append(PDFAttachment(filename: name, data: data))
            return
        }

        if contentType.type == "text/html", result.htmlBody == nil {
            let data = decodeBody(bodyData, transferEncoding: transferEncoding)
            result.htmlBody = decodeCharset(data, charset: contentType.params["charset"])
            return
        }

        if contentType.type == "text/plain", result.plainBody == nil {
            let data = decodeBody(bodyData, transferEncoding: transferEncoding)
            result.plainBody = decodeCharset(data, charset: contentType.params["charset"])
            return
        }
    }

    // MARK: - Header / body split

    /// Splits raw message (or part) bytes at the first empty line, accepting CRLF and bare LF.
    private static func splitHeaderAndBody(_ data: Data) -> (header: Data, body: Data) {
        var i = data.startIndex
        let end = data.endIndex
        while i < end {
            if i + 4 <= end, data[i] == 13, data[i + 1] == 10, data[i + 2] == 13, data[i + 3] == 10 {
                return (data.subdata(in: data.startIndex..<i), data.subdata(in: (i + 4)..<end))
            }
            if i + 2 <= end, data[i] == 10, data[i + 1] == 10 {
                return (data.subdata(in: data.startIndex..<i), data.subdata(in: (i + 2)..<end))
            }
            i += 1
        }
        return (data, Data())
    }

    /// Parses and RFC 5322 line-unfolds headers. Bytes are read as Latin-1 (lossless 1:1 byte mapping)
    /// since header structure itself is always ASCII; non-ASCII text lives in RFC 2047 encoded-words.
    private static func parseHeaders(_ headerData: Data) -> [(name: String, value: String)] {
        guard let raw = String(data: headerData, encoding: .isoLatin1) else { return [] }
        let rawLines = raw.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")

        var unfolded: [String] = []
        for line in rawLines {
            if let first = line.first, first == " " || first == "\t", !unfolded.isEmpty {
                unfolded[unfolded.count - 1] += " " + line.trimmingCharacters(in: .whitespaces)
            } else if !line.isEmpty {
                unfolded.append(line)
            }
        }

        return unfolded.compactMap { line in
            guard let colon = line.firstIndex(of: ":") else { return nil }
            let name = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            return (name, value)
        }
    }

    private static func headerValue(_ headers: [(name: String, value: String)], _ name: String) -> String? {
        headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    // MARK: - Content-Type / Content-Disposition parameter parsing

    private struct ContentTypeInfo {
        var type: String
        var params: [String: String]
    }

    private static func parseContentType(_ value: String?) -> ContentTypeInfo {
        guard let value else { return ContentTypeInfo(type: "text/plain", params: [:]) }
        let (main, params) = splitParams(value)
        return ContentTypeInfo(type: main.lowercased(), params: params)
    }

    /// Splits a `main; key=value; key2="quoted value"` header value, respecting quotes around `;`.
    private static func splitParams(_ value: String) -> (main: String, params: [String: String]) {
        var components: [String] = []
        var current = ""
        var inQuotes = false
        for ch in value {
            if ch == "\"" {
                inQuotes.toggle()
                current.append(ch)
            } else if ch == ";" && !inQuotes {
                components.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }
        components.append(current)

        let main = (components.first ?? "").trimmingCharacters(in: .whitespaces)
        var params: [String: String] = [:]
        for component in components.dropFirst() {
            guard let eq = component.firstIndex(of: "=") else { continue }
            let key = String(component[component.startIndex..<eq]).trimmingCharacters(in: .whitespaces).lowercased()
            var val = String(component[component.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if val.hasPrefix("\""), val.hasSuffix("\""), val.count >= 2 {
                val = String(val.dropFirst().dropLast())
            }
            params[key] = val
        }
        return (main, params)
    }

    /// Simple RFC 2231 extended parameter form: `charset'language'percent-encoded-value`.
    /// Continuation parameters (`filename*0*=`, etc.) are not supported.
    private static func decodeRFC2231(_ raw: String) -> String {
        let parts = raw.components(separatedBy: "'")
        guard parts.count >= 3 else { return raw }
        let encodedValue = parts[2...].joined(separator: "'")
        return encodedValue.removingPercentEncoding ?? encodedValue
    }

    // MARK: - Multipart boundary splitting

    /// Splits a multipart body into its sub-part byte ranges using `--boundary` delimiter lines.
    /// Round-trips through Latin-1 (a lossless 1:1 byte<->scalar mapping) so line-based scanning
    /// never corrupts binary payloads such as base64 attachment data.
    private static func splitMultipart(body: Data, boundary: String) -> [Data] {
        guard let text = String(data: body, encoding: .isoLatin1) else { return [] }
        let delimiter = "--\(boundary)"
        let terminator = delimiter + "--"

        var parts: [Data] = []
        var current: [String] = []
        var collecting = false

        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
            if line == terminator {
                if collecting, let d = current.joined(separator: "\n").data(using: .isoLatin1) { parts.append(d) }
                break
            }
            if line == delimiter {
                if collecting, let d = current.joined(separator: "\n").data(using: .isoLatin1) { parts.append(d) }
                collecting = true
                current = []
                continue
            }
            if collecting { current.append(line) }
        }
        return parts
    }

    // MARK: - Content-Transfer-Encoding decoding

    private static func decodeBody(_ data: Data, transferEncoding: String) -> Data {
        switch transferEncoding {
        case "base64":
            let text = String(data: data, encoding: .ascii) ?? String(data: data, encoding: .isoLatin1) ?? ""
            let stripped = text.filter { !$0.isWhitespace }
            return Data(base64Encoded: stripped, options: .ignoreUnknownCharacters) ?? Data()
        case "quoted-printable":
            return decodeQuotedPrintable(data)
        default: // "7bit", "8bit", "binary", or anything unrecognized: passthrough
            return data
        }
    }

    private static func decodeQuotedPrintable(_ data: Data) -> Data {
        let bytes = [UInt8](data)
        var output = [UInt8]()
        output.reserveCapacity(bytes.count)
        var i = 0
        while i < bytes.count {
            let b = bytes[i]
            guard b == 0x3D /* '=' */ else {
                output.append(b)
                i += 1
                continue
            }
            if i + 2 < bytes.count, bytes[i + 1] == 0x0D, bytes[i + 2] == 0x0A { // soft break "=\r\n"
                i += 3
            } else if i + 1 < bytes.count, bytes[i + 1] == 0x0A { // soft break "=\n"
                i += 2
            } else if i + 2 < bytes.count, let hi = hexValue(bytes[i + 1]), let lo = hexValue(bytes[i + 2]) {
                output.append(UInt8(hi * 16 + lo))
                i += 3
            } else {
                output.append(b) // malformed escape: pass through literally
                i += 1
            }
        }
        return Data(output)
    }

    private static func hexValue(_ byte: UInt8) -> Int? {
        switch byte {
        case 0x30...0x39: return Int(byte - 0x30)
        case 0x41...0x46: return Int(byte - 0x41) + 10
        case 0x61...0x66: return Int(byte - 0x61) + 10
        default: return nil
        }
    }

    // MARK: - Charset decoding

    private static func resolveEncoding(_ charset: String?) -> String.Encoding {
        switch (charset ?? "utf-8").lowercased() {
        case "iso-8859-1", "latin1":
            return .isoLatin1
        case "windows-1252", "cp1252":
            return .windowsCP1252
        case "us-ascii", "ascii":
            return .ascii
        default:
            return .utf8
        }
    }

    /// Decodes raw body bytes with the declared charset; never throws, falls back to lossy Latin-1.
    private static func decodeCharset(_ data: Data, charset: String?) -> String {
        let encoding = resolveEncoding(charset)
        if let string = String(data: data, encoding: encoding) {
            return string
        }
        return String(data: data, encoding: .isoLatin1) ?? ""
    }

    // MARK: - RFC 2047 encoded-word decoding (Subject, From, attachment filenames)

    private static let encodedWordPattern = #"=\?([^?]+)\?([BbQq])\?([^?]*)\?="#

    private static func decodeEncodedWords(_ input: String) -> String {
        guard input.contains("=?"), let regex = try? NSRegularExpression(pattern: encodedWordPattern) else {
            return input
        }
        let nsInput = input as NSString
        let matches = regex.matches(in: input, range: NSRange(location: 0, length: nsInput.length))
        guard !matches.isEmpty else { return input }

        var result = ""
        var lastEnd = 0
        var lastWasEncodedWord = false
        for match in matches {
            let between = nsInput.substring(with: NSRange(location: lastEnd, length: match.range.location - lastEnd))
            let isWhitespaceOnlyGap = !between.isEmpty && between.trimmingCharacters(in: .whitespaces).isEmpty
            if !(lastWasEncodedWord && isWhitespaceOnlyGap) {
                result += between
            }
            let charset = nsInput.substring(with: match.range(at: 1))
            let encodingFlag = nsInput.substring(with: match.range(at: 2)).uppercased()
            let payload = nsInput.substring(with: match.range(at: 3))
            result += decodeEncodedWordPayload(payload, encodingFlag: encodingFlag, charset: charset)
            lastEnd = match.range.location + match.range.length
            lastWasEncodedWord = true
        }
        result += nsInput.substring(from: lastEnd)
        return result
    }

    private static func decodeEncodedWordPayload(_ text: String, encodingFlag: String, charset: String) -> String {
        let stringEncoding = resolveEncoding(charset)
        let data: Data
        if encodingFlag == "B" {
            guard let decoded = Data(base64Encoded: text, options: .ignoreUnknownCharacters) else { return text }
            data = decoded
        } else { // "Q"
            let chars = [UInt8](text.utf8)
            var bytes = [UInt8]()
            bytes.reserveCapacity(chars.count)
            var i = 0
            while i < chars.count {
                let c = chars[i]
                if c == 0x5F { // '_' -> space
                    bytes.append(0x20)
                    i += 1
                } else if c == 0x3D, i + 2 < chars.count, let hi = hexValue(chars[i + 1]), let lo = hexValue(chars[i + 2]) {
                    bytes.append(UInt8(hi * 16 + lo))
                    i += 3
                } else {
                    bytes.append(c)
                    i += 1
                }
            }
            data = Data(bytes)
        }
        return String(data: data, encoding: stringEncoding) ?? String(data: data, encoding: .isoLatin1) ?? text
    }

    // MARK: - Date header parsing

    private static func parseDate(_ raw: String?) -> Date? {
        guard var value = raw else { return nil }
        if let commentRange = value.range(of: #"\s*\([^)]*\)\s*$"#, options: .regularExpression) {
            value.removeSubrange(commentRange)
        }
        value = value.trimmingCharacters(in: .whitespaces)

        for format in ["EEE, dd MMM yyyy HH:mm:ss Z", "dd MMM yyyy HH:mm:ss Z"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            if let date = formatter.date(from: value) {
                return date
            }
        }
        return nil
    }
}
