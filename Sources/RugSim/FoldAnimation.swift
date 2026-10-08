import simd

/// 收起／鋪開的折疊動畫：右半繞圓弧翻到左半上 → 上半往下對折 → 折好的小包浮起、縮小消失。
/// progress 0 = 攤平，1 = 收好消失；鋪開就倒著播。純函式，給 Cloth.pose 用。
public struct FoldAnimation {
    public var placement: RugPlacement
    /// 折痕的半徑（點）：越大折邊越圓、越厚
    public var crease: Float = 10

    public init(placement: RugPlacement) { self.placement = placement }

    // 時間軸（progress 的區段）
    static let fold1 = (0.0 as Float, 0.40 as Float)
    static let fold2 = (0.45 as Float, 0.80 as Float)
    static let away = (0.82 as Float, 1.0 as Float)

    static func ease(_ x: Float) -> Float {
        let c = min(max(x, 0), 1)
        return c < 0.5 ? 4 * c * c * c : 1 - pow(-2 * c + 2, 3) / 2
    }

    static func phase(_ p: Float, _ r: (Float, Float)) -> Float { ease((p - r.0) / (r.1 - r.0)) }

    /// 繞圓弧折：s = 離折痕的距離（> 0 才折），h = 這一點原本的高度。
    /// 折痕的圓心在 (0, c)，這一層的半徑 = c - h，所以外層繞大圈、內層繞小圈，疊起來不會穿過彼此。
    static func bend(s: Float, h: Float, angle φ: Float, c: Float) -> (s: Float, h: Float) {
        guard s > 0, φ > 0 else { return (s, h) }
        let ρ = max(c - h, 0.5)
        let arc = s / ρ
        if arc <= φ { return (ρ * sin(arc), c - ρ * cos(arc)) }
        let rest = s - φ * ρ
        return (ρ * sin(φ) + rest * cos(φ), c - ρ * cos(φ) + rest * sin(φ))
    }

    /// 攤平時在 uv 的那一點，這個 progress 下在哪裡（統一座標，z 是離地高度）
    public func position(uv: SIMD2<Float>, progress p: Float) -> SIMD3<Float> {
        let size = placement.size
        var x = (uv.x - 0.5) * size.x, y = (uv.y - 0.5) * size.y, z: Float = 0
        // 1. 右半沿垂直中線翻到左半上
        let a1 = FoldAnimation.phase(p, FoldAnimation.fold1) * .pi
        if x > 0 { let b = FoldAnimation.bend(s: x, h: 0, angle: a1, c: crease); x = b.s; z = b.h }
        // 2. 疊好的兩層，上半沿水平中線往下折（外層半徑要再大一層）
        let a2 = FoldAnimation.phase(p, FoldAnimation.fold2) * .pi
        if y > 0 { let b = FoldAnimation.bend(s: y, h: z, angle: a2, c: crease * 3); y = b.s; z = b.h }
        // 3. 折好的小包浮起、轉一點、縮小消失（以小包中心為準）
        let t = FoldAnimation.phase(p, FoldAnimation.away)
        let anchor = SIMD2<Float>(-size.x / 4, -size.y / 4)
        let spin = t * 0.35
        var q = SIMD2(x, y) - anchor
        q = SIMD2(q.x * cos(spin) - q.y * sin(spin), q.x * sin(spin) + q.y * cos(spin)) * (1 - t)
        q += anchor
        z = z * (1 - t) + 60 * sin(t * .pi * 0.9)
        let w = placement.point(u: 0.5, v: 0.5) + placement.axisX * q.x + placement.axisY * q.y
        return SIMD3(w.x, w.y, z)
    }
}
