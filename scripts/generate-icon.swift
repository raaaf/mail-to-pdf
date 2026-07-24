#!/usr/bin/env swift
// Generates the MailToPDF app icon (all required macOS AppIcon sizes) and writes the PNGs
// directly into App/Assets.xcassets/AppIcon.appiconset. Run with: swift scripts/generate-icon.swift

import AppKit

let canvasSize: CGFloat = 1024

let outputDir = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent() // scripts/
    .deletingLastPathComponent() // repo root
    .appendingPathComponent("App/Assets.xcassets/AppIcon.appiconset")

func color(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
    let r = CGFloat((hex >> 16) & 0xFF) / 255
    let g = CGFloat((hex >> 8) & 0xFF) / 255
    let b = CGFloat(hex & 0xFF) / 255
    return NSColor(srgbRed: r, green: g, blue: b, alpha: alpha)
}

func makeBitmapContext(size: Int) -> CGContext {
    guard let ctx = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { fatalError("Could not create a \(size)x\(size) bitmap context") }
    return ctx
}

/// Applies a soft drop shadow (matching the spec's envelope/badge shadow) to whatever is drawn
/// while the returned closure's body runs, then restores the graphics state.
func withDropShadow(_ ctx: CGContext, _ body: () -> Void) {
    ctx.saveGState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
    shadow.shadowBlurRadius = 30
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.set()
    body()
    ctx.restoreGState()
}

func drawMasterIcon() -> CGImage {
    let size = canvasSize
    let ctx = makeBitmapContext(size: Int(size))
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)

    // Shape: rounded rect inset 100pt on every side, radius 232pt.
    let inset: CGFloat = 100
    let shapeRect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let shapePath = NSBezierPath(roundedRect: shapeRect, xRadius: 232, yRadius: 232)

    ctx.saveGState()
    shapePath.addClip()
    let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [color(0x3730A3).cgColor, color(0x3B82F6).cgColor] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawLinearGradient(
        gradient,
        start: CGPoint(x: size / 2, y: shapeRect.maxY),
        end: CGPoint(x: size / 2, y: shapeRect.minY),
        options: []
    )
    ctx.restoreGState()

    // Subtle 1px inner highlight.
    let highlightPath = NSBezierPath(roundedRect: shapeRect.insetBy(dx: 0.5, dy: 0.5), xRadius: 231.5, yRadius: 231.5)
    highlightPath.lineWidth = 1
    color(0xFFFFFF, alpha: 0.08).setStroke()
    highlightPath.stroke()

    // Envelope body.
    let envelopeWidth = shapeRect.width * 0.55
    let envelopeHeight = envelopeWidth * 0.68
    let envelopeRect = CGRect(
        x: size / 2 - envelopeWidth / 2, y: size / 2 - envelopeHeight / 2,
        width: envelopeWidth, height: envelopeHeight
    )
    let envelopePath = NSBezierPath(roundedRect: envelopeRect, xRadius: 24, yRadius: 24)
    withDropShadow(ctx) {
        color(0xF8FAFC).setFill()
        envelopePath.fill()
    }

    // Envelope flap: two lines from the top corners meeting 55% down the envelope. Clipped to the
    // envelope's own rounded-rect path so the round line caps don't poke past its top corners.
    let flapCenter = CGPoint(x: envelopeRect.midX, y: envelopeRect.maxY - envelopeRect.height * 0.55)
    let flapPath = NSBezierPath()
    flapPath.move(to: CGPoint(x: envelopeRect.minX, y: envelopeRect.maxY))
    flapPath.line(to: flapCenter)
    flapPath.move(to: CGPoint(x: envelopeRect.maxX, y: envelopeRect.maxY))
    flapPath.line(to: flapCenter)
    flapPath.lineWidth = 14
    flapPath.lineCapStyle = .round
    flapPath.lineJoinStyle = .round
    ctx.saveGState()
    envelopePath.addClip()
    color(0xCBD5E1).setStroke()
    flapPath.stroke()
    ctx.restoreGState()

    // "PDF" badge, bottom-right, overlapping the envelope's corner.
    let badgeFont = NSFont.boldSystemFont(ofSize: 96)
    let badgeText = "PDF" as NSString
    let badgeAttrs: [NSAttributedString.Key: Any] = [.font: badgeFont, .foregroundColor: NSColor.white]
    let textSize = badgeText.size(withAttributes: badgeAttrs)
    let badgeSize = CGSize(width: textSize.width + 28 * 2, height: textSize.height + 18 * 2)
    let badgeRect = CGRect(
        x: envelopeRect.maxX - badgeSize.width / 2, y: envelopeRect.minY - badgeSize.height / 2,
        width: badgeSize.width, height: badgeSize.height
    )
    let badgePath = NSBezierPath(roundedRect: badgeRect, xRadius: 36, yRadius: 36)
    withDropShadow(ctx) {
        color(0xDC2626).setFill()
        badgePath.fill()
    }
    badgeText.draw(
        in: CGRect(x: badgeRect.midX - textSize.width / 2, y: badgeRect.midY - textSize.height / 2,
                    width: textSize.width, height: textSize.height),
        withAttributes: badgeAttrs
    )

    NSGraphicsContext.restoreGraphicsState()
    guard let image = ctx.makeImage() else { fatalError("Could not rasterize the master icon") }
    return image
}

func writePNG(_ master: CGImage, size: Int, to url: URL) {
    let ctx = makeBitmapContext(size: size)
    ctx.interpolationQuality = .high
    ctx.draw(master, in: CGRect(x: 0, y: 0, width: size, height: size))
    guard let resized = ctx.makeImage() else { fatalError("Could not resize icon to \(size)x\(size)") }

    let rep = NSBitmapImageRep(cgImage: resized)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        fatalError("Could not encode PNG at \(size)x\(size)")
    }
    do {
        try data.write(to: url)
        print("Wrote \(url.lastPathComponent) (\(size)x\(size))")
    } catch {
        fatalError("Could not write \(url.path): \(error)")
    }
}

let master = drawMasterIcon()
for size in [16, 32, 64, 128, 256, 512, 1024] {
    writePNG(master, size: size, to: outputDir.appendingPathComponent("icon_\(size).png"))
}
print("Done.")
