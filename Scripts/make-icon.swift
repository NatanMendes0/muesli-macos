// Generates Support/AppIcon.icns — a black squircle with a toasted-oat waveform.
// Run:  SDKROOT=$(xcrun --show-sdk-path) swift Scripts/make-icon.swift
import AppKit

func render(size: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx

    let s = CGFloat(size)
    let radius = s * 0.2237
    let squircle = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: s, height: s), xRadius: radius, yRadius: radius)

    let gradient = NSGradient(
        starting: NSColor(calibratedRed: 0.02, green: 0.02, blue: 0.025, alpha: 1),
        ending: NSColor(calibratedRed: 0.08, green: 0.08, blue: 0.09, alpha: 1)
    )!
    gradient.draw(in: squircle, angle: 90)

    // Subtle inner rim so the black squircle keeps crisp edges on dark docks.
    NSGraphicsContext.saveGraphicsState()
    squircle.addClip()
    let borderPath = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: s, height: s), xRadius: radius, yRadius: radius)
    borderPath.lineWidth = max(1.0, s * 0.006)
    NSColor(calibratedWhite: 1.0, alpha: 0.14).setStroke()
    borderPath.stroke()
    NSGraphicsContext.restoreGraphicsState()

    // Waveform bars.
    let heights: [CGFloat] = [0.30, 0.52, 0.80, 0.46, 0.26]
    let barW = s * 0.088
    let gap = s * 0.052
    let total = barW * CGFloat(heights.count) + gap * CGFloat(heights.count - 1)
    var x = (s - total) / 2
    let bar = NSColor(calibratedRed: 0.85, green: 0.54, blue: 0.25, alpha: 1)
    let barHighlight = NSColor(calibratedRed: 0.95, green: 0.68, blue: 0.36, alpha: 1)

    for (i, frac) in heights.enumerated() {
        let h = s * 0.66 * frac
        let rect = NSRect(x: x, y: (s - h) / 2, width: barW, height: h)
        let path = NSBezierPath(roundedRect: rect, xRadius: barW / 2, yRadius: barW / 2)
        NSGradient(starting: bar, ending: i == 2 ? barHighlight : bar)!.draw(in: path, angle: 90)
        x += barW + gap
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let fm = FileManager.default
let iconset = URL(fileURLWithPath: "Support/Muesli.iconset")
try? fm.removeItem(at: iconset)
try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)

let variants: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
for (name, size) in variants {
    let rep = render(size: size)
    try! rep.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
}

let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", "Support/AppIcon.icns"]
try! task.run()
task.waitUntilExit()
try? fm.removeItem(at: iconset)
print(task.terminationStatus == 0 ? "Wrote Support/AppIcon.icns" : "iconutil failed")
