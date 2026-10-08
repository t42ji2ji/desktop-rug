import AppKit
import MetalKit
import RugSim
import simd

/// 整張主螢幕大小的透明 Metal view。平常整個視窗不吃滑鼠，只有游標在地毯上（或按著 ⌥ 在控制點附近）才吃。
final class RugView: MTKView {
    let renderer: Renderer
    let overlay = EditOverlay()
    private(set) var cloth: Cloth?
    private var floorField: HeightField?
    private var projected: [SIMD2<Float>] = []
    private var needsDraw = true
    private(set) var editMode = false
    private var timer: Timer?
    var onChange: (() -> Void)?   // 擺法變了，要存檔

    enum Drag {
        case grab
        case move(start: SIMD2<Float>, from: RugPlacement)
        case resize(corner: Int, from: RugPlacement)
        case rotate(start: SIMD2<Float>, from: RugPlacement)
    }
    private var drag: Drag?

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

    var viewSize: SIMD2<Float> { SIMD2(Float(bounds.width), Float(bounds.height)) }

    // MARK: 地毯

    func show(_ placement: RugPlacement) {
        let c = Cloth(placement: placement)
        c.floor = floorField
        cloth = c
        renderer.cloth = c
        updateProjection()
        needsDraw = true
    }

    func hideRug() {
        cloth = nil
        renderer.cloth = nil
        drag = nil
        needsDraw = true
    }

    func setTexture(_ url: URL) {
        renderer.loadTexture(url: url)
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

    // 開發用：`DesktopRug --demo fold|bumps|edit` 跑腳本動作，方便不碰滑鼠截圖驗畫面
    var demo: String?
    private var demoFrame = 0

    private func runDemo() {
        guard let demo, let cloth else { return }
        let p = cloth.fittedPlacement()
        demoFrame += 1
        switch demo {
        case "fold":
            let from = p.point(u: 1, v: 1), to = p.point(u: 0.35, v: 0.3)
            if demoFrame == 30 { cloth.grab(near: from) }
            if demoFrame > 30 && demoFrame <= 120 {
                let t = Float(demoFrame - 30) / 90
                cloth.moveGrab(to: from + (to - from) * t + SIMD2(0, 0))
            }
            if demoFrame == 150 { cloth.release() }
        case "bumps":
            if demoFrame == 1 {
                var icons: [SIMD2<Float>] = []
                for k in 0..<4 { icons.append(p.point(u: 0.3, v: 0.6) + SIMD2(Float(k) * 4, 0)) }
                icons.append(p.point(u: 0.7, v: 0.4))
                icons += [p.point(u: 0.55, v: 0.7), p.point(u: 0.62, v: 0.7)]
                setFloor(HeightField.fromIcons(icons, iconSize: 64, origin: .zero, size: viewSize))
            }
        case "edit":
            editMode = true
            angleLabel = "11°"; activeCorner = 2
            if demoFrame == 1 { cloth.flatten(to: RugPlacement(center: p.center, angle: 11 * .pi / 180, size: p.size)) }
            needsDraw = true
        default: break
        }
    }

    private func tick() {
        guard let window else { return }
        runDemo()
        let m = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let mouse = SIMD2(Float(m.x), Float(m.y))
        let option = NSEvent.modifierFlags.contains(.option)
        if drag == nil, demo != "edit", option != editMode {
            editMode = option
            needsDraw = true
        }

        let hit: Bool
        if drag != nil { hit = true }
        else if editMode { hit = editTarget(at: mouse) != nil || overlay.toolbarHit(m) }
        else { hit = clothHit(mouse) }
        if window.ignoresMouseEvents == hit { window.ignoresMouseEvents = !hit }

        if let cloth, !cloth.isSettled || drag != nil || cloth.grabbed != nil {
            cloth.step(dt: 1.0 / 60)
            updateProjection()
            needsDraw = true
        }
        if needsDraw {
            needsDraw = false
            draw()
            overlay.update(placement: editMode ? cloth?.fittedPlacement() : nil,
                           activeCorner: activeCorner, angleLabel: angleLabel, cursor: m)
        }
    }

    private func updateProjection() {
        guard let cloth else { projected = []; return }
        let v = viewSize
        projected = cloth.pos.map { projectToScreen($0, view: v) }
    }

    /// 游標是不是在（投影後的）任何一片三角形裡。折起來的布外框會自交，所以不能用外框多邊形判斷。
    private func clothHit(_ q: SIMD2<Float>) -> Bool {
        guard let cloth, !projected.isEmpty else { return false }
        var lo = SIMD2<Float>(.infinity, .infinity), hi = -lo
        for p in projected { lo = simd_min(lo, p); hi = simd_max(hi, p) }
        if q.x < lo.x || q.y < lo.y || q.x > hi.x || q.y > hi.y { return false }
        let I = cloth.indices
        for t in stride(from: 0, to: I.count, by: 3) {
            if pointInTriangle(q, projected[Int(I[t])], projected[Int(I[t + 1])], projected[Int(I[t + 2])]) { return true }
        }
        return false
    }

    // MARK: 編輯模式（按著 ⌥）

    private enum EditTarget { case corner(Int), rotate(Int), body }
    private var activeCorner: Int?
    private var angleLabel: String?

    private func editTarget(at q: SIMD2<Float>) -> EditTarget? {
        guard let p = cloth?.fittedPlacement() else { return nil }
        let corners = p.corners
        for (k, c) in corners.enumerated() where simd_distance(c, q) < 9 { return .corner(k) }
        for (k, c) in corners.enumerated() where simd_distance(c, q) < 32 {
            // 角落外側那一圈 = 旋轉
            let local = SIMD2(simd_dot(q - p.center, p.axisX), simd_dot(q - p.center, p.axisY))
            if abs(local.x) > p.size.x / 2 - 2 || abs(local.y) > p.size.y / 2 - 2 { return .rotate(k) }
        }
        let local = SIMD2(simd_dot(q - p.center, p.axisX), simd_dot(q - p.center, p.axisY))
        if abs(local.x) <= p.size.x / 2 && abs(local.y) <= p.size.y / 2 { return .body }
        return nil
    }

    // MARK: 滑鼠

    override func mouseDown(with e: NSEvent) {
        guard let cloth else { return }
        let m = convert(e.locationInWindow, from: nil)
        let q = SIMD2(Float(m.x), Float(m.y))
        if editMode {
            guard let target = editTarget(at: q) else { return }
            let p = cloth.fittedPlacement()
            cloth.flatten(to: p)
            switch target {
            case .corner(let k): drag = .resize(corner: k, from: p); activeCorner = k; NSCursor.crosshair.push()
            case .rotate(let k): drag = .rotate(start: q, from: p); activeCorner = k; NSCursor.crosshair.push()
            case .body: drag = .move(start: q, from: p); NSCursor.closedHand.push()
            }
        } else {
            cloth.grab(near: unprojectFromScreen(q, z: 0, view: viewSize))
            cloth.moveGrab(to: unprojectFromScreen(q, z: cloth.params.grabLift, view: viewSize))
            drag = .grab
            NSCursor.closedHand.push()
        }
        needsDraw = true
    }

    override func mouseDragged(with e: NSEvent) {
        guard let cloth, let drag else { return }
        let m = convert(e.locationInWindow, from: nil)
        let q = SIMD2(Float(m.x), Float(m.y))
        switch drag {
        case .grab:
            cloth.moveGrab(to: unprojectFromScreen(q, z: cloth.params.grabLift, view: viewSize))
        case .move(let start, var p):
            p.center += q - start
            cloth.flatten(to: p)
        case .resize(let k, let p):
            cloth.flatten(to: resized(p, corner: k, to: q))
        case .rotate(let start, var p):
            let a0 = atan2(start.y - p.center.y, start.x - p.center.x)
            let a1 = atan2(q.y - p.center.y, q.x - p.center.x)
            var deg = (p.angle + a1 - a0) * 180 / .pi
            deg = remainder(deg, 360)
            let snap = (deg / 90).rounded() * 90
            if abs(deg - snap) < 2 { deg = snap }
            p.angle = deg * .pi / 180
            angleLabel = "\(Int(deg.rounded()))°"
            cloth.flatten(to: p)
        }
        updateProjection()
        needsDraw = true
    }

    override func mouseUp(with e: NSEvent) {
        guard let d = drag else { return }
        if case .grab = d { cloth?.release() }
        NSCursor.pop()
        drag = nil
        activeCorner = nil
        angleLabel = nil
        needsDraw = true
        onChange?()
    }

    /// 拖角落縮放：對角固定、保持長寬比（花色才不會被拉歪）。
    private func resized(_ p: RugPlacement, corner k: Int, to q: SIMD2<Float>) -> RugPlacement {
        let opposite = p.corners[(k + 2) % 4]
        let sx: Float = (k == 1 || k == 2) ? 1 : -1
        let sy: Float = (k >= 2) ? 1 : -1
        let d = q - opposite
        let lx = simd_dot(d, p.axisX) * sx, ly = simd_dot(d, p.axisY) * sy
        let maxW = viewSize.x * 1.2
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
