#!/usr/bin/env swift
// Generates the CapyBuddy DMG window background: brand logo + a "drag to
// Applications" arrow + caption. Renders at 1x and 2x, then combines them into a
// single HiDPI .tiff so the background stays crisp on Retina displays.
//
// Run from the repo root:  swift scripts/dmg-assets/make-background.swift
// Output: scripts/dmg-assets/dmg-background.tiff (committed; consumed by release.sh)
//
// Window layout (must match the create-dmg flags in release.sh):
//   window-size 640x400, icon-size 110
//   app icon at (170,200), Applications drop-link at (470,200)  [Finder top-left coords]

import AppKit

let W: CGFloat = 640, H: CGFloat = 400
let outPath = "scripts/dmg-assets/dmg-background.tiff"

func render(scale: CGFloat) -> NSBitmapImageRep {
    let pxW = Int(W * scale), pxH = Int(H * scale)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pxW, pixelsHigh: pxH,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: W, height: H)   // points; scale handled by the rep

    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx

    // Soft vertical gradient backdrop.
    let top = NSColor(calibratedRed: 0.98, green: 0.97, blue: 0.95, alpha: 1)
    let bottom = NSColor(calibratedRed: 0.93, green: 0.92, blue: 0.90, alpha: 1)
    NSGradient(starting: top, ending: bottom)!.draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: -90)

    // Title near the top.  No logo here — create-dmg overlays the real app icon
    // in the icon row below, so drawing the logo too would show it twice.
    // (image coords: origin bottom-left)
    let title = "Install CapyBuddy"
    let titleAttr: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 22, weight: .semibold),
        .foregroundColor: NSColor(calibratedWhite: 0.15, alpha: 1)
    ]
    let titleSize = title.size(withAttributes: titleAttr)
    title.draw(at: NSPoint(x: (W - titleSize.width) / 2, y: H - 70), withAttributes: titleAttr)

    // Drag arrow, centered on the icon row.  Icons sit at Finder y=200 (top-left
    // origin) → image y = H-200 = 200.  Draw between the two icons (x 170..470).
    let arrowY: CGFloat = H - 200
    let arrowStartX: CGFloat = 250, arrowEndX: CGFloat = 388
    let arrowColor = NSColor(calibratedRed: 0.40, green: 0.55, blue: 0.95, alpha: 1.0)
    arrowColor.setStroke()
    arrowColor.setFill()
    let shaft = NSBezierPath()
    shaft.lineWidth = 7
    shaft.lineCapStyle = .round
    shaft.move(to: NSPoint(x: arrowStartX, y: arrowY))
    shaft.line(to: NSPoint(x: arrowEndX, y: arrowY))
    shaft.stroke()
    let head = NSBezierPath()   // filled triangle
    head.move(to: NSPoint(x: arrowEndX + 22, y: arrowY))
    head.line(to: NSPoint(x: arrowEndX - 4, y: arrowY + 15))
    head.line(to: NSPoint(x: arrowEndX - 4, y: arrowY - 15))
    head.close()
    head.fill()

    // Caption near the bottom.
    let caption = "Drag CapyBuddy into the Applications folder to install"
    let capAttr: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 14, weight: .medium),
        .foregroundColor: NSColor(calibratedWhite: 0.35, alpha: 1)
    ]
    let capSize = caption.size(withAttributes: capAttr)
    caption.draw(at: NSPoint(x: (W - capSize.width) / 2, y: 44), withAttributes: capAttr)

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

// 1x and 2x reps, combined into one HiDPI TIFF (the 2x rep is tagged 144 dpi by
// virtue of having twice the pixels for the same point size).
let rep1 = render(scale: 1)
let rep2 = render(scale: 2)
let data = NSBitmapImageRep.representationOfImageReps(in: [rep1, rep2], using: .tiff,
                                                      properties: [:])!
do {
    try data.write(to: URL(fileURLWithPath: outPath))
    print("Wrote \(outPath) (\(rep1.pixelsWide)x\(rep1.pixelsHigh) + \(rep2.pixelsWide)x\(rep2.pixelsHigh))")
} catch {
    FileHandle.standardError.write("Failed to write \(outPath): \(error)\n".data(using: .utf8)!)
    exit(1)
}
