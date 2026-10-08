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
    public var gravity: Float = 4200
    public var substeps = 6
    public var drag: Float = 0.985          // 每個 substep 的速度保留
    public var floorFriction: Float = 0.18 // 貼地時每個 substep 吃掉的水平速度比例
    public var moveRigidity: Float = 0.35  // 抓中間拖（移動）時，每個 substep 把整張拉回原形的比例
    public var dragFriction: Float = 0.04  // 抓中間拖時的地板摩擦（地毯在木地板上順順滑過去）
    public var iterations = 3
    public var timeScale: Float = 1.2      // 整體動作快一點
    public var collisionScale: Float = 0.45// 互推球半徑 = 格距 × 這個
    public var lowerShare: Float = 1       // 兩層互推時下層退多少（上層退 1）
    public var layerFriction: Float = 0.5  // 兩層接觸時水平相對速度吃掉的比例（1 = 黏住一起動）
    public var thickness: Float = 5       // 兩層布疊起來的間距
    public var stretch: Float = 1.0
    public var shear: Float = 0.7
    public var bend: Float = 0.05
    public var grabLift: Float = 45
    public var grabFollow: Float = 0.2     // 抓點每個 substep 追上目標的比例，小 = 拖起來比較重
    public var maxStep: Float = 12         // 每個 substep 最多移動幾點，避免甩飛
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
    public private(set) var params = ClothParams()
    public private(set) var restSize: SIMD2<Float>

    /// 桌面高度（圖示頂出來的凸起）。nil = 平的。
    public var floor: HeightField?
    public var layerCollision = true

    public private(set) var grabbed: Int?
    private var grabTarget = SIMD3<Float>(0, 0, 0)
    /// 抓住的一小塊：手抓一把，不是捏一個點（捏一點會出現薄絲巾那種放射皺褶）
    private var grabPatch: [(k: Int, offset: SIMD2<Float>)] = []
    private var pinned: [Bool] = []
    private var grabLiftNow: Float = 0
    public private(set) var lastMotion: Float = .infinity
    /// 連續幾個 frame 只剩微小晃動。夠久就當作靜摩擦把它定住（休眠）。
    private var calmFrames = 0
    /// 0 = 抓邊角（要掀、要折），1 = 抓中間（只是要移動）
    public private(set) var grabRigidity: Float = 0

    public init(placement: RugPlacement, columns: Int = 32) {
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
        let d = min(uv[best].x, 1 - uv[best].x, uv[best].y, 1 - uv[best].y)
        let e = min(max((d - 0.08) / 0.17, 0), 1)
        grabRigidity = e * e * (3 - 2 * e)
        let spacing = restSize.x / Float(nx - 1)
        let c = SIMD2(pos[best].x, pos[best].y)
        let bi = best % nx, bj = best / nx
        grabPatch = []
        pinned = Array(repeating: false, count: pos.count)
        for j in max(0, bj - 2)...min(ny - 1, bj + 2) { for i in max(0, bi - 2)...min(nx - 1, bi + 2) {
            let k = index(i, j)
            let o = SIMD2(pos[k].x, pos[k].y) - c
            if simd_length(o) <= max(spacing * 1.1, 30) { grabPatch.append((k, o)); pinned[k] = true }
        } }
        grabLiftNow = pos[best].z
        grabTarget = pos[best]
    }

    public func moveGrab(to q: SIMD2<Float>) {
        grabTarget.x = q.x; grabTarget.y = q.y
    }

    public func release() {
        grabbed = nil
        grabPatch = []
        pinned = []
        // 重地毯放手不會被甩出去：保留四成速度
        for k in pos.indices { prev[k] = pos[k] - (pos[k] - prev[k]) * 0.4 }
    }

    /// 換手感參數。限制的強度是建立時寫進去的，所以要重建。
    public func setParams(_ p: ClothParams) {
        params = p
        buildConstraints()
        wake()
    }

    /// 外部條件變了（例如桌面凸起），讓模擬再跑起來。
    public func wake() { lastMotion = .infinity; calmFrames = 0 }

    // MARK: 模擬

    public func step(dt: Float) {
        let n = params.substeps
        let h = dt * params.timeScale / Float(n)
        if let g = grabbed {
            grabLiftNow += (params.grabLift - grabLiftNow) * min(1, dt * 10)
            // 手要跟著底下那層布的高度走，角才是「舉過」地毯再放下，不會從底下鑽過去
            var under = floorHeight(SIMD2(grabTarget.x, grabTarget.y))
            let reach = collisionRadius * 2
            let isPinned = pinned
            for k in pos.indices where isPinned.isEmpty || !isPinned[k] {
                if simd_length(SIMD2(pos[k].x - grabTarget.x, pos[k].y - grabTarget.y)) < reach {
                    under = max(under, pos[k].z + reach)
                }
            }
            grabTarget.z = max(floorHeight(SIMD2(grabTarget.x, grabTarget.y)) + grabLiftNow, under)
            _ = g
        }
        let start = pos
        for s in 0..<n {
            integrate(h)
            for _ in 0..<params.iterations { solveConstraints() }
            if grabbed != nil && grabRigidity > 0 { shapeMatch(params.moveRigidity * grabRigidity) }
            if layerCollision { collideSelf() }
            collideFloor()
        }
        var m: Float = 0
        for k in pos.indices { m = max(m, simd_length(pos[k] - start[k])) }
        if grabbed == nil { straighten() }
        lastMotion = m
        calmFrames = (m < 0.6 && grabbed == nil) ? calmFrames + 1 : 0
    }

    /// 有人抓著、或還在動、或還沒轉正，就要繼續跑。
    public var isSettled: Bool {
        grabbed == nil && abs(tilt()) < 0.003 && (lastMotion < 0.02 || calmFrames > 40)
    }

    /// 地毯整體轉了多少（弧度）：目前形狀對攤平形狀的最佳旋轉（2D Kabsch），折起來的角影響不大。
    public func tilt() -> Float { rigidFit().angle }

    /// 目前形狀對攤平形狀的最佳剛體擺法（xy 中心、旋轉角）。
    private func rigidFit() -> (center: SIMD2<Float>, angle: Float) {
        var c = SIMD2<Float>(0, 0)
        for p in pos { c += SIMD2(p.x, p.y) }
        c /= Float(pos.count)
        var sc: Float = 0, cc: Float = 0
        for k in pos.indices {
            let r = restLocal(k)
            let q = SIMD2(pos[k].x, pos[k].y) - c
            cc += r.x * q.x + r.y * q.y
            sc += r.x * q.y - r.y * q.x
        }
        return (c, atan2(sc, cc))
    }

    @inline(__always) private func restLocal(_ k: Int) -> SIMD2<Float> {
        SIMD2((uv[k].x - 0.5) * restSize.x, (uv[k].y - 0.5) * restSize.y)
    }

    /// 形狀匹配：把每個點的 xy 往「整張剛體移過去」的位置拉。抓中間拖時用，整張才會一起走、不會擠皺。
    private func shapeMatch(_ alpha: Float) {
        let (c, a) = rigidFit()
        let cs = cos(a), sn = sin(a)
        let isPinned = pinned
        for k in pos.indices where isPinned.isEmpty || !isPinned[k] {
            let r = restLocal(k)
            let goal = c + SIMD2(r.x * cs - r.y * sn, r.x * sn + r.y * cs)
            pos[k].x += (goal.x - pos[k].x) * alpha
            pos[k].y += (goal.y - pos[k].y) * alpha
            // 離手遠的地方也往地面壓，拖著走時只有手邊微微隆起
            let f = floorHeight(goal)
            if pos[k].z > f { pos[k].z += (f - pos[k].z) * alpha * 0.5 }
        }
    }

    /// 放手後整張（連折角一起）剛體轉回正向，每個 frame 轉回一部分。
    private func straighten() {
        let a = tilt()
        if abs(a) < 0.003 { return }
        let step = -a * 0.15
        var c = SIMD2<Float>(0, 0)
        for p in pos { c += SIMD2(p.x, p.y) }
        c /= Float(pos.count)
        let cs = cos(step), sn = sin(step)
        func rot(_ p: SIMD3<Float>) -> SIMD3<Float> {
            let d = SIMD2(p.x, p.y) - c
            return SIMD3(c.x + d.x * cs - d.y * sn, c.y + d.x * sn + d.y * cs, p.z)
        }
        for k in pos.indices { pos[k] = rot(pos[k]); prev[k] = rot(prev[k]) }
    }

    private func integrate(_ h: Float) {
        let gStep = params.gravity * h * h
        for (k, o) in grabPatch {
            // 抓點用彈簧追目標，不要瞬移，拉起來比較有重量感
            let p = pos[k]
            let target = grabTarget + SIMD3(o.x, o.y, 0)
            prev[k] = p
            pos[k] = p + (target - p) * params.grabFollow
        }
        let isPinned = pinned
        for k in pos.indices {
            if !isPinned.isEmpty && isPinned[k] { continue }
            let p = pos[k]
            var v = (p - prev[k]) * params.drag
            v.z -= gStep
            let speed = simd_length(v)
            if speed > params.maxStep { v *= params.maxStep / speed }
            prev[k] = p
            pos[k] = p + v
        }
    }

    private func solveConstraints() {
        let isPinned = pinned
        let anyPinned = !isPinned.isEmpty
        constraints.withUnsafeBufferPointer { C in
        pos.withUnsafeMutableBufferPointer { P in
            for c in C {
                let a = Int(c.a), b = Int(c.b)
                let wa: Float = anyPinned && isPinned[a] ? 0 : 1
                let wb: Float = anyPinned && isPinned[b] ? 0 : 1
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
        let mu = grabbed == nil ? params.floorFriction
            : params.floorFriction + (params.dragFriction - params.floorFriction) * grabRigidity
        let isPinned = pinned
        for k in pos.indices where isPinned.isEmpty || !isPinned[k] {
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

    var collisionRadius: Float { max(params.thickness, restSize.x / Float(nx - 1) * params.collisionScale) }

    /// 布自己疊起來時互相推開：不相鄰的兩個質點距離小於 2r 就各退一半。
    /// 對稱的推法不會越疊越高；r 取接近格距的一半，上層才不會從下層格子間漏下去。
    private func collideSelf() {
        let r = collisionRadius
        let cell = 2 * r
        let nx = self.nx
        let isPinned = pinned
        let n = pos.count
        var lo = SIMD2<Float>(.infinity, .infinity)
        for p in pos { lo = simd_min(lo, SIMD2(p.x, p.y)) }
        var keys = [Int](repeating: 0, count: n)
        var maxI = 0, maxJ = 0
        for k in 0..<n {
            let i = Int((pos[k].x - lo.x) / cell), j = Int((pos[k].y - lo.y) / cell)
            maxI = max(maxI, i); maxJ = max(maxJ, j)
            keys[k] = j << 16 | i
        }
        let gw = maxI + 1, gh = maxJ + 1
        var start = [Int32](repeating: 0, count: gw * gh + 1)
        for k in 0..<n { start[(keys[k] >> 16) * gw + (keys[k] & 0xffff) + 1] += 1 }
        for c in 1..<start.count { start[c] += start[c - 1] }
        var items = [Int32](repeating: 0, count: n)
        var fill = start
        for k in 0..<n { let c = (keys[k] >> 16) * gw + (keys[k] & 0xffff); items[Int(fill[c])] = Int32(k); fill[c] += 1 }

        let minD = 2 * r
        pos.withUnsafeMutableBufferPointer { P in
        prev.withUnsafeMutableBufferPointer { V in
            for k in 0..<n {
                let ci = keys[k] & 0xffff, cj = keys[k] >> 16
                let ki = k % nx, kj = k / nx
                for j in max(0, cj - 1)...min(gh - 1, cj + 1) { for i in max(0, ci - 1)...min(gw - 1, ci + 1) {
                    let c = j * gw + i
                    for e in Int(start[c])..<Int(start[c + 1]) {
                        let o = Int(items[e])
                        if o <= k { continue }
                        if abs(o % nx - ki) <= 2 && abs(o / nx - kj) <= 2 { continue }
                        let d = P[o] - P[k]
                        let len = simd_length(d)
                        if len >= minD || len < 1e-5 { continue }
                        // 上層多退、下層少退：下層貼地不能往下，平分的話會被往旁邊擠開，上層就從縫掉下去
                        let kLower = P[k].z < P[o].z
                        let wk: Float = !isPinned.isEmpty && isPinned[k] ? 0 : (kLower ? params.lowerShare : 1)
                        let wo: Float = !isPinned.isEmpty && isPinned[o] ? 0 : (kLower ? 1 : params.lowerShare)
                        if wk + wo == 0 { continue }
                        let corr = d * ((minD - len) / len / (wk + wo))
                        P[k] -= corr * wk
                        P[o] += corr * wo
                        // 層間摩擦：兩點的水平相對速度互相拉近（被抓著的點不拖動下層）
                        if wk == 0 || wo == 0 { continue }
                        let vk = P[k] - V[k], vo = P[o] - V[o]
                        let rel = (vo - vk) * (params.layerFriction * 0.5)
                        V[k] -= SIMD3(rel.x, rel.y, 0) * wk
                        V[o] += SIMD3(rel.x, rel.y, 0) * wo
                    }
                } }
            }
        } }
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

    /// 直接擺姿勢（動畫用），不跑物理。
    public func pose(_ f: (SIMD2<Float>) -> SIMD3<Float>) {
        for k in pos.indices { pos[k] = f(uv[k]) }
        prev = pos
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
}
