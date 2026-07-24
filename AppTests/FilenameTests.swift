import Testing
import Foundation
@testable import MailToPDF

/// Covers FilenameSanitizer's character replacement/stripping/collapsing rules and
/// ConvertModel.suggestedFilename's date/subject composition. Run via `xcodebuild test`.
@Suite("FilenameSanitizer")
struct FilenameSanitizerTests {

    @Test("[sanitize-path-separators] slash, backslash, and colon are replaced with a hyphen")
    func pathSeparatorsReplaced() {
        let result = FilenameSanitizer.sanitize("a/b\\c:d")
        #expect(result == "a-b-c-d")
    }

    @Test("[sanitize-control-chars] control characters are stripped, not replaced with whitespace")
    func controlCharactersStripped() {
        let result = FilenameSanitizer.sanitize("Hello\u{0001}World")
        #expect(result == "HelloWorld")
    }

    @Test("[sanitize-whitespace-collapse] runs of whitespace and newlines collapse to a single space")
    func whitespaceRunsCollapsed() {
        let result = FilenameSanitizer.sanitize("Hello    World\n\nfoo")
        #expect(result == "Hello World foo")
    }

    @Test("[sanitize-whitespace-trim] leading and trailing whitespace is trimmed")
    func whitespaceTrimmed() {
        let result = FilenameSanitizer.sanitize("   Hello World   ")
        #expect(result == "Hello World")
    }

    @Test("[sanitize-maxlength] result is capped at maxLength and trimmed after cutting")
    func maxLengthCapped() {
        let result = FilenameSanitizer.sanitize("abc def", maxLength: 4)
        #expect(result == "abc")
    }

    @Test("[sanitize-empty-fallback] empty input returns the fallback")
    func emptyInputReturnsFallback() {
        let result = FilenameSanitizer.sanitize("", fallback: "Datei")
        #expect(result == "Datei")
    }

    @Test("[sanitize-whitespace-only-fallback] whitespace-only input returns the fallback")
    func whitespaceOnlyInputReturnsFallback() {
        let result = FilenameSanitizer.sanitize("   \n\t  ", fallback: "Datei")
        #expect(result == "Datei")
    }
}

@Suite("ConvertModel filenames")
@MainActor
struct ConvertModelFilenameTests {

    private func makeMessage(subject: String, date: Date?) -> EmailMessage {
        EmailMessage(subject: subject, from: "sender@example.de", date: date,
                     htmlBody: nil, plainBody: nil, pdfAttachments: [])
    }

    @Test("[convertmodel-date-prefix] the message date is formatted yyyy-MM-dd and prefixes the filename")
    func filenamePrefixedWithFormattedDate() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let expectedFormatter = DateFormatter()
        expectedFormatter.dateFormat = "yyyy-MM-dd"
        let expectedDateString = expectedFormatter.string(from: date)

        let model = ConvertModel()
        let message = makeMessage(subject: "Hello", date: date)
        let filename = model.suggestedFilename(for: message)

        #expect(filename.hasPrefix("\(expectedDateString) "))
    }

    @Test("[convertmodel-subject-sanitized] the subject is sanitized, replacing path separators with a hyphen")
    func subjectIsSanitized() {
        let model = ConvertModel()
        let message = makeMessage(subject: "Rechnung 03/2026: Apple", date: Date(timeIntervalSince1970: 0))
        let filename = model.suggestedFilename(for: message)

        #expect(filename.hasSuffix("Rechnung 03-2026- Apple.pdf"))
    }

    @Test("[convertmodel-subject-maxlength] the subject portion is capped at 80 characters")
    func subjectIsCappedAt80Characters() {
        let model = ConvertModel()
        let longSubject = String(repeating: "a", count: 200)
        let message = makeMessage(subject: longSubject, date: Date(timeIntervalSince1970: 0))
        let filename = model.suggestedFilename(for: message)

        let withoutExtension = filename.replacingOccurrences(of: ".pdf", with: "")
        let subjectPart = withoutExtension.split(separator: " ", maxSplits: 1)[1]
        #expect(subjectPart.count == 80)
    }

    @Test("[convertmodel-empty-subject-fallback] an empty subject falls back to \"E-Mail\"")
    func emptySubjectFallsBackToMail() {
        let model = ConvertModel()
        let message = makeMessage(subject: "", date: Date(timeIntervalSince1970: 0))
        let filename = model.suggestedFilename(for: message)

        #expect(filename.hasSuffix(" E-Mail.pdf"))
    }

    @Test("[convertmodel-pdf-extension] the suggested filename always ends with .pdf")
    func filenameAlwaysEndsWithPdfExtension() {
        let model = ConvertModel()
        let message = makeMessage(subject: "Some Subject", date: nil)
        let filename = model.suggestedFilename(for: message)

        #expect(filename.hasSuffix(".pdf"))
    }
}
