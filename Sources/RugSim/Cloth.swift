import simd

/// 地毯攤平時在桌面上的擺法。座標是螢幕點（原點左下、y 向上），z 是離桌面的高度。
public struct RugPlacement: Codable, Equatable {
    public var center: SIMD2<Float>
    public var angle: Float          // 弧度
    public var size: SIMD2<Float>    // 寬、高

    public init(center: SIMD2<Float>, angle: Float, size: SIMD2<Float>) {
        self.center = center; self.angle = angle; self.size = size
    }

    public var axisX: SIMD2<Float> { SIMD2(cos(angle), sin(angle)) }
    public var axisY: SIMD2<Float> { SIMD2(-sin(angle), cos(angle)) }

    /// u,v ∈ [0,1]，(0,0) 是左下角。
    public func point(u: Float, v: Float) -> SIMD2<Float> {
        center + axisX * ((u - 0.5) * size.x) + axisY * ((v - 0.5) * size.y)
    }

    public var corners: [SIMD2<Float>] {
        [point(u: 0, v: 0), point(u: 1, v: 0), point(u: 1, v: 1), point(u: 0, v: 1)]
    }
}

public struct ClothParams {
    public var gravity: Float = 2600
    public var substeps = 6
    public var drag: Float = 0.995          // 每個 substep 的速度保留
    public var floorFriction: Float = 0.12  // 貼地時每個 substep 吃掉的水平速度比例
    public var thickness: Float = 2.5       // 兩層布疊起來的間距
    public var stretch: Float = 1.0
    public var shear: Float = 0.7
    public var bend: Float = 0.12
    public var grabLift: Float = 70
    public init() {}
}

private struct Constraint { var a: Int32; var b: Int32; var rest: Float; var k: Float }

public final class Cloth {
    public let nx: Int
    public let ny: Int
    public private(set) var pos: [SIMD3<Float>]
    private var prev: [SIMD3<Float>]
    private var invMass: [Float]
    private var constraints: [Constraint] = []
    public let uv: [SIMD2<Float>]
    public let indices: [UInt32]
    public var params = ClothParams()
    public private(set) var restSize: SIMD2<Float>

    /// 桌面高度（圖示頂出來的凸起）。nil = 平的。
    public var floor: HeightField?
    public var layerCollision = true

    public private(set) var grabbed: Int?
    private var grabTarget = SIMD3<Float>(0, 0, 0)
    private var grabLiftNow: Float = 0
    public private(set) var lastMotion: Float = .infinity
    /// 連續幾個 frame 只剩微小晃動。夠久就當作靜摩擦把它定住（休眠）。
    private var calmFrames = 0

    public init(placement: RugPlacement, columns: Int = 48) {
        let aspect = placement.size.y / placement.size.x
        nx = columns
        ny = max(4, Int((Float(columns - 1) * aspect).rounded()) + 1)
        restSize = placement.size
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
        pos = []; prev = []; invMass = Array(repeating: 1, count: nx * ny)
        flatten(to: placement)
    }

    @inline(__always) public func index(_ i: Int, _ j: Int) -> Int { j * nx + i }

    /// 立刻把布鋪平到指定擺法（編輯模式、重設用）。尺寸變了會重建限制。
    public func flatten(to p: RugPlacement) {
        restSize = p.size
        pos = uv.map { let q = p.point(u: $0.x, v: $0.y); return SIMD3(q.x, q.y, floorHeight(q) ) }
        prev = pos
        buildConstraints()
        lastMotion = .infinity
        calmFrames = 0
    }

    private func buildConstraints() {
        let dx = restSize.x / Float(nx - 1), dy = restSize.y / Float(ny - 1)
        let diag = (dx * dx + dy * dy).squareRoot()
        var c: [Constraint] = []
        func add(_ i0: Int, _ j0: Int, _ i1: Int, _ j1: Int, _ rest: Float, _ k: Float) {
            guard i1 >= 0, i1 < nx, j1 < ny else { return }
            c.append(Constraint(a: Int32(index(i0, j0)), b: Int32(index(i1, j1)), rest: rest, k: k))
        }
        for j in 0..<ny { for i in 0..<nx {
            add(i, j, i + 1, j, dx, params.stretch)
            add(i, j, i, j + 1, dy, params.stretch)
            add(i, j, i + 1, j + 1, diag, params.shear)
            add(i, j, i - 1, j + 1, diag, params.shear)
            add(i, j, i + 2, j, dx * 2, params.bend)
            add(i, j, i, j + 2, dy * 2, params.bend)
        } }
        constraints = c
    }

    @inline(__always) private func floorHeight(_ q: SIMD2<Float>) -> Float {
        floor?.sample(q.x, q.y) ?? 0
    }

    // MARK: 抓取

    /// 抓住離 (x,y) 最近、最上層的質點。target 用螢幕上看到的位置（已經投影過的），由呼叫端換算。
    public func grab(near q: SIMD2<Float>) {
        var best = -1; var bestScore = Float.infinity
        for k in pos.indices {
            let d = simd_length(SIMD2(pos[k].x, pos[k].y) - q)
            let score = d - pos[k].z * 0.5   // 疊在上面的那層優先
            if score < bestScore { bestScore = score; best = k }
        }
        guard best >= 0 else { return }
        grabbed = best
        calmFrames = 0
        grabLiftNow = pos[best].z
        grabTarget = pos[best]
    }

    public func moveGrab(to q: SIMD2<Float>) {
        grabTarget.x = q.x; grabTarget.y = q.y
    }

    public func release() { grabbed = nil }

    /// 外部條件變了（例如桌面凸起），讓模擬再跑起來。
    public func wake() { lastMotion = .infinity; calmFrames = 0 }

    // MARK: 模擬

    public func step(dt: Float) {
        let n = params.substeps
        let h = dt / Float(n)
        if let g = grabbed {
            grabLiftNow += (params.grabLift - grabLiftNow) * min(1, dt * 10)
            grabTarget.z = floorHeight(SIMD2(grabTarget.x, grabTarget.y)) + grabLiftNow
            _ = g
        }
        let start = pos
        let support = layerCollision ? findSupports(LayerIndex(cloth: self)) : []
        for s in 0..<n {
            integrate(h)
            solveConstraints()
            if layerCollision { collideLayers(support) }
            collideFloor()
        }
        var m: Float = 0
        for k in pos.indices { m = max(m, simd_length(pos[k] - start[k])) }
        lastMotion = m
        calmFrames = (m < 0.6 && grabbed == nil) ? calmFrames + 1 : 0
    }

    /// 有人抓著、或還在動，就要繼續跑。
    public var isSettled: Bool { grabbed == nil && (lastMotion < 0.02 || calmFrames > 40) }

    private func integrate(_ h: Float) {
        let gStep = params.gravity * h * h
        for k in pos.indices {
            if k == grabbed {
                // 抓點用彈簧追目標，不要瞬移，拉起來比較有重量感
                let p = pos[k]
                prev[k] = p
                pos[k] = p + (grabTarget - p) * 0.35
                continue
            }
            let p = pos[k]
            var v = (p - prev[k]) * params.drag
            v.z -= gStep
            prev[k] = p
            pos[k] = p + v
        }
    }

    private func solveConstraints() {
        let g = grabbed ?? -1
        constraints.withUnsafeBufferPointer { C in
        pos.withUnsafeMutableBufferPointer { P in
            for c in C {
                let a = Int(c.a), b = Int(c.b)
                let wa: Float = (a == g) ? 0 : 1
                let wb: Float = (b == g) ? 0 : 1
                let w = wa + wb
                if w == 0 { continue }
                let d = P[b] - P[a]
                let len = simd_length(d)
                if len < 1e-6 { continue }
                // bend 只抗壓縮不抗拉伸會更像厚毯；這裡兩向都抗，k 小就好
                let corr = d * ((len - c.rest) / len * c.k / w)
                P[a] += corr * wa
                P[b] -= corr * wb
            }
        } }
    }

    private func collideFloor() {
        let mu = params.floorFriction
        for k in pos.indices where k != grabbed {
            let f = floorHeight(SIMD2(pos[k].x, pos[k].y))
            if pos[k].z <= f {
                pos[k].z = f
                if prev[k].z < f { prev[k].z = f }
                // 貼地摩擦：把上一步的水平位置往現在拉，等於吃掉水平速度
                let vx = pos[k].x - prev[k].x, vy = pos[k].y - prev[k].y
                prev[k].x += vx * mu
                prev[k].y += vy * mu
            }
        }
    }

    /// 布自己疊起來時，上層要停在下層上面。地毯幾乎都是由上往下看、層層往上疊，所以只處理垂直方向：
    /// frame 開始時記下每個點正壓在哪片（非鄰近的）三角形上方，這個 frame 內就維持「在它上面 thickness」。
    /// 只維持既有的上下關係、不重新判斷，兩層才不會互相往上頂。
    private func findSupports(_ L: LayerIndex) -> [Int32] {
        let nx = self.nx
        var out = [Int32](repeating: -1, count: pos.count)
        indices.withUnsafeBufferPointer { I in
        L.items.withUnsafeBufferPointer { items in
        pos.withUnsafeBufferPointer { P in
            for k in 0..<P.count {
                let p = P[k]
                let ki = k % nx, kj = k / nx
                var best: Float = -.infinity
                for r in L.range(near: p.x, p.y) {
                    let tri = Int(items[r])
                    let a = Int(I[tri * 3]), b = Int(I[tri * 3 + 1]), c = Int(I[tri * 3 + 2])
                    if abs(a % nx - ki) <= 2 && abs(a / nx - kj) <= 2 { continue }
                    guard let z = Cloth.heightOnTriangle(SIMD2(p.x, p.y), P[a], P[b], P[c]) else { continue }
                    if z < p.z && z > best { best = z; out[k] = Int32(tri) }
                }
            }
        } } }
        return out
    }

    private func collideLayers(_ support: [Int32]) {
        let t = params.thickness
        let g = grabbed ?? -1
        indices.withUnsafeBufferPointer { I in
        prev.withUnsafeMutableBufferPointer { V in
        pos.withUnsafeMutableBufferPointer { P in
            for k in 0..<P.count where k != g && support[k] >= 0 {
                let tri = Int(support[k])
                let a = Int(I[tri * 3]), b = Int(I[tri * 3 + 1]), c = Int(I[tri * 3 + 2])
                guard let z = Cloth.heightOnTriangle(SIMD2(P[k].x, P[k].y), P[a], P[b], P[c], margin: 0.25),
                      P[k].z < z + t else { continue }
                P[k].z = z + t
                // 層間摩擦，垂直速度歸零（毯子很重，不彈）
                V[k].x += (P[k].x - V[k].x) * 0.5
                V[k].y += (P[k].y - V[k].y) * 0.5
                V[k].z = P[k].z
            }
        } } }
    }

    static func heightOnTriangle(_ q: SIMD2<Float>, _ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>,
                                 margin m: Float = 0) -> Float? {
        let v0 = SIMD2(b.x - a.x, b.y - a.y), v1 = SIMD2(c.x - a.x, c.y - a.y), v2 = q - SIMD2(a.x, a.y)
        let den = v0.x * v1.y - v1.x * v0.y
        if abs(den) < 1e-6 { return nil }
        let s = (v2.x * v1.y - v1.x * v2.y) / den
        let tt = (v0.x * v2.y - v2.x * v0.y) / den
        if s < -m || tt < -m || s + tt > 1 + m { return nil }
        return a.z + s * (b.z - a.z) + tt * (c.z - a.z)
    }

    // MARK: 給畫面用

    public func normals() -> [SIMD3<Float>] {
        var out = [SIMD3<Float>](repeating: .zero, count: pos.count)
        for j in 0..<ny { for i in 0..<nx {
            let l = pos[index(max(i - 1, 0), j)], r = pos[index(min(i + 1, nx - 1), j)]
            let d = pos[index(i, max(j - 1, 0))], u = pos[index(i, min(j + 1, ny - 1))]
            out[index(i, j)] = simd_normalize(simd_cross(r - l, u - d))
        } }
        return out
    }

    /// 外框一圈（逆時針），點擊判定用。
    public func outline() -> [SIMD3<Float>] {
        var ring: [SIMD3<Float>] = []
        for i in 0..<nx { ring.append(pos[index(i, 0)]) }
        for j in 1..<ny { ring.append(pos[index(nx - 1, j)]) }
        for i in stride(from: nx - 2, through: 0, by: -1) { ring.append(pos[index(i, ny - 1)]) }
        for j in stride(from: ny - 2, through: 1, by: -1) { ring.append(pos[index(0, j)]) }
        return ring
    }

    /// 從目前的布形狀反推一個攤平的擺法（存檔、進編輯模式用）。
    public func fittedPlacement() -> RugPlacement {
        var c = SIMD2<Float>(0, 0)
        for p in pos { c += SIMD2(p.x, p.y) }
        c /= Float(pos.count)
        var ax = SIMD2<Float>(0, 0)
        for j in 0..<ny {
            let a = pos[index(0, j)], b = pos[index(nx - 1, j)]
            ax += SIMD2(b.x - a.x, b.y - a.y)
        }
        return RugPlacement(center: c, angle: atan2(ax.y, ax.x), size: restSize)
    }

    func trianglePositions(_ tri: Int) -> (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>) {
        (pos[Int(indices[tri * 3])], pos[Int(indices[tri * 3 + 1])], pos[Int(indices[tri * 3 + 2])])
    }
}

/// 三角形的 xy 格子索引（counting sort 成扁平陣列），每個 frame 建一次。
struct LayerIndex {
    let cell: Float
    let ox: Float, oy: Float
    let gw: Int, gh: Int
    var start: [Int32]
    var items: [Int32]

    init(cloth: Cloth) {
        cell = max(cloth.restSize.x / Float(cloth.nx - 1), 4) * 2
        let P = cloth.pos
        var lo = SIMD2<Float>(.infinity, .infinity), hi = -lo
        for p in P { lo = simd_min(lo, SIMD2(p.x, p.y)); hi = simd_max(hi, SIMD2(p.x, p.y)) }
        ox = lo.x; oy = lo.y
        gw = Int((hi.x - lo.x) / cell) + 1; gh = Int((hi.y - lo.y) / cell) + 1
        let triCount = cloth.indices.count / 3
        var ranges = [(Int32, Int32, Int32, Int32)](repeating: (0, 0, 0, 0), count: triCount)
        var count = [Int32](repeating: 0, count: gw * gh + 1)
        for t in 0..<triCount {
            let (a, b, c) = cloth.trianglePositions(t)
            let i0 = Int32((min(a.x, b.x, c.x) - ox) / cell), i1 = Int32((max(a.x, b.x, c.x) - ox) / cell)
            let j0 = Int32((min(a.y, b.y, c.y) - oy) / cell), j1 = Int32((max(a.y, b.y, c.y) - oy) / cell)
            ranges[t] = (i0, i1, j0, j1)
            for j in j0...j1 { for i in i0...i1 { count[Int(j) * gw + Int(i) + 1] += 1 } }
        }
        for k in 1..<count.count { count[k] += count[k - 1] }
        start = count
        items = [Int32](repeating: 0, count: Int(count[count.count - 1]))
        var fill = count
        for t in 0..<triCount {
            let (i0, i1, j0, j1) = ranges[t]
            for j in j0...j1 { for i in i0...i1 {
                let k = Int(j) * gw + Int(i)
                items[Int(fill[k])] = Int32(t); fill[k] += 1
            } }
        }
    }

    /// 回傳 items 裡的範圍；格子外回空範圍。
    @inline(__always) func range(near x: Float, _ y: Float) -> Range<Int> {
        let fx = (x - ox) / cell, fy = (y - oy) / cell
        if fx < 0 || fy < 0 { return 0..<0 }
        let i = Int(fx), j = Int(fy)
        if i >= gw || j >= gh { return 0..<0 }
        let k = j * gw + i
        return Int(start[k])..<Int(start[k + 1])
    }
}
