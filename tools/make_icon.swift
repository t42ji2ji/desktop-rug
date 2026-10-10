// app 圖示：把 `DesktopRug --icon` 畫出來的地毯（透明背景）放到 macOS 標準的圓角方形底板上，輸出 Resources/AppIcon.icns
//   build/DesktopRug.app/Contents/MacOS/DesktopRug --icon /tmp/rug.png && swift tools/make_icon.swift /tmp/rug.png
import AppKit
import UniformTypeIdentifiers

let src = CommandLine.arguments[1]
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let rug = NSImage(contentsOfFile: src)!.cgImage(forProposedRect: nil, context: nil, hints: nil)!

let S = 1024
let ctx = CGContext(data: nil, width: S, height: S, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
// 底板：824×824、圓角 185（Apple 的 macOS 圖示格線），淺木色漸層
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let path = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: NSColor.black.withAlphaComponent(0.3).cgColor)
ctx.addPath(path); ctx.setFillColor(NSColor(red: 0.84, green: 0.70, blue: 0.53, alpha: 1).cgColor); ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(path); ctx.clip()
let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
    NSColor(red: 0.93, green: 0.83, blue: 0.68, alpha: 1).cgColor,
    NSColor(red: 0.80, green: 0.64, blue: 0.47, alpha: 1).cgColor,
] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: 924), end: CGPoint(x: 0, y: 100), options: [])
// 木地板的板縫
ctx.setStrokeColor(NSColor(red: 0.55, green: 0.40, blue: 0.28, alpha: 0.25).cgColor)
ctx.setLineWidth(3)
for y in stride(from: 100.0, through: 924.0, by: 103.0) { ctx.move(to: CGPoint(x: 100, y: y)); ctx.addLine(to: CGPoint(x: 924, y: y)) }
ctx.strokePath()
// 地毯：裁掉透明邊、斜一點放在中間
ctx.translateBy(x: 512, y: 500)
ctx.rotate(by: 0.12)
let w: CGFloat = 860, h = w * CGFloat(rug.height) / CGFloat(rug.width)
ctx.draw(rug, in: CGRect(x: -w / 2, y: -h / 2, width: w, height: h))
ctx.restoreGState()

let master = ctx.makeImage()!
let iconset = root.appendingPathComponent("build/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
func write(_ img: CGImage, _ url: URL) {
    let d = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(d, img, nil); CGImageDestinationFinalize(d)
}
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = base * scale
        let c = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.interpolationQuality = .high
        c.draw(master, in: CGRect(x: 0, y: 0, width: px, height: px))
        write(c.makeImage()!, iconset.appendingPathComponent("icon_\(base)x\(base)\(scale == 2 ? "@2x" : "").png"))
    }
}
write(master, root.appendingPathComponent("Resources/icon-1024.png"))
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try! p.run(); p.waitUntilExit()
print("wrote Resources/AppIcon.icns")
