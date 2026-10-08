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
    private let ring: [Int]

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
        var rg: [Int] = []
        for i in 0..<nx { rg.append(i) }
        for j in 1..<ny { rg.append(j * nx + nx - 1) }
        for i in stride(from: nx - 2, through: 0, by: -1) { rg.append((ny - 1) * nx + i) }
        for j in stride(from: ny - 2, through: 1, by: -1) { rg.append(j * nx) }
        ring = rg
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
            normals[j * nx + i] = simd_normalize(simd_cross(r - l, u - d))
        } }
        buildSide(floor: cloth.floor)
    }

    /// 沿外圈往布的背面方向長出一圈 thickness 高的側牆。外圈是逆時針，所以 切線×法線 指向外側。
    private mutating func buildSide(floor: HeightField?) {
        let n = ring.count
        var top = [SIMD3<Float>](), bot = [SIMD3<Float>](), out = [SIMD3<Float>]()
        top.reserveCapacity(n); bot.reserveCapacity(n); out.reserveCapacity(n)
        for a in 0..<n {
            let k = ring[a]
            let t = pos[ring[(a + 1) % n]] - pos[ring[(a + n - 1) % n]]
            let nrm = normals[k]
            top.append(pos[k])
            var b = pos[k] - nrm * thickness
            b.z = max(b.z, floor?.sample(b.x, b.y) ?? 0, 0)
            bot.append(b)
            out.append(simd_normalize(simd_cross(t, nrm)))
        }
        side.removeAll(keepingCapacity: true)
        for a in 0..<n {
            let b = (a + 1) % n
            let ua = uv[ring[a]], ub = uv[ring[b]]
            side += [(top[a], out[a], ua), (bot[a], out[a], ua), (bot[b], out[b], ub),
                     (top[a], out[a], ua), (bot[b], out[b], ub), (top[b], out[b], ub)]
        }
    }
}
