// Renders the app icon artwork. Run via ./Resources/Icon/make_icon.sh
//   legacy.png – complete 1024px icon in the webapp.wtf style: paper squircle with a dot grid, a tilted lavender
//                card the mascot (purr.svg, drawn by make_mascot.py) peeks out of, and an acid sticker with a
//                hand-drawn TV.
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
let size = 1024.0

func png(_ draw: (CGContext) -> Void) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw(NSGraphicsContext.current!.cgContext)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

func rgb(_ hex: UInt32) -> CGColor {
    CGColor(red: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}
// webapp.wtf palette
let paper = rgb(0xF5F0E7), ink = rgb(0x25221F), lavender = rgb(0xBFABEF), acid = rgb(0xDFEF68)

let cat = NSImage(contentsOf: out.appendingPathComponent("purr.svg"))!

/// Draws `body` rotated by `degrees` around the centre of `rect`.
func rotated(_ ctx: CGContext, _ rect: CGRect, _ degrees: CGFloat, _ body: () -> Void) {
    ctx.saveGState()
    ctx.translateBy(x: rect.midX, y: rect.midY)
    ctx.rotate(by: degrees * .pi / 180)
    ctx.translateBy(x: -rect.midX, y: -rect.midY)
    body()
    ctx.restoreGState()
}

/// Ink outline + hard offset shadow (y up in CoreGraphics, so the shadow goes down = negative y).
func brutalRect(_ ctx: CGContext, _ rect: CGRect, fill: CGColor, line: CGFloat, shadow: CGFloat) {
    ctx.setFillColor(ink)
    ctx.fill(rect.offsetBy(dx: shadow, dy: -shadow))
    ctx.setFillColor(fill)
    ctx.fill(rect)
    // Stroke centred on the edge: it covers the anti-aliasing seam between the fill and the shadow.
    ctx.setStrokeColor(ink)
    ctx.setLineWidth(line)
    ctx.stroke(rect)
}

// Icon on Apple's macOS grid: 824px rounded square centred on the 1024 canvas.
try png { ctx in
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let squircle = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: CGColor(gray: 0, alpha: 0.3))
    ctx.addPath(squircle)
    ctx.setFillColor(paper)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()
    // dot grid
    ctx.setFillColor(ink.copy(alpha: 0.12)!)
    for x in stride(from: 124.0, to: 924, by: 44) {
        for y in stride(from: 124.0, to: 924, by: 44) { ctx.fillEllipse(in: CGRect(x: x - 3, y: y - 3, width: 6, height: 6)) }
    }

    // Lavender card with the cat peeking up from its bottom edge.
    let card = CGRect(x: 205, y: 190, width: 590, height: 610)
    rotated(ctx, card, -4) {
        brutalRect(ctx, card, fill: lavender, line: 18, shadow: 30)
        ctx.saveGState()
        ctx.clip(to: card.insetBy(dx: 9, dy: 9))
        let w = 500.0, h = w * cat.size.height / cat.size.width
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        cat.draw(in: CGRect(x: card.midX - w / 2 - 10, y: card.minY - h * 0.14, width: w, height: h))
        ctx.restoreGState()
        ctx.setStrokeColor(ink)
        ctx.setLineWidth(18)
        ctx.stroke(card)
    }
    ctx.restoreGState()

    // Acid sticker with a TV, top right, tilted the other way.
    let sticker = CGRect(x: 600, y: 640, width: 260, height: 200)
    rotated(ctx, sticker, 9) {
        brutalRect(ctx, sticker, fill: acid, line: 14, shadow: 18)
        glyphInk(in: sticker.insetBy(dx: 58, dy: 30))
    }
}.write(to: out.appendingPathComponent("legacy.png"))

/// A retro TV with antennas and a play triangle, drawn by hand (SF Symbols may not be used in app icons).
func glyphInk(in rect: CGRect) {
    let ctx = NSGraphicsContext.current!.cgContext
    let line = rect.height * 0.12
    ctx.setStrokeColor(ink)
    ctx.setFillColor(ink)
    ctx.setLineWidth(line)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    let screen = CGRect(x: rect.minX + line / 2, y: rect.minY + line / 2,
                        width: rect.width - line, height: rect.height * 0.68)
    ctx.addPath(CGPath(roundedRect: screen, cornerWidth: line * 1.4, cornerHeight: line * 1.4, transform: nil))
    ctx.strokePath()
    // antennas
    let top = CGPoint(x: screen.midX, y: screen.maxY + line * 0.3)
    ctx.move(to: top); ctx.addLine(to: CGPoint(x: top.x - rect.width * 0.2, y: rect.maxY - line / 2))
    ctx.move(to: top); ctx.addLine(to: CGPoint(x: top.x + rect.width * 0.2, y: rect.maxY - line / 2))
    ctx.strokePath()
    // play triangle
    let s = screen.height * 0.42, c = CGPoint(x: screen.midX + s * 0.08, y: screen.midY)
    ctx.move(to: CGPoint(x: c.x - s * 0.45, y: c.y + s * 0.52))
    ctx.addLine(to: CGPoint(x: c.x + s * 0.55, y: c.y))
    ctx.addLine(to: CGPoint(x: c.x - s * 0.45, y: c.y - s * 0.52))
    ctx.closePath()
    ctx.setLineWidth(line * 0.5)
    ctx.drawPath(using: .fillStroke)
}
