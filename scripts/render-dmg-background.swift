import AppKit

let width = 800.0
let height = 460.0
let size = NSSize(width: width, height: height)
guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(width),
    pixelsHigh: Int(height),
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else {
    fputs("could not make a bitmap\n", stderr)
    exit(1)
}
rep.size = size

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

let paper = NSColor(srgbRed: 0.937, green: 0.894, blue: 0.812, alpha: 1)
let ink = NSColor(srgbRed: 0.106, green: 0.086, blue: 0.071, alpha: 1)
let blush = NSColor(srgbRed: 0.831, green: 0.325, blue: 0.169, alpha: 1)
let card = NSColor(srgbRed: 0.969, green: 0.941, blue: 0.894, alpha: 1)
let muted = NSColor(srgbRed: 0.361, green: 0.318, blue: 0.275, alpha: 1)

paper.setFill()
NSRect(origin: .zero, size: size).fill()

func rounded(_ rect: NSRect, _ radius: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
}

func drawText(_ text: String, font: NSFont, color: NSColor, rect: NSRect, align: NSTextAlignment) {
    let style = NSMutableParagraphStyle()
    style.alignment = align
    NSAttributedString(string: text, attributes: [
        .font: font,
        .foregroundColor: color,
        .paragraphStyle: style
    ]).draw(in: rect)
}

drawText(
    "INSTALL SHOW BAR",
    font: .systemFont(ofSize: 12, weight: .semibold),
    color: muted,
    rect: NSRect(x: 48, y: height - 46, width: 400, height: 18),
    align: .left
)
drawText(
    "Drag it across.",
    font: NSFont(name: "Palatino-Roman", size: 40) ?? .systemFont(ofSize: 40),
    color: ink,
    rect: NSRect(x: 46, y: height - 96, width: 520, height: 48),
    align: .left
)

// Wells sit under the real icons. Centers: (200, 248) and (600, 248) from the top.
let wellCenters = [200.0, 600.0]
for center in wellCenters {
    let well = NSRect(x: center - 108, y: 78, width: 216, height: 228)
    card.setFill()
    rounded(well, 32).fill()
    ink.withAlphaComponent(0.85).setStroke()
    let stroke = rounded(well, 32)
    stroke.lineWidth = 1.5
    stroke.stroke()
}

func windowCard(_ origin: NSPoint, _ scale: CGFloat, _ alpha: CGFloat) {
    let rect = NSRect(x: origin.x, y: origin.y, width: 78 * scale, height: 54 * scale)
    NSColor.white.withAlphaComponent(alpha).setFill()
    rounded(rect, 8).fill()
    blush.withAlphaComponent(alpha).setFill()
    NSRect(x: rect.minX + 8, y: rect.maxY - 16, width: 26 * scale, height: 6).fill()
    muted.withAlphaComponent(alpha * 0.55).setFill()
    NSRect(x: rect.minX + 8, y: rect.minY + 12, width: 46 * scale, height: 4).fill()
    NSRect(x: rect.minX + 8, y: rect.minY + 20, width: 30 * scale, height: 4).fill()
}

// A trail, faint at Show Bar and solid as it reaches Applications.
let flight: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
    (318, 196, 0.62, 0.22),
    (362, 214, 0.74, 0.38),
    (410, 228, 0.86, 0.55),
    (458, 220, 0.96, 0.75),
    (506, 204, 1.05, 0.95)
]
for (x, y, scale, alpha) in flight {
    windowCard(NSPoint(x: x, y: y), scale, alpha)
}

blush.setStroke()
let arrow = NSBezierPath()
arrow.lineWidth = 3
arrow.lineCapStyle = .round
arrow.lineJoinStyle = .round
arrow.move(to: NSPoint(x: 548, y: 214))
arrow.line(to: NSPoint(x: 574, y: 214))
arrow.line(to: NSPoint(x: 562, y: 226))
arrow.move(to: NSPoint(x: 574, y: 214))
arrow.line(to: NSPoint(x: 562, y: 202))
arrow.stroke()

drawText(
    "Drop Show Bar on Applications",
    font: .systemFont(ofSize: 14, weight: .medium),
    color: ink,
    rect: NSRect(x: 40, y: 22, width: 460, height: 22),
    align: .left
)
drawText(
    "macOS 14 or later",
    font: .systemFont(ofSize: 13),
    color: muted,
    rect: NSRect(x: 520, y: 22, width: 240, height: 22),
    align: .right
)

NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else {
    fputs("could not encode png\n", stderr)
    exit(1)
}
try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
print(CommandLine.arguments[1])
