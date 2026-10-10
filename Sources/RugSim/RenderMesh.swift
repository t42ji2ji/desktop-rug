import simd

/// 物理用粗格子算（皺褶才會大、拉力傳得快），畫面用這個從粗格子 Catmull-Rom 內插出來的細網格，
/// 折角和隆起的輪廓才不會變成多邊形折線。
public struct RenderMesh {
    public let nx: Int
    public let ny: Int
    public private(set) var pos: [SIMD3<Float>]
    public private(set) var normals: [SIMD3<Float>]
    public let uv: [SIMD2<Float>]
    public let indices: [UInt32]
    private let factor: Int
    /// 地毯外圈的側面（三角形清單，已展開），從上往下看時給出厚度
    public private(set) var side: [(pos: SIMD3<Float>, nrm: SIMD3<Float>, uv: SIMD2<Float>)] = []
    public var thickness: Float = 6
    public var cornerRadius: Float = 16
    private var restSize: SIMD2<Float>

    public init(cloth: Cloth, factor: Int = 4) {
        self.factor = factor
        nx = (cloth.nx - 1) * factor + 1
        ny = (cloth.ny - 1) * factor + 1
        var uvs: [SIMD2<Float>] = []
        for j in 0..<ny { for i in 0..<nx {
            uvs.append(SIMD2(Float(i) / Float(nx - 1), Float(j) / Float(ny - 1)))
        } }
        uv = uvs
        var idx: [UInt32] = []
        for j in 0..<(ny - 1) { for i in 0..<(nx - 1) {
            let a = UInt32(j * nx + i), b = a + 1, c = a + UInt32(nx), d = c + 1
            idx += [a, b, d, a, d, c]
        } }
        indices = idx
        restSize = cloth.restSize
        pos = Array(repeating: .zero, count: nx * ny)
        normals = Array(repeating: SIMD3(0, 0, 1), count: nx * ny)
        update(from: cloth)
    }

    @inline(__always) private static func weights(_ t: Float) -> SIMD4<Float> {
        let t2 = t * t, t3 = t2 * t
        return SIMD4(-0.5 * t3 + t2 - 0.5 * t,
                     1.5 * t3 - 2.5 * t2 + 1,
                     -1.5 * t3 + 2 * t2 + 0.5 * t,
                     0.5 * t3 - 0.5 * t2)
    }

    public mutating func update(from cloth: Cloth) {
        restSize = cloth.restSize   // 編輯模式縮放會改尺寸
        let cx = cloth.nx, cy = cloth.ny, f = factor
        let P = cloth.pos
        let wts = (0..<f).map { RenderMesh.weights(Float($0) / Float(f)) }
        for j in 0..<ny {
            let gj = min(j / f, cy - 2), fj = j - gj * f
            let wy = j == ny - 1 ? SIMD4<Float>(0, 0, 1, 0) : wts[fj]
            for i in 0..<nx {
                let gi = min(i / f, cx - 2), fi = i - gi * f
                let wx = i == nx - 1 ? SIMD4<Float>(0, 0, 1, 0) : wts[fi]
                var p = SIMD3<Float>(0, 0, 0)
                for b in 0..<4 {
                    let jj = min(max(gj - 1 + b, 0), cy - 1)
                    var row = SIMD3<Float>(0, 0, 0)
                    for a in 0..<4 {
                        let ii = min(max(gi - 1 + a, 0), cx - 1)
                        row += P[jj * cx + ii] * wx[a]
                    }
                    p += row * wy[b]
                }
                // 粗格子之間的桌面凸起靠細網格自己貼地補回來
                if let floor = cloth.floor { p.z = max(p.z, floor.sample(p.x, p.y)) }
                // 模擬的 z 是布的底面；畫出來的頂面再墊一個厚度
                p.z = max(p.z, 0) + thickness
                pos[j * nx + i] = p
            }
        }
        for j in 0..<ny { for i in 0..<nx {
            let l = pos[j * nx + max(i - 1, 0)], r = pos[j * nx + min(i + 1, nx - 1)]
            let d = pos[max(j - 1, 0) * nx + i], u = pos[min(j + 1, ny - 1) * nx + i]
            // 收起動畫最後整塊縮成一點，法線算不出來：當成朝上
            let c = simd_cross(r - l, u - d)
            normals[j * nx + i] = simd_length(c) > 1e-6 ? simd_normalize(c) : SIMD3(0, 0, 1)
        } }
        buildSide(floor: cloth.floor)
    }

    /// 在細網格上以 uv 雙線性取樣位置和法線。
    public func sample(_ q: SIMD2<Float>) -> (SIMD3<Float>, SIMD3<Float>) {
        let fx = min(max(q.x, 0), 1) * Float(nx - 1), fy = min(max(q.y, 0), 1) * Float(ny - 1)
        let i = min(Int(fx), nx - 2), j = min(Int(fy), ny - 2)
        let tx = fx - Float(i), ty = fy - Float(j)
        func lerp4<T: SIMD>(_ a: [T], _ k: Int) -> T where T.Scalar == Float {
            let v00 = a[k], v10 = a[k + 1], v01 = a[k + nx], v11 = a[k + nx + 1]
            return (v00 * (1 - tx) + v10 * tx) * (1 - ty) + (v01 * (1 - tx) + v11 * tx) * ty
        }
        let k = j * nx + i
        let n = lerp4(normals, k)
        return (lerp4(pos, k), simd_length(n) > 1e-6 ? simd_normalize(n) : SIMD3(0, 0, 1))
    }

    /// 圓角外框上的一圈 uv（逆時針，從左下角圓弧結束處開始）。
    private func roundedRing() -> [SIMD2<Float>] {
        let w = restSize.x, h = restSize.y
        let r = min(cornerRadius, min(w, h) * 0.5)
        let step = max(w / Float(nx - 1), 2)
        var pts: [SIMD2<Float>] = []   // 以點為單位、原點在左下
        func line(_ a: SIMD2<Float>, _ b: SIMD2<Float>) {
            let n = max(1, Int(simd_length(b - a) / step))
            for s in 0..<n { pts.append(a + (b - a) * (Float(s) / Float(n))) }
        }
        func arc(_ c: SIMD2<Float>, from a0: Float) {
            let n = max(1, Int(r * .pi / 2 / step))
            for s in 0..<n { let a = a0 + .pi / 2 * Float(s) / Float(n); pts.append(c + SIMD2(cos(a), sin(a)) * r) }
        }
        line(SIMD2(r, 0), SIMD2(w - r, 0)); arc(SIMD2(w - r, r), from: -.pi / 2)
        line(SIMD2(w, r), SIMD2(w, h - r)); arc(SIMD2(w - r, h - r), from: 0)
        line(SIMD2(w - r, h), SIMD2(r, h)); arc(SIMD2(r, h - r), from: .pi / 2)
        line(SIMD2(0, h - r), SIMD2(0, r)); arc(SIMD2(r, r), from: .pi)
        return pts.map { SIMD2($0.x / w, $0.y / h) }
    }

    /// 沿圓角外框往布的背面方向長出一圈 thickness 高的側牆。外框是逆時針，所以 切線×法線 指向外側。
    private mutating func buildSide(floor: HeightField?) {
        let uvs = roundedRing()
        let n = uvs.count
        let samples = uvs.map { sample($0) }
        var top = [SIMD3<Float>](), bot = [SIMD3<Float>](), out = [SIMD3<Float>]()
        for a in 0..<n {
            let (p, nrm) = samples[a]
            let t = samples[(a + 1) % n].0 - samples[(a + n - 1) % n].0
            top.append(p)
            var b = p - nrm * thickness
            b.z = max(b.z, floor?.sample(b.x, b.y) ?? 0, 0)
            bot.append(b)
            let o = simd_cross(t, nrm)
            out.append(simd_length(o) > 1e-6 ? simd_normalize(o) : SIMD3(1, 0, 0))
        }
        side.removeAll(keepingCapacity: true)
        for a in 0..<n {
            let b = (a + 1) % n
            let ua = uvs[a], ub = uvs[b]
            side += [(top[a], out[a], ua), (bot[a], out[a], ua), (bot[b], out[b], ub),
                     (top[a], out[a], ua), (bot[b], out[b], ub), (top[b], out[b], ub)]
        }
    }
}
