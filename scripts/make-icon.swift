// Renders the Dabble app icon. Usage: swift scripts/make-icon.swift <output.png> [size]
import AppKit

let args = CommandLine.arguments
let output = args.count > 1 ? args[1] : "icon.png"
let size = args.count > 2 ? CGFloat(Double(args[2])!) : 1024

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
let s = size / 1024

// Full-bleed background; the OS applies its own mask.
let colors = [NSColor(srgbRed: 0.98, green: 0.36, blue: 0.30, alpha: 1).cgColor, NSColor(srgbRed: 0.80, green: 0.11, blue: 0.20, alpha: 1).cgColor] as CFArray
let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: size), end: CGPoint(x: size, y: 0), options: [])

// Soft highlight.
ctx.setFillColor(NSColor(white: 1, alpha: 0.08).cgColor)
ctx.fillEllipse(in: CGRect(x: -200 * s, y: 520 * s, width: 1000 * s, height: 760 * s))

// Checkbox.
let box = CGRect(x: 262 * s, y: 262 * s, width: 500 * s, height: 500 * s)
let path = CGPath(roundedRect: box, cornerWidth: 120 * s, cornerHeight: 120 * s, transform: nil)
ctx.setShadow(offset: CGSize(width: 0, height: -18 * s), blur: 40 * s, color: NSColor(white: 0, alpha: 0.25).cgColor)
ctx.setFillColor(NSColor.white.cgColor)
ctx.addPath(path)
ctx.fillPath()
ctx.setShadow(offset: .zero, blur: 0, color: nil)

// Check mark.
ctx.setStrokeColor(NSColor(srgbRed: 0.86, green: 0.15, blue: 0.20, alpha: 1).cgColor)
ctx.setLineWidth(78 * s)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)
ctx.move(to: CGPoint(x: 375 * s, y: 520 * s))
ctx.addLine(to: CGPoint(x: 475 * s, y: 410 * s))
ctx.addLine(to: CGPoint(x: 660 * s, y: 640 * s))
ctx.strokePath()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
