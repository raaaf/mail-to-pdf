import SwiftUI

@main
struct MailToPDFApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 360, height: 360)
        .defaultPosition(.center)
        .windowResizability(.contentSize)
    }
}
