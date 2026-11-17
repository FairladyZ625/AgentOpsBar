import AppKit
import CoreGraphics
import Foundation

guard CommandLine.arguments.count >= 2 else {
    fputs("Usage: swift generate_icon.swift <output-iconset-dir>\n", stderr)
    exit(2)
}

let outDir = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

func renderIcon(pixelSize: Int) -> Data? {
    let s = CGFloat(pixelSize)
    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
          let ctx = CGContext(
              data: nil,
              width: pixelSize,
              height: pixelSize,
              bitsPerComponent: 8,
              bytesPerRow: 0,
              space: colorSpace,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          )
    else { return nil }

    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)

    let inset = s * 0.085
    let rect = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let radius = rect.width * 0.225
    let bgPath = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

    ctx.saveGState()
    ctx.addPath(bgPath)
    ctx.clip()

    let gradColors = [
        CGColor(srgbRed: 0.12, green: 0.15, blue: 0.21, alpha: 1.0),
        CGColor(srgbRed: 0.07, green: 0.08, blue: 0.11, alpha: 1.0),
    ] as CFArray
    if let grad = CGGradient(colorsSpace: colorSpace, colors: gradColors, locations: [0.0, 1.0]) {
        ctx.drawLinearGradient(
            grad,
            start: CGPoint(x: s * 0.25, y: s * 0.92),
            end: CGPoint(x: s * 0.75, y: s * 0.08),
            options: []
        )
    }
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(bgPath)
    ctx.setStrokeColor(CGColor(srgbRed: 0.36, green: 0.61, blue: 0.96, alpha: 0.35))
    ctx.setLineWidth(max(1.0, s * 0.015))
    ctx.strokePath()
    ctx.restoreGState()

    let ringRadius = s * 0.155
    let ringStroke = s * 0.068
    let leftCenter = CGPoint(x: s * 0.39, y: s * 0.53)
    let rightCenter = CGPoint(x: s * 0.61, y: s * 0.53)

    ctx.saveGState()
    ctx.setLineCap(.round)
    ctx.setLineWidth(ringStroke)

    ctx.setStrokeColor(CGColor(srgbRed: 0.36, green: 0.61, blue: 0.96, alpha: 1.0))
    ctx.addArc(center: leftCenter, radius: ringRadius, startAngle: .pi * 0.22, endAngle: .pi * 1.78, clockwise: false)
    ctx.strokePath()

    ctx.setStrokeColor(CGColor(srgbRed: 0.98, green: 0.75, blue: 0.14, alpha: 1.0))
    ctx.addArc(center: rightCenter, radius: ringRadius, startAngle: -.pi * 0.78, endAngle: .pi * 0.78, clockwise: false)
    ctx.strokePath()
    ctx.restoreGState()

    let dotRadius = s * 0.038
    let pillY = s * 0.255
    ctx.setFillColor(CGColor(srgbRed: 0.29, green: 0.87, blue: 0.50, alpha: 1.0))
    ctx.fillEllipse(in: CGRect(x: s * 0.36 - dotRadius, y: pillY - dotRadius, width: dotRadius * 2, height: dotRadius * 2))

    let barRect = CGRect(x: s * 0.44, y: pillY - s * 0.018, width: s * 0.22, height: s * 0.036)
    let barPath = CGPath(roundedRect: barRect, cornerWidth: s * 0.018, cornerHeight: s * 0.018, transform: nil)
    ctx.addPath(barPath)
    ctx.setFillColor(CGColor(srgbRed: 0.90, green: 0.92, blue: 0.96, alpha: 0.85))
    ctx.fillPath()

    guard let cgImg = ctx.makeImage() else { return nil }
    let rep = NSBitmapImageRep(cgImage: cgImg)
    return rep.representation(using: .png, properties: [:])
}

let specs: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

for (filename, px) in specs {
    guard let data = renderIcon(pixelSize: px) else {
        fputs("Failed to render \(filename)\n", stderr)
        exit(1)
    }
    try data.write(to: outDir.appendingPathComponent(filename))
}
