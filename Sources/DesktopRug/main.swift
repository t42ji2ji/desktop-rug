import AppKit
import UniformTypeIdentifiers
import MetalKit
import RugSim
import simd

/// 地毯花色：app bundle 的 Resources/patterns，加上使用者自己加的（Application Support/DesktopRug/patterns）。
struct Pattern {
    let id: String
    let url: URL
    var title: String { Pattern.title(for: id) }
    var isUserAdded: Bool { url.deletingLastPathComponent().standardizedFileURL == Pattern.userDir.standardizedFileURL }

    static let titles = prefersChinese ? [
        "persian-red": "波斯紅", "blue-tabriz": "大不里士藍", "beni-ourain": "摩洛哥白",
        "kilim": "基里姆", "sage-modern": "鼠尾草綠", "retro-check": "復古格紋",
        "pink-floral": "玫瑰古董", "pixel-space": "太空",
    ] : [
        "persian-red": "Persian Red", "blue-tabriz": "Blue Tabriz", "beni-ourain": "Beni Ourain",
        "kilim": "Kilim", "sage-modern": "Sage", "retro-check": "Retro Check",
        "pink-floral": "Faded Rose", "pixel-space": "Space",
    ]
    static func title(for id: String) -> String { titles[id] ?? id }
    static let defaultID = "retro-check"

    static let imageExtensions: Set = ["png", "jpg", "jpeg", "heic", "tif", "tiff", "webp"]

    static var userDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("DesktopRug/patterns", isDirectory: true)
    }

    static func all() -> [Pattern] {
        func list(_ dir: URL?) -> [Pattern] {
            guard let dir else { return [] }
            let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            return files.filter { imageExtensions.contains($0.pathExtension.lowercased()) }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
                .map { Pattern(id: $0.deletingPathExtension().lastPathComponent, url: $0) }
        }
        var builtIn = list(Bundle.main.resourceURL?.appendingPathComponent("patterns"))
        if builtIn.isEmpty {
            builtIn = list(URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("patterns"))
        }
        // 預設的復古格紋排第一，自己加的排最後
        builtIn.sort { ($0.id == defaultID ? 0 : 1, $0.id) < ($1.id == defaultID ? 0 : 1, $1.id) }
        return builtIn + list(userDir)
    }

    /// 把本機圖片複製進 app 的花色資料夾，回傳新花色。
    static func importImage(_ src: URL) -> Pattern? {
        try? FileManager.default.createDirectory(at: userDir, withIntermediateDirectories: true)
        let name = src.deletingPathExtension().lastPathComponent
        var dest = userDir.appendingPathComponent(src.lastPathComponent)
        var n = 2
        while FileManager.default.fileExists(atPath: dest.path) {
            dest = userDir.appendingPathComponent("\(name) \(n).\(src.pathExtension)"); n += 1
        }
        guard (try? FileManager.default.copyItem(at: src, to: dest)) != nil else { return nil }
        return Pattern(id: dest.deletingPathExtension().lastPathComponent, url: dest)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let rug = RugController()
    var statusItem: NSStatusItem!
    var patterns = Pattern.all()
    let defaults = UserDefaults.standard
    let iconQueue = DispatchQueue(label: "desktop-icons")
    var lastIcons: DesktopIcons.Snapshot?
    var tuningPanel: TuningPanel?

    var patternID: String {
        get { defaults.string(forKey: "pattern") ?? Pattern.defaultID }
        set { defaults.set(newValue, forKey: "pattern") }
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--record"), i + 1 < args.count { recordShowcase(to: args[i + 1]); exit(0) }
        if let i = args.firstIndex(of: "--icon"), i + 1 < args.count { renderIcon(to: args[i + 1]); exit(0) }
        rug.onChange = { [weak self] in self?.save() }
        rug.onSurfacesChanged = { [weak self] in self?.wireOverlays() }
        rug.setupScreens()

        applyPattern()
        if let i = CommandLine.arguments.firstIndex(of: "--demo"), i + 1 < CommandLine.arguments.count {
            rug.demo = CommandLine.arguments[i + 1]
        }
        // demo 一律先鋪出來（不寫回「已收起」的設定）
        if !defaults.bool(forKey: "hidden") || rug.demo != nil { rug.show(savedPlacement() ?? defaultPlacement()) }
        rug.start()
        if rug.demo == "tuning" { showTuning() }

        setupStatusItem()
        pollIcons()
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.pollIcons() }

        // 螢幕插拔、排列改變：每個螢幕的視窗重建
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.rug.setupScreens()
            self?.lastIcons = nil
        }
    }

    /// 每個螢幕的花色列都接到同一組動作
    func wireOverlays() {
        for s in rug.surfaces {
            let o = s.overlay
            o.onPick = { [weak self] id in self?.patternID = id; self?.applyPattern(); self?.selectSwatch(id) }
            o.onDelete = { [weak self] id in self?.deletePattern(id) }
            o.addButton.target = self
            o.addButton.action = #selector(addLocalImage)
            o.trashButton.target = self
            o.trashButton.action = #selector(hideRug)
            o.onToggleCat = { [weak self] name in
                guard let self else { return }
                self.rug.toggleCat(name)
                for s in self.rug.surfaces { s.overlay.showCats(self.rug.visibleCats) }
            }
            o.setCats(rug.catKinds.compactMap { n in rug.catThumbnail(n).map { (n, $0) } }, visible: rug.visibleCats)
        }
        refreshSwatches()
    }

    func selectSwatch(_ id: String) { for s in rug.surfaces { s.overlay.select(id) } }

    // MARK: 官網素材（不開視窗、不寫設定）

    /// 展示影片：逐格輸出到 ffmpeg，存成帶透明背景的 .mov（之後再疊背景、壓成網頁用的檔）
    func recordShowcase(to path: String) {
        let size = SIMD2<Float>(1280, 800), scale: CGFloat = 1.5
        applyPattern()
        rug.demo = "showcase"
        rug.setShowcaseCats(["orange", "calico", "british"])
        rug.showcasePlacement = RugPlacement(center: size / 2, angle: 0, size: SIMD2(640, 640 / 1.5))
        let w = Int(CGFloat(size.x) * scale), h = Int(CGFloat(size.y) * scale)
        let ff = Process()
        ff.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
        ff.arguments = ["-y", "-loglevel", "error", "-f", "rawvideo", "-pix_fmt", "bgra", "-s", "\(w)x\(h)", "-r", "30",
                        "-i", "-", "-c:v", "qtrle", "-pix_fmt", "argb", path]
        let pipe = Pipe()
        ff.standardInput = pipe
        try! ff.run()
        let open = NSCursor.openHand.image, closed = NSCursor.closedHand.image
        let renderer = Renderer(view: offscreenView())
        rug.record(region: .zero, size: size, scale: scale, frames: 1200, every: 2, renderer: renderer) { px, w, h in
            var px = px
            // 畫手的游標（影片裡才看得出在抓哪裡）
            if let c = rug.demoCursor {
                px.withUnsafeMutableBytes { buf in
                    let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                        space: CGColorSpaceCreateDeviceRGB(),
                                        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
                    let img = c.closed ? closed : open
                    let s = CGFloat(30) * scale
                    let rect = CGRect(x: CGFloat(c.pos.x) * scale - s / 2, y: CGFloat(c.pos.y) * scale - s / 2, width: s, height: s)
                    if let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) { ctx.draw(cg, in: rect) }
                }
            }
            pipe.fileHandleForWriting.write(Data(px))
        }
        pipe.fileHandleForWriting.closeFile()
        ff.waitUntilExit()
    }

    /// app 圖示：角掀起來的地毯，透明背景 1024×1024
    func renderIcon(to path: String) {
        applyPattern()
        let size = SIMD2<Float>(1024, 1024)
        rug.iconPose(RugPlacement(center: SIMD2(512, 500), angle: 0, size: SIMD2(800, 800 / 1.5)))
        let renderer = Renderer(view: offscreenView())
        rug.record(region: .zero, size: size, scale: 1, frames: 1, every: 1, renderer: renderer) { px, w, h in
            var px = px
            px.withUnsafeMutableBytes { buf in
                let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                    space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
                let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)!
                CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
                CGImageDestinationFinalize(dest)
            }
        }
    }

    private func offscreenView() -> MTKView {
        let v = MTKView(frame: .zero, device: rug.device)
        v.colorPixelFormat = .bgra8Unorm
        v.depthStencilPixelFormat = .depth32Float
        return v
    }

    // MARK: 擺法存檔

    func defaultPlacement() -> RugPlacement {
        let m = rug.mainCamera
        let w = m.size.x * 0.42
        return RugPlacement(center: m.center, angle: 0, size: SIMD2(w, w / 1.5))
    }

    func savedPlacement() -> RugPlacement? {
        guard let d = defaults.data(forKey: "placement") else { return nil }
        return try? JSONDecoder().decode(RugPlacement.self, from: d)
    }

    func save() {
        guard let p = rug.placement, let d = try? JSONEncoder().encode(p) else { return }
        defaults.set(d, forKey: "placement")
    }

    // MARK: 花色

    func applyPattern() {
        guard let p = patterns.first(where: { $0.id == patternID }) ?? patterns.first else { return }
        rug.setTexture(p.url)
    }

    func patternMenu() -> NSMenu {
        let menu = NSMenu()
        for p in patterns {
            let item = NSMenuItem(title: p.title, action: #selector(pickPattern(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = p.id
            item.state = p.id == patternID ? .on : .off
            if let img = NSImage(contentsOf: p.url) {
                img.size = NSSize(width: 72, height: 48)
                item.image = img
            }
            menu.addItem(item)
        }
        return menu
    }

    func refreshSwatches() {
        for s in rug.surfaces {
            s.overlay.setPatterns(patterns.map { ($0.id, $0.url, $0.isUserAdded) }, selected: patternID)
        }
    }

    func deletePattern(_ id: String) {
        guard let p = patterns.first(where: { $0.id == id }), p.isUserAdded else { return }
        try? FileManager.default.removeItem(at: p.url)
        patterns = Pattern.all()
        if patternID == id { patternID = Pattern.defaultID; applyPattern() }
        refreshSwatches()
    }

    @objc func addLocalImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.message = L("選一張圖片當地毯花色", "Choose an image to use as the rug pattern")
        rug.holdEdit = true
        NSApp.activate(ignoringOtherApps: true)
        let ok = panel.runModal() == .OK
        rug.holdEdit = false
        guard ok, let url = panel.url, let p = Pattern.importImage(url) else { return }
        patterns = Pattern.all()
        patternID = p.id
        applyPattern()
        refreshSwatches()
    }

    @objc func pickPattern(_ item: NSMenuItem) {
        guard let id = item.representedObject as? String else { return }
        patternID = id
        applyPattern()
        selectSwatch(id)
    }

    @objc func hideRug() {
        save()
        defaults.set(true, forKey: "hidden")
        rug.stowRug {}
    }

    @objc func showRug() {
        defaults.set(false, forKey: "hidden")
        rug.showAnimated(savedPlacement() ?? defaultPlacement())
    }

    @objc func resetRug() {
        defaults.set(false, forKey: "hidden")
        rug.showAnimated(defaultPlacement())
        save()
    }


    @objc func showTuning() {
        if tuningPanel == nil {
            let p = TuningPanel(tuning: rug.tuning)
            p.onChange = { [weak self] t, rebuild in self?.rug.apply(t, rebuild: rebuild) }
            p.center()
            tuningPanel = p
        }
        NSApp.activate(ignoringOtherApps: true)
        tuningPanel?.makeKeyAndOrderFront(nil)
    }

    // MARK: 選單列

    func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "rectangle.checkered", accessibilityDescription: "Desktop Rug")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let pat = NSMenuItem(title: L("花色", "Pattern"), action: nil, keyEquivalent: "")
        pat.submenu = patternMenu()
        menu.addItem(pat)
        menu.addItem(.separator())
        if rug.cloth == nil {
            menu.addItem(withTitle: L("鋪上地毯", "Lay Out the Rug"), action: #selector(showRug), keyEquivalent: "").target = self
        } else {
            menu.addItem(withTitle: L("收起地毯", "Put the Rug Away"), action: #selector(hideRug), keyEquivalent: "").target = self
        }
        menu.addItem(withTitle: L("地毯放回中間", "Move Rug to Center"), action: #selector(resetRug), keyEquivalent: "").target = self
        menu.addItem(withTitle: L("調整參數…", "Tune the Feel…"), action: #selector(showTuning), keyEquivalent: "").target = self

        menu.addItem(.separator())
        let hint = NSMenuItem(title: L("右鍵地毯或按住 ⌥：移動、縮放、換花色", "Right-click the rug or hold ⌥ to move, resize, restyle"), action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        menu.addItem(withTitle: L("結束", "Quit Desktop Rug"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    // MARK: 桌面圖示 → 凸起

    func pollIcons() {
        // Finder 關掉桌面圖示時不用問（也不會跳自動化權限）
        guard rug.demo == nil else { return }
        let finder = UserDefaults(suiteName: "com.apple.finder")
        if finder?.object(forKey: "CreateDesktop") != nil && finder?.bool(forKey: "CreateDesktop") == false {
            if lastIcons != nil { lastIcons = nil; rug.setFloor(nil) }
            return
        }
        let desk = rug.desktopBounds, mainHeight = rug.mainCamera.size.y
        iconQueue.async { [weak self] in
            guard let snap = DesktopIcons.read() else { return }
            DispatchQueue.main.async {
                guard let self, snap != self.lastIcons else { return }
                self.lastIcons = snap
                // Finder 座標：主螢幕左上原點、y 向下（其他螢幕的圖示也在同一個座標系裡）
                let lo = desk.origin, hi = desk.origin + desk.size
                let centers = snap.centers.map { SIMD2(Float($0.x), mainHeight - Float($0.y)) }
                    .filter { $0.x >= lo.x && $0.y >= lo.y && $0.x <= hi.x && $0.y <= hi.y }
                self.rug.setFloor(centers.isEmpty ? nil :
                    HeightField.fromIcons(centers, iconSize: Float(snap.iconSize), origin: desk.origin, size: desk.size))
            }
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
