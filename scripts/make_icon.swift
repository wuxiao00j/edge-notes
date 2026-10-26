import AppKit

// 用法: swift make_icon.swift <输出目录>
let outDir = URL(fileURLWithPath: CommandLine.arguments[1])
let S: CGFloat = 1024

func color(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

func drawIcon(in ctx: CGContext) {
    // y 轴朝下，便于按设计稿坐标画
    ctx.translateBy(x: 0, y: S)
    ctx.scaleBy(x: 1, y: -1)

    // ---- 底板：macOS 圆角方形 + 投影
    let plate = CGRect(x: 100, y: 100, width: 824, height: 824)
    let platePath = CGPath(roundedRect: plate, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 14), blur: 30, color: color(0x000000, 0.28).cgColor)
    ctx.addPath(platePath); ctx.setFillColor(color(0x7EC6F2).cgColor); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(platePath); ctx.clip()
    let sky = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [color(0x5DB4EE).cgColor, color(0xA9DBFA).cgColor, color(0xE6F5FF).cgColor] as CFArray, locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(sky, start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: [])
    // 云
    ctx.setFillColor(color(0xFFFFFF, 0.75).cgColor)
    for (x, y, w, h) in [(150.0, 790.0, 260.0, 110.0), (250.0, 750.0, 200.0, 130.0), (640.0, 820.0, 300.0, 120.0), (720.0, 780.0, 180.0, 120.0)] {
        ctx.fillEllipse(in: CGRect(x: x, y: y, width: w, height: h))
    }
    // 顶部高光
    ctx.setFillColor(color(0xFFFFFF, 0.10).cgColor)
    ctx.fillEllipse(in: CGRect(x: -100, y: -420, width: 1224, height: 700))
    ctx.restoreGState()

    // ---- 绳子：二次曲线
    let p0 = CGPoint(x: 150, y: 318), p1 = CGPoint(x: 874, y: 318), c = CGPoint(x: 512, y: 470)
    func ropeY(_ t: CGFloat) -> CGFloat { (1 - t) * (1 - t) * p0.y + 2 * t * (1 - t) * c.y + t * t * p1.y }
    func ropeX(_ t: CGFloat) -> CGFloat { p0.x + (p1.x - p0.x) * t }
    func ropeAngle(_ t: CGFloat) -> CGFloat {
        let dy = 2 * (1 - t) * (c.y - p0.y) + 2 * t * (p1.y - c.y)
        return atan2(dy, p1.x - p0.x)
    }
    let rope = CGMutablePath()
    rope.move(to: p0); rope.addQuadCurve(to: p1, control: c)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 6), blur: 6, color: color(0x1E3A5A, 0.35).cgColor)
    ctx.addPath(rope); ctx.setStrokeColor(color(0x8A6440).cgColor); ctx.setLineWidth(15); ctx.setLineCap(.round); ctx.strokePath()
    ctx.restoreGState()
    // 绳子纹理
    ctx.saveGState()
    ctx.addPath(rope); ctx.setStrokeColor(color(0xB58A5C).cgColor); ctx.setLineWidth(5)
    ctx.setLineDash(phase: 0, lengths: [14, 12]); ctx.strokePath()
    ctx.restoreGState()
    // 两端的环
    for p in [p0, p1] {
        ctx.setStrokeColor(color(0x6B4C2E).cgColor); ctx.setLineWidth(10)
        ctx.strokeEllipse(in: CGRect(x: p.x - 20, y: p.y - 20, width: 40, height: 40))
    }

    // ---- 挂件
    func hang(at t: CGFloat, tilt: CGFloat, size: CGSize, draw: (CGRect) -> Void) {
        let top = CGPoint(x: ropeX(t), y: ropeY(t) - 8)
        ctx.saveGState()
        ctx.translateBy(x: top.x, y: top.y)
        ctx.rotate(by: tilt * .pi / 180)
        let rect = CGRect(x: -size.width / 2, y: 0, width: size.width, height: size.height)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 16), blur: 22, color: color(0x10304F, 0.32).cgColor)
        draw(rect)
        ctx.restoreGState()
        // 夹子
        let pin = CGRect(x: -19, y: -46, width: 38, height: 100)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 4), blur: 5, color: color(0x000000, 0.30).cgColor)
        let pinPath = CGPath(roundedRect: pin, cornerWidth: 9, cornerHeight: 9, transform: nil)
        ctx.addPath(pinPath); ctx.setFillColor(color(0xC99A62).cgColor); ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: pin, cornerWidth: 9, cornerHeight: 9, transform: nil)); ctx.clip()
        let wood = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [color(0xEBC28A).cgColor, color(0xB98652).cgColor] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(wood, start: CGPoint(x: pin.minX, y: 0), end: CGPoint(x: pin.maxX, y: 0), options: [])
        ctx.setFillColor(color(0x7A5532, 0.55).cgColor); ctx.fill(CGRect(x: pin.minX, y: -8, width: pin.width, height: 4))
        ctx.restoreGState()
        ctx.setFillColor(color(0x9AA3AD).cgColor)
        ctx.fillEllipse(in: CGRect(x: -8, y: -16, width: 16, height: 16))
        ctx.restoreGState()
    }

    // 黄色便签
    hang(at: 0.27, tilt: -7, size: CGSize(width: 284, height: 290)) { r in
        let path = CGPath(roundedRect: r, cornerWidth: 16, cornerHeight: 16, transform: nil)
        ctx.addPath(path); ctx.setFillColor(color(0xFFDD55).cgColor); ctx.fillPath()
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
        ctx.addPath(path); ctx.clip()
        let paper = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [color(0xFFEB85).cgColor, color(0xFFD444).cgColor] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(paper, start: CGPoint(x: 0, y: r.minY), end: CGPoint(x: 0, y: r.maxY), options: [])
        // 待办勾选 + 文字行
        let ink = color(0xA87A12, 0.75)
        for (i, w) in [(0, 150.0), (1, 120.0), (2, 165.0)] {
            let y = r.minY + 92 + CGFloat(i) * 62
            let box = CGRect(x: r.minX + 42, y: y - 4, width: 30, height: 30)
            ctx.setStrokeColor(ink.cgColor); ctx.setLineWidth(6)
            ctx.addPath(CGPath(roundedRect: box, cornerWidth: 8, cornerHeight: 8, transform: nil)); ctx.strokePath()
            if i == 0 {
                ctx.setLineCap(.round); ctx.setLineJoin(.round); ctx.setLineWidth(7)
                ctx.move(to: CGPoint(x: box.minX + 6, y: box.midY + 1))
                ctx.addLine(to: CGPoint(x: box.minX + 13, y: box.maxY - 6))
                ctx.addLine(to: CGPoint(x: box.maxX - 4, y: box.minY + 4))
                ctx.strokePath()
            }
            ctx.setFillColor(ink.withAlphaComponent(i == 0 ? 0.35 : 0.7).cgColor)
            ctx.addPath(CGPath(roundedRect: CGRect(x: r.minX + 92, y: y + 3, width: w, height: 16), cornerWidth: 8, cornerHeight: 8, transform: nil))
            ctx.fillPath()
        }
        // 右下折角
        ctx.setFillColor(color(0xE8B92E).cgColor)
        ctx.move(to: CGPoint(x: r.maxX, y: r.maxY - 56)); ctx.addLine(to: CGPoint(x: r.maxX - 56, y: r.maxY)); ctx.addLine(to: CGPoint(x: r.maxX - 56, y: r.maxY - 56)); ctx.closePath(); ctx.fillPath()
        ctx.restoreGState()
    }

    // 拍立得照片
    hang(at: 0.765, tilt: 6, size: CGSize(width: 252, height: 300)) { r in
        let path = CGPath(roundedRect: r, cornerWidth: 10, cornerHeight: 10, transform: nil)
        ctx.addPath(path); ctx.setFillColor(color(0xFCFCFA).cgColor); ctx.fillPath()
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
        let photo = CGRect(x: r.minX + 20, y: r.minY + 22, width: r.width - 40, height: 206)
        ctx.addRect(photo); ctx.clip()
        let dusk = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [color(0xFF9E6B).cgColor, color(0xFFD08A).cgColor] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(dusk, start: CGPoint(x: 0, y: photo.minY), end: CGPoint(x: 0, y: photo.maxY), options: [])
        ctx.setFillColor(color(0xFFF4C2).cgColor)
        ctx.fillEllipse(in: CGRect(x: photo.midX + 10, y: photo.minY + 40, width: 70, height: 70))
        ctx.setFillColor(color(0x5FB46A).cgColor)
        ctx.fillEllipse(in: CGRect(x: photo.minX - 80, y: photo.minY + 140, width: 260, height: 180))
        ctx.setFillColor(color(0x3E9A57).cgColor)
        ctx.fillEllipse(in: CGRect(x: photo.midX - 30, y: photo.minY + 155, width: 260, height: 180))
        ctx.restoreGState()
    }
}

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let g = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = g
    let ctx = g.cgContext
    ctx.interpolationQuality = .high
    ctx.scaleBy(x: CGFloat(px) / S, y: CGFloat(px) / S)
    drawIcon(in: ctx)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
var images: [String] = []
for (pt, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let name = "icon_\(pt)x\(pt)\(scale == 2 ? "@2x" : "").png"
    try render(pt * scale).write(to: outDir.appendingPathComponent(name))
    images.append("""
        { "filename" : "\(name)", "idiom" : "mac", "scale" : "\(scale)x", "size" : "\(pt)x\(pt)" }
    """)
}
let contents = "{\n  \"images\" : [\n" + images.joined(separator: ",\n") + "\n  ],\n  \"info\" : { \"author\" : \"xcode\", \"version\" : 1 }\n}\n"
try contents.write(to: outDir.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
print("ok")
