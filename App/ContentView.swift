import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var model = ConvertModel()
    @State private var isTargeted = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        dropZone
            .frame(minWidth: 340, minHeight: 340)
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [UTType(filenameExtension: "eml")!, .emailMessage]
        if panel.runModal() == .OK {
            model.handle(panel.urls)
        }
    }

    // MARK: - Drop zone

    private var dropZone: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 22)
                .fill(isTargeted ? Color.accentColor.opacity(0.14) : Color(nsColor: .windowBackgroundColor))
            RoundedRectangle(cornerRadius: 22)
                .strokeBorder(
                    isTargeted ? Color.accentColor : Color.secondary.opacity(0.35),
                    style: StrokeStyle(lineWidth: 2, dash: [9, 7]))
            stateContent
                .padding(24)
                .multilineTextAlignment(.center)
                .animation(reduceMotion ? nil : .spring(duration: 0.35), value: model.state)
        }
        .padding(16)
        .overlay {
            MailDropView(onTargeted: { isTargeted = $0 }, onFiles: { model.handle($0) }, onError: { model.fail($0) })
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: isTargeted)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Ablagebereich für E-Mails")
        .accessibilityValue(accessibilityStateValue)
        .accessibilityHint("Ziehe eine E-Mail aus Apple Mail hierher oder wähle eine .eml-Datei aus, um sie als PDF zu speichern")
    }

    // MARK: - State-driven center content

    private var stateContent: some View {
        VStack(spacing: 14) {
            icon
                .font(.system(size: 54, weight: .light))
                .contentTransition(.symbolEffect(.replace))
                .accessibilityHidden(true)
            Text(title)
                .font(.title3.weight(.medium))
            subtitleText
                .font(.callout)
            if case .converting = model.state {
                ProgressView().controlSize(.small)
            }
            if case .idle = model.state {
                Button("Datei auswählen…") { chooseFiles() }
                    .padding(.top, 2)
                Text(".eml · Nachricht aus Apple Mail")
                    .font(.caption).foregroundStyle(.tertiary)
                    .padding(.top, 2)
            }
        }
    }

    @ViewBuilder
    private var icon: some View {
        switch model.state {
        case .idle:
            Image(systemName: "envelope.arrow.triangle.branch")
                .foregroundStyle(isTargeted ? Color.accentColor : Color.secondary)
                .scaleEffect(isTargeted && !reduceMotion ? 1.08 : 1)
        case .converting:
            Image(systemName: "envelope.open")
                .foregroundStyle(Color.accentColor)
                .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion)
        case .done:
            if reduceMotion {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.green)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.green)
                    .symbolEffect(.bounce, options: .nonRepeating, value: model.state)
            }
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundStyle(Color.red)
        }
    }

    private var title: String {
        switch model.state {
        case .idle: "E-Mail hierher ziehen"
        case .converting: "Wird verarbeitet…"
        case .done: "Gespeichert"
        case .failed: "Fehlgeschlagen"
        }
    }

    private var subtitleText: some View {
        Text(subtitleString)
            .foregroundStyle(subtitleColor)
            .lineLimit(subtitleTruncates ? 1 : nil)
            .truncationMode(.middle)
    }

    private var subtitleString: String {
        switch model.state {
        case .idle: "und sie wird als PDF gespeichert"
        case .converting(let name): name
        case .done(let name): name
        case .failed(let message): message
        }
    }

    private var subtitleColor: Color {
        if case .failed = model.state { return .red }
        return .secondary
    }

    private var subtitleTruncates: Bool {
        switch model.state {
        case .converting, .done: true
        default: false
        }
    }

    private var accessibilityStateValue: String {
        switch model.state {
        case .idle: ""
        case .converting: "Verarbeitung läuft"
        case .done: "Erfolgreich gespeichert"
        case .failed(let message): message
        }
    }
}
