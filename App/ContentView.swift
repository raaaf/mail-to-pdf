import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    let model: ConvertModel
    @State private var isTargeted = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(model: ConvertModel) {
        self.model = model
    }

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
            ViewThatFits(in: .vertical) {
                stateContent
                ScrollView(.vertical) {
                    stateContent
                }
            }
            .padding(24)
            .multilineTextAlignment(.center)
            .animation(reduceMotion ? nil : .spring(duration: 0.35), value: model.state)
        }
        .padding(16)
        .overlay {
            MailDropView(
                onTargeted: { isTargeted = $0 },
                onFiles: { model.handle($0) },
                onError: { model.fail($0) },
                onDropStarted: { model.beginReceiving() }
            )
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: isTargeted)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Ablagebereich für E-Mails")
        .accessibilityValue(accessibilityStateValue)
        .accessibilityHint("Ziehe eine E-Mail aus Apple Mail hierher oder wähle eine .eml-Datei aus, um sie als PDF zu speichern")
        .onChange(of: model.state) { _, _ in
            let text = accessibilityStateValue
            guard !text.isEmpty else { return }
            NSAccessibility.post(
                element: NSApp.mainWindow ?? NSApp as Any,
                notification: .announcementRequested,
                userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }
    }

    // MARK: - State-driven center content

    /// Swaps between the icon/title/subtitle content and the PDF preview card as a whole, so the
    /// preview can slide in "out of the envelope" instead of morphing individual pieces.
    private var stateContent: some View {
        Group {
            if case .saving(let preview, let pages) = model.state {
                previewCard(image: preview, pages: pages)
                    .transition(previewTransition)
            } else {
                defaultStateContent
                    .transition(reduceMotion ? .identity : .opacity)
            }
        }
    }

    private var previewTransition: AnyTransition {
        ConvertModel.previewTransition(reduceMotion: reduceMotion)
    }

    private var defaultStateContent: some View {
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
                Button("Abbrechen") { model.cancel() }
                    .keyboardShortcut(.cancelAction)
                    .padding(.top, 2)
            } else {
                Button("Datei auswählen…") { chooseFiles() }
                    .keyboardShortcut("o", modifiers: .command)
                    .padding(.top, 2)
            }
            if case .idle = model.state {
                Text(".eml · Nachricht aus Apple Mail")
                    .font(.caption).foregroundStyle(.tertiary)
                    .padding(.top, 2)
            }
        }
        .onTapGesture { model.dismissFailure() }
    }

    /// The "saving" state: a page-1 thumbnail with a page-count caption. No icon slot and no
    /// buttons here, the save panel sheet above it owns the save/cancel actions.
    private func previewCard(image: NSImage, pages: Int) -> some View {
        VStack(spacing: 10) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: 220, maxHeight: 300)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .shadow(color: .black.opacity(0.25), radius: 12, y: 6)
                .accessibilityHidden(true)
            Text(ConvertModel.pageCountLabel(pages))
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var icon: some View {
        switch model.state {
        case .idle:
            Image(systemName: "envelope.arrow.triangle.branch")
                .foregroundStyle(isTargeted ? Color.accentColor : Color.secondary)
                .scaleEffect(isTargeted && !reduceMotion ? 1.08 : 1)
        case .saving:
            Image(systemName: "envelope.open")
                .foregroundStyle(Color.accentColor)
        case .converting:
            if let display = model.state.display {
                Image(systemName: display.symbol)
                    .foregroundStyle(display.color)
                    .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion)
            }
        case .done:
            if let display = model.state.display {
                if reduceMotion {
                    Image(systemName: display.symbol).foregroundStyle(display.color)
                } else {
                    Image(systemName: display.symbol)
                        .foregroundStyle(display.color)
                        .symbolEffect(.bounce, options: .nonRepeating, value: model.state)
                }
            }
        case .failed, .cancelled:
            if let display = model.state.display {
                Image(systemName: display.symbol).foregroundStyle(display.color)
            }
        }
    }

    private var title: String {
        switch model.state {
        case .idle: "E-Mail hierher ziehen"
        case .saving: "Wird gespeichert…"
        case .converting, .done, .failed, .cancelled: model.state.display?.title ?? ""
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
        case .saving(_, let pages): ConvertModel.pageCountLabel(pages)
        case .done(let name): name
        case .failed(let message): message
        case .cancelled: "Es wurde kein PDF gespeichert."
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
        case .saving(_, let pages): "Vorschau bereit, \(pages) Seiten, Speichern-Dialog geöffnet"
        case .done: "Erfolgreich gespeichert"
        case .failed(let message): "\(message). Klicken zum Schließen"
        case .cancelled: "Abgebrochen"
        }
    }
}
