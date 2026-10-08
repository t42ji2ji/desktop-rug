import AppKit
import RugSim

/// 編輯模式（右鍵或按著 ⌥）疊在地毯上的控制點、下方的「花色／收起」工具列。
final class EditOverlay: NSView {
    private var placement: RugPlacement?
    private var activeCorner: Int?
    let toolbar = NSVisualEffectView()
    let designButton = NSButton()
    let trashButton = NSButton()

    override init(frame: NSRect) {
        super.init(frame: frame)
        toolbar.material = .hudWindow
        toolbar.blendingMode = .behindWindow
        toolbar.state = .active
        toolbar.wantsLayer = true
        toolbar.layer?.cornerRadius = 15
        toolbar.layer?.masksToBounds = true
        toolbar.isHidden = true

        designButton.title = "花色"
        designButton.image = NSImage(systemSymbolName: "paintbrush.pointed", accessibilityDescription: "花色")
        designButton.imagePosition = .imageLeading
        trashButton.image = NSImage(systemSymbolName: "trash", accessibilityDescription: "收起地毯")
        trashButton.imagePosition = .imageOnly
        for b in [designButton, trashButton] {
            b.isBordered = false
            b.font = .systemFont(ofSize: 12, weight: .medium)
            b.contentTintColor = .labelColor
            toolbar.addSubview(b)
        }
        let divider = NSBox(frame: NSRect(x: 76, y: 7, width: 1, height: 16))
        divider.boxType = .separator
        toolbar.addSubview(divider)
        designButton.frame = NSRect(x: 8, y: 3, width: 64, height: 24)
        trashButton.frame = NSRect(x: 82, y: 3, width: 28, height: 24)
        toolbar.frame.size = NSSize(width: 118, height: 30)
        addSubview(toolbar)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// 只有工具列吃滑鼠，其他地方穿透給底下的 RugView。
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let v = super.hitTest(point), v !== self else { return nil }
        return v
    }

    func toolbarHit(_ p: CGPoint) -> Bool { !toolbar.isHidden && toolbar.frame.contains(p) }

    func update(placement: RugPlacement?, activeCorner: Int?) {
        self.placement = placement
        self.activeCorner = activeCorner
        if let p = placement {
            let lowest = p.corners.map(\.y).min()!
            toolbar.setFrameOrigin(NSPoint(x: CGFloat(p.center.x) - toolbar.frame.width / 2,
                                           y: CGFloat(lowest) - 26 - toolbar.frame.height))
            toolbar.isHidden = false
        } else {
            toolbar.isHidden = true
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let p = placement else { return }
        for (k, c) in p.corners.enumerated() {
            let r: CGFloat = 4.5
            let dot = NSBezierPath(ovalIn: NSRect(x: CGFloat(c.x) - r, y: CGFloat(c.y) - r, width: r * 2, height: r * 2))
            (k == activeCorner ? NSColor.controlAccentColor : .white).setFill()
            dot.fill()
            NSColor.black.withAlphaComponent(0.35).setStroke()
            dot.lineWidth = 0.75
            dot.stroke()
        }
    }
}
