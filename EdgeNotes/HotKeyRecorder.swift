import SwiftUI
import AppKit
import Carbon

extension HotKeyChord {
    static func from(event: NSEvent) -> HotKeyChord? {
        // Ignore pure modifier presses
        let keyCode = UInt32(event.keyCode)
        if keyCode == UInt32(kVK_Command) || keyCode == UInt32(kVK_Shift)
            || keyCode == UInt32(kVK_Option) || keyCode == UInt32(kVK_Control)
            || keyCode == UInt32(kVK_RightCommand) || keyCode == UInt32(kVK_RightShift)
            || keyCode == UInt32(kVK_RightOption) || keyCode == UInt32(kVK_RightControl) {
            return nil
        }
        var mods: UInt32 = 0
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) { mods |= UInt32(cmdKey) }
        if flags.contains(.option) { mods |= UInt32(optionKey) }
        if flags.contains(.shift) { mods |= UInt32(shiftKey) }
        if flags.contains(.control) { mods |= UInt32(controlKey) }
        guard mods != 0 else { return nil } // require at least one modifier
        return HotKeyChord(keyCode: keyCode, modifiers: mods, label: label(keyCode: keyCode, modifiers: mods))
    }

    static func label(keyCode: UInt32, modifiers: UInt32) -> String {
        var parts: [String] = []
        if modifiers & UInt32(controlKey) != 0 { parts.append("⌃") }
        if modifiers & UInt32(optionKey) != 0 { parts.append("⌥") }
        if modifiers & UInt32(shiftKey) != 0 { parts.append("⇧") }
        if modifiers & UInt32(cmdKey) != 0 { parts.append("⌘") }
        parts.append(keyName(keyCode))
        return parts.joined()
    }

    private static func keyName(_ keyCode: UInt32) -> String {
        let map: [UInt32: String] = [
            UInt32(kVK_ANSI_A): "A", UInt32(kVK_ANSI_B): "B", UInt32(kVK_ANSI_C): "C",
            UInt32(kVK_ANSI_D): "D", UInt32(kVK_ANSI_E): "E", UInt32(kVK_ANSI_F): "F",
            UInt32(kVK_ANSI_G): "G", UInt32(kVK_ANSI_H): "H", UInt32(kVK_ANSI_I): "I",
            UInt32(kVK_ANSI_J): "J", UInt32(kVK_ANSI_K): "K", UInt32(kVK_ANSI_L): "L",
            UInt32(kVK_ANSI_M): "M", UInt32(kVK_ANSI_N): "N", UInt32(kVK_ANSI_O): "O",
            UInt32(kVK_ANSI_P): "P", UInt32(kVK_ANSI_Q): "Q", UInt32(kVK_ANSI_R): "R",
            UInt32(kVK_ANSI_S): "S", UInt32(kVK_ANSI_T): "T", UInt32(kVK_ANSI_U): "U",
            UInt32(kVK_ANSI_V): "V", UInt32(kVK_ANSI_W): "W", UInt32(kVK_ANSI_X): "X",
            UInt32(kVK_ANSI_Y): "Y", UInt32(kVK_ANSI_Z): "Z",
            UInt32(kVK_ANSI_0): "0", UInt32(kVK_ANSI_1): "1", UInt32(kVK_ANSI_2): "2",
            UInt32(kVK_ANSI_3): "3", UInt32(kVK_ANSI_4): "4", UInt32(kVK_ANSI_5): "5",
            UInt32(kVK_ANSI_6): "6", UInt32(kVK_ANSI_7): "7", UInt32(kVK_ANSI_8): "8",
            UInt32(kVK_ANSI_9): "9",
            UInt32(kVK_Space): "空格", UInt32(kVK_Return): "↩", UInt32(kVK_Escape): "⎋",
            UInt32(kVK_Tab): "⇥", UInt32(kVK_Delete): "⌫",
        ]
        return map[keyCode] ?? "键\(keyCode)"
    }
}

struct HotKeyRecorderButton: View {
    let title: String
    @Binding var chord: HotKeyChord
    var onChange: () -> Void
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Button(recording ? "按下新快捷键…" : chord.label) {
                toggleRecording()
            }
            .buttonStyle(.bordered)
            .foregroundStyle(recording ? Color.accentColor : .primary)
            if recording {
                Button("取消") { stopRecording() }.buttonStyle(.borderless)
            }
        }
        .onDisappear { stopRecording() }
    }

    private func toggleRecording() {
        if recording { stopRecording() } else { startRecording() }
    }

    private func startRecording() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == UInt16(kVK_Escape) {
                DispatchQueue.main.async { stopRecording() }
                return nil
            }
            if let newChord = HotKeyChord.from(event: event) {
                DispatchQueue.main.async {
                    chord = newChord
                    onChange()
                    stopRecording()
                }
                return nil
            }
            return nil
        }
    }

    private func stopRecording() {
        recording = false
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }
}
