// Draws DevPilot's app icon and writes Support/AppIcon.icns.
//
//   swift scripts/make-icon.swift
//
// Original artwork drawn with Core Graphics (SF Symbols may not be used in app icons).
import AppKit

let root = URL(filePath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appending(path: "DevPilot.iconset", directoryHint: .isDirectory)
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

/// Draws on a 1024×1024 design grid (origin bottom-left), scaled to `pixels`.
func render(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let context = NSGraphicsContext.current!.cgContext
    context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    let colors = CGColorSpaceCreateDeviceRGB()

    // macOS icon grid: 824×824 rounded square centred on the canvas, with a soft shadow.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    context.addPath(shape)
    context.setFillColor(NSColor.black.cgColor)
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(shape)
    context.clip()
    let background = CGGradient(colorsSpace: colors, colors: [
        NSColor(red: 0.36, green: 0.30, blue: 0.95, alpha: 1).cgColor,
        NSColor(red: 0.10, green: 0.62, blue: 0.96, alpha: 1).cgColor,
    ] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(background, start: CGPoint(x: 100, y: 924), end: CGPoint(x: 924, y: 100), options: [])
    // Soft light from the top.
    let glow = CGGradient(colorsSpace: colors, colors: [
        NSColor.white.withAlphaComponent(0.22).cgColor, NSColor.white.withAlphaComponent(0).cgColor,
    ] as CFArray, locations: [0, 1])!
    context.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 960), startRadius: 0,
                               endCenter: CGPoint(x: 512, y: 960), endRadius: 620, options: [])

    // Dashed flight trail behind the plane.
    let trail = CGMutablePath()
    trail.move(to: CGPoint(x: 215, y: 300))
    trail.addCurve(to: CGPoint(x: 455, y: 405), control1: CGPoint(x: 300, y: 205), control2: CGPoint(x: 400, y: 250))
    context.addPath(trail)
    context.setStrokeColor(NSColor.white.withAlphaComponent(0.55).cgColor)
    context.setLineWidth(26)
    context.setLineCap(.round)
    context.setLineDash(phase: 0, lengths: [2, 52])
    context.strokePath()
    context.setLineDash(phase: 0, lengths: [])

    // Paper plane: two wings and an inner fold, flying up and to the right.
    let nose = CGPoint(x: 790, y: 735)
    let leftWing = CGPoint(x: 255, y: 545)
    let fold = CGPoint(x: 460, y: 470)
    let tail = CGPoint(x: 560, y: 275)
    let keel = CGPoint(x: 470, y: 385)
    func polygon(_ points: [CGPoint], _ color: NSColor) {
        context.beginPath()
        context.addLines(between: points)
        context.closePath()
        context.setFillColor(color.cgColor)
        context.fillPath()
    }
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -14), blur: 24, color: NSColor.black.withAlphaComponent(0.25).cgColor)
    polygon([nose, leftWing, fold], .white)
    context.restoreGState()
    polygon([nose, fold, tail], NSColor(white: 0.90, alpha: 1))
    polygon([fold, tail, keel], NSColor(red: 0.74, green: 0.80, blue: 0.95, alpha: 1))

    context.restoreGState()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try render(pixels: size).write(to: iconset.appending(path: "icon_\(size)x\(size).png"))
    try render(pixels: size * 2).write(to: iconset.appending(path: "icon_\(size)x\(size)@2x.png"))
}
let output = root.appending(path: "Support/AppIcon.icns")
let iconutil = Process()
iconutil.executableURL = URL(filePath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
try render(pixels: 1024).write(to: root.appending(path: "Support/AppIcon-1024.png"))
print("Wrote \(output.path)")
