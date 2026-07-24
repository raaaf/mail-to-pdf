# MailToPDF

Native macOS app (SwiftUI, Swift 6, macOS 15+). Drag an email out of Apple
Mail or drop a `.eml` file, get a paginated A4 PDF plus extracted PDF
attachments. No third-party dependencies, no SPM package.

## Architecture

| File | Responsibility |
|---|---|
| `App/MailToPDFApp.swift` | App entry point, single `WindowGroup`. |
| `App/ContentView.swift` | Drop zone UI, state-driven (idle/converting/done/failed). |
| `App/MailDropView.swift` | `NSViewRepresentable` drag target: Mail selection (AppleScript), file promises, Finder `.eml`. |
| `App/EmailParser.swift` | Pure MIME parser (no AppKit). Headers, multipart, RFC 2047, charsets, transfer encodings, PDF extraction. Unit-tested. |
| `App/PDFRenderer.swift` | Offscreen `WKWebView` + `NSPrintOperation` pagination to A4 PDF, `createPDF` fallback. |
| `App/InvoiceExtractor.swift` | Merchant/amount guess for smarter filenames: on-device FoundationModels when available, regex fallback otherwise. |
| `App/ConvertModel.swift` | Orchestrates parse -> render + extract (concurrently) -> preview -> save panel sheet -> attachment save; owns UI state. |

## Key technical decisions

- **No file promises from modern Mail.app.** Dragging a message only puts
  `com.apple.mail.PasteboardTypeMessageTransfer` on the pasteboard.
  `MailDropView` detects that type and reads the selected message(s) via
  `NSAppleScript` (`source of m`), not `osascript`, so the TCC automation
  prompt attributes to this app. File promises / `.eml` URLs remain a
  fallback for other apps and OS versions.
- **A4 pagination via `NSPrintOperation`**, not `createPDF` alone: `createPDF`
  produces one tall page, not paginated A4. It is used only as a fallback if
  the print operation fails.
- **`NSPrintOperation`'s `didRun` callback can arrive on a background
  thread** (seen in a real crash report), so `printOperationDidRun` is
  `nonisolated` and hops via `DispatchQueue.main.async` +
  `MainActor.assumeIsolated` before touching `@MainActor` state. Same
  pattern for file-promise completion in `MailDropView`.
- **Hand-rolled MIME parser**, deliberately: scoped enough to not need a
  dependency, and keeps `EmailParser` unit-testable without a live
  WebKit/AppKit stack.
- **FoundationModels usage is gated twice**: `#available(macOS 26.0, *)` at
  compile time (deployment target stays macOS 15) and a runtime
  `SystemLanguageModel.default.availability` check, raced against an 8s
  timeout. The regex-based fallback in `InvoiceExtractor.extractFallback` is
  always compiled and is the only path unit-tested, since the LLM path is
  not deterministic.

## Build and test

```sh
xcodegen generate
xcodebuild -project MailToPDF.xcodeproj -scheme MailToPDF build -destination 'platform=macOS'
xcodebuild -project MailToPDF.xcodeproj -scheme MailToPDF test -destination 'platform=macOS'
```

Run `xcodegen generate` after any change to `project.yml` or to files under
`App/`, `AppTests/`, `Tests/Fixtures/` (the `.xcodeproj` is generated and
gitignored).

## Conventions

- Swift 6 strict concurrency; `nonisolated` explicitly where AppKit/WebKit
  calls back on a background thread.
- XcodeGen (`project.yml`) is the source of truth; do not hand-edit
  `MailToPDF.xcodeproj`.
- UI strings are German; code, comments, filenames, commits are English.
- Fixtures live under `Tests/Fixtures/*.eml`, loaded via `Bundle(for:)` in
  `AppTests/EmailParserTests.swift`.
