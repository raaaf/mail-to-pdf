import SwiftUI

/// Settings window opened from the menubar icon's right-click menu: a real (if currently tiny)
/// settings section above a minimal about/credit block. Grows when more settings arrive.
struct SettingsView: View {
    @State private var loginItems = LoginItemManager()

    private var versionString: String {
        let info = Bundle.main.infoDictionary
        let shortVersion = info?["CFBundleShortVersionString"] as? String ?? "-"
        let build = info?["CFBundleVersion"] as? String ?? "-"
        return "Version \(shortVersion) (\(build))"
    }

    var body: some View {
        VStack(spacing: 12) {
            Toggle("Bei Anmeldung starten", isOn: Binding(
                get: { loginItems.isEnabled },
                set: { loginItems.setEnabled($0) }
            ))
            Text("Funktioniert zuverlässig, wenn die App im Programme-Ordner liegt.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Divider()

            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
            Text("MailToPDF")
                .font(.title3.weight(.semibold))
            Text(versionString)
                .font(.caption)
                .foregroundStyle(.secondary)
            Divider()
            Text("Gestaltet und entwickelt von Rafael Alex")
                .font(.callout)
            Link("rafaelalex.de", destination: URL(string: "https://rafaelalex.de")!)
                .font(.callout)
        }
        .padding(24)
        .frame(width: 300, height: 320)
    }
}
