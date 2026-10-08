import AppKit
import MetalKit
import RugSim
import simd

/// 一個螢幕上的透明 Metal view：只負責畫自己那一塊、把滑鼠事件換成統一座標交給 controller。
/// 平常整個視窗不吃滑鼠，只有游標在地毯上（或編輯模式在控制點附近）才吃。
final class RugSurface: MTKView {
    let renderer: Renderer
    let overlay = EditOverlay()
    weak var controller: RugController?

    init(frame: CGRect, device: MTLDevice) {
        let tmp = MTKView(frame: .zero, device: device)
        tmp.colorPixelFormat = .bgra8Unorm
        tmp.depthStencilPixelFormat = .depth32Float
        renderer = Renderer(view: tmp)
        super.init(frame: frame, device: device)
        colorPixelFormat = .bgra8Unorm
        depthStencilPixelFormat = .depth32Float
        layer?.isOpaque = false
        framebufferOnly = true
        isPaused = true
        enableSetNeedsDisplay = false
        delegate = renderer
        overlay.frame = bounds
        overlay.autoresizingMask = [.width, .height]
        addSubview(overlay)
    }

    required init(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// 這個螢幕在統一座標裡的範圍
    var camera: ScreenCamera {
        let f = window?.frame ?? .zero
        return ScreenCamera(origin: SIMD2(Float(f.minX), Float(f.minY)), size: SIMD2(Float(f.width), Float(f.height)))
    }

    /// 拖曳跨到別的螢幕時事件仍送到按下的那個視窗，座標會超出範圍，換成統一座標就沒問題
    private func global(_ e: NSEvent) -> SIMD2<Float> {
        let o = window?.frame.origin ?? .zero
        return SIMD2(Float(e.locationInWindow.x + o.x), Float(e.locationInWindow.y + o.y))
    }

    override func mouseDown(with e: NSEvent) { controller?.mouseDown(at: global(e)) }
    override func mouseDragged(with e: NSEvent) { controller?.mouseDragged(to: global(e)) }
    override func mouseUp(with e: NSEvent) { controller?.mouseUp() }
    override func rightMouseDown(with e: NSEvent) { controller?.rightMouseDown(at: global(e)) }
}

/// 地毯本體：一張布、所有互動狀態、每個 frame 的模擬。座標一律是跨螢幕的統一座標
/// （AppKit 螢幕座標：主螢幕左下為原點、y 向上）。每個螢幕一個 RugSurface 負責畫。
final class RugController: NSObject {
    let device = MTLCreateSystemDefaultDevice()!
    private(set) var surfaces: [RugSurface] = []
    private var windows: [NSPanel] = []
    private(set) var cloth: Cloth?
    private var floorField: HeightField?
    private var needsDraw = true
    private(set) var editMode = false
    private var timer: Timer?
    private var saveWhenSettled = false
    /// 右鍵進入、不用按著 ⌥ 的編輯模式；點地毯外面或再按右鍵離開
    private(set) var stickyEdit = false
    /// 檔案選擇視窗開著時（modal），點那個視窗不算「點外面」
    var holdEdit = false
    var onChange: (() -> Void)?   // 擺法變了，要存檔
    var onSurfacesChanged: (() -> Void)?   // 螢幕重建了，工具列按鈕要重新接線
    var tuning = Tuning.load()
    private var textureURL: URL?
    private lazy var catSprites = CatSprites(device: device)
    /// 住在地毯上的貓（kind = 第幾種花色的貓）
    private var cats: [(kind: Int, cat: Cat)] = []
    /// 要顯示哪幾隻（貓的名字），預設只有橘貓
    private(set) var visibleCats = Set(UserDefaults.standard.stringArray(forKey: "visibleCats") ?? ["orange"])
    var catKinds: [String] { catSprites.kinds.map(\.name) }

    /// 編輯模式的貓頭像（抬頭看你那一格；還沒有就用站姿）
    func catThumbnail(_ name: String) -> NSImage? {
        guard let dir = Bundle.main.resourceURL?.appendingPathComponent("cats") else { return nil }
        for (anim, frame) in [("lookup", 12), ("walk", 0)] {
            guard let img = NSImage(contentsOf: dir.appendingPathComponent("\(name)-\(anim).png")),
                  let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
            let cw = cg.width / 4, ch = cg.height / 4
            guard let cell = cg.cropping(to: CGRect(x: (frame % 4) * cw, y: (frame / 4) * ch, width: cw, height: ch)) else { continue }
            return NSImage(cgImage: cell, size: NSSize(width: 48, height: 32))
        }
        return nil
    }

    func toggleCat(_ name: String) {
        if visibleCats.contains(name) {
            visibleCats.remove(name)
            cats.removeAll { catSprites.kinds[$0.kind].name == name }
        } else if let k = catSprites.kinds.firstIndex(where: { $0.name == name }), let cloth {
            visibleCats.insert(name)
            // 新來的貓放在地毯中間附近、沒被蓋住的地方
            let size = cloth.restSize
            var p = SIMD2<Float>(Float.random(in: -0.25...0.25) * size.x, Float.random(in: -0.2...0.2) * size.y)
            for _ in 0..<10 where cloth.isCovered(uv: p / size + 0.5) {
                p = SIMD2(Float.random(in: -0.35...0.35) * size.x, Float.random(in: -0.3...0.3) * size.y)
            }
            cats.append((k, Cat(pos: p, heading: Float.random(in: -.pi ... .pi), length: tuning.catLength,
                                seed: UInt64.random(in: 1...UInt64.max))))
        } else {
            visibleCats.insert(name)
        }
        UserDefaults.standard.set(Array(visibleCats), forKey: "visibleCats")
        needsDraw = true
    }

    enum Drag {
        case grab
        case move(start: SIMD2<Float>, from: RugPlacement)
        case resize(corner: Int, from: RugPlacement)
        case cat(index: Int)
    }
    private var drag: Drag?

    // MARK: 螢幕

    /// 每個螢幕開一個桌面層的透明視窗。螢幕插拔時重建。
    func setupScreens() {
        for w in windows { w.orderOut(nil) }
        windows = []; surfaces = []
        for screen in NSScreen.screens {
            let w = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
            // 桌面圖示上面一層、一般視窗下面
            w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = false
            w.ignoresMouseEvents = true
            w.hidesOnDeactivate = false
            w.isReleasedWhenClosed = false
            let s = RugSurface(frame: NSRect(origin: .zero, size: screen.frame.size), device: device)
            s.autoresizingMask = [.width, .height]
            s.controller = self
            w.contentView = s
            w.setFrame(screen.frame, display: false)
            w.orderFrontRegardless()
            windows.append(w); surfaces.append(s)
        }
        applyLook()
        if let textureURL { for s in surfaces { s.renderer.loadTexture(url: textureURL) } }
        for s in surfaces { s.renderer.cloth = cloth }
        onSurfacesChanged?()
        needsDraw = true
    }

    /// 主螢幕（有選單列、統一座標的原點）
    var mainCamera: ScreenCamera {
        let f = NSScreen.screens[0].frame
        return ScreenCamera(origin: SIMD2(Float(f.minX), Float(f.minY)), size: SIMD2(Float(f.width), Float(f.height)))
    }

    /// 所有螢幕合起來的範圍
    var desktopBounds: (origin: SIMD2<Float>, size: SIMD2<Float>) {
        let u = NSScreen.screens.map(\.frame).reduce(CGRect.null) { $0.union($1) }
        return (SIMD2(Float(u.minX), Float(u.minY)), SIMD2(Float(u.width), Float(u.height)))
    }

    private func surface(containing q: SIMD2<Float>) -> RugSurface? {
        surfaces.first { $0.camera.contains(q) } ?? surfaces.first
    }

    // MARK: 地毯

    func show(_ placement: RugPlacement) {
        let c = Cloth(placement: placement, columns: Int(tuning.columns))
        c.setParams(tuning.params)
        c.floor = floorField
        cloth = c
        for s in surfaces { s.renderer.cloth = c }
        spawnCats(rugSize: placement.size)
        applyLook()
        needsDraw = true
    }

    private func applyLook() {
        for s in surfaces {
            s.renderer.sideThickness = tuning.sideThickness
            s.renderer.shadowAlpha = tuning.shadowAlpha
            s.renderer.cornerRadius = tuning.cornerRadius
            s.renderer.catLength = tuning.catLength
            s.renderer.catSprites = catSprites
        }
        for i in cats.indices { cats[i].cat.length = tuning.catLength }
    }

    /// 收起／鋪開的折疊動畫（播放中不跑物理、不畫貓、不吃互動）
    private var fold: (t: Float, duration: Float, reverse: Bool, anim: FoldAnimation, done: () -> Void)?
    private var stow: Bool { fold != nil }

    func stowRug(then done: @escaping () -> Void) {
        guard let cloth, fold == nil else { return }
        var p = cloth.fittedPlacement()
        p.angle = 0
        cloth.release()
        drag = nil
        stickyEdit = false
        fold = (0, 1.7, false, FoldAnimation(placement: p), done)
    }

    /// 從折好的小包落下、打開兩折，鋪成這個擺法
    func showAnimated(_ placement: RugPlacement) {
        show(placement)
        drag = nil
        stickyEdit = false
        fold = (0, 1.5, true, FoldAnimation(placement: placement), {})
        stepFold()
    }

    private func stepFold() {
        guard var f = fold, let cloth else { return }
        f.t += 1.0 / 60
        fold = f
        let progress = f.reverse ? 1 - f.t / f.duration : f.t / f.duration
        let anim = f.anim
        cloth.pose { uv in anim.position(uv: uv, progress: min(max(progress, 0), 1)) }
        needsDraw = true
        guard f.t >= f.duration else { return }
        fold = nil
        if f.reverse {
            cloth.flatten(to: anim.placement)   // 攤平後交給物理
        } else {
            hideRug()
        }
        f.done()
    }

    /// 要顯示的貓各一隻，散在地毯上
    private func spawnCats(rugSize: SIMD2<Float>) {
        guard cats.isEmpty else { return }
        let kinds = catSprites.kinds.indices.filter { visibleCats.contains(catSprites.kinds[$0].name) }
        let n = kinds.count
        cats = kinds.enumerated().map { i, kind in
            let x = (Float(i) + 0.5) / Float(max(n, 1)) - 0.5
            let pos = SIMD2(x * rugSize.x * 0.7, (i % 2 == 0 ? 0.15 : -0.15) * rugSize.y)
            return (kind, Cat(pos: pos, heading: Float(i) * 1.7, length: tuning.catLength, seed: UInt64(kind + 1) &* 7919))
        }
    }

    func hideRug() {
        stickyEdit = false
        cloth = nil
        for s in surfaces { s.renderer.cloth = nil }
        drag = nil
        needsDraw = true
    }

    /// 面板改了參數。rebuild = 格子數變了，要整張重建。
    func apply(_ t: Tuning, rebuild: Bool) {
        tuning = t
        applyLook()
        if rebuild, let cloth {
            var p = cloth.fittedPlacement()
            p.angle = 0
            show(p)
        } else {
            cloth?.setParams(t.params)
        }
        needsDraw = true
    }

    func setTexture(_ url: URL) {
        textureURL = url
        for s in surfaces { s.renderer.loadTexture(url: url) }
        needsDraw = true
    }

    func setFloor(_ f: HeightField?) {
        floorField = f
        cloth?.floor = f
        cloth?.wake()
    }

    var placement: RugPlacement? { cloth?.fittedPlacement() }

    // MARK: 每個 frame

    func start() {
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // 開發用：`DesktopRug --demo fold|flick|bumps|edit|stow|appear|cross|tuning` 跑腳本動作，方便不碰滑鼠截圖驗畫面
    var demo: String?
    private var demoFrame = 0
    private var demoFrom = SIMD2<Float>(0, 0)
    private var demoTo = SIMD2<Float>(0, 0)

    private func runDemo() {
        guard let demo, let cloth else { return }
        let p = cloth.fittedPlacement()
        demoFrame += 1
        switch demo {
        case "fold":
            if demoFrame == 30 { demoFrom = p.point(u: 1, v: 1); demoTo = p.point(u: 0.35, v: 0.3); cloth.grab(near: demoFrom) }
            let from = demoFrom, to = demoTo
            if demoFrame > 30 && demoFrame <= 120 {
                let t = Float(demoFrame - 30) / 90
                cloth.moveGrab(to: from + (to - from) * t)
            }
            if demoFrame == 150 { cloth.release() }
        case "flick":
            if demoFrame == 30 { demoFrom = p.point(u: 0.5, v: 0.5); cloth.grab(near: demoFrom) }
            let from = demoFrom
            if demoFrame > 30 && demoFrame <= 48 { cloth.moveGrab(to: from + SIMD2(Float(demoFrame - 30) * 25, 0)) }
            if demoFrame == 48 { cloth.release() }
        case "bumps":
            if demoFrame == 1 {
                var icons: [SIMD2<Float>] = []
                for k in 0..<4 { icons.append(p.point(u: 0.3, v: 0.6) + SIMD2(Float(k) * 4, 0)) }
                icons.append(p.point(u: 0.7, v: 0.4))
                icons += [p.point(u: 0.55, v: 0.7), p.point(u: 0.62, v: 0.7)]
                let d = desktopBounds
                setFloor(HeightField.fromIcons(icons, iconSize: 64, origin: d.origin, size: d.size))
            }
        case "cross":
            // 放在主螢幕下緣（跨到下方螢幕），再抓中間往下拖
            if demoFrame == 1 { cloth.flatten(to: RugPlacement(center: SIMD2(950, 60), angle: 0, size: p.size)) }
            if demoFrame == 30 { demoFrom = SIMD2(950, 60); cloth.grab(near: demoFrom) }
            if demoFrame > 30 && demoFrame <= 90 { cloth.moveGrab(to: demoFrom + SIMD2(0, -Float(demoFrame - 30) * 5)) }
            if demoFrame == 90 { cloth.release() }
        case "stow":
            if demoFrame == 30 { stowRug {} }
        case "appear":
            if demoFrame == 30 { showAnimated(p) }
        case "edit":
            editMode = true
            activeCorner = 2
            needsDraw = true
        default: break
        }
    }

    private func tick() {
        runDemo()
        let m = NSEvent.mouseLocation
        let mouse = SIMD2(Float(m.x), Float(m.y))
        let option = NSEvent.modifierFlags.contains(.option)
        if drag == nil, demo != "edit", (option || stickyEdit) != editMode {
            editMode = option || stickyEdit
            needsDraw = true
        }

        // 只有游標所在的那個螢幕可能要吃滑鼠
        var anyHit = false
        for (s, w) in zip(surfaces, windows) {
            let cam = s.camera
            let hit: Bool
            if drag != nil { hit = true }
            else if !cam.contains(mouse) { hit = false }
            else if editMode {
                let local = CGPoint(x: CGFloat(mouse.x - cam.origin.x), y: CGFloat(mouse.y - cam.origin.y))
                hit = editTarget(at: mouse) != nil || s.overlay.toolbarHit(local)
            } else { hit = catAt(mouse) != nil || clothHit(mouse, camera: cam) }
            if w.ignoresMouseEvents == hit { w.ignoresMouseEvents = !hit }
            anyHit = anyHit || hit
        }
        if stickyEdit, !anyHit, !holdEdit, NSEvent.pressedMouseButtons != 0 {
            stickyEdit = false
        }

        if let cloth, !stow, !cats.isEmpty {
            let positions = cats.map(\.cat.pos)
            for i in cats.indices {
                let others = positions.enumerated().filter { $0.offset != i }.map(\.element)
                let size = cloth.restSize
                cats[i].cat.update(dt: 1.0 / 60, rugSize: size, others: others) { p in
                    !cloth.isCovered(uv: SIMD2(p.x / size.x + 0.5, p.y / size.y + 0.5))
                }
            }
            needsDraw = true
        }
        if stow {
            stepFold()
        } else if let cloth, !cloth.isSettled || drag != nil || cloth.grabbed != nil {
            cloth.step(dt: 1.0 / 60)
            needsDraw = true
        }
        // 拖完放手時布還在半空，等它躺平再存，存到的擺法才對
        if saveWhenSettled, drag == nil, cloth?.isSettled ?? true {
            saveWhenSettled = false
            onChange?()
        }
        if needsDraw {
            needsDraw = false
            let p = editMode && !stow ? cloth?.fittedPlacement() : nil
            // 花色列只放在地毯中心所在的那個螢幕
            let home = p.flatMap { surface(containing: $0.center) }
            for s in surfaces {
                let cam = s.camera
                s.renderer.origin = cam.origin
                s.renderer.cats = !stow ? cats.map { ($0.kind, $0.cat.pose) } : []
                s.draw()
                var local = p
                local?.center -= cam.origin
                s.overlay.update(placement: local, activeCorner: activeCorner, showToolbar: s === home)
            }
        }
    }

    /// 游標是不是在這個螢幕看到的任何一片三角形裡。折起來的布外框會自交，所以不能用外框多邊形判斷。
    private func clothHit(_ q: SIMD2<Float>, camera: ScreenCamera) -> Bool {
        guard let cloth else { return false }
        let projected = cloth.pos.map { camera.project($0) }
        var lo = SIMD2<Float>(.infinity, .infinity), hi = -lo
        for p in projected { lo = simd_min(lo, p); hi = simd_max(hi, p) }
        if q.x < lo.x || q.y < lo.y || q.x > hi.x || q.y > hi.y { return false }
        let I = cloth.indices
        for t in stride(from: 0, to: I.count, by: 3) {
            if pointInTriangle(q, projected[Int(I[t])], projected[Int(I[t + 1])], projected[Int(I[t + 2])]) { return true }
        }
        return false
    }

    // MARK: 編輯模式（右鍵或按著 ⌥）

    private enum EditTarget { case corner(Int), body }
    private var activeCorner: Int?

    private func editTarget(at q: SIMD2<Float>) -> EditTarget? {
        guard let p = cloth?.fittedPlacement() else { return nil }
        for (k, c) in p.corners.enumerated() where simd_distance(c, q) < 9 { return .corner(k) }
        let local = SIMD2(simd_dot(q - p.center, p.axisX), simd_dot(q - p.center, p.axisY))
        if abs(local.x) <= p.size.x / 2 && abs(local.y) <= p.size.y / 2 { return .body }
        return nil
    }

    // MARK: 滑鼠（統一座標）

    func mouseDown(at q: SIMD2<Float>) {
        guard let cloth, !stow else { return }
        if editMode {
            guard let target = editTarget(at: q) else { return }
            var p = cloth.fittedPlacement()
            p.angle = 0
            cloth.flatten(to: p)
            switch target {
            case .corner(let k): drag = .resize(corner: k, from: p); activeCorner = k; NSCursor.crosshair.push()
            case .body: drag = .move(start: q, from: p); NSCursor.closedHand.push()
            }
        } else if let i = catAt(q) {
            // 點到貓：拎起來（貓在地毯上面，優先於抓地毯）
            cats[i].cat.pickUp()
            cats[i].cat.carry(to: rugLocal(q))
            drag = .cat(index: i)
            NSCursor.closedHand.push()
        } else {
            guard let cam = surface(containing: q)?.camera else { return }
            cloth.grab(near: cam.unproject(q, z: 0))
            cloth.moveGrab(to: cam.unproject(q, z: cloth.params.grabLift))
            drag = .grab
            NSCursor.closedHand.push()
        }
        needsDraw = true
    }

    func rightMouseDown(at q: SIMD2<Float>) {
        guard !stow else { return }
        if stickyEdit { stickyEdit = false }
        else if let cam = surface(containing: q)?.camera, clothHit(q, camera: cam) { stickyEdit = true }
        needsDraw = true
    }

    func mouseDragged(to q: SIMD2<Float>) {
        guard let cloth, let drag else { return }
        switch drag {
        case .grab:
            // 拖到哪個螢幕就用那個螢幕的鏡頭換算
            guard let cam = surface(containing: q)?.camera else { return }
            cloth.moveGrab(to: cam.unproject(q, z: cloth.params.grabLift))
        case .move(let start, var p):
            p.center += q - start
            cloth.flatten(to: p)
        case .resize(let k, let p):
            cloth.flatten(to: resized(p, corner: k, to: q))
        case .cat(let i):
            cats[i].cat.carry(to: rugLocal(q))
        }
        needsDraw = true
    }

    func mouseUp() {
        guard let d = drag else { return }
        NSCursor.pop()
        drag = nil
        activeCorner = nil
        needsDraw = true
        switch d {
        case .grab: cloth?.release(); saveWhenSettled = true
        case .cat(let i): cats[i].cat.drop()
        default: onChange?()
        }
    }

    /// 統一座標 → 地毯局部座標（地毯中心為原點、沿地毯的軸）
    private func rugLocal(_ q: SIMD2<Float>) -> SIMD2<Float> {
        guard let p = cloth?.fittedPlacement() else { return q }
        return SIMD2(simd_dot(q - p.center, p.axisX), simd_dot(q - p.center, p.axisY))
    }

    /// 游標底下有沒有貓（橢圓判定，大約是身體不含尾巴）
    private func catAt(_ q: SIMD2<Float>) -> Int? {
        guard !stow, cloth != nil else { return nil }
        let local = rugLocal(q)
        for i in cats.indices.reversed() {
            let c = cats[i].cat
            let d = local - c.pos
            let a = -c.heading
            let r = SIMD2(d.x * cos(a) - d.y * sin(a), d.x * sin(a) + d.y * cos(a))
            let L = tuning.catLength
            if pow(r.x / (L * 0.4), 2) + pow(r.y / (L * 0.2), 2) <= 1 { return i }
        }
        return nil
    }

    /// 拖角落縮放：對角固定、保持長寬比（花色才不會被拉歪）。
    private func resized(_ p: RugPlacement, corner k: Int, to q: SIMD2<Float>) -> RugPlacement {
        let opposite = p.corners[(k + 2) % 4]
        let sx: Float = (k == 1 || k == 2) ? 1 : -1
        let sy: Float = (k >= 2) ? 1 : -1
        let d = q - opposite
        let lx = simd_dot(d, p.axisX) * sx, ly = simd_dot(d, p.axisY) * sy
        let maxW = desktopBounds.size.x
        let s = min(max(max(lx / p.size.x, ly / p.size.y), 160 / p.size.x), maxW / p.size.x)
        var out = p
        out.size = p.size * s
        out.center = opposite + p.axisX * (sx * out.size.x / 2) + p.axisY * (sy * out.size.y / 2)
        return out
    }
}

private func pointInTriangle(_ p: SIMD2<Float>, _ a: SIMD2<Float>, _ b: SIMD2<Float>, _ c: SIMD2<Float>) -> Bool {
    func cross(_ u: SIMD2<Float>, _ v: SIMD2<Float>) -> Float { u.x * v.y - u.y * v.x }
    let d1 = cross(b - a, p - a), d2 = cross(c - b, p - b), d3 = cross(a - c, p - c)
    let neg = d1 < 0 || d2 < 0 || d3 < 0, pos = d1 > 0 || d2 > 0 || d3 > 0
    return !(neg && pos)
}
