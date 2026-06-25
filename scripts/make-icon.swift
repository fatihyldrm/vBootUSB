#!/usr/bin/env swift
import AppKit

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: r/255, green: g/255, blue: b/255, alpha: a)
}

func draw(_ ctx: CGContext, _ S: CGFloat) {
    ctx.clear(CGRect(x: 0, y: 0, width: S, height: S))

    let inset = S * 0.045
    let bg = CGRect(x: inset, y: inset, width: S - 2*inset, height: S - 2*inset)
    let corner = bg.width * 0.225
    let bgPath = CGPath(roundedRect: bg, cornerWidth: corner, cornerHeight: corner, transform: nil)
    ctx.saveGState()
    ctx.addPath(bgPath); ctx.clip()
    let space = CGColorSpaceCreateDeviceRGB()
    let grad = CGGradient(colorsSpace: space,
                          colors: [color(59,130,246), color(29,78,216)] as CFArray,
                          locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: S/2, y: S),
                           end: CGPoint(x: S/2, y: 0), options: [])
    ctx.restoreGState()

    let bodyW = S * 0.30, bodyH = S * 0.38
    let capW  = S * 0.20, capH = S * 0.14
    let gap   = S * 0.015
    let total = bodyH + gap + capH
    let cx = S / 2
    let bottomY = (S - total) / 2

    let bodyRect = CGRect(x: cx - bodyW/2, y: bottomY, width: bodyW, height: bodyH)
    let capRect  = CGRect(x: cx - capW/2, y: bottomY + bodyH + gap, width: capW, height: capH)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -S*0.012), blur: S*0.03,
                  color: color(0,0,0,0.28))
    let bodyPath = CGPath(roundedRect: bodyRect, cornerWidth: S*0.045, cornerHeight: S*0.045, transform: nil)
    ctx.addPath(bodyPath); ctx.setFillColor(color(255,255,255)); ctx.fillPath()
    ctx.restoreGState()

    let capPath = CGPath(roundedRect: capRect, cornerWidth: S*0.022, cornerHeight: S*0.022, transform: nil)
    ctx.addPath(capPath); ctx.setFillColor(color(199,205,214)); ctx.fillPath()

    let prongW = capW * 0.22, prongH = capH * 0.42
    let py = capRect.maxY - prongH - S*0.006
    for dx in [-capW*0.18, capW*0.18] {
        let pr = CGRect(x: cx + dx - prongW/2, y: py, width: prongW, height: prongH)
        ctx.addPath(CGPath(roundedRect: pr, cornerWidth: S*0.008, cornerHeight: S*0.008, transform: nil))
        ctx.setFillColor(color(55,65,81)); ctx.fillPath()
    }

    let boltW = bodyW * 0.66, boltH = bodyH * 0.80
    let ox = cx - boltW/2, oy = bodyRect.midY - boltH/2
    let pts: [(CGFloat, CGFloat)] = [
        (0.62, 1.00), (0.20, 0.48), (0.46, 0.48),
        (0.38, 0.00), (0.80, 0.56), (0.54, 0.56)
    ]
    let bolt = CGMutablePath()
    for (i, p) in pts.enumerated() {
        let pt = CGPoint(x: ox + p.0*boltW, y: oy + p.1*boltH)
        if i == 0 { bolt.move(to: pt) } else { bolt.addLine(to: pt) }
    }
    bolt.closeSubpath()
    ctx.addPath(bolt); ctx.setFillColor(color(251,191,36)); ctx.fillPath()
    ctx.addPath(bolt); ctx.setStrokeColor(color(180,83,9)); ctx.setLineWidth(S*0.006); ctx.strokePath()
}

func makePNG(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                              isPlanar: false, colorSpaceName: .deviceRGB,
                              bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let gctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = gctx
    draw(gctx.cgContext, CGFloat(px))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

let specs: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
for (name, px) in specs {
    let data = makePNG(px)
    try! data.write(to: URL(fileURLWithPath: outDir + "/" + name))
}
print("Iconset written: \(outDir) (\(specs.count) png)")
