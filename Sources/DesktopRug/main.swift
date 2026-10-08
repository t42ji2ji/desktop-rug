import AppKit
import UniformTypeIdentifiers
import RugSim
import simd

/// 地毯花色：app bundle 的 Resources/patterns，加上使用者自己加的（Application Support/DesktopRug/patterns）。
struct Pattern {
    let id: String
    let url: URL
    var title: String { Pattern.title(for: id) }
    var isUserAdded: Bool { url.deletingLastPathComponent().standardizedFileURL == Pattern.userDir.standardizedFileURL }

    static let titles = [
        "persian-red": "波斯紅", "blue-tabriz": "大不里士藍", "beni-ourain": "摩洛哥白",
        "kilim": "基里姆", "sage-modern": "鼠尾草綠", "retro-check": "復古格紋",
        "pink-floral": "玫瑰古董", "pixel-space": "太空",
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
    var window: NSPanel!
    var view: RugView!
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
        // 主顯示器（有選單列、Finder 桌面座標的原點）
        let screen = NSScreen.screens[0]
        window = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                         backing: .buffered, defer: false)
        // 桌面圖示上面一層、一般視窗下面
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false

        view = RugView(frame: NSRect(origin: .zero, size: screen.frame.size), device: MTLCreateSystemDefaultDevice()!)
        view.autoresizingMask = [.width, .height]
        window.contentView = view
        window.setFrame(screen.frame, display: false)
        window.orderFrontRegardless()

        view.onChange = { [weak self] in self?.save() }
        view.overlay.onPick = { [weak self] id in self?.patternID = id; self?.applyPattern() }
        view.overlay.onDelete = { [weak self] id in self?.deletePattern(id) }
        view.overlay.addButton.target = self
        view.overlay.addButton.action = #selector(addLocalImage)
        refreshSwatches()
        view.overlay.trashButton.target = self
        view.overlay.trashButton.action = #selector(hideRug)

        applyPattern()
        if !defaults.bool(forKey: "hidden") { view.show(savedPlacement() ?? defaultPlacement()) }
        if let i = CommandLine.arguments.firstIndex(of: "--demo"), i + 1 < CommandLine.arguments.count {
            view.demo = CommandLine.arguments[i + 1]
        }
        view.start()
        if view.demo == "tuning" { showTuning() }

        setupStatusItem()
        pollIcons()
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.pollIcons() }

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            guard let self, let s = NSScreen.screens.first else { return }
            self.window.setFrame(s.frame, display: true)
            self.lastIcons = nil
        }
    }

    // MARK: 擺法存檔

    func defaultPlacement() -> RugPlacement {
        let s = view.viewSize
        let w = s.x * 0.42
        return RugPlacement(center: s * 0.5, angle: 0, size: SIMD2(w, w / 1.5))
    }

    func savedPlacement() -> RugPlacement? {
        guard let d = defaults.data(forKey: "placement") else { return nil }
        return try? JSONDecoder().decode(RugPlacement.self, from: d)
    }

    func save() {
        guard let p = view.placement, let d = try? JSONEncoder().encode(p) else { return }
        defaults.set(d, forKey: "placement")
    }

    // MARK: 花色

    func applyPattern() {
        guard let p = patterns.first(where: { $0.id == patternID }) ?? patterns.first else { return }
        view.setTexture(p.url)
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
        view.overlay.setPatterns(patterns.map { ($0.id, $0.url, $0.isUserAdded) }, selected: patternID)
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
        panel.message = "選一張圖片當地毯花色"
        view.holdEdit = true
        NSApp.activate(ignoringOtherApps: true)
        let ok = panel.runModal() == .OK
        view.holdEdit = false
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
        view.overlay.select(id)
    }

    @objc func hideRug() {
        save()
        defaults.set(true, forKey: "hidden")
        view.stowRug {}
    }

    @objc func showRug() {
        defaults.set(false, forKey: "hidden")
        view.show(savedPlacement() ?? defaultPlacement())
    }

    @objc func resetRug() {
        defaults.set(false, forKey: "hidden")
        view.show(defaultPlacement())
        save()
    }

    @objc func showTuning() {
        if tuningPanel == nil {
            let p = TuningPanel(tuning: view.tuning)
            p.onChange = { [weak self] t, rebuild in self?.view.apply(t, rebuild: rebuild) }
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
        let pat = NSMenuItem(title: "花色", action: nil, keyEquivalent: "")
        pat.submenu = patternMenu()
        menu.addItem(pat)
        menu.addItem(.separator())
        if view.cloth == nil {
            menu.addItem(withTitle: "鋪上地毯", action: #selector(showRug), keyEquivalent: "").target = self
        } else {
            menu.addItem(withTitle: "收起地毯", action: #selector(hideRug), keyEquivalent: "").target = self
        }
        menu.addItem(withTitle: "地毯放回中間", action: #selector(resetRug), keyEquivalent: "").target = self
        menu.addItem(withTitle: "調整參數…", action: #selector(showTuning), keyEquivalent: "").target = self
        menu.addItem(.separator())
        let hint = NSMenuItem(title: "右鍵地毯或按住 ⌥：移動、縮放、換花色", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        menu.addItem(withTitle: "結束", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    // MARK: 桌面圖示 → 凸起

    func pollIcons() {
        // Finder 關掉桌面圖示時不用問（也不會跳自動化權限）
        guard view.demo == nil else { return }
        let finder = UserDefaults(suiteName: "com.apple.finder")
        if finder?.object(forKey: "CreateDesktop") != nil && finder?.bool(forKey: "CreateDesktop") == false {
            if lastIcons != nil { lastIcons = nil; view.setFloor(nil) }
            return
        }
        let size = view.viewSize
        iconQueue.async { [weak self] in
            guard let snap = DesktopIcons.read() else { return }
            DispatchQueue.main.async {
                guard let self, snap != self.lastIcons else { return }
                self.lastIcons = snap
                // Finder 座標：主螢幕左上原點、y 向下
                let centers = snap.centers.map { SIMD2(Float($0.x), size.y - Float($0.y)) }
                    .filter { $0.x >= 0 && $0.y >= 0 && $0.x <= size.x && $0.y <= size.y }
                self.view.setFloor(centers.isEmpty ? nil :
                    HeightField.fromIcons(centers, iconSize: Float(snap.iconSize), origin: .zero, size: size))
            }
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
