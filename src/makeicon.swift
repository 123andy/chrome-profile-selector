import AppKit

// Concept A "route split" on Scientist.com navy (#1F346F).
// Canvas is 1024x1024 with the standard macOS icon margin; all coordinates
// are in 1024-space and scaled per output size.

func draw1024(in size: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()
    let scale = size / 1024.0
    let t = NSAffineTransform()
    t.scale(by: scale)
    t.concat()

    func color(_ hex: UInt32) -> NSColor {
        NSColor(calibratedRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
    let navy = color(0x1F346F)
    let white = NSColor.white
    let orange = color(0xFF9F0A)
    let green = color(0x30D158)
    let purple = color(0xBF5AF2)

    // Squircle background (824pt content box, macOS-style margin)
    let bg = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824),
                          xRadius: 185, yRadius: 185)
    navy.setFill()
    bg.fill()

    // NOTE: AppKit y is flipped vs. design coords; design y=327 (top branch)
    // becomes 1024-327=697 here, and vice versa. Symmetric, so only labels swap.
    white.setStroke()
    white.setFill()

    // Input dot + stem
    NSBezierPath(ovalIn: NSRect(x: 265 - 46, y: 512 - 46, width: 92, height: 92)).fill()
    let stem = NSBezierPath()
    stem.lineWidth = 41
    stem.lineCapStyle = .round
    stem.move(to: NSPoint(x: 265, y: 512))
    stem.line(to: NSPoint(x: 409, y: 512))
    stem.stroke()

    // Three branches
    func branch(toY endY: CGFloat) {
        let p = NSBezierPath()
        p.lineWidth = 41
        p.lineCapStyle = .round
        p.move(to: NSPoint(x: 409, y: 512))
        if endY == 512 {
            p.line(to: NSPoint(x: 697, y: 512))
        } else {
            p.curve(to: NSPoint(x: 697, y: endY),
                    controlPoint1: NSPoint(x: 533, y: 512),
                    controlPoint2: NSPoint(x: 574, y: endY))
        }
        p.stroke()
    }
    branch(toY: 697)
    branch(toY: 512)
    branch(toY: 327)

    // Profile dots (with white ring)
    func dot(_ y: CGFloat, _ c: NSColor) {
        let r: CGFloat = 57
        let rect = NSRect(x: 718 - r, y: y - r, width: r * 2, height: r * 2)
        c.setFill()
        NSBezierPath(ovalIn: rect).fill()
        let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 7.5, dy: 7.5).offsetBy(dx: 0, dy: 0))
        _ = ring
        white.setStroke()
        let outline = NSBezierPath(ovalIn: rect)
        outline.lineWidth = 15
        outline.stroke()
    }
    dot(697, orange)
    dot(512, green)
    dot(327, purple)

    img.unlockFocus()
    return img
}

func writePNG(_ image: NSImage, to url: URL) {
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        fatalError("render failed for \(url.lastPathComponent)")
    }
    try! png.write(to: url)
}

let out = URL(fileURLWithPath: CommandLine.arguments[1])
let iconset = out.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let sizes: [(String, CGFloat)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
for (name, px) in sizes {
    writePNG(draw1024(in: px), to: iconset.appendingPathComponent(name))
}
print("iconset written to \(iconset.path)")
