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
    var catsEnabled = UserDefaults.standard.object(forKey: "cats") as? Bool ?? true {
        didSet { UserDefaults.standard.set(catsEnabled, forKey: "cats"); needsDraw = true }
    }

    enum Drag {
        case grab
        case move(start: SIMD2<Float>, from: RugPlacement)
        case resize(corner: Int, from: RugPlacement)
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

    /// 收起動畫：右半翻到左半上、上半往下對折、縮小消失，播完才真的收起。
    private var stow: (frame: Int, base: RugPlacement, done: () -> Void)?

    func stowRug(then done: @escaping () -> Void) {
        guard let cloth, stow == nil else { return }
        var p = cloth.fittedPlacement()
        p.angle = 0
        cloth.release()
        drag = nil
        stickyEdit = false
        stow = (0, p, done)
    }

    private func stepStow() {
        guard var s = stow, let cloth else { return }
        s.frame += 1
        stow = s
        let t = Float(s.frame) / 60
        func ease(_ x: Float) -> Float { let c = min(max(x, 0), 1); return c * c * (3 - 2 * c) }
        let a1 = ease(t / 0.45) * .pi, a2 = ease((t - 0.45) / 0.45) * .pi
        let shrink = 1 - ease((t - 0.95) / 0.35)
        let p = s.base, th: Float = 4
        cloth.pose { uv in
            var x = (uv.x - 0.5) * p.size.x, y = (uv.y - 0.5) * p.size.y, z: Float = 0
            // 1. 沿垂直中線把右半翻過來
            if x > 0 { let r = x; x = r * cos(a1); z = r * sin(a1) + th * a1 / .pi }
            // 2. 疊好的兩層再沿水平中線把上半往下折
            if y > 0 { let r = y, zz = z; y = r * cos(a2) - zz * sin(a2); z = r * sin(a2) + zz * cos(a2) + 2 * th * a2 / .pi }
            // 3. 縮小收走（往左下那一塊的中心縮）
            let anchor = SIMD2<Float>(-p.size.x / 4, -p.size.y / 4)
            let q = anchor + (SIMD2(x, y) - anchor) * shrink
            let w = p.center + p.axisX * q.x + p.axisY * q.y
            return SIMD3(w.x, w.y, z * shrink)
        }
        needsDraw = true
        if t >= 1.3 { stow = nil; hideRug(); s.done() }
    }

    /// 每種貓一隻，散在地毯上
    private func spawnCats(rugSize: SIMD2<Float>) {
        guard cats.isEmpty else { return }
        let n = catSprites.kinds.count
        cats = (0..<n).map { i in
            let x = (Float(i) + 0.5) / Float(max(n, 1)) - 0.5
            let pos = SIMD2(x * rugSize.x * 0.7, (i % 2 == 0 ? 0.15 : -0.15) * rugSize.y)
            return (i, Cat(pos: pos, heading: Float(i) * 1.7, length: tuning.catLength, seed: UInt64(i + 1) &* 7919))
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

    // 開發用：`DesktopRug --demo fold|flick|bumps|edit|stow|tuning` 跑腳本動作，方便不碰滑鼠截圖驗畫面
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
            } else { hit = clothHit(mouse, camera: cam) }
            if w.ignoresMouseEvents == hit { w.ignoresMouseEvents = !hit }
            anyHit = anyHit || hit
        }
        if stickyEdit, !anyHit, !holdEdit, NSEvent.pressedMouseButtons != 0 {
            stickyEdit = false
        }

        if catsEnabled, let cloth, stow == nil, !cats.isEmpty {
            let positions = cats.map(\.cat.pos)
            for i in cats.indices {
                let others = positions.enumerated().filter { $0.offset != i }.map(\.element)
                cats[i].cat.update(dt: 1.0 / 60, rugSize: cloth.restSize, others: others)
            }
            needsDraw = true
        }
        if stow != nil {
            stepStow()
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
            let p = editMode && stow == nil ? cloth?.fittedPlacement() : nil
            // 花色列只放在地毯中心所在的那個螢幕
            let home = p.flatMap { surface(containing: $0.center) }
            for s in surfaces {
                let cam = s.camera
                s.renderer.origin = cam.origin
                s.renderer.cats = catsEnabled && stow == nil ? cats.map { ($0.kind, $0.cat.pose) } : []
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
        guard let cloth, stow == nil else { return }
        if editMode {
            guard let target = editTarget(at: q) else { return }
            var p = cloth.fittedPlacement()
            p.angle = 0
            cloth.flatten(to: p)
            switch target {
            case .corner(let k): drag = .resize(corner: k, from: p); activeCorner = k; NSCursor.crosshair.push()
            case .body: drag = .move(start: q, from: p); NSCursor.closedHand.push()
            }
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
        guard stow == nil else { return }
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
        }
        needsDraw = true
    }

    func mouseUp() {
        guard let d = drag else { return }
        NSCursor.pop()
        drag = nil
        activeCorner = nil
        needsDraw = true
        if case .grab = d { cloth?.release(); saveWhenSettled = true } else { onChange?() }
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
