import AppKit
import RugSim

/// 編輯模式（右鍵或按著 ⌥）疊在地毯上的控制點，和下方一排花色縮圖（最後是「＋」加本機圖片、收起）。
final class EditOverlay: NSView {
    private var placement: RugPlacement?
    private var activeCorner: Int?
    let toolbar = NSVisualEffectView()
    private let row = NSStackView()
    private let catRow = NSStackView()
    private let rows = NSStackView()
    var onToggleCat: ((String) -> Void)?
    private var catButtons: [(name: String, button: NSButton)] = []
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

        addButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: L("加入本機圖片", "Add your own image"))
        trashButton.image = NSImage(systemSymbolName: "trash", accessibilityDescription: L("收起地毯", "Put the rug away"))
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
        catRow.orientation = .horizontal
        catRow.spacing = 6
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 6
        rows.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        rows.addArrangedSubview(row)
        rows.addArrangedSubview(catRow)
        toolbar.addSubview(rows)
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
                x.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: L("刪除這個花色", "Delete this pattern"))
                x.contentTintColor = .white
                x.toolTip = L("刪除這個花色", "Delete this pattern")
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
        relayout()
    }

    private func relayout() {
        rows.layoutSubtreeIfNeeded()
        let size = rows.fittingSize
        rows.frame = NSRect(origin: .zero, size: size)
        toolbar.frame.size = size
    }

    /// 第二列：每隻貓一個頭像，點了切換顯示
    func setCats(_ items: [(name: String, image: NSImage)], visible: Set<String>) {
        for v in catRow.arrangedSubviews { catRow.removeArrangedSubview(v); v.removeFromSuperview() }
        catButtons = []
        for item in items {
            let b = NSButton()
            b.isBordered = false
            b.imagePosition = .imageOnly
            b.imageScaling = .scaleProportionallyUpOrDown
            b.image = item.image
            b.target = self
            b.action = #selector(catToggled(_:))
            b.wantsLayer = true
            b.layer?.cornerRadius = 6
            b.layer?.borderColor = NSColor.controlAccentColor.cgColor
            b.widthAnchor.constraint(equalToConstant: 48).isActive = true
            b.heightAnchor.constraint(equalToConstant: 36).isActive = true
            catButtons.append((item.name, b))
            catRow.addArrangedSubview(b)
        }
        showCats(visible)
        relayout()
    }

    func showCats(_ visible: Set<String>) {
        for c in catButtons {
            let on = visible.contains(c.name)
            c.button.layer?.borderWidth = on ? 2.5 : 0
            c.button.alphaValue = on ? 1 : 0.4
        }
    }

    @objc private func catToggled(_ b: NSButton) {
        if let name = catButtons.first(where: { $0.button === b })?.name { onToggleCat?(name) }
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
