/// 桌面上的凸起高度圖。每個圖示佔一塊，疊越多越高，最後模糊成圓潤的包。
public struct HeightField {
    public let origin: SIMD2<Float>
    public let cell: Float
    public let w: Int
    public let h: Int
    public private(set) var values: [Float]

    public init(origin: SIMD2<Float>, size: SIMD2<Float>, cell: Float = 8) {
        self.origin = origin
        self.cell = cell
        w = Int((size.x / cell).rounded(.up)) + 1
        h = Int((size.y / cell).rounded(.up)) + 1
        values = Array(repeating: 0, count: w * h)
    }

    /// 在矩形範圍內加高度（圖示的圖案＋檔名那一塊）。
    public mutating func addBox(center: SIMD2<Float>, size: SIMD2<Float>, height: Float) {
        let lo = (center - size / 2 - origin) / cell, hi = (center + size / 2 - origin) / cell
        let i0 = max(0, Int(lo.x.rounded())), i1 = min(w - 1, Int(hi.x.rounded()))
        let j0 = max(0, Int(lo.y.rounded())), j1 = min(h - 1, Int(hi.y.rounded()))
        guard i0 <= i1, j0 <= j1 else { return }
        for j in j0...j1 { for i in i0...i1 { values[j * w + i] += height } }
    }

    public mutating func clamp(max m: Float) {
        for k in values.indices { values[k] = min(values[k], m) }
    }

    /// 可分離的盒狀模糊跑幾次 ≈ 高斯。
    public mutating func blur(radius r: Int, passes: Int = 3) {
        guard r > 0 else { return }
        var tmp = values
        for _ in 0..<passes {
            for j in 0..<h {
                var acc: Float = 0
                for i in -r...r { acc += values[j * w + min(max(i, 0), w - 1)] }
                for i in 0..<w {
                    tmp[j * w + i] = acc / Float(2 * r + 1)
                    acc += values[j * w + min(i + r + 1, w - 1)] - values[j * w + max(i - r, 0)]
                }
            }
            for i in 0..<w {
                var acc: Float = 0
                for j in -r...r { acc += tmp[min(max(j, 0), h - 1) * w + i] }
                for j in 0..<h {
                    values[j * w + i] = acc / Float(2 * r + 1)
                    acc += tmp[min(j + r + 1, h - 1) * w + i] - tmp[max(j - r, 0) * w + i]
                }
            }
        }
    }

    public var isFlat: Bool { values.allSatisfy { $0 < 0.01 } }

    /// 雙線性取樣，範圍外 = 0。
    public func sample(_ x: Float, _ y: Float) -> Float {
        let fx = (x - origin.x) / cell, fy = (y - origin.y) / cell
        if fx < 0 || fy < 0 { return 0 }
        let i = Int(fx), j = Int(fy)
        if i >= w - 1 || j >= h - 1 { return 0 }
        let tx = fx - Float(i), ty = fy - Float(j)
        let a = values[j * w + i], b = values[j * w + i + 1]
        let c = values[(j + 1) * w + i], d = values[(j + 1) * w + i + 1]
        return (a * (1 - tx) + b * tx) * (1 - ty) + (c * (1 - tx) + d * tx) * ty
    }

    /// 由圖示中心建高度圖。iconSize 是 Finder 的圖示大小（點）。
    public static func fromIcons(_ centers: [SIMD2<Float>], iconSize: Float,
                                 origin: SIMD2<Float>, size: SIMD2<Float>) -> HeightField {
        var f = HeightField(origin: origin, size: size)
        // 圖示 + 下方檔名大約是 1.3 倍寬、1.7 倍高，中心往下移一點
        let box = SIMD2(iconSize * 1.3, iconSize * 1.7)
        for c in centers { f.addBox(center: c - SIMD2(0, iconSize * 0.3), size: box, height: 10) }
        f.clamp(max: 60)
        f.blur(radius: max(1, Int(iconSize * 0.25 / f.cell)))
        return f
    }
}
