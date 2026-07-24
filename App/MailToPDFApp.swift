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
        configureMainMenu()
    }

    /// `LSUIElement` hides the menu bar, but an `NSMenu` installed as `NSApp.mainMenu` still
    /// wires up its key equivalents app-wide even though it's never drawn. This invisible menu
    /// exists solely so the settings window has a working Cmd+Q and Cmd+W.
    private func configureMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu
        appMenu.addItem(withTitle: "Beenden", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenuItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "Schließen", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        NSApp.mainMenu = mainMenu
    }
}
