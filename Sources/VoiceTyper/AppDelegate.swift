import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = UserSettings()
    private let recorder = AudioRecorder()
    private let client = TranscriptionClient()
    private let modelCatalogClient = ModelCatalogClient()
    private let vocabularyGenerator = VocabularyGenerator()
    private let outputController = OutputController()
    private let hotKeyManager = HotKeyManager()
    private let shortcutGestureMonitor = ShortcutGestureMonitor()
    private let recordingOverlay = RecordingOverlayController()

    private var statusItem: NSStatusItem?
    private var startStopItem: NSMenuItem?
    private var statusMenuItem: NSMenuItem?
    private var lastResultItem: NSMenuItem?
    private var lastTimingItem: NSMenuItem?
    private var lastTimingTitle = "耗时：暂无"
    private var settingsWindow: NSWindow?
    private var recordingMode: RecordingMode?
    private var activeRecordingSnapshot: SettingsSnapshot?
    private var activeRealtimeSession: RealtimeTranscriptionSession?
    private var pendingRealtimeStopAfterStart = false
    private var pendingShortcutTapRelease = false
    private var pendingShortcutHoldRecognition = false
    private var pendingShortcutHoldEnd = false
    private var state: AppState = .idle {
        didSet { updateMenu() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        applyDockIconVisibility()
        outputController.updateLastExternalApplication(NSWorkspace.shared.frontmostApplication)
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(frontmostApplicationChanged(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )

        setupApplicationMenu()
        setupMenuBar()
        configureRecordingShortcut()
        updateMenu()
        recordingOverlay.prepare()

        if !settings.isConfigured {
            showSettings()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        hotKeyManager.unregister()
        shortcutGestureMonitor.stop()
        activeRealtimeSession?.cancel()
        recorder.cancel()
        recordingOverlay.hide()
    }

    @objc private func toggleRecordingAction() {
        Task { @MainActor [weak self] in
            await self?.toggleRecording()
        }
    }

    @objc private func showSettingsAction() {
        showSettings()
    }

    @objc private func requestAccessibilityAction() {
        _ = PermissionCenter.promptForAccessibilityPermission()
        PermissionCenter.openAccessibilitySettings()
    }

    @objc private func requestMicrophoneAction() {
        Task { @MainActor in
            _ = await PermissionCenter.requestMicrophoneAccess(openSettingsIfDenied: true)
        }
    }

    @objc private func requestInputMonitoringAction() {
        _ = PermissionCenter.promptForInputMonitoringPermission()
        PermissionCenter.openInputMonitoringSettings()
    }

    @objc private func quitAction() {
        NSApp.terminate(nil)
    }

    @objc private func frontmostApplicationChanged(_ notification: Notification) {
        outputController.updateLastExternalApplication(
            notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        )
    }

    private func setupMenuBar() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "mic", accessibilityDescription: "说入法")
        item.button?.imagePosition = .imageLeading
        item.button?.target = self
        item.button?.action = #selector(toggleRecordingAction)

        let menu = NSMenu()
        let status = NSMenuItem(title: "待命", action: nil, keyEquivalent: "")
        status.isEnabled = false
        statusMenuItem = status
        menu.addItem(status)

        menu.addItem(.separator())

        let startStop = NSMenuItem(
            title: "开始录音  \(triggerDescription)",
            action: #selector(toggleRecordingAction),
            keyEquivalent: ""
        )
        startStop.target = self
        startStopItem = startStop
        menu.addItem(startStop)

        let lastResult = NSMenuItem(title: "最近结果：无", action: nil, keyEquivalent: "")
        lastResult.isEnabled = false
        lastResultItem = lastResult
        menu.addItem(lastResult)

        let lastTiming = NSMenuItem(title: lastTimingTitle, action: nil, keyEquivalent: "")
        lastTiming.isEnabled = false
        lastTimingItem = lastTiming
        menu.addItem(lastTiming)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "设置...", action: #selector(showSettingsAction), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let microphoneItem = NSMenuItem(title: "麦克风权限", action: #selector(requestMicrophoneAction), keyEquivalent: "")
        microphoneItem.target = self
        menu.addItem(microphoneItem)

        let accessibilityItem = NSMenuItem(title: "辅助功能权限", action: #selector(requestAccessibilityAction), keyEquivalent: "")
        accessibilityItem.target = self
        menu.addItem(accessibilityItem)

        let inputMonitoringItem = NSMenuItem(title: "输入监控权限", action: #selector(requestInputMonitoringAction), keyEquivalent: "")
        inputMonitoringItem.target = self
        menu.addItem(inputMonitoringItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "退出 说入法", action: #selector(quitAction), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        item.menu = menu
        statusItem = item
    }

    private func setupApplicationMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem(title: "说入法", action: nil, keyEquivalent: "")
        mainMenu.addItem(appMenuItem)

        let appMenu = NSMenu()
        let aboutItem = NSMenuItem(
            title: "关于 说入法",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        aboutItem.target = NSApp
        appMenu.addItem(aboutItem)
        appMenu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "设置...", action: #selector(showSettingsAction), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        appMenu.addItem(.separator())

        let quitItem = NSMenuItem(title: "退出 说入法", action: #selector(quitAction), keyEquivalent: "q")
        quitItem.target = self
        appMenu.addItem(quitItem)
        mainMenu.setSubmenu(appMenu, for: appMenuItem)

        let editMenuItem = NSMenuItem(title: "编辑", action: nil, keyEquivalent: "")
        mainMenu.addItem(editMenuItem)

        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(NSMenuItem(title: "撤销", action: Selector(("undo:")), keyEquivalent: "z"))
        editMenu.addItem(NSMenuItem(title: "重做", action: Selector(("redo:")), keyEquivalent: "Z"))
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        mainMenu.setSubmenu(editMenu, for: editMenuItem)

        NSApp.mainMenu = mainMenu
    }

    private func registerHotKey() {
        hotKeyManager.unregister()
    }

    private func configureRecordingShortcut() {
        registerHotKey()
        shortcutGestureMonitor.stop()

        shortcutGestureMonitor.start(
            shortcut: settings.recordingShortcut,
            shortcutEventsEnabled: true,
            holdEnabled: settings.holdToRecordEnabled,
            onPressBegan: { [weak self] in
                Task { @MainActor in
                    await self?.shortcutPressBegan()
                }
            },
            onTap: { [weak self] in
                Task { @MainActor in
                    self?.shortcutTapReleased()
                }
            },
            onHoldBegan: { [weak self] in
                Task { @MainActor in
                    self?.shortcutHoldRecognized()
                }
            },
            onHoldEnded: { [weak self] in
                Task { @MainActor in
                    await self?.shortcutHoldEnded()
                }
            },
            onCancel: { [weak self] in
                Task { @MainActor in
                    self?.cancelRecording()
                }
            }
        )
    }

    private func showSettings() {
        if let settingsWindow {
            settingsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let root = SettingsView(
            settings: settings,
            fetchModels: { [settings, modelCatalogClient] in
                let snapshot = try settings.modelCatalogSnapshot()
                return try await modelCatalogClient.fetchModels(settings: snapshot)
            },
            hotKeyChanged: { [weak self] in
                self?.configureRecordingShortcut()
                self?.updateMenu()
            },
            dockIconChanged: { [weak self] in
                self?.applyDockIconVisibility()
            },
            requestMicrophone: {
                Task { @MainActor in
                    _ = await PermissionCenter.requestMicrophoneAccess(openSettingsIfDenied: true)
                }
            },
            requestAccessibility: {
                _ = PermissionCenter.promptForAccessibilityPermission()
                PermissionCenter.openAccessibilitySettings()
            },
            requestInputMonitoring: {
                _ = PermissionCenter.promptForInputMonitoringPermission()
                PermissionCenter.openInputMonitoringSettings()
            }
        )

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 740, height: 700),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "说入法 设置"
        window.center()
        window.contentView = EditingHostingView(rootView: root)
        window.isReleasedWhenClosed = false
        window.delegate = self
        settingsWindow = window

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @MainActor
    private func toggleRecording() async {
        switch state {
        case .idle, .failed:
            await startRecording(mode: .toggle)
        case .recording:
            await stopAndTranscribe()
        case .processing:
            NSSound.beep()
        }
    }

    @MainActor
    private func shortcutPressBegan() async {
        resetPendingShortcutFlags()
        switch state {
        case .idle, .failed:
            await startRecording(mode: .pendingShortcut)
            await applyPendingShortcutDecisionAfterStart()
        case .recording:
            await stopAndTranscribe()
        case .processing:
            NSSound.beep()
        }
    }

    @MainActor
    private func shortcutTapReleased() {
        pendingShortcutTapRelease = true
        guard state == .recording, recordingMode == .pendingShortcut else {
            return
        }
        recordingMode = .toggle
    }

    @MainActor
    private func shortcutHoldRecognized() {
        pendingShortcutHoldRecognition = true
        guard state == .recording, recordingMode == .pendingShortcut else {
            return
        }
        recordingMode = .functionHold
    }

    @MainActor
    private func shortcutHoldEnded() async {
        pendingShortcutHoldEnd = true
        guard state == .recording, recordingMode == .functionHold else {
            return
        }
        await stopAndTranscribe()
    }

    @MainActor
    private func applyPendingShortcutDecisionAfterStart() async {
        guard state == .recording, recordingMode == .pendingShortcut else {
            return
        }

        if pendingShortcutHoldRecognition {
            recordingMode = .functionHold
        } else if pendingShortcutTapRelease {
            recordingMode = .toggle
        }

        if pendingShortcutHoldEnd, recordingMode == .functionHold {
            await stopAndTranscribe()
        }
    }

    private func resetPendingShortcutFlags() {
        pendingShortcutTapRelease = false
        pendingShortcutHoldRecognition = false
        pendingShortcutHoldEnd = false
    }

    @MainActor
    private func cancelRecording() {
        guard state == .recording else {
            return
        }

        recorder.cancel()
        activeRealtimeSession?.cancel()
        activeRealtimeSession = nil
        activeRecordingSnapshot = nil
        recordingMode = nil
        pendingRealtimeStopAfterStart = false
        resetPendingShortcutFlags()
        outputController.clearTarget()
        recordingOverlay.hide()
        state = .idle
    }

    @MainActor
    private func startRecording(mode: RecordingMode) async {
        outputController.captureTarget()

        guard settings.isConfigured else {
            outputController.clearTarget()
            resetPendingShortcutFlags()
            presentError("请先在设置里填写 ASR endpoint、API key 和 ASR 模型。")
            showSettings()
            return
        }

        let allowed = await PermissionCenter.requestMicrophoneAccess()
        guard allowed else {
            outputController.clearTarget()
            resetPendingShortcutFlags()
            presentError("没有麦克风权限，说入法不能录音。")
            return
        }

        do {
            let snapshot = try settings.snapshot()
            let isStreaming = snapshot.requestMode == .dashScopeQwenASRRealtime
            activeRecordingSnapshot = snapshot
            recordingMode = mode
            pendingRealtimeStopAfterStart = false
            state = .recording
            recordingOverlay.showRecording(
                streaming: isStreaming
            ) { [recorder] in
                recorder.currentLevel()
            }

            if snapshot.requestMode == .dashScopeQwenASRRealtime {
                let audioRouter = RealtimeAudioRouter()
                do {
                    try recorder.startStreaming { pcmData in
                        audioRouter.send(pcmData)
                    }
                } catch {
                    audioRouter.cancel()
                    throw error
                }

                let realtimeSession = try await client.startRealtimeTranscription(
                    settings: snapshot,
                    onPreview: nil
                )
                audioRouter.attach(realtimeSession)
                activeRealtimeSession = realtimeSession
                if pendingRealtimeStopAfterStart {
                    pendingRealtimeStopAfterStart = false
                    await stopAndTranscribe()
                }
            } else {
                try recorder.start()
            }
        } catch {
            recorder.cancel()
            activeRealtimeSession?.cancel()
            activeRealtimeSession = nil
            activeRecordingSnapshot = nil
            recordingMode = nil
            pendingRealtimeStopAfterStart = false
            resetPendingShortcutFlags()
            recordingOverlay.hide()
            outputController.clearTarget()
            state = .failed(error.localizedDescription)
            presentError("录音启动失败：\(error.localizedDescription)")
        }
    }

    @MainActor
    private func stopAndTranscribe() async {
        do {
            let completedRecordingMode = recordingMode
            let snapshot = try transcriptionSnapshot(for: completedRecordingMode)
            let realtimeSession = activeRealtimeSession
            let audioURL: URL?
            let stopStartedAt = Date()

            if realtimeSession == nil,
               snapshot.requestMode == .dashScopeQwenASRRealtime,
               recorder.isRecording {
                pendingRealtimeStopAfterStart = true
                return
            }

            if realtimeSession != nil {
                recorder.stopStreaming()
                activeRealtimeSession = nil
                pendingRealtimeStopAfterStart = false
                audioURL = nil
            } else {
                audioURL = try recorder.stop()
            }
            let stopElapsed = Date().timeIntervalSince(stopStartedAt)

            activeRecordingSnapshot = nil
            recordingMode = nil
            resetPendingShortcutFlags()
            state = .processing
            recordingOverlay.hide()

            let transcriptionResult: TranscriptionResult
            let finalReplacementTask: Task<TranscriptionResult?, Never>?
            let transcriptionStartedAt = Date()
            if let realtimeSession {
                let realtimeOutcome = try await client.finishRealtimeTranscriptionImmediately(
                    realtimeSession,
                    settings: snapshot
                )
                transcriptionResult = realtimeOutcome.initial
                finalReplacementTask = realtimeOutcome.finalReplacement
            } else if let audioURL {
                defer { try? FileManager.default.removeItem(at: audioURL) }
                let transcriptionOutcome = try await client.transcribeImmediately(
                    audioURL: audioURL,
                    settings: snapshot
                )
                transcriptionResult = transcriptionOutcome.initial
                finalReplacementTask = transcriptionOutcome.finalReplacement
            } else {
                throw RecorderError.notRecording
            }
            let transcriptionElapsed = Date().timeIntervalSince(transcriptionStartedAt)
            let text = transcriptionResult.text

            state = .idle
            updateLastResult(text)
            settings.recordInput(text)

            let outputStartedAt = Date()
            let baseTiming = "耗时：停止 \(formatDuration(stopElapsed)) · \(transcriptionResult.stage.timingLabel) \(formatDuration(transcriptionElapsed))"
            let updateOutputTiming: (TimeInterval, TextOutputMethod) -> Void = { [weak self] outputElapsed, outputMethod in
                guard let self else {
                    return
                }
                let totalElapsed = Date().timeIntervalSince(stopStartedAt)
                self.updateTiming("\(baseTiming) · 输出 \(self.formatDuration(outputElapsed))（\(outputMethod.title)）· 总 \(self.formatDuration(totalElapsed))")
            }

            outputController.output(
                text,
                autoPaste: snapshot.autoPaste,
                preserveClipboard: snapshot.preserveClipboard,
                completion: { outputMethod, replacementHandle in
                    Task { @MainActor [weak self] in
                        updateOutputTiming(Date().timeIntervalSince(outputStartedAt), outputMethod)
                        self?.recordingOverlay.hide()
                        if let finalReplacementTask, let replacementHandle {
                            self?.applyFinalReplacement(
                                finalReplacementTask,
                                originalText: text,
                                replacementHandle: replacementHandle
                            )
                        }
                    }
                }
            )

            outputController.clearTarget()

            if snapshot.autoGenerateVocabulary {
                Task { @MainActor [weak self] in
                    guard let self else {
                        return
                    }
                    let vocabularyStartedAt = Date()
                    let terms = await self.vocabularyGenerator.generateTerms(from: text, settings: snapshot)
                    let vocabularyElapsed = Date().timeIntervalSince(vocabularyStartedAt)
                    let added = self.settings.appendVocabularyTerms(terms)
                    if added > 0 {
                        self.lastResultItem?.title = "\(self.lastResultItem?.title ?? "最近结果")  · 词库 +\(added)"
                    }
                    self.appendTimingDetail("词库 \(self.formatDuration(vocabularyElapsed))")
                }
            }
        } catch TranscriptionError.noAudioCaptured {
            activeRealtimeSession?.cancel()
            activeRealtimeSession = nil
            activeRecordingSnapshot = nil
            recordingMode = nil
            pendingRealtimeStopAfterStart = false
            resetPendingShortcutFlags()
            outputController.clearTarget()
            recordingOverlay.hide()
            state = .idle
            lastResultItem?.title = "最近结果：未能收到有效语音"
            recordingOverlay.showMessage("未能收到有效语音，请重试")
        } catch {
            activeRealtimeSession?.cancel()
            activeRealtimeSession = nil
            activeRecordingSnapshot = nil
            recordingMode = nil
            pendingRealtimeStopAfterStart = false
            resetPendingShortcutFlags()
            outputController.clearTarget()
            recordingOverlay.hide()
            state = .failed(error.localizedDescription)
            presentError("转写失败：\(error.localizedDescription)")
        }
    }

    private func transcriptionSnapshot(for mode: RecordingMode?) throws -> SettingsSnapshot {
        if let activeRecordingSnapshot {
            return activeRecordingSnapshot
        }

        return try settings.snapshot()
    }

    private func updateLastResult(_ text: String) {
        let oneLine = text.replacingOccurrences(of: "\n", with: " ")
        let preview = oneLine.count > 32 ? String(oneLine.prefix(32)) + "..." : oneLine
        lastResultItem?.title = "最近结果：\(preview)"
    }

    private func applyFinalReplacement(
        _ finalReplacementTask: Task<TranscriptionResult?, Never>,
        originalText: String,
        replacementHandle: TextReplacementHandle
    ) {
        Task { @MainActor [weak self] in
            guard let self,
                  let finalResult = await finalReplacementTask.value,
                  self.normalizedText(finalResult.text) != self.normalizedText(originalText),
                  self.outputController.replaceOutput(replacementHandle, with: finalResult.text) else {
                return
            }

            self.updateLastResult(finalResult.text)
            self.appendTimingDetail("后台校正")
        }
    }

    private func normalizedText(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func updateTiming(_ title: String) {
        lastTimingTitle = title
        lastTimingItem?.title = title
        NSLog("[说入法] %@", title)
    }

    private func appendTimingDetail(_ detail: String) {
        updateTiming("\(lastTimingTitle) · \(detail)")
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        if duration < 1 {
            return "\(Int((duration * 1_000).rounded()))ms"
        }

        return String(format: "%.1fs", duration)
    }

    private func updateMenu() {
        switch state {
        case .idle:
            statusMenuItem?.title = "待命"
            startStopItem?.title = "开始录音  \(triggerDescription)"
            statusItem?.button?.image = NSImage(systemSymbolName: "mic", accessibilityDescription: "说入法")
            statusItem?.button?.title = ""
        case .recording:
            statusMenuItem?.title = "正在录音"
            startStopItem?.title = "停止并转写  \(triggerDescription)"
            statusItem?.button?.image = NSImage(systemSymbolName: "stop.circle.fill", accessibilityDescription: "停止录音")
            statusItem?.button?.title = " REC"
        case .processing:
            statusMenuItem?.title = "待命"
            startStopItem?.title = "开始录音  \(triggerDescription)"
            statusItem?.button?.image = NSImage(systemSymbolName: "mic", accessibilityDescription: "说入法")
            statusItem?.button?.title = ""
        case .failed(let message):
            statusMenuItem?.title = "错误：\(message)"
            startStopItem?.title = "重新开始  \(triggerDescription)"
            statusItem?.button?.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: "错误")
            statusItem?.button?.title = ""
        }
    }

    private func presentError(_ message: String) {
        NSSound.beep()
        let alert = NSAlert()
        alert.messageText = "说入法"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    private var triggerDescription: String {
        settings.recordingShortcut.displayName
    }

    private func applyDockIconVisibility() {
        NSApp.setActivationPolicy(settings.showDockIcon ? .regular : .accessory)
    }
}

extension AppDelegate: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        if notification.object as AnyObject === settingsWindow {
            settingsWindow = nil
        }
    }
}

private enum AppState: Equatable {
    case idle
    case recording
    case processing
    case failed(String)
}

private enum RecordingMode: Equatable {
    case pendingShortcut
    case toggle
    case functionHold
}

private final class RealtimeAudioRouter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "VoiceTyper.AppDelegate.realtimeAudioRouter")
    private var session: RealtimeTranscriptionSession?
    private var pendingChunks: [Data] = []
    private var pendingByteCount = 0
    private var isCancelled = false
    private let maxPendingByteCount = 640_000

    func send(_ pcmData: Data) {
        guard !pcmData.isEmpty else {
            return
        }

        queue.async { [weak self] in
            guard let self, !self.isCancelled else {
                return
            }

            if let session = self.session {
                session.sendAudio(pcmData)
                return
            }

            self.pendingChunks.append(pcmData)
            self.pendingByteCount += pcmData.count
            while self.pendingByteCount > self.maxPendingByteCount,
                  !self.pendingChunks.isEmpty {
                self.pendingByteCount -= self.pendingChunks.removeFirst().count
            }
        }
    }

    func attach(_ session: RealtimeTranscriptionSession) {
        queue.sync {
            guard !isCancelled else {
                return
            }

            self.session = session
            let chunks = pendingChunks
            pendingChunks.removeAll()
            pendingByteCount = 0
            for chunk in chunks {
                session.sendAudio(chunk)
            }
        }
    }

    func cancel() {
        queue.async { [weak self] in
            self?.isCancelled = true
            self?.session = nil
            self?.pendingChunks.removeAll()
            self?.pendingByteCount = 0
        }
    }
}
