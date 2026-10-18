import AppKit

// The same overlapping-window mark used by docs/public/images/wordmark.svg.
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
func color(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
            green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1)
}
func png(_ name: String, width: Int, height: Int, scale: Int = 1, draw: () -> Void) throws {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width * scale,
        pixelsHigh: height * scale, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    bitmap.size = NSSize(width: width, height: height)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    draw()
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name))
}
func mark() {
    let tile = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824),
        xRadius: 190, yRadius: 190)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.2)
    shadow.shadowBlurRadius = 24; shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.set(); color(0x638ffb).setFill(); tile.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: color(0x42b7ff), ending: color(0x9074ff))!.draw(in: tile, angle: -45)
    NSColor.white.withAlphaComponent(0.35).setStroke(); tile.lineWidth = 2; tile.stroke()
    // Scale the original 112-point mark to the macOS icon's optical bounds.
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current!.cgContext.translateBy(x: 100, y: 100)
    NSGraphicsContext.current!.cgContext.scaleBy(x: 824.0 / 112, y: 824.0 / 112)
    NSColor.white.setStroke()
    let back = NSBezierPath(roundedRect: NSRect(x: 24, y: 47, width: 49, height: 40), xRadius: 6, yRadius: 6)
    back.lineWidth = 5.5; back.stroke()
    let front = NSBezierPath(roundedRect: NSRect(x: 41, y: 30, width: 49, height: 40), xRadius: 6, yRadius: 6)
    color(0x638ffb).setFill(); front.fill(); front.lineWidth = 5.5; front.stroke()
    NSGraphicsContext.restoreGraphicsState()
}
func text(_ value: String, y: CGFloat, size: CGFloat, weight: NSFont.Weight, tint: UInt32) {
    let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: color(tint)]
    let label = NSAttributedString(string: value, attributes: attributes)
    label.draw(at: NSPoint(x: (640 - label.size().width) / 2, y: y))
}
try png("icon-1024.png", width: 1024, height: 1024, draw: mark)
try png("background.png", width: 640, height: 400, scale: 2) {
    NSGradient(starting: color(0xf6f8ff), ending: color(0xeceffc))!.draw(
        in: NSBezierPath(rect: NSRect(x: 0, y: 0, width: 640, height: 400)), angle: -90)
    text("换台", y: 320, size: 32, weight: .semibold, tint: 0x202c48)
    text("像换台一样切换窗口。", y: 288, size: 14, weight: .regular, tint: 0x62708b)
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: 288, y: 196)); arrow.line(to: NSPoint(x: 352, y: 196))
    arrow.move(to: NSPoint(x: 341, y: 207)); arrow.line(to: NSPoint(x: 352, y: 196))
    arrow.line(to: NSPoint(x: 341, y: 185))
    arrow.lineWidth = 2.5; arrow.lineCapStyle = .round; arrow.lineJoinStyle = .round
    color(0x8c9bc1).setStroke(); arrow.stroke()
    text("拖入应用程序，即可安装", y: 66, size: 16, weight: .medium, tint: 0x354566)
    text("安装后从“应用程序”打开换台，在菜单栏开始使用", y: 38, size: 12, weight: .regular, tint: 0x75819a)
}
