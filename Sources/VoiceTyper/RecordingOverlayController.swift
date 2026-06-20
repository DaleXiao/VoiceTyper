import AppKit
import SwiftUI

final class RecordingOverlayController {
    fileprivate enum Layout {
        static let width: CGFloat = 208
        static let height: CGFloat = 52
    }
    fileprivate enum Refresh {
        static let interval: TimeInterval = 1.0 / 12.0
    }

    private let model = RecordingOverlayModel()
    private var panel: NSPanel?
    private var timer: Timer?
    private var levelProvider: (() -> CGFloat)?

    func prepare() {
        guard panel == nil else {
            return
        }

        let panel = makePanel()
        self.panel = panel
        position(panel)
    }

    func showRecording(
        streaming: Bool,
        levelProvider: @escaping () -> CGFloat
    ) {
        self.levelProvider = levelProvider
        model.phase = .recording
        model.animationTime = ProcessInfo.processInfo.systemUptime
        showPanel()
        startTimer()
    }

    func showMessage(_ message: String) {
        timer?.invalidate()
        timer = nil
        levelProvider = nil
        model.phase = .message
        model.message = message
        model.level = 0
        model.animationTime = 0
        showPanel()

        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            if self?.model.phase == .message {
                self?.hide()
            }
        }
    }

    func hide() {
        timer?.invalidate()
        timer = nil
        levelProvider = nil
        model.message = ""
        model.level = 0
        model.animationTime = 0
        panel?.orderOut(nil)
    }

    private func showPanel() {
        let panel = panel ?? makePanel()
        self.panel = panel
        position(panel)
        panel.orderFrontRegardless()
    }

    private func startTimer() {
        timer?.invalidate()
        let timer = Timer(timeInterval: Refresh.interval, repeats: true) { [weak self] _ in
            guard let self else {
                return
            }

            let level = self.levelProvider?() ?? 0
            self.model.animationTime = ProcessInfo.processInfo.systemUptime
            if abs(self.model.level - level) > 0.01 {
                self.model.level = level
            }
        }
        timer.tolerance = Refresh.interval * 0.25
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Layout.width, height: Layout.height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let hostingView = NSHostingView(rootView: RecordingOverlayView(model: model))
        hostingView.frame = NSRect(x: 0, y: 0, width: Layout.width, height: Layout.height)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = hostingView
        return panel
    }

    private func position(_ panel: NSPanel) {
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let screen else {
            return
        }

        let frame = screen.visibleFrame
        let size = panel.frame.size
        let origin = NSPoint(x: frame.midX - size.width / 2, y: frame.minY + 18)
        panel.setFrameOrigin(origin)
    }
}

final class RecordingOverlayModel: ObservableObject {
    @Published var phase: RecordingOverlayPhase = .recording
    @Published var message: String = ""
    @Published var level: CGFloat = 0
    @Published var animationTime: TimeInterval = 0
}

enum RecordingOverlayPhase {
    case recording
    case processing
    case message
}

private struct RecordingOverlayView: View {
    @ObservedObject var model: RecordingOverlayModel

    var body: some View {
        content(time: model.animationTime)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(CapsuleMaterialBackground())
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(Color.white.opacity(0.20), lineWidth: 1)
            )
        .frame(width: RecordingOverlayController.Layout.width, height: RecordingOverlayController.Layout.height)
    }

    @ViewBuilder
    private func content(time: TimeInterval) -> some View {
        switch model.phase {
        case .recording, .processing:
            HStack(spacing: 12) {
                recordingDot
                    .frame(width: 22, height: 22)

                WaveformBars(level: model.level, time: time)
                    .frame(width: 76, height: 26)
            }
        case .message:
            Text(model.message)
                .font(.caption.weight(.medium))
                .foregroundStyle(.white.opacity(0.94))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
    }

    private var recordingDot: some View {
        Circle()
            .fill(Color.red)
            .frame(width: 9, height: 9)
            .shadow(color: .red.opacity(0.55), radius: 7)
    }

}

private struct CapsuleMaterialBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> CapsuleVisualEffectView {
        let view = CapsuleVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.wantsLayer = true
        view.layer?.masksToBounds = true
        return view
    }

    func updateNSView(_ nsView: CapsuleVisualEffectView, context: Context) {}
}

private final class CapsuleVisualEffectView: NSVisualEffectView {
    private var lastMaskSize: NSSize = .zero

    override func layout() {
        super.layout()
        wantsLayer = true
        layer?.cornerRadius = bounds.height / 2
        layer?.masksToBounds = true
        updateMaskImageIfNeeded()
    }

    private func updateMaskImageIfNeeded() {
        guard bounds.size.width > 0,
              bounds.size.height > 0,
              bounds.size != lastMaskSize else {
            return
        }

        lastMaskSize = bounds.size
        maskImage = Self.capsuleMaskImage(size: bounds.size)
    }

    private static func capsuleMaskImage(size: NSSize) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.black.setFill()
        NSBezierPath(
            roundedRect: NSRect(origin: .zero, size: size),
            xRadius: size.height / 2,
            yRadius: size.height / 2
        ).fill()
        image.unlockFocus()
        image.isTemplate = true
        return image
    }
}

private struct WaveformBars: View {
    let level: CGFloat
    let time: TimeInterval

    var body: some View {
        HStack(alignment: .center, spacing: 4) {
            ForEach(0..<9, id: \.self) { index in
                RoundedRectangle(cornerRadius: 2.5)
                    .fill(Color.white.opacity(0.92))
                    .frame(width: 4.5, height: height(for: index))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private func height(for index: Int) -> CGFloat {
        let phase = sin(time * 8.0 + Double(index) * 0.72)
        let ripple = CGFloat((phase + 1) / 2)
        let envelope = 0.35 + level * 0.65
        let shape = CGFloat([0.35, 0.52, 0.78, 0.48, 1.0, 0.48, 0.78, 0.52, 0.35][index])
        return 6 + 20 * envelope * (0.38 + ripple * 0.62) * shape
    }
}
