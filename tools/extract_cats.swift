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

/// GPT 的透明圖在背景留了很多幾乎透明的彩色雜點：太透明的歸零，再刪掉每格裡跟身體不相連的小碎塊。
func cleanSpecks(_ ctx: CGContext, cellW: Int, cellH: Int) {
    let w = ctx.width, h = ctx.height, bpr = ctx.bytesPerRow
    let px = ctx.data!.bindMemory(to: UInt8.self, capacity: bpr * h)
    for y in 0..<h { for x in 0..<w where px[y * bpr + x * 4 + 3] < 30 {
        for c in 0..<4 { px[y * bpr + x * 4 + c] = 0 }
    } }
    var seen = [Bool](repeating: false, count: w * h)
    for cy in stride(from: 0, to: h, by: cellH) { for cx in stride(from: 0, to: w, by: cellW) {
        var comps: [[Int]] = []
        for y in cy..<min(cy + cellH, h) { for x in cx..<min(cx + cellW, w) {
            let i = y * w + x
            if seen[i] || px[y * bpr + x * 4 + 3] == 0 { continue }
            var stack = [i], comp: [Int] = []
            seen[i] = true
            while let k = stack.popLast() {
                comp.append(k)
                let kx = k % w, ky = k / w
                for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                    let nx = kx + dx, ny = ky + dy
                    guard nx >= cx, ny >= cy, nx < min(cx + cellW, w), ny < min(cy + cellH, h) else { continue }
                    let n = ny * w + nx
                    if !seen[n] && px[ny * bpr + nx * 4 + 3] != 0 { seen[n] = true; stack.append(n) }
                }
            }
            comps.append(comp)
        } }
        guard let biggest = comps.map(\.count).max() else { continue }
        for comp in comps where comp.count < max(40, biggest / 50) {
            for k in comp { for c in 0..<4 { px[(k / w) * bpr + (k % w) * 4 + c] = 0 } }
        }
    } }
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
        // 只取這一格自己的內容再位移，隔壁格子的尾巴尖才不會被帶進來
        let cellRect = CGRect(x: Double(col) * cw, y: Double(row) * ch, width: cw, height: ch).integral
        guard let cell = srcImg.cropping(to: cellRect) else { continue }
        ctx.saveGState()
        ctx.clip(to: dst)
        ctx.draw(cell, in: CGRect(x: Double(dst.minX) + shiftX * sx, y: Double(dst.minY) - shiftY * sy,
                                  width: Double(cell.width) * sx, height: Double(cell.height) * sy))
        ctx.restoreGState()
    }
    cleanSpecks(ctx, cellW: outCell.w, cellH: outCell.h)
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
