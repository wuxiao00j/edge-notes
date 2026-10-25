import SwiftUI
import AppKit

/// 可接收键盘输入的面板（borderless NSPanel 默认 canBecomeKey 常为 false，导致完全无法打字）。
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// 初版磨玻璃本色背景。
struct GlassBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blending
        v.state = .active
        v.isEmphasized = true
        return v
    }

    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material = material
        v.blendingMode = blending
        v.state = .active
    }
}

struct FrostedPanelBackground: View {
    /// nil / glass → 纯磨玻璃；其它颜色在玻璃上淡淡叠一层
    var tint: NoteColor? = nil

    var body: some View {
        ZStack {
            GlassBackground(material: .hudWindow, blending: .behindWindow)
            if let tint, tint.normalized != .glass {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(tint.fill.opacity(0.45))
            }
        }
    }
}


extension NSView {
    func findSubview<T: NSView>(ofType type: T.Type) -> T? {
        if let match = self as? T { return match }
        for child in subviews {
            if let found = child.findSubview(ofType: type) { return found }
        }
        return nil
    }
}
