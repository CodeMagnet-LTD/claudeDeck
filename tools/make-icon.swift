#!/usr/bin/env swift
// Renders the ClaudeDeck app icon with CoreGraphics — no external assets.
//
//   swift tools/make-icon.swift [outdir]      (default outdir: Support)
//
// Writes <outdir>/AppIcon.iconset/*.png (all macOS sizes), converts it with
// `iconutil -c icns` to <outdir>/AppIcon.icns, and fills the Xcode asset catalog
// <outdir>/Assets.xcassets/AppIcon.appiconset (PNG files + Contents.json).
// Every size is drawn natively from vector paths; ≤ 64 px uses a simplified layout
// (fewer, larger shapes) so the prompt and the status dots still read at 16 px.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Palette

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

let bgTop = rgb(0x34302C)
let bgBottom = rgb(0x0E0D0C)
let orange = rgb(0xD97757)
let orangeLight = rgb(0xEE8F6C)
let green = rgb(0x3FCF6E)
let red = rgb(0xF0564A)
let yellow = rgb(0xF4C23C)
let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

// MARK: - Geometry helpers

/// Rounded rect with Apple-style continuous ("squircle") corners.
/// Each corner blends into the straight edge over `1.528 * r` using three cubic segments
/// (same construction UIKit/AppKit use for `.continuous` corners).
func continuousRect(_ rect: CGRect, radius r0: CGFloat) -> CGPath {
    let p = CGMutablePath()
    let r = min(r0, min(rect.width, rect.height) / 2 / 1.528)
    let (x, y, w, h) = (rect.minX, rect.minY, rect.width, rect.height)
    // Control-point coefficients (unit radius) for one corner, from edge to apex.
    func corner(_ ox: CGFloat, _ oy: CGFloat, _ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) {
        // Local frame: corner point at (ox,oy); u = direction along incoming edge (towards corner),
        // v = direction along outgoing edge (away from corner). Points are corner - a*u + b*v.
        func pt(_ a: CGFloat, _ b: CGFloat) -> CGPoint {
            CGPoint(x: ox - a * r * ux + b * r * vx, y: oy - a * r * uy + b * r * vy)
        }
        p.addLine(to: pt(1.528665, 0))
        p.addCurve(to: pt(0.631493, 0.074911), control1: pt(1.088492, 0), control2: pt(0.868406, 0))
        p.addCurve(to: pt(0.074911, 0.631493), control1: pt(0.372824, 0.169060), control2: pt(0.169060, 0.372824))
        p.addCurve(to: pt(0, 1.528665), control1: pt(0, 0.868406), control2: pt(0, 1.088492))
    }
    p.move(to: CGPoint(x: x + w / 2, y: y))
    corner(x + w, y, 1, 0, 0, 1)        // top-right   (y grows downward in our drawing space)
    corner(x + w, y + h, 0, 1, -1, 0)   // bottom-right
    corner(x, y + h, -1, 0, 0, -1)      // bottom-left
    corner(x, y, 0, -1, 1, 0)           // top-left
    p.closeSubpath()
    return p
}

func linearGradient(_ ctx: CGContext, _ colors: [CGColor], from: CGPoint, to: CGPoint) {
    let g = CGGradient(colorsSpace: sRGB, colors: colors as CFArray, locations: nil)!
    ctx.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

// MARK: - Drawing (1024 × 1024 design space, origin top-left, y down)

struct Detail {
    let px: Int
    var tiny: Bool { px <= 20 }     // 16 px
    var small: Bool { px <= 64 }    // 32 / 64 px
}

func drawIcon(_ ctx: CGContext, _ d: Detail) {
    let s = CGFloat(d.px) / 1024
    ctx.translateBy(x: 0, y: CGFloat(d.px))
    ctx.scaleBy(x: s, y: -s)
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high

    // Apple macOS template: 824 × 824 body centred horizontally, 100 pt margins, ~22.5 % radius.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = continuousRect(body, radius: 185)

    // Drop shadow under the body (shadow offsets are in device space, y up).
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * s), blur: 28 * s, color: rgb(0x000000, 0.45))
    ctx.addPath(bodyPath)
    ctx.setFillColor(bgBottom)
    ctx.fillPath()
    ctx.restoreGState()

    // Background: warm charcoal → near black, plus a faint warm glow behind the cards.
    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    linearGradient(ctx, [bgTop, rgb(0x1C1A18), bgBottom], from: CGPoint(x: 512, y: 100), to: CGPoint(x: 512, y: 924))
    if !d.tiny {
        let glow = CGGradient(colorsSpace: sRGB, colors: [rgb(0xD97757, 0.20), rgb(0xD97757, 0)] as CFArray, locations: [0, 1])!
        ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 560), startRadius: 0,
                               endCenter: CGPoint(x: 512, y: 560), endRadius: 430, options: [])
    }
    ctx.restoreGState()

    // Hairline highlight on the body's upper edge.
    if !d.small {
        ctx.saveGState()
        ctx.addPath(bodyPath)
        ctx.clip()
        ctx.addPath(continuousRect(body.insetBy(dx: 1.5, dy: 1.5), radius: 183.5))
        ctx.setLineWidth(3)
        ctx.replacePathWithStrokedPath()
        ctx.clip()
        linearGradient(ctx, [rgb(0xFFFFFF, 0.22), rgb(0xFFFFFF, 0.0)], from: CGPoint(x: 512, y: 100), to: CGPoint(x: 512, y: 520))
        ctx.restoreGState()
    }

    // Card geometry.
    let card: CGRect
    let cardRadius: CGFloat
    if d.tiny {
        card = CGRect(x: 150, y: 232, width: 724, height: 560)
        cardRadius = 110
    } else if d.small {
        card = CGRect(x: 150, y: 330, width: 640, height: 480)
        cardRadius = 90
    } else {
        card = CGRect(x: 184, y: 372, width: 560, height: 420)
        cardRadius = 64
    }
    let pivot = CGPoint(x: card.maxX - 40, y: card.maxY + 60)   // fan around a point below the deck

    // Back cards (fanned).
    let backs: [(angle: CGFloat, fill: CGColor, edge: CGColor)] = d.tiny ? [] :
        d.small ? [(10, rgb(0x5A514A), rgb(0xFFFFFF, 0.10))] :
        [(15, rgb(0x4A433D), rgb(0xFFFFFF, 0.12)),
         (7.5, rgb(0x655A51), rgb(0xFFFFFF, 0.16))]
    for b in backs {
        ctx.saveGState()
        ctx.translateBy(x: pivot.x, y: pivot.y)
        ctx.rotate(by: b.angle * .pi / 180)
        ctx.translateBy(x: -pivot.x, y: -pivot.y)
        let path = continuousRect(card, radius: cardRadius)
        ctx.setShadow(offset: CGSize(width: 0, height: -8 * s), blur: 30 * s, color: rgb(0x000000, 0.45))
        ctx.addPath(path)
        ctx.setFillColor(b.fill)
        ctx.fillPath()
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
        ctx.addPath(path)
        ctx.setStrokeColor(b.edge)
        ctx.setLineWidth(3)
        ctx.strokePath()
        ctx.restoreGState()
    }

    // Front card: terminal window.
    let front = continuousRect(card, radius: cardRadius)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14 * s), blur: 40 * s, color: rgb(0x000000, 0.6))
    ctx.addPath(front)
    ctx.setFillColor(rgb(0x191716))
    ctx.fillPath()
    ctx.restoreGState()

    let barH: CGFloat = d.tiny ? 180 : d.small ? 118 : 92
    ctx.saveGState()
    ctx.addPath(front)
    ctx.clip()
    linearGradient(ctx, [rgb(0x221F1D), rgb(0x141312)], from: CGPoint(x: 0, y: card.minY), to: CGPoint(x: 0, y: card.maxY))
    // Title bar.
    let bar = CGRect(x: card.minX, y: card.minY, width: card.width, height: barH)
    ctx.addRect(bar)
    ctx.clip()
    linearGradient(ctx, [rgb(0x3D3834), rgb(0x2F2B28)], from: CGPoint(x: 0, y: bar.minY), to: CGPoint(x: 0, y: bar.maxY))
    ctx.restoreGState()
    if !d.tiny {
        ctx.setFillColor(rgb(0x000000, 0.35))
        ctx.fill(CGRect(x: card.minX, y: card.minY + barH, width: card.width, height: 3))
    }
    // Card rim.
    ctx.saveGState()
    ctx.addPath(continuousRect(card.insetBy(dx: 1.5, dy: 1.5), radius: cardRadius - 1.5))
    ctx.setStrokeColor(rgb(0xFFFFFF, d.small ? 0.22 : 0.16))
    ctx.setLineWidth(3)
    ctx.strokePath()
    ctx.restoreGState()

    // Status dots: running / needs you / your turn.
    let dotR: CGFloat = d.tiny ? 62 : d.small ? 36 : 22
    let dotGap: CGFloat = d.tiny ? 170 : d.small ? 92 : 64
    let dotX0 = card.minX + (d.tiny ? 86 : d.small ? 74 : 56)
    for (i, c) in [green, red, yellow].enumerated() {
        let center = CGPoint(x: dotX0 + CGFloat(i) * dotGap, y: card.minY + barH / 2)
        let rect = CGRect(x: center.x - dotR, y: center.y - dotR, width: dotR * 2, height: dotR * 2)
        ctx.saveGState()
        if !d.small { ctx.setShadow(offset: .zero, blur: 14 * s, color: c.copy(alpha: 0.7)) }
        ctx.setFillColor(c)
        ctx.fillEllipse(in: rect)
        ctx.restoreGState()
        if !d.small {   // soft specular highlight
            ctx.saveGState()
            ctx.addEllipse(in: rect)
            ctx.clip()
            linearGradient(ctx, [rgb(0xFFFFFF, 0.35), rgb(0xFFFFFF, 0)],
                           from: CGPoint(x: 0, y: rect.minY), to: CGPoint(x: 0, y: rect.midY))
            ctx.restoreGState()
        }
    }

    // Prompt ">_" in Claude orange, drawn as paths (no font dependency).
    let content = CGRect(x: card.minX, y: card.minY + barH, width: card.width, height: card.height - barH)
    let stroke: CGFloat = d.tiny ? 104 : d.small ? 64 : 44
    let chevH: CGFloat = d.tiny ? 230 : d.small ? 200 : 170
    let chevW: CGFloat = chevH * 0.55
    let px0 = card.minX + (d.tiny ? 120 : d.small ? 100 : 86)
    let midY = content.midY + (d.tiny ? 0 : 4)
    let chevron = CGMutablePath()
    chevron.move(to: CGPoint(x: px0, y: midY - chevH / 2))
    chevron.addLine(to: CGPoint(x: px0 + chevW, y: midY))
    chevron.addLine(to: CGPoint(x: px0, y: midY + chevH / 2))
    let underscoreW: CGFloat = d.tiny ? 240 : d.small ? 210 : 190
    let ux = px0 + chevW + (d.tiny ? 90 : d.small ? 84 : 70)
    let underscore = CGRect(x: ux, y: midY + chevH / 2 - stroke / 2, width: underscoreW, height: stroke)

    ctx.saveGState()
    if !d.small { ctx.setShadow(offset: .zero, blur: 36 * s, color: rgb(0xD97757, 0.55)) }
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    ctx.addPath(chevron)
    ctx.setLineWidth(stroke)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.replacePathWithStrokedPath()
    ctx.addPath(CGPath(roundedRect: underscore, cornerWidth: stroke / 2, cornerHeight: stroke / 2, transform: nil))
    ctx.clip()
    linearGradient(ctx, [orangeLight, orange], from: CGPoint(x: 0, y: midY - chevH / 2), to: CGPoint(x: 0, y: midY + chevH / 2))
    ctx.endTransparencyLayer()
    ctx.restoreGState()
}

// MARK: - Output

func renderPNG(px: Int, to url: URL) throws {
    guard let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                              space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        throw NSError(domain: "make-icon", code: 1, userInfo: [NSLocalizedDescriptionKey: "CGContext failed"])
    }
    drawIcon(ctx, Detail(px: px))
    guard let image = ctx.makeImage(),
          let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw NSError(domain: "make-icon", code: 2, userInfo: [NSLocalizedDescriptionKey: "PNG encode failed"])
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else {
        throw NSError(domain: "make-icon", code: 3, userInfo: [NSLocalizedDescriptionKey: "PNG write failed: \(url.path)"])
    }
}

let fm = FileManager.default
let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Support")
let iconset = outDir.appendingPathComponent("AppIcon.iconset")
let appiconset = outDir.appendingPathComponent("Assets.xcassets/AppIcon.appiconset")
try? fm.removeItem(at: iconset)
try? fm.removeItem(at: appiconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
try fm.createDirectory(at: appiconset, withIntermediateDirectories: true)

// iconutil naming: icon_<pt>x<pt>[@2x].png
var images: [[String: String]] = []
for pt in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(pt)x\(pt)\(scale == 2 ? "@2x" : "").png"
        let file = iconset.appendingPathComponent(name)
        try renderPNG(px: pt * scale, to: file)
        try fm.copyItem(at: file, to: appiconset.appendingPathComponent(name))
        images.append(["idiom": "mac", "size": "\(pt)x\(pt)", "scale": "\(scale)x", "filename": name])
    }
}

let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
let json = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try json.write(to: appiconset.appendingPathComponent("Contents.json"))
let catalogContents = outDir.appendingPathComponent("Assets.xcassets/Contents.json")
try #"{"info":{"author":"xcode","version":1}}"#.write(to: catalogContents, atomically: true, encoding: .utf8)

let icns = outDir.appendingPathComponent("AppIcon.icns")
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
try task.run()
task.waitUntilExit()
guard task.terminationStatus == 0 else {
    FileHandle.standardError.write("iconutil failed (\(task.terminationStatus))\n".data(using: .utf8)!)
    exit(1)
}
try? fm.removeItem(at: iconset)
print("Wrote \(icns.path) and \(appiconset.path) (1024 master: icon_512x512@2x.png)")
