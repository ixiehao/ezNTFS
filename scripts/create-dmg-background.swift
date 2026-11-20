import AppKit

guard CommandLine.arguments.count == 2 else {
    fatalError("Usage: create-dmg-background.swift <output.png>")
}

let output = URL(fileURLWithPath: CommandLine.arguments[1])
let size = NSSize(width: 680, height: 430)
guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
), let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else {
    fatalError("Could not create the Finder background.")
}

func color(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
            green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: alpha)
}

func centered(_ text: String, y: CGFloat, size: CGFloat, weight: NSFont.Weight, ink: UInt32) {
    let style = NSMutableParagraphStyle()
    style.alignment = .center
    NSAttributedString(string: text, attributes: [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: color(ink),
        .paragraphStyle: style
    ]).draw(in: NSRect(x: 38, y: y, width: bitmap.size.width - 76, height: size * 1.5))
}

bitmap.size = size
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = graphics
let canvas = NSRect(origin: .zero, size: size)
NSGradient(colors: [color(0xF7FAFF), color(0xE8F0FC)])!.draw(in: canvas, angle: 270)
NSGradient(colors: [color(0xCDDEF7, alpha: 0.56), color(0xCDDEF7, alpha: 0)])!.draw(
    fromCenter: NSPoint(x: 340, y: 222), radius: 0, toCenter: NSPoint(x: 340, y: 222), radius: 280,
    options: [.drawsAfterEndingLocation]
)

centered("ezNTFS", y: 339, size: 32, weight: .semibold, ink: 0x233650)

let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: 307, y: 233))
arrow.line(to: NSPoint(x: 373, y: 233))
arrow.move(to: NSPoint(x: 364, y: 241))
arrow.line(to: NSPoint(x: 373, y: 233))
arrow.line(to: NSPoint(x: 364, y: 225))
arrow.lineWidth = 2.6
arrow.lineCapStyle = .round
arrow.lineJoinStyle = .round
color(0x3671BF).setStroke()
arrow.stroke()

centered("将 ezNTFS 拖到「应用程序」完成安装", y: 95, size: 15, weight: .medium, ink: 0x354E72)
NSGraphicsContext.restoreGraphicsState()

guard let png = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("Could not write the Finder background.")
}
try png.write(to: output)
