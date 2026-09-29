import AppKit
import Foundation

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let resources = root.appendingPathComponent("Resources", isDirectory: true)
let deliverables = root.appendingPathComponent("outputs/icon", isDirectory: true)
try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: deliverables, withIntermediateDirectories: true)

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
}

func speechPanel(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) -> NSBezierPath {
    let radius: CGFloat = 64
    let k: CGFloat = 0.55228475
    let path = NSBezierPath()
    path.move(to: NSPoint(x: x + radius, y: y + height))
    path.line(to: NSPoint(x: x + width - radius, y: y + height))
    path.curve(to: NSPoint(x: x + width, y: y + height - radius),
               controlPoint1: NSPoint(x: x + width - radius + radius * k, y: y + height),
               controlPoint2: NSPoint(x: x + width, y: y + height - radius + radius * k))
    path.line(to: NSPoint(x: x + width, y: y + radius))
    path.curve(to: NSPoint(x: x + width - radius, y: y),
               controlPoint1: NSPoint(x: x + width, y: y + radius - radius * k),
               controlPoint2: NSPoint(x: x + width - radius + radius * k, y: y))
    path.line(to: NSPoint(x: x + 166, y: y))
    path.line(to: NSPoint(x: x + 53, y: y - 72))
    path.curve(to: NSPoint(x: x + 37, y: y - 60),
               controlPoint1: NSPoint(x: x + 39, y: y - 81),
               controlPoint2: NSPoint(x: x + 31, y: y - 76))
    path.line(to: NSPoint(x: x + 58, y: y + 1))
    path.curve(to: NSPoint(x: x, y: y + radius),
               controlPoint1: NSPoint(x: x + 22, y: y + 5),
               controlPoint2: NSPoint(x: x, y: y + 26))
    path.line(to: NSPoint(x: x, y: y + height - radius))
    path.curve(to: NSPoint(x: x + radius, y: y + height),
               controlPoint1: NSPoint(x: x, y: y + height - radius + radius * k),
               controlPoint2: NSPoint(x: x + radius - radius * k, y: y + height))
    path.close()
    return path
}

func fillWithShadow(_ path: NSBezierPath, fill: NSColor, blur: CGFloat, offset: NSSize, opacity: CGFloat) {
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = color(0, 0, 0, alpha: opacity)
    shadow.shadowBlurRadius = blur
    shadow.shadowOffset = offset
    shadow.set()
    fill.setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()
}

guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
    fatalError("Cannot create the icon canvas")
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
context.shouldAntialias = true
context.imageInterpolation = .high
NSColor.clear.setFill()
NSRect(x: 0, y: 0, width: 1024, height: 1024).fill(using: .copy)

let tile = NSBezierPath(roundedRect: NSRect(x: 76, y: 76, width: 872, height: 872), xRadius: 196, yRadius: 196)
fillWithShadow(tile, fill: color(0.14, 0.15, 0.15), blur: 22, offset: NSSize(width: 0, height: -10), opacity: 0.28)
NSGradient(starting: color(0.24, 0.25, 0.25), ending: color(0.10, 0.115, 0.115))!.draw(in: tile, angle: -90)
NSGraphicsContext.saveGraphicsState()
tile.addClip()
let topEdge = NSBezierPath(roundedRect: NSRect(x: 80, y: 80, width: 864, height: 864), xRadius: 192, yRadius: 192)
color(1, 1, 1, alpha: 0.13).setStroke()
topEdge.lineWidth = 2
topEdge.stroke()
NSGraphicsContext.restoreGraphicsState()

let rearPanel = speechPanel(x: 286, y: 264, width: 548, height: 418)
fillWithShadow(rearPanel, fill: color(0.08, 0.36, 0.29), blur: 18, offset: NSSize(width: 0, height: -9), opacity: 0.28)
NSGradient(starting: color(0.19, 0.73, 0.53), ending: color(0.10, 0.48, 0.36))!.draw(in: rearPanel, angle: -90)

let frontPanel = speechPanel(x: 190, y: 352, width: 548, height: 418)
fillWithShadow(frontPanel, fill: color(0.95, 0.96, 0.95), blur: 24, offset: NSSize(width: 0, height: -16), opacity: 0.34)
NSGradient(starting: color(1, 1, 1), ending: color(0.87, 0.91, 0.89))!.draw(in: frontPanel, angle: -90)
color(1, 1, 1, alpha: 0.78).setStroke()
frontPanel.lineWidth = 2
frontPanel.stroke()

let chevron = NSBezierPath()
chevron.move(to: NSPoint(x: 300, y: 636))
chevron.line(to: NSPoint(x: 395, y: 554))
chevron.line(to: NSPoint(x: 300, y: 472))
chevron.lineWidth = 44
chevron.lineCapStyle = .round
chevron.lineJoinStyle = .round
color(0.14, 0.19, 0.18).setStroke()
chevron.stroke()

let cursor = NSBezierPath(roundedRect: NSRect(x: 463, y: 450, width: 150, height: 44), xRadius: 12, yRadius: 12)
NSGradient(starting: color(0.17, 0.75, 0.49), ending: color(0.08, 0.59, 0.39))!.draw(in: cursor, angle: -90)

NSGraphicsContext.restoreGraphicsState()
guard let data = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("Cannot encode the icon PNG")
}
try data.write(to: resources.appendingPathComponent("AppIcon.png"), options: .atomic)
try data.write(to: deliverables.appendingPathComponent("AppIcon.png"), options: .atomic)
print("Rendered \(deliverables.appendingPathComponent("AppIcon.png").path)")
