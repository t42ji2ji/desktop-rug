// 把 GPT 生的貓動畫圖（cats/raw/<cat>-<anim>.png，4×4 格、透明背景）整理成 app 用的貼圖：
//   swift tools/extract_cats.swift
// 輸出 cats/<cat>-<anim>.png（4×4，每格 192×128）與 cats/meta.json（每隻貓的身長，以格寬為 1）。
// 一支動畫只算一個位移：所有格子的身體重心平均起來對到格子中心，動畫內部的移動才不會被壓平。
import AppKit
import ImageIO
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath)
let rawDir = root.appendingPathComponent("cats/raw")
let outDir = root.appendingPathComponent("cats")
let cols = 4, rows = 4
let outCell = (w: 192, h: 128)

func load(_ url: URL) -> (w: Int, h: Int, px: [UInt8])? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
    let w = img.width, h = img.height
    var px = [UInt8](repeating: 0, count: w * h * 4)
    let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    return (w, h, px)   // 第 0 列是圖的最上面
}

var meta: [String: [String: Double]] = [:]
let files = (try? FileManager.default.contentsOfDirectory(at: rawDir, includingPropertiesForKeys: nil)) ?? []
for url in files.filter({ $0.pathExtension == "png" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
    let name = url.deletingPathExtension().lastPathComponent
    guard let img = load(url) else { print("skip", name); continue }
    let cw = Double(img.w) / Double(cols), ch = Double(img.h) / Double(rows)

    // 每格的 alpha 重心與寬度
    var cx = 0.0, cy = 0.0, n = 0.0
    var widths: [Double] = []
    var edgeTouch = 0
    for f in 0..<(cols * rows) {
        let x0 = Int(Double(f % cols) * cw), y0 = Int(Double(f / cols) * ch)
        let x1 = Int(Double(f % cols + 1) * cw), y1 = Int(Double(f / cols + 1) * ch)
        var minX = Int.max, maxX = -1, minY = Int.max, maxY = -1
        for y in y0..<y1 { for x in x0..<x1 {
            let a = Double(img.px[(y * img.w + x) * 4 + 3]) / 255
            if a > 0.5 {
                cx += Double(x - x0) * a; cy += Double(y - y0) * a; n += a
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        } }
        if maxX >= 0 {
            widths.append(Double(maxX - minX))
            if minX <= x0 + 1 || maxX >= x1 - 2 || minY <= y0 + 1 || maxY >= y1 - 2 { edgeTouch += 1 }
        }
    }
    guard n > 0 else { print("empty", name); continue }
    let shiftX = cw / 2 - cx / n, shiftY = ch / 2 - cy / n

    // 畫到輸出圖：每格先位移再縮小
    let ow = outCell.w * cols, oh = outCell.h * rows
    let ctx = CGContext(data: nil, width: ow, height: oh, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    let srcImg = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(url as CFURL, nil)!, 0, nil)!
    let sx = Double(outCell.w) / cw, sy = Double(outCell.h) / ch
    for f in 0..<(cols * rows) {
        let col = f % cols, row = f / cols
        // CoreGraphics 原點在左下：輸出第 row 列（由上數）在 y = (rows-1-row)*h
        let dst = CGRect(x: col * outCell.w, y: (rows - 1 - row) * outCell.h, width: outCell.w, height: outCell.h)
        ctx.saveGState()
        ctx.clip(to: dst)
        // 把整張原圖放好，讓這一格（含位移）落在 dst
        let ox = Double(dst.minX) - (Double(col) * cw - shiftX) * sx
        let oyTop = Double(row) * ch - shiftY   // 這格在原圖的上緣（含位移）
        let oy = Double(dst.maxY) - (Double(img.h) - oyTop) * sy
        ctx.draw(srcImg, in: CGRect(x: ox, y: oy, width: Double(img.w) * sx, height: Double(img.h) * sy))
        ctx.restoreGState()
    }
    let out = outDir.appendingPathComponent(name + ".png")
    let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    CGImageDestinationFinalize(dest)

    let parts = name.split(separator: "-")
    if parts.count == 2, parts[1] == "walk" {
        let w = widths.sorted()[widths.count / 2]
        meta[String(parts[0]), default: [:]]["bodyLength"] = w / cw   // 身長佔格寬的比例
    }
    print(String(format: "%@  shift (%.0f, %.0f)px  frames touching edge: %d", name, shiftX, shiftY, edgeTouch))
}
let json = try! JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys])
try! json.write(to: outDir.appendingPathComponent("meta.json"))
print("meta", String(data: json, encoding: .utf8)!)
