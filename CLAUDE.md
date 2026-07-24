# MailToPDF

Native macOS menubar app (SwiftUI + AppKit, Swift 6, macOS 15+). Drag an email
out of Apple Mail or drop a `.eml` file onto the menubar icon, get a
paginated A4 PDF plus extracted PDF attachments. No third-party dependencies,
no SPM package.

## Architecture

| File | Responsibility |
|---|---|
| `App/MailToPDFApp.swift` | `NSApplicationDelegate` bootstrap (`static func main()`), not a SwiftUI `App`/`Scene`. No Dock icon (`LSUIElement`), so nothing to host a window-based scene. |
| `App/StatusItemController.swift` | Owns the `NSStatusItem`, its `DropTargetView` drop target, the popover (hosts `ContentView`), the right-click menu (Einstellungen, Beenden), the settings window, the icon success/failure feedback, and the `DropShelfController`. |
| `App/DropShelfController.swift` | Floating drop target that fades in just below the cursor during a relevant system-wide drag (Mail message or `.eml`), so the user doesn't have to aim for the menubar icon; becomes a live status card on drop, same states as `ContentView`. |
| `App/SettingsView.swift` | Settings window: launch-at-login toggle above a minimal about/credit block (app icon, version, author, link to rafaelalex.de). |
| `App/LoginItemManager.swift` | Wraps `SMAppService.mainApp` for the launch-at-login toggle; reads `.status` back after register/unregister rather than assuming success. |
| `App/ContentView.swift` | Drop zone UI, state-driven (idle/converting/saving/done/failed/cancelled). Takes its `ConvertModel` via `init`, does not own it. |
| `App/MailDropView.swift` | `NSViewRepresentable` wrapping `DropTargetView`, used inside `ContentView`'s popover drop zone; `DropTargetView` itself is also attached directly as a status-item-button subview by `StatusItemController`. Drag target: Mail selection (AppleScript), file promises, Finder `.eml`. |
| `App/EmailParser.swift` | Pure MIME parser (no AppKit). Headers, multipart, RFC 2047, charsets, transfer encodings, PDF extraction. Unit-tested. |
| `App/PDFRenderer.swift` | Offscreen `WKWebView` + `NSPrintOperation` pagination to A4 PDF, `createPDF` fallback. |
| `App/InvoiceExtractor.swift` | Merchant/amount guess for smarter filenames: on-device FoundationModels when available, regex fallback otherwise. |
| `App/ConvertModel.swift` | Orchestrates parse -> render + extract (concurrently) -> preview -> centered save panel (`runModal`) -> attachment save; owns UI state. |

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
- **Menubar-only via `LSUIElement`**, not `NSApp.setActivationPolicy`: the
  Info.plist key alone suppresses the Dock icon before launch. The status
  item's button hosts the same `DropTargetView` used inside `ContentView`
  (its `hitTest` already returns nil so clicks pass through to the button;
  drag-destination resolution is independent of hitTest), so click-to-toggle
  and drag-to-convert work on the exact same view without duplicating drop
  logic. The save panel is always a centered `NSSavePanel.runModal()`, not a
  window sheet: the app is menubar-only, so there is no app window to attach
  a sheet to (and pinning it under the menubar icon would be worse UX than
  centering it).
- **`runModal()` blocks the main actor for as long as the save panel is
  open.** `ConvertModel` sets `state = .saving(...)` and then `await
  Task.yield()` immediately before calling it, so already-enqueued MainActor
  observers (the drop shelf's hide-on-`.saving` handler, SwiftUI's own
  diffing) actually get to run first; without that yield the shelf would
  stay visible for the panel's entire lifetime instead of hiding right away.
- **`DropShelfController` detects drags by polling `NSPasteboard(name: .drag)`'s
  `changeCount` from global `.leftMouseDragged` monitors**, not by registering
  as a system-wide drag destination. `NSEvent`'s global monitors need no
  Accessibility permission. Monitor tokens are `nonisolated(unsafe)` so they
  can be removed in `deinit`, which Swift 6 requires to be nonisolated even
  on a `@MainActor` class; the shelf's fade uses the `async` overload of
  `NSAnimationContext.runAnimationGroup` rather than its `completionHandler:`
  overload, since that parameter is `@Sendable` and can't capture the
  (non-Sendable) `NSPanel`.

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
