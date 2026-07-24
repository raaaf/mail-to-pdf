import Testing
import Foundation
@testable import MailToPDF

/// A private class used only to anchor `Bundle(for:)` at the test bundle so fixtures placed under
/// `Tests/Fixtures` (added as resources to the MailToPDFTests target) can be located at runtime.
private final class FixtureAnchor {}

private func fixtureData(_ name: String) throws -> Data {
    let bundle = Bundle(for: FixtureAnchor.self)
    guard let url = bundle.url(forResource: name, withExtension: "eml") else {
        throw EmailParserError.invalidData
    }
    return try Data(contentsOf: url)
}

/// Covers header/body splitting, RFC 2047 decoding, multipart recursion, quoted-printable and
/// base64 transfer decoding, and charset conversion in EmailParser. Run via `xcodebuild test`.
@Suite("EmailParser")
struct EmailParserTests {

    @Test("[parser-subject] RFC 2047 base64-encoded UTF-8 subject decodes with correct umlauts")
    func subjectDecoding() throws {
        let message = try EmailParser.parse(data: fixtureData("simple-html-utf8"))
        #expect(message.subject == "Grüße vom Café")
    }

    @Test("[parser-from] plain From header is preserved as-is")
    func fromDecoding() throws {
        let message = try EmailParser.parse(data: fixtureData("simple-html-utf8"))
        #expect(message.from == "Absender Eins <absender@example.de>")
    }

    @Test("[parser-from-q] RFC 2047 Q-encoded ISO-8859-1 From header decodes with correct umlauts")
    func fromQEncodedDecoding() throws {
        let message = try EmailParser.parse(data: fixtureData("latin1-quoted-printable"))
        #expect(message.from == "Bärbel Schröder <baerbel@example.de>")
    }

    @Test("[parser-date] RFC 5322 date header parses to the expected calendar components")
    func dateParsing() throws {
        let message = try EmailParser.parse(data: fixtureData("multipart-alternative-base64"))
        let date = try #require(message.date)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        // "Tue, 15 Aug 2023 09:30:00 +0200" -> 07:30 UTC
        #expect(components.year == 2023)
        #expect(components.month == 8)
        #expect(components.day == 15)
        #expect(components.hour == 7)
        #expect(components.minute == 30)
    }

    @Test("[parser-html-qp] quoted-printable UTF-8 HTML body decodes with correct umlauts")
    func htmlBodyDecoding() throws {
        let message = try EmailParser.parse(data: fixtureData("simple-html-utf8"))
        let html = try #require(message.htmlBody)
        #expect(html.contains("Schöne Grüße aus München"))
    }

    @Test("[parser-plain-latin1] quoted-printable ISO-8859-1 plain body decodes with correct umlauts")
    func plainBodyLatin1Fallback() throws {
        let message = try EmailParser.parse(data: fixtureData("latin1-quoted-printable"))
        let plain = try #require(message.plainBody)
        #expect(plain.contains("Grüße"))
        #expect(plain.contains("wünschen"))
    }

    @Test("[parser-qp-softbreak] a quoted-printable soft line break is removed, not turned into a space")
    func quotedPrintableSoftLineBreak() throws {
        let message = try EmailParser.parse(data: fixtureData("latin1-quoted-printable"))
        let plain = try #require(message.plainBody)
        // The fixture's raw body breaks the word "Ihnen" across a soft line break ("Ihne=\nn");
        // a correct decoder rejoins it into one word with no inserted whitespace or newline.
        #expect(plain.contains("wir wünschen Ihnen ein"))
    }

    @Test("[parser-multipart-alt] multipart/alternative picks the base64-encoded HTML part")
    func multipartAlternativeBase64Body() throws {
        let message = try EmailParser.parse(data: fixtureData("multipart-alternative-base64"))
        let html = try #require(message.htmlBody)
        #expect(html.contains("Hallo <b>Welt</b>"))
    }

    @Test("[parser-nested] a text/html body nested two levels deep (mixed > alternative) is found")
    func nestedMultipartBodyPick() throws {
        let message = try EmailParser.parse(data: fixtureData("with-pdf-attachment"))
        let html = try #require(message.htmlBody)
        #expect(html.contains("Anbei die Rechnung als PDF-Anhang"))
    }

    @Test("[parser-attachment] a PDF attachment inside multipart/mixed is extracted with its filename and data")
    func attachmentExtraction() throws {
        let message = try EmailParser.parse(data: fixtureData("with-pdf-attachment"))
        #expect(message.pdfAttachments.count == 1)
        let attachment = try #require(message.pdfAttachments.first)
        #expect(attachment.filename == "Rechnung.pdf")
        let header = String(data: attachment.data.prefix(5), encoding: .ascii)
        #expect(header == "%PDF-")
    }
}
