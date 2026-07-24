import AppKit

/// Pure AppDelegate entry point (no SwiftUI `App`/`WindowGroup`): MailToPDF is a menubar-only app
/// with `LSUIElement` set, so there is no Dock icon and no regular window to host a `Scene`.
@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItemController: StatusItemController?

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItemController = StatusItemController()
    }
}
