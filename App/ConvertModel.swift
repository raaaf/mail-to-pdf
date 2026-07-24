import AppKit
import Observation
import UniformTypeIdentifiers
import os

/// Drives the drop -> parse -> render -> save pipeline and the status shown in ContentView.
@MainActor
@Observable
final class ConvertModel {
    enum State: Equatable {
        case idle
        case converting(String)
        case done(String)
        case cancelled
        case failed(String)
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
            try await renderer.render(message: message, to: tempURL)
            guard !Task.isCancelled else {
                state = .cancelled
                scheduleReset(after: 3)
                cleanUpIfMailDrop(url)
                return
            }

            let panel = NSSavePanel()
            panel.allowedContentTypes = [.pdf]
            panel.nameFieldStringValue = suggestedFilename(for: message)
            guard panel.runModal() == .OK, let destination = panel.url else {
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

    func suggestedFilename(for message: EmailMessage) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let dateString = dateFormatter.string(from: message.date ?? Date())
        let subject = FilenameSanitizer.sanitize(message.subject, maxLength: 80, fallback: "E-Mail")
        return "\(dateString) \(subject).pdf"
    }
}
