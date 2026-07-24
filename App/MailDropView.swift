import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Transparent overlay that accepts a dragged Mail message (AppleScript selection export, with
/// file promise as a fallback for other apps/OS versions) or a Finder `.eml` file.
struct MailDropView: NSViewRepresentable {
    var onTargeted: (Bool) -> Void
    var onFiles: ([URL]) -> Void
    var onError: ((String) -> Void)? = nil

    func makeNSView(context: Context) -> DropTargetView {
        let view = DropTargetView()
        view.onTargeted = onTargeted
        view.onFiles = onFiles
        view.onError = onError
        return view
    }

    func updateNSView(_ nsView: DropTargetView, context: Context) {
        nsView.onTargeted = onTargeted
        nsView.onFiles = onFiles
        nsView.onError = onError
    }
}

/// Thread-safe collection point for URLs produced by multiple file-promise completion callbacks,
/// which arrive on `promiseQueue` (a background queue), not the main actor.
private final class ReceivedURLBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URL] = []

    func append(_ url: URL) {
        lock.lock()
        storage.append(url)
        lock.unlock()
    }

    var urls: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

@MainActor
final class DropTargetView: NSView {
    /// Mail.app puts this type (and no file promise) on the drag pasteboard for its own messages.
    static let mailMessageTransferType = NSPasteboard.PasteboardType("com.apple.mail.PasteboardTypeMessageTransfer")

    var onTargeted: ((Bool) -> Void)?
    var onFiles: (([URL]) -> Void)?
    var onError: ((String) -> Void)?

    /// Dedicated queue for `NSFilePromiseReceiver` completion work, per Apple's guidance.
    private let promiseQueue = OperationQueue()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerDragTypes()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerDragTypes()
    }

    private func registerDragTypes() {
        let promiseTypes = NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
        registerForDraggedTypes(promiseTypes + [.fileURL, Self.mailMessageTransferType])
    }

    // Let mouse events (e.g. the "Datei auswählen…" button) pass through to the SwiftUI content
    // below. AppKit resolves drag-and-drop destinations via registeredDraggedTypes, not hitTest,
    // so this view still receives drag callbacks even though it is invisible to click hit testing.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let accept = isAcceptable(sender)
        onTargeted?(accept)
        return accept ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onTargeted?(false)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        onTargeted?(false)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onTargeted?(false)
        let pasteboard = sender.draggingPasteboard

        // Mail.app messages: no file promise is offered, only this custom pasteboard type.
        if pasteboard.types?.contains(Self.mailMessageTransferType) == true {
            receiveMailSelection()
            return true
        }

        guard let objects = pasteboard.readObjects(
            forClasses: [NSFilePromiseReceiver.self, NSURL.self], options: nil
        ), !objects.isEmpty else { return false }

        var directURLs: [URL] = []
        var promiseReceivers: [NSFilePromiseReceiver] = []
        for object in objects {
            if let receiver = object as? NSFilePromiseReceiver {
                promiseReceivers.append(receiver)
            } else if let url = object as? URL, isEML(url) {
                directURLs.append(url)
            }
        }
        guard !directURLs.isEmpty || !promiseReceivers.isEmpty else { return false }

        if !directURLs.isEmpty {
            onFiles?(directURLs)
        }
        if !promiseReceivers.isEmpty {
            receivePromises(promiseReceivers)
        }
        return true
    }

    // MARK: - Mail.app selection export (AppleScript)

    private static let mailAccessErrorMessage = "Zugriff auf Mail wurde verweigert. Erlaube ihn unter Systemeinstellungen > Datenschutz & Sicherheit > Automation."

    /// Converts the messages currently selected in Mail.app (a drag always carries the selection,
    /// so dragging N selected messages converts all N) by running an AppleScript off the main
    /// actor, writing each raw source to a temp .eml file, then hopping back to report the result.
    private func receiveMailSelection() {
        Task.detached { [weak self] in
            let urls = Self.writeMailSelectionToFiles()
            await MainActor.run {
                guard let self else { return }
                if let urls, !urls.isEmpty {
                    self.onFiles?(urls)
                } else {
                    self.onError?(Self.mailAccessErrorMessage)
                }
            }
        }
    }

    /// Runs the AppleScript and writes each returned message source to a temp .eml file.
    /// Returns nil on script error or empty selection, so the caller reports a single error.
    private nonisolated static func writeMailSelectionToFiles() -> [URL]? {
        guard let sources = runMailSelectionSources(), !sources.isEmpty else { return nil }

        let destinationDir = makeTempDestinationDirectory()
        var urls: [URL] = []
        for (index, source) in sources.enumerated() {
            let data = source.data(using: .utf8) ?? source.data(using: .isoLatin1) ?? Data()
            let url = destinationDir.appendingPathComponent("message-\(index + 1).eml")
            if (try? data.write(to: url)) != nil {
                urls.append(url)
            }
        }
        return urls
    }

    /// Uses `NSAppleScript` (not `osascript`) so the TCC automation prompt attributes to this app.
    private nonisolated static func runMailSelectionSources() -> [String]? {
        let source = """
        tell application "Mail"
            set msgList to selection
            set srcList to {}
            repeat with m in msgList
                set end of srcList to (source of m) as string
            end repeat
            return srcList
        end tell
        """
        guard let script = NSAppleScript(source: source) else { return nil }
        var errorInfo: NSDictionary?
        let result = script.executeAndReturnError(&errorInfo)
        if errorInfo != nil { return nil }

        let count = result.numberOfItems
        guard count > 0 else { return [] }
        var sources: [String] = []
        for index in 1...count {
            if let value = result.atIndex(index)?.stringValue {
                sources.append(value)
            }
        }
        return sources
    }

    // MARK: - File promise receiving (fallback for other apps/OS versions)

    /// Creates a fresh temp subdirectory to receive converted/exported message files into.
    private nonisolated static func makeTempDestinationDirectory() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MailToPDF-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Receives every promised file into a fresh temp subdirectory, skipping files that error out,
    /// then hops back to the main actor once all receivers have completed.
    private func receivePromises(_ receivers: [NSFilePromiseReceiver]) {
        let destinationDir = Self.makeTempDestinationDirectory()
        let collected = ReceivedURLBox()
        let group = DispatchGroup()
        for receiver in receivers {
            group.enter()
            receiver.receivePromisedFiles(atDestination: destinationDir, options: [:], operationQueue: promiseQueue) { url, error in
                if error == nil { collected.append(url) }
                group.leave()
            }
        }
        group.notify(queue: .main) { [weak self] in
            // group.notify(queue: .main) guarantees this runs on the main thread; assumeIsolated
            // makes that guarantee visible to the compiler so `self` (a @MainActor type) can be touched.
            MainActor.assumeIsolated {
                let urls = collected.urls
                guard !urls.isEmpty else { return }
                self?.onFiles?(urls)
            }
        }
    }

    private func isAcceptable(_ sender: NSDraggingInfo) -> Bool {
        let pasteboard = sender.draggingPasteboard
        if pasteboard.types?.contains(Self.mailMessageTransferType) == true {
            return true
        }
        if pasteboard.canReadObject(forClasses: [NSFilePromiseReceiver.self], options: nil) {
            return true
        }
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] {
            return urls.contains { isEML($0) }
        }
        return false
    }

    private func isEML(_ url: URL) -> Bool {
        if url.pathExtension.lowercased() == "eml" { return true }
        if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType {
            return type.conforms(to: .emailMessage)
        }
        return false
    }
}
