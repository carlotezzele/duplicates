// Draws Doppio's app icon (two identical photos on an espresso-coloured tile) as a
// 1024×1024 PNG. scripts/make-icon.sh turns it into App/Doppio.icns.
// Usage: swift scripts/make-icon.swift <output.png>
import AppKit

let side: CGFloat = 1024
let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-1024.png"

let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(side), height: Int(side), bitsPerComponent: 8, bytesPerRow: 0,
                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

// Tile: macOS icon grid (824 pt square, ~185 pt corner radius) with a soft shadow.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.35))
ctx.addPath(tilePath)
ctx.setFillColor(color(0x4A2C1A))
ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(tilePath)
ctx.clip()
let gradient = CGGradient(colorsSpace: space, colors: [color(0x8A5A36), color(0x3A2213)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY), options: [])
// A faint crema highlight across the top.
ctx.setFillColor(color(0xFFFFFF, 0.06))
ctx.fillEllipse(in: CGRect(x: tile.minX - 120, y: tile.midY + 80, width: tile.width + 240, height: 520))
ctx.restoreGState()

/// One photo: white card, landscape inside (sky, sun, two hills).
func photo(center: CGPoint, angle: CGFloat, dim: Bool) {
    let card = CGRect(x: -230, y: -175, width: 460, height: 350)
    ctx.saveGState()
    ctx.translateBy(x: center.x, y: center.y)
    ctx.rotate(by: angle)
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(0x000000, 0.4))
    ctx.addPath(CGPath(roundedRect: card, cornerWidth: 26, cornerHeight: 26, transform: nil))
    ctx.setFillColor(color(0xFFF8EE))
    ctx.fillPath()
    ctx.setShadow(offset: .zero, blur: 0, color: nil)

    let picture = card.insetBy(dx: 26, dy: 26)
    let picturePath = CGPath(roundedRect: picture, cornerWidth: 12, cornerHeight: 12, transform: nil)
    ctx.addPath(picturePath)
    ctx.clip()
    let sky = CGGradient(colorsSpace: space, colors: [color(0x9FD3F0), color(0xE6F4FB)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(sky, start: CGPoint(x: 0, y: picture.maxY), end: CGPoint(x: 0, y: picture.minY), options: [])
    ctx.setFillColor(color(0xF2B33D))
    ctx.fillEllipse(in: CGRect(x: picture.maxX - 130, y: picture.maxY - 120, width: 78, height: 78))
    ctx.setFillColor(color(0x5E9E73))
    ctx.move(to: CGPoint(x: picture.minX, y: picture.minY))
    ctx.addLine(to: CGPoint(x: picture.minX, y: picture.minY + 90))
    ctx.addQuadCurve(to: CGPoint(x: picture.midX + 40, y: picture.minY + 40),
                     control: CGPoint(x: picture.minX + 150, y: picture.minY + 230))
    ctx.addLine(to: CGPoint(x: picture.midX + 40, y: picture.minY))
    ctx.fillPath()
    ctx.setFillColor(color(0x3F7A55))
    ctx.move(to: CGPoint(x: picture.minX + 90, y: picture.minY))
    ctx.addQuadCurve(to: CGPoint(x: picture.maxX, y: picture.minY + 130),
                     control: CGPoint(x: picture.midX + 110, y: picture.minY + 260))
    ctx.addLine(to: CGPoint(x: picture.maxX, y: picture.minY))
    ctx.fillPath()
    if dim {
        ctx.setFillColor(color(0x3A2213, 0.18))
        ctx.fill(picture)
    }
    ctx.restoreGState()
}

photo(center: CGPoint(x: 445, y: 575), angle: 0.13, dim: true)
photo(center: CGPoint(x: 580, y: 445), angle: -0.07, dim: false)

let image = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
print("Wrote \(output)")
