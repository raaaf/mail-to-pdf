import Foundation
import FoundationModels

/// Merchant/amount guess extracted from an email, used to build a smarter suggested filename.
/// `amount` is formatted like "9,99 EUR" when present.
struct InvoiceInfo: Sendable {
    var merchant: String?
    var amount: String?
}

/// On-device extraction schema for Apple Intelligence (macOS 26+ only). Kept at file scope: an
/// `@Generable` type cannot be declared locally inside a function.
@available(macOS 26.0, *)
@Generable
private struct ExtractedInvoice {
    @Guide(description: "The merchant or company name that issued this invoice or receipt")
    var merchant: String?
    @Guide(description: "The gross total amount due, as a plain decimal number like 42.50, no currency symbol")
    var amount: String?
    @Guide(description: "The ISO 4217 currency code, e.g. EUR or USD")
    var currency: String?
}

/// Guesses the merchant and gross total amount from an email, for a smarter suggested filename.
/// Prefers on-device Apple Intelligence (nothing leaves the Mac) when available, racing an 8s
/// timeout; falls back to a pure regex/string heuristic otherwise. The fallback is always
/// compiled and is the only path unit-tested, since the LLM path is not deterministic.
enum InvoiceExtractor {
    private static let maxInputLength = 4000
    private static let llmTimeoutSeconds = 8.0

    static func extract(from message: EmailMessage) async -> InvoiceInfo {
        let text = extractionText(for: message)
        guard !text.isEmpty else { return InvoiceInfo(merchant: nil, amount: nil) }

        if #available(macOS 26.0, *), case .available = SystemLanguageModel.default.availability,
           let info = await withLLMTimeout(text: text) {
            return info
        }
        return extractFallback(from: message, text: text)
    }

    // MARK: - On-device LLM path (macOS 26+)

    @available(macOS 26.0, *)
    private static func withLLMTimeout(text: String) async -> InvoiceInfo? {
        await withTaskGroup(of: InvoiceInfo?.self) { group in
            group.addTask { await extractWithLLM(text: text) }
            group.addTask {
                try? await Task.sleep(for: .seconds(llmTimeoutSeconds))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    @available(macOS 26.0, *)
    private static func extractWithLLM(text: String) async -> InvoiceInfo? {
        do {
            let session = LanguageModelSession(
                instructions: "Extract the merchant and the gross total amount due from this email. Leave a field unset if you are not confident."
            )
            let response = try await session.respond(to: text, generating: ExtractedInvoice.self)
            let content = response.content
            return InvoiceInfo(merchant: content.merchant, amount: formattedAmount(content.amount, currency: content.currency))
        } catch {
            return nil
        }
    }

    private static func formattedAmount(_ value: String?, currency: String?) -> String? {
        guard let value, let decimal = parseAmount(value) else { return nil }
        return normalizedAmountString(decimal, currency: currency ?? "EUR")
    }

    // MARK: - Fallback: regex/string heuristic (no LLM, deterministic, unit-tested)

    /// Pure, synchronous extraction with no LLM involved. Exposed internally so tests can exercise
    /// it directly without depending on `extract(from:)`'s non-deterministic LLM race.
    static func extractFallback(from message: EmailMessage, text: String? = nil) -> InvoiceInfo {
        InvoiceInfo(
            merchant: merchantFromDisplayName(message.from),
            amount: largestAmount(in: text ?? extractionText(for: message))
        )
    }

    private static func merchantFromDisplayName(_ from: String) -> String? {
        let name: String
        if let angleBracket = from.firstIndex(of: "<") {
            name = String(from[from.startIndex..<angleBracket])
        } else {
            name = from
        }
        let trimmed = name.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Finds every `<amount> <EUR|€>` / `<EUR|€> <amount>` occurrence and returns the largest one,
    /// formatted as "N,NN EUR" (largest = gross total heuristic: subtotal/tax lines are smaller).
    private static func largestAmount(in text: String) -> String? {
        let pattern = #"€\s?(\d[\d.,]*\d)|EUR\s?(\d[\d.,]*\d)|(\d[\d.,]*\d)\s?€|(\d[\d.,]*\d)\s?EUR"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let nsText = text as NSString

        var best: Double?
        for match in regex.matches(in: text, range: NSRange(location: 0, length: nsText.length)) {
            for group in 1...4 {
                let range = match.range(at: group)
                guard range.location != NSNotFound, let value = parseAmount(nsText.substring(with: range)) else { continue }
                if best == nil || value > best! { best = value }
                break
            }
        }
        guard let best else { return nil }
        return normalizedAmountString(best, currency: "EUR")
    }

    /// Parses a number that may use German grouping (`1.234,56`), a bare decimal comma (`12,34`),
    /// or a bare decimal point (`12.34`), returning its value regardless of which style was used.
    private static func parseAmount(_ raw: String) -> Double? {
        var normalized = raw.trimmingCharacters(in: .whitespaces)
        if normalized.contains(",") {
            normalized = normalized.replacingOccurrences(of: ".", with: "")
            normalized = normalized.replacingOccurrences(of: ",", with: ".")
        }
        return Double(normalized)
    }

    private static func normalizedAmountString(_ value: Double, currency: String) -> String {
        String(format: "%.2f", value).replacingOccurrences(of: ".", with: ",") + " " + currency
    }

    // MARK: - Shared input text

    /// Subject + From + plain-text body (or HTML with tags crudely stripped), capped for the LLM
    /// context and to keep the regex fallback fast.
    private static func extractionText(for message: EmailMessage) -> String {
        var parts = [message.subject, message.from]
        if let plain = message.plainBody, !plain.isEmpty {
            parts.append(plain)
        } else if let html = message.htmlBody {
            parts.append(html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression))
        }
        return String(parts.joined(separator: "\n").prefix(maxInputLength))
    }
}
