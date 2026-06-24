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
            .padding(.vertical, 10)
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
                    .frame(width: 88, height: 30)
            }
            .offset(x: -8)
        case .message:
            Text(model.message)
                .font(.caption.weight(.medium))
                .foregroundStyle(.black.opacity(0.88))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
    }

    private var recordingDot: some View {
        let recordingGreen = Color(red: 0.18, green: 0.95, blue: 0.43)

        return Circle()
            .fill(
                RadialGradient(
                    colors: [
                        Color.white.opacity(0.85),
                        recordingGreen,
                        recordingGreen.opacity(0.92)
                    ],
                    center: .center,
                    startRadius: 0,
                    endRadius: 4
                )
            )
            .frame(width: 8, height: 8)
            .shadow(color: recordingGreen.opacity(0.88), radius: 6)
            .shadow(color: recordingGreen.opacity(0.42), radius: 13)
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
        HStack(alignment: .center, spacing: Self.dotSpacing) {
            ForEach(0..<Self.columnCount, id: \.self) { column in
                VStack(spacing: Self.dotSpacing) {
                    ForEach(0..<Self.rowCount, id: \.self) { row in
                        Circle()
                            .fill(Color.primary.opacity(dotOpacity(column: column, row: row)))
                            .frame(width: Self.dotSize, height: Self.dotSize)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private func dotOpacity(column: Int, row: Int) -> Double {
        let clampedLevel = min(max(level, 0), 1)
        let pulse = CGFloat((sin(time * 5.8) + 1) / 2)
        let activity = 0.38 + clampedLevel * 0.62
        let litColumns = CGFloat(Self.columnCount - 1) * (0.32 + activity * (0.36 + pulse * 0.24))
        let columnPosition = CGFloat(column)
        let headDistance = abs(columnPosition - litColumns)
        let rowDistance = abs(CGFloat(row) - 1)
        let body = columnPosition <= litColumns ? CGFloat(0.56) : CGFloat(0.10)
        let head = max(0, 1 - headDistance / 2.1) * 0.36
        let tail = max(0, 1 - max(columnPosition - litColumns, 0) / 2.8) * 0.18
        let rowWeight = rowDistance == 0 ? CGFloat(1.0) : CGFloat(0.52)
        let shimmer = CGFloat((sin(time * 7.0 + Double(column) * 0.42) + 1) / 2)
        let opacity = (body + head + tail) * rowWeight * (0.84 + shimmer * 0.16)

        return Double(min(max(opacity, 0.08), 0.96))
    }

    private static let columnCount = 14
    private static let rowCount = 3
    private static let dotSize: CGFloat = 3.2
    private static let dotSpacing: CGFloat = 3
}
