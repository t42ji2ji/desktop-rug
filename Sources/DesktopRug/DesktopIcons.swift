import AppKit

/// 向 Finder 問桌面上每個圖示的位置。Finder 關掉桌面圖示（CreateDesktop = false）時會拿到空的。
/// 座標是 Finder 的：主螢幕左上角為原點、y 向下，指圖示中心。
enum DesktopIcons {
    struct Snapshot: Equatable {
        var centers: [CGPoint]
        var iconSize: CGFloat
    }

    private static let script = NSAppleScript(source: """
    tell application "Finder"
        set out to ""
        repeat with p in (get desktop position of every item of desktop)
            try
                set out to out & (item 1 of p) & "," & (item 2 of p) & ";"
            end try
        end repeat
        set s to 64
        try
            set s to icon size of icon view options of window of desktop
        end try
        return (s as text) & "|" & out
    end tell
    """)

    /// 會卡住呼叫的 thread（Apple Event），在背景 queue 呼叫。
    static func read() -> Snapshot? {
        var err: NSDictionary?
        guard let s = script?.executeAndReturnError(&err).stringValue else { return nil }
        let parts = s.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let size = CGFloat(Double(parts[0]) ?? 64)
        let pts = parts[1].split(separator: ";").compactMap { pair -> CGPoint? in
            let xy = pair.split(separator: ",")
            guard xy.count == 2, let x = Double(xy[0]), let y = Double(xy[1]) else { return nil }
            return CGPoint(x: x, y: y)
        }
        return Snapshot(centers: pts, iconSize: size)
    }
}
