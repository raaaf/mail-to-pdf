import AppKit
import Observation
import SwiftUI

/// Owns the menubar status item, which is itself a drop target for Mail messages and `.eml`
/// files (reusing `DropTargetView` exactly as the old in-window overlay did), plus the popover
/// that hosts the existing `ContentView` drop zone.
@MainActor
final class StatusItemController {
    private static let idleSymbol = "envelope.arrow.triangle.branch"

    private let model = ConvertModel()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()
    private var statusIconResetTask: Task<Void, Never>?
    private var dropShelf: DropShelfController?
    private var settingsWindow: NSWindow?

    init() {
        configureButton()
        configurePopover()
        model.onStateChange { [weak self] in self?.handleStateChange() }
        dropShelf = DropShelfController(model: model)
    }

    // MARK: - Status item button + drop target

    private func configureButton() {
        guard let button = statusItem.button else { return }
        setIcon(Self.idleSymbol, description: "MailToPDF")
        button.target = self
        button.action = #selector(statusItemClicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])

        let dropView = DropTargetView(frame: button.bounds)
        dropView.autoresizingMask = [.width, .height]
        dropView.onTargeted = { [weak button] targeted in
            button?.isHighlighted = targeted
        }
        dropView.onDropStarted = { [weak self] in
            self?.model.beginReceiving()
        }
        dropView.onFiles = { [weak self] urls in
            NSApp.activate(ignoringOtherApps: true)
            self?.model.handle(urls)
        }
        dropView.onError = { [weak self] message in
            self?.model.fail(message)
            self?.showPopover()
        }
        button.addSubview(dropView)
    }

    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        // Control+left-click is the macOS convention for triggering a context menu, alongside
        // an actual right-click.
        let isControlClick = event?.type == .leftMouseUp && event?.modifierFlags.contains(.control) == true
        if event?.type == .rightMouseUp || isControlClick {
            showMenu()
        } else {
            togglePopover()
        }
    }

    // MARK: - Right-click menu

    private func showMenu() {
        guard let button = statusItem.button else { return }
        let menu = NSMenu()

        let settingsItem = NSMenuItem(title: "Einstellungen…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.keyEquivalentModifierMask = [.command]
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Beenden", action: #selector(quit), keyEquivalent: "q")
        quitItem.keyEquivalentModifierMask = [.command]
        quitItem.target = self
        menu.addItem(quitItem)

        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Settings window

    /// Lazily creates one settings window and reuses it on subsequent opens. `LSUIElement` apps
    /// can still show regular windows; a menubar app has no Dock icon to relaunch it from, so the
    /// window is kept alive (`isReleasedWhenClosed = false`) rather than torn down on close.
    @objc private func openSettings() {
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 300, height: 260),
                styleMask: [.titled, .closable],
                backing: .buffered, defer: false
            )
            window.title = "Einstellungen"
            window.isReleasedWhenClosed = false
            let hostingController = NSHostingController(rootView: SettingsView())
            window.contentViewController = hostingController
            window.setContentSize(hostingController.view.fittingSize)
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Popover

    private func configurePopover() {
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 360, height: 420)
        popover.contentViewController = NSHostingController(rootView: ContentView(model: model))
    }

    private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem.button, !popover.isShown else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Status icon feedback

    private func handleStateChange() {
        switch model.state {
        case .done: showTemporaryIcon("checkmark.circle", description: "MailToPDF – Gespeichert")
        case .failed: showTemporaryIcon("xmark.circle", description: "MailToPDF – Fehlgeschlagen")
        default: break
        }
    }

    /// Swaps to `symbolName` for ~2s, then back to the idle envelope icon.
    private func showTemporaryIcon(_ symbolName: String, description: String) {
        statusIconResetTask?.cancel()
        setIcon(symbolName, description: description)
        statusIconResetTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.setIcon(Self.idleSymbol, description: "MailToPDF")
        }
    }

    private func setIcon(_ symbolName: String, description: String) {
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: description)
        image?.isTemplate = true
        statusItem.button?.image = image
    }
}
