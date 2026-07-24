import Testing
import Foundation
@testable import MailToPDF

/// Covers `InvoiceExtractor.extractFallback` only: the pure regex/string heuristic. The on-device
/// LLM path in `extract(from:)` is not deterministic and is intentionally not exercised here.
@Suite("InvoiceExtractor fallback")
struct InvoiceExtractorTests {

    private func message(from: String = "", subject: String = "", plainBody: String? = nil) -> EmailMessage {
        EmailMessage(subject: subject, from: from, date: nil, htmlBody: nil, plainBody: plainBody, pdfAttachments: [])
    }

    @Test("[invoice-merchant-angle-bracket] merchant is the display name before the angle bracket")
    func merchantFromDisplayName() {
        let info = InvoiceExtractor.extractFallback(from: message(from: "ACME GmbH <billing@acme.example>"))
        #expect(info.merchant == "ACME GmbH")
    }

    @Test("[invoice-merchant-no-angle-bracket] a bare address with no display name is used as-is")
    func merchantFallsBackToRawFrom() {
        let info = InvoiceExtractor.extractFallback(from: message(from: "billing@acme.example"))
        #expect(info.merchant == "billing@acme.example")
    }

    @Test("[invoice-amount-german-grouped] '1.234,56 €' parses as German-grouped thousands + decimal comma")
    func amountGermanGrouped() {
        let info = InvoiceExtractor.extractFallback(from: message(plainBody: "Gesamtbetrag: 1.234,56 €"))
        #expect(info.amount == "1234,56 EUR")
    }

    @Test("[invoice-amount-euro-prefix] '€ 12,34' (symbol before amount) is recognized")
    func amountEuroPrefix() {
        let info = InvoiceExtractor.extractFallback(from: message(plainBody: "Betrag: € 12,34"))
        #expect(info.amount == "12,34 EUR")
    }

    @Test("[invoice-amount-eur-decimal-point] 'EUR 12.34' (code prefix, decimal point) is recognized")
    func amountEURCodeDecimalPoint() {
        let info = InvoiceExtractor.extractFallback(from: message(plainBody: "Total due: EUR 12.34"))
        #expect(info.amount == "12,34 EUR")
    }

    @Test("[invoice-amount-eur-suffix] '12,34 EUR' (code after amount) is recognized")
    func amountEURCodeSuffix() {
        let info = InvoiceExtractor.extractFallback(from: message(plainBody: "Rechnungsbetrag 12,34 EUR bitte begleichen"))
        #expect(info.amount == "12,34 EUR")
    }

    @Test("[invoice-amount-largest] the largest amount found wins (gross total over line items)")
    func largestAmountWins() {
        let text = "Position 1: 5,00 EUR\nPosition 2: 12,50 EUR\nGesamtbetrag: 17,50 EUR"
        let info = InvoiceExtractor.extractFallback(from: message(plainBody: text))
        #expect(info.amount == "17,50 EUR")
    }

    @Test("[invoice-empty-input] empty subject/from/body yields both fields nil")
    func emptyInputYieldsNil() {
        let info = InvoiceExtractor.extractFallback(from: message())
        #expect(info.merchant == nil)
        #expect(info.amount == nil)
    }
}
