import AppKit
import Observation
import UniformTypeIdentifiers

/// Drives the drop -> parse -> render -> save pipeline and the status shown in ContentView.
@MainActor
@Observable
final class ConvertModel {
    enum State: Equatable {
        case idle
        case converting(String)
        case done(String)
        case failed(String)
    }

    var state: State = .idle

    private let renderer = PDFRenderer()
    private var resetTask: Task<Void, Never>?

    /// Reports an error that happened before any file could be parsed (e.g. drag source access).
    func fail(_ message: String) {
        state = .failed(message)
        scheduleReset(after: 5)
    }

    /// Processes each dropped file sequentially, showing one save panel per email.
    func handle(_ urls: [URL]) {
        Task {
            for url in urls {
                await process(url)
            }
        }
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
        do {
            let message = try EmailParser.parse(fileURL: url)
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("pdf")
            try await renderer.render(message: message, to: tempURL)

            let panel = NSSavePanel()
            panel.allowedContentTypes = [.pdf]
            panel.nameFieldStringValue = suggestedFilename(for: message)
            guard panel.runModal() == .OK, let destination = panel.url else {
                try? FileManager.default.removeItem(at: tempURL)
                state = .idle
                return
            }

            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: tempURL, to: destination)

            saveAttachments(message.pdfAttachments,
                             baseName: destination.deletingPathExtension().lastPathComponent,
                             directory: destination.deletingLastPathComponent())

            state = .done(destination.lastPathComponent)
            scheduleReset(after: 3)
        } catch {
            state = .failed("Die E-Mail konnte nicht verarbeitet werden.")
            scheduleReset(after: 5)
        }
    }

    /// Writes each PDF attachment next to the saved email PDF, deduping filename collisions.
    private func saveAttachments(_ attachments: [PDFAttachment], baseName: String, directory: URL) {
        for attachment in attachments {
            let sanitized = FilenameSanitizer.sanitize(attachment.filename, fallback: "Anhang.pdf")
            let url = uniqueURL(for: "\(baseName) – \(sanitized)", in: directory)
            try? attachment.data.write(to: url)
        }
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

    func suggestedFilename(for message: EmailMessage) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let dateString = dateFormatter.string(from: message.date ?? Date())
        let subject = FilenameSanitizer.sanitize(message.subject, maxLength: 80, fallback: "Mail")
        return "\(dateString) \(subject).pdf"
    }
}
