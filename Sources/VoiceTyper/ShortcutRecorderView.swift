import AppKit
import SwiftUI

struct ShortcutRecorderView: View {
    @Binding var shortcut: RecordingShortcut
    let onChange: () -> Void

    @State private var isRecording = false
    @State private var monitor: Any?
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(shortcut.displayName)
                    .font(.system(.body, design: .monospaced).weight(.semibold))
                    .frame(minWidth: 116, alignment: .leading)

                Button(isRecording ? "按下新的快捷键" : "录制快捷键") {
                    if isRecording {
                        stopRecording()
                    } else {
                        startRecording()
                    }
                }

                if isRecording {
                    Button("取消") {
                        stopRecording()
                    }
                    .buttonStyle(.link)
                }

                Button("恢复默认 fn") {
                    resetToDefault()
                }
                .buttonStyle(.link)
                .disabled(shortcut == .functionKey && !isRecording)
            }

            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onDisappear {
            stopRecording()
        }
    }

    private func startRecording() {
        stopRecording()
        isRecording = true
        message = "按 fn，或按一个带 ⌘/⌥/⌃/⇧ 的组合键。"

        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            if let newShortcut = RecordingShortcut.from(event: event) {
                shortcut = newShortcut
                message = "已设置为 \(newShortcut.displayName)"
                stopRecording()
                onChange()
                return nil
            }

            if event.type == .keyDown {
                message = "普通按键需要配合 ⌘/⌥/⌃/⇧；fn 可以单独使用。"
                return nil
            }

            return event
        }
    }

    private func stopRecording() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        isRecording = false
    }

    private func resetToDefault() {
        stopRecording()
        shortcut = .functionKey
        message = "已恢复为 fn"
        onChange()
    }
}
