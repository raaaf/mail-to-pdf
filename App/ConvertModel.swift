import AppKit
import Observation
import PDFKit
import SwiftUI
import UniformTypeIdentifiers
import os

/// Page-1 thumbnail shown inside the save panel itself (as `accessoryView`), since on a narrow
/// window the panel sheet otherwise covers the in-window preview card entirely.
private struct SavePanelPreview: View {
    let image: NSImage
    let pages: Int

    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxHeight: 280)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .shadow(color: .black.opacity(0.25), radius: 12, y: 6)
                .accessibilityHidden(true)
            Text(ConvertModel.pageCountLabel(pages))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(width: 260, height: 330)
        .accessibilityElement(children: .combine)
    }
}

/// Drives the drop -> parse -> render -> save pipeline and the status shown in ContentView.
@MainActor
@Observable
final class ConvertModel {
    enum State: Equatable {
        case idle
        case converting(String)
        case saving(preview: NSImage, pages: Int)
        case done(String)
        case cancelled
        case failed(String)

        /// The preview image is compared by reference: it is only ever produced once per render,
        /// so identity is a sufficient (and cheap) equality check for the SwiftUI diffing this feeds.
        static func == (lhs: State, rhs: State) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle), (.cancelled, .cancelled):
                return true
            case (.converting(let a), .converting(let b)), (.done(let a), .done(let b)), (.failed(let a), .failed(let b)):
                return a == b
            case (.saving(let imageA, let pagesA), .saving(let imageB, let pagesB)):
                return imageA === imageB && pagesA == pagesB
            default:
                return false
            }
        }
    }

    var state: State = .idle

    private let renderer = PDFRenderer()
    private let logger = Logger(subsystem: "de.rafaelalex.MailToPDF", category: "convert")
    private var resetTask: Task<Void, Never>?
    private var processingTask: Task<Void, Never>?
    private var pendingURLs: [URL] = []
    private var isProcessing = false

    /// Reports an error that happened before any file could be parsed (e.g. drag source access).
    func fail(_ message: String) {
        state = .failed(message)
    }

    /// Processes each dropped file sequentially, showing one save panel per email.
    /// Queues drops that arrive while a conversion is already in flight instead of
    /// running them concurrently against the shared renderer.
    func handle(_ urls: [URL]) {
        pendingURLs.append(contentsOf: urls)
        guard !isProcessing else { return }
        isProcessing = true
        processingTask = Task {
            while !pendingURLs.isEmpty && !Task.isCancelled {
                let url = pendingURLs.removeFirst()
                await process(url)
            }
            isProcessing = false
            processingTask = nil
        }
    }

    /// Cancels the current queue: drops any not-yet-started files and stops the in-flight conversion
    /// at the next safe checkpoint.
    func cancel() {
        pendingURLs.removeAll()
        processingTask?.cancel()
    }

    /// Cancels any pending auto-reset-to-idle and schedules a new one after `seconds`.
    private func scheduleReset(after seconds: Double) {
        resetTask?.cancel()
        resetTask = Task {
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            state = .idle
        }
    }

    private func process(_ url: URL) async {
        resetTask?.cancel()
        resetTask = nil
        state = .converting(url.lastPathComponent)
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("pdf")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        do {
            let message = try await Task.detached {
                try EmailParser.parse(fileURL: url)
            }.value
            guard !Task.isCancelled else {
                state = .cancelled
                scheduleReset(after: 3)
                cleanUpIfMailDrop(url)
                return
            }
            async let invoiceInfo = InvoiceExtractor.extract(from: message)
            try await renderer.render(message: message, to: tempURL)
            guard !Task.isCancelled else {
                state = .cancelled
                scheduleReset(after: 3)
                cleanUpIfMailDrop(url)
                return
            }

            let preview: (thumbnail: NSImage, pages: Int)?
            if let rendered = await Task.detached { Self.makePreview(url: tempURL) }.value,
               let image = NSImage(data: rendered.thumbnailData) {
                preview = (image, rendered.pages)
            } else {
                preview = nil
            }
            // Show the preview immediately; the invoice extraction (which the LLM can stall on)
            // is awaited only afterwards, right before it's needed for the panel's filename.
            if let preview {
                state = .saving(preview: preview.thumbnail, pages: preview.pages)
            }

            let invoice = await invoiceInfo

            let panel = NSSavePanel()
            panel.allowedContentTypes = [.pdf]
            panel.nameFieldStringValue = suggestedFilename(for: message, invoice: invoice)
            if let preview {
                panel.accessoryView = makeAccessoryView(thumbnail: preview.thumbnail, pages: preview.pages)
            }
            guard await presentSavePanel(panel) == .OK, let destination = panel.url else {
                state = .cancelled
                scheduleReset(after: 3)
                cleanUpIfMailDrop(url)
                return
            }

            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: tempURL, to: destination)

            let failedAttachments = saveAttachments(message.pdfAttachments,
                                                      baseName: destination.deletingPathExtension().lastPathComponent,
                                                      directory: destination.deletingLastPathComponent())

            if failedAttachments > 0 {
                state = .failed("\(failedAttachments) von \(message.pdfAttachments.count) Anhängen konnten nicht gespeichert werden.")
            } else {
                state = .done(destination.lastPathComponent)
                scheduleReset(after: 3)
            }
            cleanUpIfMailDrop(url)
        } catch {
            logger.error("Failed to convert \(url.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
            fail("Die E-Mail konnte nicht verarbeitet werden. Prüfe die Datei oder versuche es erneut.")
            cleanUpIfMailDrop(url)
        }
    }

    /// Writes each PDF attachment next to the saved email PDF, deduping filename collisions.
    /// Returns the number of attachments that could not be written.
    private func saveAttachments(_ attachments: [PDFAttachment], baseName: String, directory: URL) -> Int {
        var failed = 0
        for attachment in attachments {
            let sanitized = FilenameSanitizer.sanitize(attachment.filename)
            let url = uniqueURL(for: "\(baseName) – \(sanitized)", in: directory)
            do {
                try attachment.data.write(to: url)
            } catch {
                failed += 1
            }
        }
        return failed
    }

    /// Appends " 2", " 3", ... before the extension until the filename no longer collides.
    private func uniqueURL(for filename: String, in directory: URL) -> URL {
        let stem = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        var candidate = directory.appendingPathComponent(filename)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let suffixed = ext.isEmpty ? "\(stem) \(counter)" : "\(stem) \(counter).\(ext)"
            candidate = directory.appendingPathComponent(suffixed)
            counter += 1
        }
        return candidate
    }

    /// Removes Mail's temporary drop file (and its parent directory, if now empty) after processing.
    /// Only touches files under a parent directory named "MailToPDF-…" inside the temp directory,
    /// so files dropped directly from Finder are never deleted.
    private func cleanUpIfMailDrop(_ url: URL) {
        let parent = url.deletingLastPathComponent()
        guard parent.deletingLastPathComponent().standardizedFileURL == FileManager.default.temporaryDirectory.standardizedFileURL,
              parent.lastPathComponent.hasPrefix("MailToPDF-") else { return }
        try? FileManager.default.removeItem(at: url)
        if let remaining = try? FileManager.default.contentsOfDirectory(atPath: parent.path), remaining.isEmpty {
            try? FileManager.default.removeItem(at: parent)
        }
    }

    /// Renders a small page-1 thumbnail plus the total page count, for the "saving" preview card
    /// and the save panel's accessory view. Returns nil if the PDF can't be opened; the pipeline
    /// still proceeds straight to the save panel in that case.
    /// Does synchronous disk I/O, so it's `nonisolated` and meant to be called off the main actor
    /// (e.g. via `Task.detached`); the thumbnail comes back as `Data` rather than `NSImage`, which
    /// isn't `Sendable`, and is turned back into an image on the main actor by the caller.
    nonisolated static func makePreview(url: URL) -> (thumbnailData: Data, pages: Int)? {
        guard let document = PDFDocument(url: url), let page = document.page(at: 0) else { return nil }
        let thumbnail = page.thumbnail(of: NSSize(width: 220, height: 300), for: .mediaBox)
        guard let thumbnailData = thumbnail.tiffRepresentation else { return nil }
        return (thumbnailData, document.pageCount)
    }

    /// Shared "Seite 1 von N" caption used by the in-window preview card and the save panel's
    /// accessory view, with the singular special case for a 1-page document.
    static func pageCountLabel(_ pages: Int) -> String {
        pages == 1 ? "Seite 1 von 1" : "Seite 1 von \(pages)"
    }

    /// Wraps the SwiftUI preview in an `NSHostingView` sized to fit the panel's accessory area.
    private func makeAccessoryView(thumbnail: NSImage, pages: Int) -> NSView {
        let hostingView = NSHostingView(rootView: SavePanelPreview(image: thumbnail, pages: pages))
        hostingView.frame = NSRect(x: 0, y: 0, width: 260, height: 330)
        return hostingView
    }

    /// Shows the save panel as a sheet on the key/main window (no extra click versus a plain modal),
    /// falling back to `runModal()` if there is no window to attach a sheet to.
    private func presentSavePanel(_ panel: NSSavePanel) async -> NSApplication.ModalResponse {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else {
            return panel.runModal()
        }
        return await withCheckedContinuation { continuation in
            panel.beginSheetModal(for: window) { response in
                continuation.resume(returning: response)
            }
        }
    }

    /// Builds "<date> <merchant> <amount>.pdf" from whatever `invoice` could extract, omitting
    /// missing parts. The amount is what makes the name self-sufficient without the subject, so
    /// the sanitized subject is appended whenever no amount was extracted, regardless of whether
    /// a merchant was found.
    func suggestedFilename(for message: EmailMessage, invoice: InvoiceInfo = InvoiceInfo(merchant: nil, amount: nil)) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let dateString = dateFormatter.string(from: message.date ?? Date())

        var parts = [dateString]
        if let merchant = invoice.merchant, !merchant.isEmpty {
            parts.append(FilenameSanitizer.sanitize(merchant, maxLength: 60, fallback: ""))
        }
        if let amount = invoice.amount, !amount.isEmpty {
            parts.append(FilenameSanitizer.sanitize(amount, maxLength: 20, fallback: ""))
        }
        if invoice.amount == nil {
            parts.append(FilenameSanitizer.sanitize(message.subject, maxLength: 80, fallback: "E-Mail"))
        }
        return parts.filter { !$0.isEmpty }.joined(separator: " ") + ".pdf"
    }
}
