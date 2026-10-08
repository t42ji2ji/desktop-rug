import AppKit
import RugSim

/// 編輯模式（右鍵或按著 ⌥）疊在地毯上的控制點，和下方一排花色縮圖（最後是「＋」加本機圖片、收起）。
final class EditOverlay: NSView {
    private var placement: RugPlacement?
    private var activeCorner: Int?
    let toolbar = NSVisualEffectView()
    private let row = NSStackView()
    let trashButton = NSButton()
    let addButton = NSButton()
    var onPick: ((String) -> Void)?
    var onDelete: ((String) -> Void)?
    private var swatches: [(id: String, button: NSButton)] = []

    static let swatchSize = NSSize(width: 54, height: 36)

    override init(frame: NSRect) {
        super.init(frame: frame)
        toolbar.material = .hudWindow
        toolbar.blendingMode = .behindWindow
        toolbar.state = .active
        toolbar.wantsLayer = true
        toolbar.layer?.cornerRadius = 12
        toolbar.layer?.masksToBounds = true
        toolbar.isHidden = true

        addButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "加入本機圖片")
        trashButton.image = NSImage(systemSymbolName: "trash", accessibilityDescription: "收起地毯")
        for b in [addButton, trashButton] {
            b.isBordered = false
            b.imagePosition = .imageOnly
            b.contentTintColor = .labelColor
        }
        addButton.wantsLayer = true
        addButton.layer?.cornerRadius = 4
        addButton.layer?.borderWidth = 1
        addButton.layer?.borderColor = NSColor.secondaryLabelColor.cgColor
        addButton.widthAnchor.constraint(equalToConstant: Self.swatchSize.width).isActive = true
        addButton.heightAnchor.constraint(equalToConstant: Self.swatchSize.height).isActive = true
        trashButton.widthAnchor.constraint(equalToConstant: 28).isActive = true

        row.orientation = .horizontal
        row.spacing = 6
        row.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        toolbar.addSubview(row)
        addSubview(toolbar)
    }

    /// 重建花色縮圖列。
    func setPatterns(_ items: [(id: String, url: URL, removable: Bool)], selected: String) {
        for v in row.arrangedSubviews { row.removeArrangedSubview(v); v.removeFromSuperview() }
        swatches = []
        for item in items {
            let b = NSButton()
            b.isBordered = false
            b.imagePosition = .imageOnly
            b.imageScaling = .scaleAxesIndependently
            if let img = NSImage(contentsOf: item.url) { img.size = Self.swatchSize; b.image = img }
            b.toolTip = Pattern.title(for: item.id)
            b.target = self
            b.action = #selector(picked(_:))
            b.wantsLayer = true
            b.layer?.cornerRadius = 4
            b.layer?.masksToBounds = true
            b.widthAnchor.constraint(equalToConstant: Self.swatchSize.width).isActive = true
            b.heightAnchor.constraint(equalToConstant: Self.swatchSize.height).isActive = true
            swatches.append((item.id, b))
            row.addArrangedSubview(b)
            if item.removable {
                // 自己加的圖右上角有 ×
                let x = NSButton()
                x.isBordered = false
                x.imagePosition = .imageOnly
                x.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "刪除這個花色")
                x.contentTintColor = .white
                x.toolTip = "刪除這個花色"
                x.target = self
                x.action = #selector(deleted(_:))
                x.identifier = NSUserInterfaceItemIdentifier(item.id)
                x.translatesAutoresizingMaskIntoConstraints = false
                b.addSubview(x)
                NSLayoutConstraint.activate([
                    x.topAnchor.constraint(equalTo: b.topAnchor, constant: 1),
                    x.trailingAnchor.constraint(equalTo: b.trailingAnchor, constant: -1),
                    x.widthAnchor.constraint(equalToConstant: 14), x.heightAnchor.constraint(equalToConstant: 14),
                ])
            }
        }
        row.addArrangedSubview(addButton)
        let divider = NSBox()
        divider.boxType = .separator
        divider.heightAnchor.constraint(equalToConstant: 24).isActive = true
        row.addArrangedSubview(divider)
        row.addArrangedSubview(trashButton)
        select(selected)
        row.layoutSubtreeIfNeeded()
        let size = row.fittingSize
        row.frame = NSRect(origin: .zero, size: size)
        toolbar.frame.size = size
    }

    func select(_ id: String) {
        for s in swatches {
            s.button.layer?.borderWidth = s.id == id ? 2.5 : 0
            s.button.layer?.borderColor = NSColor.controlAccentColor.cgColor
        }
    }

    @objc private func deleted(_ b: NSButton) {
        if let id = b.identifier?.rawValue { onDelete?(id) }
    }

    @objc private func picked(_ b: NSButton) {
        guard let id = swatches.first(where: { $0.button === b })?.id else { return }
        select(id)
        onPick?(id)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// 只有工具列吃滑鼠，其他地方穿透給底下的 RugView。
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let v = super.hitTest(point), v !== self else { return nil }
        return v
    }

    func toolbarHit(_ p: CGPoint) -> Bool { !toolbar.isHidden && toolbar.frame.contains(p) }

    func update(placement: RugPlacement?, activeCorner: Int?, showToolbar: Bool) {
        self.placement = placement
        self.activeCorner = activeCorner
        if let p = placement, showToolbar {
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
