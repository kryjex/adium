// Draws the background picture of the release disk image.
//
// Run it after a change to the layout, then commit the result:
//   swift scripts/make-dmg-background.swift Packaging/dmg-background.tiff
//
// The output is a two-representation TIFF (1x and 2x). Finder picks the
// representation that matches the display, so the background stays sharp on a
// Retina screen. The size is the DMG window size in points. Keep it in sync
// with the --window-size and --icon coordinates of the `dmg` target in the
// Makefile: the arrow is drawn at the icon centers, so a change to one without
// the other puts the arrow off the icons.

import AppKit

let width = 660.0
let height = 400.0
let iconCenterY = 190.0   // measured from the top of the window, like Finder
let appIconX = 170.0
let dropLinkX = 490.0

// AppKit draws from the bottom left. Finder positions icons from the top left.
func fromTop(_ y: Double) -> Double { height - y }

func color(_ hex: UInt32, _ alpha: Double = 1) -> NSColor {
    NSColor(srgbRed: Double((hex >> 16) & 0xff) / 255,
            green: Double((hex >> 8) & 0xff) / 255,
            blue: Double(hex & 0xff) / 255,
            alpha: alpha)
}

func draw(scale: Double) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: width, height: height)

    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context

    // Base wash, lighter at the top so the two icon labels stay readable.
    NSGradient(colors: [color(0xFDFCFF), color(0xF1E9FB)])!
        .draw(in: NSRect(x: 0, y: 0, width: width, height: height), angle: -90)

    // Soft purple glow behind the drop target.
    NSGradient(colors: [color(0xB794E8, 0.22), color(0xB794E8, 0)])!
        .draw(in: NSRect(x: width / 2 - 320, y: fromTop(iconCenterY) - 240,
                         width: 640, height: 480),
              relativeCenterPosition: .zero)

    let title = "Fluorite" as NSString
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 30, weight: .semibold),
        .foregroundColor: color(0x4A3270),
        .kern: 1.5,
    ]
    let titleSize = title.size(withAttributes: attributes)
    title.draw(at: NSPoint(x: (width - titleSize.width) / 2, y: fromTop(72)),
               withAttributes: attributes)

    // Arrow from the app icon to the Applications alias.
    let arrow = NSBezierPath()
    let y = fromTop(iconCenterY)
    let start = appIconX + 96.0
    let end = dropLinkX - 96.0
    arrow.move(to: NSPoint(x: start, y: y))
    arrow.line(to: NSPoint(x: end - 16, y: y))
    arrow.lineWidth = 6
    arrow.lineCapStyle = .round
    color(0x9B77D4, 0.55).setStroke()
    arrow.stroke()

    let head = NSBezierPath()
    head.move(to: NSPoint(x: end, y: y))
    head.line(to: NSPoint(x: end - 22, y: y + 15))
    head.line(to: NSPoint(x: end - 22, y: y - 15))
    head.close()
    color(0x9B77D4, 0.55).setFill()
    head.fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let output = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1] : "Packaging/dmg-background.tiff"
let directory = (output as NSString).deletingLastPathComponent
let base = ((output as NSString).lastPathComponent as NSString).deletingPathExtension

// tiffutil builds the multi-resolution file, so write both scales first.
for scale in [1.0, 2.0] {
    let suffix = scale == 1 ? "" : "@2x"
    let path = "\(directory)/\(base)\(suffix).png"
    let png = draw(scale: scale).representation(using: .png, properties: [:])!
    try png.write(to: URL(fileURLWithPath: path))
    print("wrote \(path)")
}

let tiffutil = Process()
tiffutil.executableURL = URL(fileURLWithPath: "/usr/bin/tiffutil")
tiffutil.arguments = ["-cathidpicheck",
                      "\(directory)/\(base).png",
                      "\(directory)/\(base)@2x.png",
                      "-out", output]
try tiffutil.run()
tiffutil.waitUntilExit()
guard tiffutil.terminationStatus == 0 else {
    fatalError("tiffutil exited with status \(tiffutil.terminationStatus)")
}

// The single-scale PNGs only existed to feed tiffutil.
try FileManager.default.removeItem(atPath: "\(directory)/\(base).png")
try FileManager.default.removeItem(atPath: "\(directory)/\(base)@2x.png")
print("wrote \(output)")
