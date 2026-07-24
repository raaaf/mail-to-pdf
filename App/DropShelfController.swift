import AppKit
import Observation
import SwiftUI

/// Drives the shelf's highlight state from `DropTargetView`'s plain closure callback.
@Observable
private final class ShelfHighlightModel {
    var isTargeted = false
}

/// The shelf's content: mirrors ContentView's state-driven drop zone (idle prompt, converting
/// progress, page preview, done/cancelled/failed result) at a smaller size, so a drop on the
/// shelf shows its own live feedback instead of vanishing until the save panel appears. Tapping
/// a failed card dismisses it back to idle.
private struct ShelfContentView: View {
    let model: ConvertModel
    let highlight: ShelfHighlightModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16)
                .fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(borderColor, style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
            content
                .padding(16)
                .multilineTextAlignment(.center)
                .animation(reduceMotion ? nil : .spring(duration: 0.35), value: model.state)
        }
        .frame(width: DropShelfController.shelfSize.width, height: DropShelfController.shelfSize.height)
        .contentShape(Rectangle())
        .onTapGesture { model.dismissFailure() }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: highlight.isTargeted)
    }

    private var borderColor: Color {
        if highlight.isTargeted { return .accentColor }
        if case .failed = model.state { return .red.opacity(0.6) }
        return .secondary.opacity(0.5)
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle:
            idleContent
                .transition(reduceMotion ? .identity : .opacity)
        case .converting(let name):
            convertingContent(name: name)
                .transition(reduceMotion ? .identity : .opacity)
        case .saving(let preview, let pages):
            previewContent(image: preview, pages: pages)
                .transition(ConvertModel.previewTransition(reduceMotion: reduceMotion))
        case .done(let name):
            resultContent(systemName: "checkmark.circle.fill", color: .green, title: "Gespeichert", detail: name, bounce: true)
                .transition(reduceMotion ? .identity : .opacity)
        case .cancelled:
            resultContent(systemName: "minus.circle.fill", color: .secondary, title: "Abgebrochen", detail: nil, bounce: false)
                .transition(reduceMotion ? .identity : .opacity)
        case .failed(let message):
            resultContent(systemName: "xmark.circle.fill", color: .red, title: "Fehlgeschlagen", detail: message,
                          hint: "Klicken zum Schließen", bounce: false)
                .transition(reduceMotion ? .identity : .opacity)
        }
    }

    private var idleContent: some View {
        VStack(spacing: 8) {
            Image(systemName: "envelope.arrow.triangle.branch")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(highlight.isTargeted ? Color.accentColor : Color.secondary)
            Text("Hierher ziehen")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
    }

    private func convertingContent(name: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "envelope.open")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(Color.accentColor)
                .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion)
            Text("Wird verarbeitet…")
                .font(.caption.weight(.medium))
            Text(name)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            ProgressView().controlSize(.small)
        }
    }

    private func previewContent(image: NSImage, pages: Int) -> some View {
        VStack(spacing: 6) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxHeight: 190)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .shadow(color: .black.opacity(0.25), radius: 12, y: 6)
            Text(ConvertModel.pageCountLabel(pages))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func resultContent(systemName: String, color: Color, title: String, detail: String?,
                                hint: String? = nil, bounce: Bool) -> some View {
        VStack(spacing: 6) {
            Group {
                if bounce && !reduceMotion {
                    Image(systemName: systemName).symbolEffect(.bounce, options: .nonRepeating, value: model.state)
                } else {
                    Image(systemName: systemName)
                }
            }
            .font(.system(size: 28, weight: .light))
            .foregroundStyle(color)
            Text(title)
                .font(.caption.weight(.medium))
            if let detail {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(color == .red ? .red : .secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            if let hint {
                Text(hint)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

/// A small floating drop target that fades in just below the mouse cursor when the user starts
/// dragging a Mail message or `.eml` file anywhere in the system, so they don't have to aim for
/// the menubar icon (or hover the very top edge, which risks triggering Mission Control). Detects
/// relevant drags by polling the system drag pasteboard from global mouse-drag monitors, the same
/// technique used by menubar utilities that don't want to register as a full drag destination
/// everywhere; this needs no Accessibility permission. Once something is dropped on it, the shelf
/// stays up and shows the same converting/done/failed feedback as the popover, then fades out the
/// moment the state moves to `.saving`, since the centered save dialog that appears right after
/// takes over as the visible surface.
@MainActor
final class DropShelfController {
    static let shelfSize = NSSize(width: 240, height: 300)
    private static let fadeDuration: TimeInterval = 0.15
    private static let hideDelay: Double = 0.25

    private let model: ConvertModel
    private let highlight = ShelfHighlightModel()

    /// Created once and reused for the controller's lifetime, never deallocated in between shows.
    /// The Mail drop path (`receiveMailSelection`) runs an AppleScript for up to ~2s and holds its
    /// `DropTargetView` only weakly; if `hideShelf` tore down the panel/view hierarchy in between,
    /// that weak reference would go nil mid-flight and silently drop the converted mail.
    private lazy var panel: NSPanel = makePanel()

    // Plain opaque monitor tokens (never touched concurrently: only assigned on the main actor in
    // `installMonitors`, only read in the nonisolated `deinit`), so `nonisolated(unsafe)` is safe
    // and lets `deinit` (which can't be MainActor-isolated, per Swift 6) remove them.
    private nonisolated(unsafe) var globalDragMonitor: Any?
    private nonisolated(unsafe) var globalUpMonitor: Any?
    private nonisolated(unsafe) var localUpMonitor: Any?
    private var lastSeenChangeCount = -1
    private var hideTask: Task<Void, Never>?

    init(model: ConvertModel) {
        self.model = model
        installMonitors()
        observeModelState()
    }

    deinit {
        if let globalDragMonitor { NSEvent.removeMonitor(globalDragMonitor) }
        if let globalUpMonitor { NSEvent.removeMonitor(globalUpMonitor) }
        if let localUpMonitor { NSEvent.removeMonitor(localUpMonitor) }
    }

    // MARK: - Drag detection

    /// Only a global monitor for drag movement: a drag started inside our own popover doesn't
    /// need the shelf, and simply not monitoring local drags is the simplest way to ignore it.
    /// Mouse-up is monitored both locally and globally, so the shelf always gets a hide check
    /// whether the drop lands inside our own app or elsewhere.
    private func installMonitors() {
        globalDragMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged]) { [weak self] event in
            self?.handleDragged(event)
        }
        globalUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] _ in
            self?.scheduleHide()
        }
        localUpMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] event in
            self?.scheduleHide()
            return event
        }
    }

    private func handleDragged(_ event: NSEvent) {
        let pasteboard = NSPasteboard(name: .drag)
        let changeCount = pasteboard.changeCount
        guard changeCount != lastSeenChangeCount else { return }
        lastSeenChangeCount = changeCount
        guard isRelevantDrag(pasteboard) else { return }
        hideTask?.cancel()
        hideTask = nil
        showShelf()
    }

    private func isRelevantDrag(_ pasteboard: NSPasteboard) -> Bool {
        if pasteboard.types?.contains(DropTargetView.mailMessageTransferType) == true {
            return true
        }
        if pasteboard.canReadObject(forClasses: [NSFilePromiseReceiver.self], options: nil) {
            return true
        }
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] {
            return urls.contains { $0.pathExtension.lowercased() == "eml" }
        }
        return false
    }

    /// Hides after a short delay, but only if the model is idle by then: a drag that ended without
    /// dropping on the shelf leaves the model idle, so this fires; a drop that's still being
    /// processed (converting/saving/done/failed) is left alone. The same delayed re-check is
    /// reused by `observeModelState` once processing finishes and the model returns to idle on its
    /// own, so there is exactly one hide-scheduling implementation for both triggers.
    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.hideDelay))
            guard !Task.isCancelled, let self, self.model.state == .idle else { return }
            self.hideShelf(animated: true)
        }
    }

    /// Re-subscribes after every change, since `withObservationTracking` fires its `onChange`
    /// closure only once per registration. The closure itself runs off the main actor, so hop
    /// back before touching `self`. When the model settles back to idle (either the auto-reset
    /// after done/cancelled, or a tap dismissing a failed card) while the shelf is visible, this
    /// schedules the same delayed hide as a mouse-up with nothing dropped.
    private func observeModelState() {
        withObservationTracking {
            _ = model.state
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.handleModelStateChange()
                self?.observeModelState()
            }
        }
    }

    private func handleModelStateChange() {
        guard panel.isVisible else { return }
        if case .saving = model.state {
            // The centered save dialog presents right after this state is set and takes over as
            // the visible surface, so the shelf's own preview card would just be redundant.
            // Must complete synchronously (not the animated/Task-spawning path): `presentSavePanel`
            // calls `runModal()` right after, which blocks the MainActor, so any hide work still
            // queued as a separate Task would never run until the save panel closes.
            hideShelf(animated: false)
        } else if model.state == .idle {
            scheduleHide()
        }
    }

    // MARK: - Shelf panel

    /// Reuses the existing panel, just repositioning and fading it in. Guards against a redundant
    /// double-show via `isVisible` rather than `panel == nil`, since the panel is never nilled out.
    private func showShelf() {
        guard !panel.isVisible else { return }
        position(panel)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        Task { await animateAlpha(of: panel, to: 1) }
    }

    /// Only fades/orders the panel out; never releases it or its view hierarchy. See the `panel`
    /// property's doc comment for why the panel must survive across hides.
    private func hideShelf(animated: Bool) {
        hideTask?.cancel()
        hideTask = nil
        guard panel.isVisible else { return }
        guard animated else {
            panel.orderOut(nil)
            return
        }
        Task {
            await animateAlpha(of: panel, to: 0)
            panel.orderOut(nil)
        }
    }

    /// Fades `panel` to `value`, awaiting the animation's completion via the `async` overload of
    /// `runAnimationGroup`. Deliberately not the `completionHandler:` overload: that parameter is
    /// typed `@Sendable`, so its closure cannot capture an AppKit object like `panel`.
    private func animateAlpha(of panel: NSPanel, to value: CGFloat) async {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            panel.alphaValue = value
            return
        }
        await NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fadeDuration
            panel.animator().alphaValue = value
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.shelfSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true

        let hostingView = NSHostingView(rootView: ShelfContentView(model: model, highlight: highlight))
        hostingView.frame = NSRect(origin: .zero, size: Self.shelfSize)
        panel.contentView = hostingView

        let dropView = DropTargetView(frame: hostingView.bounds)
        dropView.autoresizingMask = [.width, .height]
        dropView.onTargeted = { [weak self] targeted in
            self?.highlight.isTargeted = targeted
        }
        dropView.onDropStarted = { [weak self] in
            // Cancel any pending hide immediately, synchronously with the drop: the AppleScript
            // Mail import can take 0.5-2s before `onFiles` fires, and the mouse-up-triggered
            // `scheduleHide` would otherwise see `.idle` at its +0.25s fire time and hide the
            // shelf out from under the import. `beginReceiving` flips state to `.converting`
            // right away, so that fire-time idle check fails too, belt and suspenders.
            self?.hideTask?.cancel()
            self?.model.beginReceiving()
        }
        dropView.onFiles = { [weak self] urls in
            // Deliberately does not hide: the card now shows converting/saving/done feedback in
            // place, and the shelf hides itself once the model settles back to idle.
            NSApp.activate(ignoringOtherApps: true)
            self?.model.handle(urls)
        }
        dropView.onError = { [weak self] message in
            self?.model.fail(message)
        }
        hostingView.addSubview(dropView)

        return panel
    }

    /// Positions the panel just below the mouse cursor at the moment a relevant drag is detected.
    /// Called once per show, not on every mouse move: a target that keeps tracking the cursor
    /// would run away from it as the user tries to drop onto it. Clamped fully inside the visible
    /// frame of whichever screen currently has the mouse, so it never hangs off-screen (or under
    /// the Dock/menu bar) when the drag starts near an edge.
    private func position(_ panel: NSPanel) {
        let mouseLocation = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) ?? NSScreen.main else { return }
        let margin: CGFloat = 8
        let visibleFrame = screen.visibleFrame
        var origin = NSPoint(
            x: mouseLocation.x - Self.shelfSize.width / 2,
            y: mouseLocation.y - Self.shelfSize.height - 40
        )
        origin.x = min(max(origin.x, visibleFrame.minX + margin), visibleFrame.maxX - Self.shelfSize.width - margin)
        origin.y = min(max(origin.y, visibleFrame.minY + margin), visibleFrame.maxY - Self.shelfSize.height - margin)
        panel.setFrameOrigin(origin)
    }
}
