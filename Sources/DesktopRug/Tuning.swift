import AppKit
import RugSim

/// 手感參數：存在 UserDefaults，面板拉桿即時套用到地毯上。
struct Tuning {
    var params = ClothParams()
    var columns: Float = 32
    var sideThickness: Float = 6
    var shadowAlpha: Float = 0.22
    var cornerRadius: Float = 16

    struct Knob {
        let key: String
        let title: String
        let range: ClosedRange<Float>
        let path: WritableKeyPath<Tuning, Float>
    }

    static let knobs: [Knob] = [
        Knob(key: "gravity", title: "重力", range: 1000...9000, path: \.params.gravity),
        Knob(key: "timeScale", title: "速度", range: 0.5...2.0, path: \.params.timeScale),
        Knob(key: "floorFriction", title: "地板摩擦", range: 0...0.6, path: \.params.floorFriction),
        Knob(key: "moveRigidity", title: "拖中間時整張跟著走", range: 0...1, path: \.params.moveRigidity),
        Knob(key: "dragFriction", title: "拖中間時地板摩擦", range: 0...0.4, path: \.params.dragFriction),
        Knob(key: "bend", title: "抗彎曲", range: 0...0.5, path: \.params.bend),
        Knob(key: "grabLift", title: "抓起高度", range: 5...150, path: \.params.grabLift),
        Knob(key: "grabFollow", title: "跟手速度", range: 0.03...1, path: \.params.grabFollow),
        Knob(key: "collisionScale", title: "疊層間距", range: 0.3...0.8, path: \.params.collisionScale),
        Knob(key: "columns", title: "格子數（橫向）", range: 16...56, path: \.columns),
        Knob(key: "sideThickness", title: "邊緣厚度", range: 0...20, path: \.sideThickness),
        Knob(key: "shadowAlpha", title: "陰影濃度", range: 0...0.6, path: \.shadowAlpha),
        Knob(key: "cornerRadius", title: "圓角", range: 0...80, path: \.cornerRadius),
    ]

    static func load() -> Tuning {
        var t = Tuning()
        let saved = UserDefaults.standard.dictionary(forKey: "tuning") as? [String: Double] ?? [:]
        for k in knobs { if let v = saved[k.key] { t[keyPath: k.path] = Float(v) } }
        return t
    }

    func save() {
        var d: [String: Double] = [:]
        for k in Tuning.knobs { d[k.key] = Double(self[keyPath: k.path]) }
        UserDefaults.standard.set(d, forKey: "tuning")
    }

    var asText: String {
        Tuning.knobs.map { "\($0.key) = \(Tuning.format(self[keyPath: $0.path]))" }.joined(separator: "\n")
    }

    static func format(_ v: Float) -> String {
        v == v.rounded() ? String(format: "%.0f", v) : String(format: "%.2f", v)
    }
}

/// 「調整參數…」面板：一列一個拉桿，改了立刻生效。
final class TuningPanel: NSPanel {
    private var sliders: [NSSlider] = []
    private var values: [NSTextField] = []
    var tuning: Tuning
    var onChange: ((Tuning, _ rebuild: Bool) -> Void)?

    init(tuning: Tuning) {
        self.tuning = tuning
        super.init(contentRect: NSRect(x: 0, y: 0, width: 420, height: 10),
                   styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
        title = "地毯參數"
        isFloatingPanel = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false

        var rows: [[NSView]] = []
        for (i, k) in Tuning.knobs.enumerated() {
            let label = NSTextField(labelWithString: k.title)
            label.alignment = .right
            let slider = NSSlider(value: Double(tuning[keyPath: k.path]), minValue: Double(k.range.lowerBound),
                                  maxValue: Double(k.range.upperBound), target: self, action: #selector(slid(_:)))
            slider.tag = i
            slider.widthAnchor.constraint(equalToConstant: 200).isActive = true
            let value = NSTextField(labelWithString: Tuning.format(tuning[keyPath: k.path]))
            value.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            value.widthAnchor.constraint(equalToConstant: 48).isActive = true
            sliders.append(slider); values.append(value)
            rows.append([label, slider, value])
        }
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 8
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing

        let reset = NSButton(title: "重設預設值", target: self, action: #selector(resetAll))
        let copy = NSButton(title: "複製數值", target: self, action: #selector(copyValues))
        let buttons = NSStackView(views: [reset, copy])
        let stack = NSStackView(views: [grid, buttons])
        stack.orientation = .vertical
        stack.alignment = .trailing
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        contentView = stack
        setContentSize(stack.fittingSize)
    }

    @objc private func slid(_ s: NSSlider) {
        let k = Tuning.knobs[s.tag]
        var v = Float(s.doubleValue)
        if k.key == "columns" { v = v.rounded() }
        tuning[keyPath: k.path] = v
        values[s.tag].stringValue = Tuning.format(v)
        tuning.save()
        // 格子數拖動時每一格都重建太頓，放開滑鼠才重建
        let up = NSApp.currentEvent?.type == .leftMouseUp
        onChange?(tuning, k.key == "columns" && up)
    }

    @objc private func resetAll() {
        tuning = Tuning()
        tuning.save()
        for (i, k) in Tuning.knobs.enumerated() {
            sliders[i].doubleValue = Double(tuning[keyPath: k.path])
            values[i].stringValue = Tuning.format(tuning[keyPath: k.path])
        }
        onChange?(tuning, true)
    }

    @objc private func copyValues() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(tuning.asText, forType: .string)
    }
}
