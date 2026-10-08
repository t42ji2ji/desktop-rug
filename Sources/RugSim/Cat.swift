import simd

/// 一隻住在地毯上的貓的行為。座標是地毯的局部座標（點，地毯中心為原點、x 沿地毯寬），
/// 所以地毯被拖走、被掀起時貓跟著走。畫面只拿 `pose` 去畫。
public struct Cat {
    public enum Anim: String, CaseIterable { case walk, belly, scratch, lookup }

    /// 畫面要的東西：哪支動畫第幾格、在地毯上的位置、頭朝的方向（弧度，0 = 沿地毯寬向右）
    public struct Pose {
        public var anim: Anim; public var frame: Int; public var pos: SIMD2<Float>; public var heading: Float
        /// 被拎起來了（畫大一點、影子拉遠）
        public var lifted = false
    }

    enum State {
        case walk(target: SIMD2<Float>)
        case idle(left: Float)
        case scratch(left: Float)
        case bellyIn(t: Float)
        case bellyLoop(left: Float)
        case bellyOut(t: Float)
        case lookIn(t: Float)
        case lookLoop(left: Float)
        case lookOut(t: Float)
        case held
        case hop(target: SIMD2<Float>)   // 被蓋住：快步鑽出來
    }

    public static let frames = 16
    public var length: Float          // 貓身長（點），用來留邊與換算步幅
    public var speed: Float = 42      // 走路速度（點/秒）
    public var strideFrames: Float = 8 // 走一個步伐循環（walk 的 8 格）走多遠 = length * 0.9
    public private(set) var pos: SIMD2<Float>
    public private(set) var heading: Float
    private(set) var state: State
    private var walkPhase: Float = 0  // 走路幀（依走過的距離前進，腳才不會滑）
    private var loopClock: Float = 0
    private var rng: SplitMix

    public init(pos: SIMD2<Float>, heading: Float, length: Float, seed: UInt64) {
        self.pos = pos; self.heading = heading; self.length = length
        rng = SplitMix(seed)
        state = .idle(left: 0.5 + Float(seed % 5) * 0.4)
    }

    public var pose: Pose {
        switch state {
        case .walk, .hop:
            return Pose(anim: .walk, frame: Int(walkPhase) % Cat.frames, pos: pos, heading: heading)
        case .idle:
            return Pose(anim: .walk, frame: 0, pos: pos, heading: heading)
        case .scratch:
            return Pose(anim: .scratch, frame: Int(loopClock * 10) % Cat.frames, pos: pos, heading: heading)
        case .bellyIn(let t):   // 0–7 格：躺下、翻過去
            return Pose(anim: .belly, frame: min(7, Int(t * 8)), pos: pos, heading: heading)
        case .bellyLoop:        // 8–15 格：肚子朝上撥腳
            return Pose(anim: .belly, frame: 8 + Int(loopClock * 8) % 8, pos: pos, heading: heading)
        case .bellyOut(let t):  // 倒著播 7–0：翻回來
            return Pose(anim: .belly, frame: max(0, 7 - Int(t * 8)), pos: pos, heading: heading)
        case .lookIn(let t):    // 0–7 格：坐下、抬頭
            return Pose(anim: .lookup, frame: min(7, Int(t * 8)), pos: pos, heading: heading)
        case .lookLoop:         // 8–15 格：坐著抬頭看（眨眼、耳朵動）
            return Pose(anim: .lookup, frame: 8 + Int(loopClock * 6) % 8, pos: pos, heading: heading)
        case .lookOut(let t):   // 倒著播：低頭、站起來
            return Pose(anim: .lookup, frame: max(0, 7 - Int(t * 8)), pos: pos, heading: heading)
        case .held:             // 被拎著：抬頭看你
            return Pose(anim: .lookup, frame: 12, pos: pos, heading: heading, lifted: true)
        }
    }

    /// rugSize：地毯目前尺寸（點）。others：其他貓的位置，挑目的地時避開。
    public mutating func pickUp() { state = .held }
    public mutating func carry(to p: SIMD2<Float>) { pos = p }
    /// 放下：下一個 update 會把位置收回地毯內
    public mutating func drop() { state = .idle(left: rng.float(0.6, 1.4)) }
    public var isHeld: Bool { if case .held = state { return true } else { return false } }

    /// spotOK：地毯局部座標的某點能不能待（沒被翻過來的布蓋住）。測試時預設處處都可以。
    public mutating func update(dt: Float, rugSize: SIMD2<Float>, others: [SIMD2<Float>],
                                spotOK: (SIMD2<Float>) -> Bool = { _ in true }) {
        if case .held = state { return }
        let half = rugSize / 2 - SIMD2(repeating: length * 0.55)
        // 地毯被縮小了：先站回地毯上
        pos = simd_clamp(pos, -simd_max(half, .zero), simd_max(half, .zero))
        loopClock += dt
        // 被蓋住了：不管在做什麼，先鑽出來跑到最近沒被蓋住的地方
        if case .hop = state {} else if !spotOK(pos), let safe = nearestOK(rugSize: rugSize, spotOK: spotOK) {
            state = .hop(target: safe)
        }
        switch state {
        case .hop(let target):
            let d = target - pos
            let dist = simd_length(d)
            if dist < 4 || !spotOK(target) {
                state = .idle(left: rng.float(0.4, 1.0))
                return
            }
            heading = atan2(d.y, d.x)
            let step = min(dist, speed * 3.5 * dt)
            pos += d / dist * step
            walkPhase += step / (length * 0.9) * strideFrames
        case .walk(let target):
            let d = target - pos
            let dist = simd_length(d)
            if dist < 4 { pickNext(rugSize: rugSize, others: others, spotOK: spotOK); return }
            // 慢慢轉向目標，轉的時候也放慢
            let want = atan2(d.y, d.x)
            var turn = remainder(want - heading, 2 * .pi)
            turn = max(-3 * dt, min(3 * dt, turn))
            heading = remainder(heading + turn, 2 * .pi)
            let step = min(dist, speed * dt * max(0.3, cos(want - heading)))
            pos += SIMD2(cos(heading), sin(heading)) * step
            walkPhase += step / (length * 0.9) * strideFrames
        case .idle(let left):
            state = left - dt <= 0 ? .idle(left: 0) : .idle(left: left - dt)
            if left - dt <= 0 { pickNext(rugSize: rugSize, others: others, spotOK: spotOK) }
        case .scratch(let left):
            if left - dt <= 0 { pickNext(rugSize: rugSize, others: others, spotOK: spotOK) } else { state = .scratch(left: left - dt) }
        case .bellyIn(let t):
            state = t + dt >= 1 ? .bellyLoop(left: rng.float(3, 6)) : .bellyIn(t: t + dt)
            loopClock = 0
        case .bellyLoop(let left):
            state = left - dt <= 0 ? .bellyOut(t: 0) : .bellyLoop(left: left - dt)
        case .bellyOut(let t):
            if t + dt >= 1 { state = .idle(left: rng.float(0.5, 1.5)) } else { state = .bellyOut(t: t + dt) }
        case .lookIn(let t):
            state = t + dt / 1.2 >= 1 ? .lookLoop(left: rng.float(3, 6)) : .lookIn(t: t + dt / 1.2)
            loopClock = 0
        case .lookLoop(let left):
            state = left - dt <= 0 ? .lookOut(t: 0) : .lookLoop(left: left - dt)
        case .lookOut(let t):
            if t + dt / 0.7 >= 1 { pickNext(rugSize: rugSize, others: others, spotOK: spotOK) } else { state = .lookOut(t: t + dt / 0.7) }
        case .held:
            break
        }
    }

    /// 由近到遠找一個能待的點
    private mutating func nearestOK(rugSize: SIMD2<Float>, spotOK: (SIMD2<Float>) -> Bool) -> SIMD2<Float>? {
        let half = simd_max(rugSize / 2 - SIMD2(repeating: length * 0.6), SIMD2(repeating: 1))
        for ring in 1...8 {
            let r = Float(ring) * length * 0.5
            for k in 0..<12 {
                let a = Float(k) / 12 * 2 * .pi + Float(ring) * 0.4
                let t = simd_clamp(pos + SIMD2(cos(a), sin(a)) * r, -half, half)
                if spotOK(t) { return t }
            }
        }
        return nil
    }

    private mutating func pickNext(rugSize: SIMD2<Float>, others: [SIMD2<Float>], spotOK: (SIMD2<Float>) -> Bool) {
        loopClock = 0
        let r = rng.float(0, 1)
        if r < 0.45 {
            let half = simd_max(rugSize / 2 - SIMD2(repeating: length * 0.6), SIMD2(repeating: 1))
            // 試幾個點，挑離其他貓最遠的
            var best = pos, bestScore = -Float.infinity
            for _ in 0..<10 {
                let t = SIMD2(rng.float(-half.x, half.x), rng.float(-half.y, half.y))
                if !spotOK(t) { continue }   // 不走到被蓋住的地方
                let near = others.map { simd_length($0 - t) }.min() ?? 1e9
                let score = min(near, length * 2) + min(simd_length(t - pos), length * 3) * 0.3
                if score > bestScore { bestScore = score; best = t }
            }
            state = .walk(target: best)
        } else if r < 0.6 {
            state = .scratch(left: rng.float(2.5, 4.5))
        } else if r < 0.75 {
            state = .bellyIn(t: 0)
        } else if r < 0.9 {
            state = .lookIn(t: 0)
        } else {
            state = .idle(left: rng.float(1, 3))
        }
    }
}

/// 可重現的亂數（測試用固定 seed）
struct SplitMix {
    var s: UInt64
    init(_ seed: UInt64) { s = seed &+ 0x9E3779B97F4A7C15 }
    mutating func next() -> UInt64 {
        s &+= 0x9E3779B97F4A7C15
        var z = s
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func float(_ lo: Float, _ hi: Float) -> Float {
        lo + (hi - lo) * Float(next() >> 40) / Float(1 << 24)
    }
}
