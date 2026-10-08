import AppKit
import RugSim

/// 按著 ⌥ 時疊在地毯上的控制點、角度標籤、下方的「花色／刪除」工具列。
final class EditOverlay: NSView {
    private var placement: RugPlacement?
    private var activeCorner: Int?
    private var angleLabel: String?
    private var cursor = CGPoint.zero
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

    func update(placement: RugPlacement?, activeCorner: Int?, angleLabel: String?, cursor: CGPoint) {
        self.placement = placement
        self.activeCorner = activeCorner
        self.angleLabel = angleLabel
        self.cursor = cursor
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
        if let label = angleLabel {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.white,
            ]
            let s = NSAttributedString(string: label, attributes: attrs)
            let size = s.size()
            let box = NSRect(x: cursor.x + 14, y: cursor.y - 22, width: size.width + 12, height: size.height + 6)
            NSColor.black.withAlphaComponent(0.7).setFill()
            NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5).fill()
            s.draw(at: NSPoint(x: box.minX + 6, y: box.minY + 3))
        }
    }
}
