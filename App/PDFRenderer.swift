import AppKit
import WebKit

/// Renders a parsed email as a paginated A4 PDF via an offscreen WKWebView + NSPrintOperation.
/// Not unit-testable headlessly (needs a live WebKit render + print pipeline); correctness is
/// verified by compilation and manual testing.
@MainActor
final class PDFRenderer: NSObject, WKNavigationDelegate {

    enum RenderError: Error {
        case printFailed
    }

    private var webView: WKWebView?
    private var loadContinuation: (() -> Void)?
    private var printContinuation: ((Bool) -> Void)?

    func render(message: EmailMessage, to url: URL) async throws {
        let html = composeHTML(for: message)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 595, height: 842))
        webView.navigationDelegate = self
        self.webView = webView

        await waitForLoad(timeout: .seconds(10)) {
            webView.loadHTMLString(html, baseURL: nil)
        }
        try? await Task.sleep(for: .seconds(1.5)) // grace period for images to finish loading

        var success = await runPrintOperation(webView: webView, url: url)
        if !success || !FileManager.default.fileExists(atPath: url.path) {
            success = await fallbackCreatePDF(webView: webView, url: url)
        }
        self.webView = nil

        guard success else { throw RenderError.printFailed }
    }

    // MARK: - HTML composition

    private func composeHTML(for message: EmailMessage) -> String {
        let header = headerBlock(for: message)
        if let html = message.htmlBody {
            return insertHeader(header, into: html)
        }
        let escaped = escapeHTML(message.plainBody ?? "")
        let body = "<pre style=\"font: 12px -apple-system; white-space: pre-wrap\">\(escaped)</pre>"
        return "<!DOCTYPE html><html><head><meta charset=\"utf-8\"></head><body>\(header)\(body)</body></html>"
    }

    private func headerBlock(for message: EmailMessage) -> String {
        let dateString = message.date.map {
            DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .short)
        } ?? ""
        return """
        <div style="font: 12px -apple-system; color: #333; margin-bottom: 12px;">
          <div><strong>Von:</strong> \(escapeHTML(message.from))</div>
          <div><strong>Betreff:</strong> \(escapeHTML(message.subject))</div>
          <div><strong>Datum:</strong> \(escapeHTML(dateString))</div>
        </div>
        <hr>
        """
    }

    private func insertHeader(_ header: String, into html: String) -> String {
        if let range = html.range(of: "<body[^>]*>", options: [.regularExpression, .caseInsensitive]) {
            var result = html
            result.insert(contentsOf: header, at: range.upperBound)
            return result
        }
        return "<!DOCTYPE html><html><head><meta charset=\"utf-8\"></head><body>\(header)\(html)</body></html>"
    }

    private func escapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    // MARK: - Load waiting (with timeout)

    private func waitForLoad(timeout: Duration, start: () -> Void) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var resumed = false
            let resume: () -> Void = { [weak self] in
                guard !resumed else { return }
                resumed = true
                self?.loadContinuation = nil
                continuation.resume()
            }
            loadContinuation = resume
            start()
            Task {
                try? await Task.sleep(for: timeout)
                resume()
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loadContinuation?()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loadContinuation?()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loadContinuation?()
    }

    // MARK: - Pagination via NSPrintOperation

    private func runPrintOperation(webView: WKWebView, url: URL) async -> Bool {
        let printInfo = NSPrintInfo()
        printInfo.paperSize = NSSize(width: 595.28, height: 841.89)
        printInfo.topMargin = 36
        printInfo.bottomMargin = 36
        printInfo.leftMargin = 36
        printInfo.rightMargin = 36
        printInfo.horizontalPagination = .automatic
        printInfo.verticalPagination = .automatic
        printInfo.jobDisposition = .save
        printInfo.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url

        let op = webView.printOperation(with: printInfo)
        op.showsPrintPanel = false
        op.showsProgressPanel = false
        op.view?.frame = NSRect(origin: .zero, size: printInfo.paperSize)

        let hostWindow = NSApp.keyWindow ?? offscreenWindow()

        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            printContinuation = { success in continuation.resume(returning: success) }
            op.runModal(for: hostWindow, delegate: self,
                        didRun: #selector(PDFRenderer.printOperationDidRun(_:success:contextInfo:)),
                        contextInfo: nil)
        }
    }

    // NSPrintOperation may invoke this on a background thread (observed in a crash report), so it
    // cannot be MainActor-isolated like the rest of this class; hop explicitly before touching state.
    @objc private nonisolated func printOperationDidRun(_ printOperation: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.printContinuation?(success)
                self?.printContinuation = nil
            }
        }
    }

    private func offscreenWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 595, height: 842),
                               styleMask: [.borderless], backing: .buffered, defer: false)
        window.setIsVisible(false)
        return window
    }

    // MARK: - Fallback: direct PDF snapshot

    private func fallbackCreatePDF(webView: WKWebView, url: URL) async -> Bool {
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<Result<Data, Error>, Never>) in
            webView.createPDF(configuration: WKPDFConfiguration()) { result in
                continuation.resume(returning: result)
            }
        }
        guard case .success(let data) = result else { return false }
        do {
            try data.write(to: url)
            return true
        } catch {
            return false
        }
    }
}
