import AppKit
import RugSim
import simd

/// 地毯花色：app bundle 的 Resources/patterns/*.png。
struct Pattern {
    let id: String
    let url: URL
    var title: String { Pattern.titles[id] ?? id }

    static let titles = [
        "persian-red": "波斯紅", "blue-tabriz": "大不里士藍", "beni-ourain": "摩洛哥白",
        "kilim": "基里姆", "sage-modern": "鼠尾草綠", "retro-check": "復古格紋",
        "pink-floral": "玫瑰古董", "pixel-space": "太空",
    ]

    static func all() -> [Pattern] {
        let dirs = [Bundle.main.resourceURL?.appendingPathComponent("patterns"),
                    URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("patterns")]
        for case let dir? in dirs {
            let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            let pngs = files.filter { $0.pathExtension.lowercased() == "png" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            if !pngs.isEmpty {
                let list = pngs.map { Pattern(id: $0.deletingPathExtension().lastPathComponent, url: $0) }
                // 波斯紅（原作那款）排第一
                return list.sorted { ($0.id == "persian-red" ? 0 : 1, $0.id) < ($1.id == "persian-red" ? 0 : 1, $1.id) }
            }
        }
        return []
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var window: NSPanel!
    var view: RugView!
    var statusItem: NSStatusItem!
    let patterns = Pattern.all()
    let defaults = UserDefaults.standard
    let iconQueue = DispatchQueue(label: "desktop-icons")
    var lastIcons: DesktopIcons.Snapshot?

    var patternID: String {
        get { defaults.string(forKey: "pattern") ?? patterns.first?.id ?? "" }
        set { defaults.set(newValue, forKey: "pattern") }
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        let screen = NSScreen.main!
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
        view.overlay.designButton.target = self
        view.overlay.designButton.action = #selector(showPatternMenu(_:))
        view.overlay.trashButton.target = self
        view.overlay.trashButton.action = #selector(hideRug)

        applyPattern()
        if !defaults.bool(forKey: "hidden") { view.show(savedPlacement() ?? defaultPlacement()) }
        view.start()

        setupStatusItem()
        pollIcons()
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.pollIcons() }

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            guard let self, let s = NSScreen.main else { return }
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

    @objc func showPatternMenu(_ sender: NSButton) {
        patternMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc func pickPattern(_ item: NSMenuItem) {
        guard let id = item.representedObject as? String else { return }
        patternID = id
        applyPattern()
    }

    @objc func hideRug() {
        save()
        view.hideRug()
        defaults.set(true, forKey: "hidden")
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
        menu.addItem(.separator())
        let hint = NSMenuItem(title: "按住 ⌥ 可移動、旋轉、縮放", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        menu.addItem(withTitle: "結束", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    // MARK: 桌面圖示 → 凸起

    func pollIcons() {
        // Finder 關掉桌面圖示時不用問（也不會跳自動化權限）
        if UserDefaults(suiteName: "com.apple.finder")?.object(forKey: "CreateDesktop") as? Bool == false {
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
