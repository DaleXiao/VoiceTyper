import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: UserSettings
    let fetchModels: () async throws -> [String]
    let hotKeyChanged: () -> Void
    let dockIconChanged: () -> Void
    let requestMicrophone: () -> Void
    let requestAccessibility: () -> Void
    let requestInputMonitoring: () -> Void

    @State private var isFetchingModels = false
    @State private var isTestingConnection = false
    @State private var apiConnectionStatus: APIConnectionStatus = .untested
    @State private var historyActionMessage: String?
    @State private var pendingHistoryDeletion: HistoryDeletionRequest?
    @State private var microphonePermissionStatus = PermissionCenter.microphonePermissionStatus()
    @State private var accessibilityPermissionStatus = PermissionCenter.accessibilityPermissionStatus()
    @State private var inputMonitoringPermissionStatus = PermissionCenter.inputMonitoringPermissionStatus()
    @State private var selectedPane: SettingsPane = .general

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            Divider()

            HStack(alignment: .top, spacing: 18) {
                paneList

                Divider()

                selectedSettingsPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(22)
        .frame(width: 740, height: 700)
        .onAppear(perform: refreshPermissionStatus)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissionStatus()
        }
        .alert(item: $pendingHistoryDeletion, content: historyDeletionAlert)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 36, height: 36)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 4) {
                Text("说入法")
                    .font(.title2.weight(.semibold))
                Text("快捷键 \(settings.recordingShortcut.displayName)")
                    .foregroundStyle(.secondary)
            }

            Spacer()

            ConfigurationStatusIcon(isConfigured: settings.isConfigured)
        }
    }

    private var paneList: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(SettingsPane.allCases) { pane in
                Button {
                    selectedPane = pane
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: pane.systemImage)
                            .frame(width: 18)
                        Text(pane.title)
                        Spacer(minLength: 0)
                    }
                    .font(.callout.weight(selectedPane == pane ? .semibold : .regular))
                    .foregroundStyle(selectedPane == pane ? Color.accentColor : Color.primary)
                    .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                    .padding(.horizontal, 10)
                    .contentShape(Rectangle())
                    .background {
                        if selectedPane == pane {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.accentColor.opacity(0.12))
                        }
                    }
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .transaction { transaction in
                    transaction.animation = nil
                }
            }
        }
        .frame(width: 150)
    }

    private var selectedSettingsPane: some View {
        paneContent(selectedPane)
            .transaction { transaction in
                transaction.animation = nil
            }
    }

    @ViewBuilder
    private func paneContent(_ pane: SettingsPane) -> some View {
        switch pane {
        case .general:
            generalSettingsTab
        case .statistics:
            statisticsTab
        case .dictionary:
            dictionarySettingsTab
        case .api:
            apiSettingsTab
        }
    }

    private var generalSettingsTab: some View {
        Form {
            Section("快捷键") {
                ShortcutRecorderView(shortcut: $settings.recordingShortcut) {
                    hotKeyChanged()
                }
            }

            Section("行为") {
                Picker("听写语言", selection: $settings.languageCode) {
                    ForEach(dictationLanguageOptions) { option in
                        Text(option.title).tag(option.code)
                    }
                }
                .pickerStyle(.menu)

                Toggle("自动粘贴到当前光标", isOn: $settings.autoPaste)
                Toggle("粘贴后恢复剪贴板", isOn: $settings.preserveClipboard)
                Toggle("显示 Dock 图标", isOn: $settings.showDockIcon)
                    .onChange(of: settings.showDockIcon) { _ in
                        dockIconChanged()
                    }
            }

            Section("权限") {
                PermissionStatusRow(
                    title: "麦克风",
                    systemImage: "mic",
                    status: microphonePermissionStatus,
                    actionTitle: "请求"
                ) {
                    requestMicrophonePermission()
                }

                PermissionStatusRow(
                    title: "辅助功能",
                    systemImage: "cursorarrow.click",
                    status: accessibilityPermissionStatus,
                    actionTitle: "打开"
                ) {
                    requestAccessibilityPermission()
                }

                PermissionStatusRow(
                    title: "输入监控",
                    systemImage: "keyboard",
                    status: inputMonitoringPermissionStatus,
                    actionTitle: "打开"
                ) {
                    requestInputMonitoringPermission()
                }

                HStack {
                    Spacer()
                    Button("刷新状态") {
                        refreshPermissionStatus()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding(.top, 8)
    }

    private var statisticsTab: some View {
        return VStack(alignment: .leading, spacing: 16) {
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4),
                spacing: 12
            ) {
                StatisticBox(title: "输入字数", value: settings.inputStatistics.characterCount)
                StatisticBox(title: "使用次数", value: settings.inputStatistics.usageCount)
                StatisticBox(title: "词数", value: settings.inputStatistics.wordCount)
                StatisticBox(title: "句子数", value: settings.inputStatistics.sentenceCount)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    Toggle("记录输入历史", isOn: $settings.inputHistoryEnabled)

                    Stepper(
                        inputHistoryRetentionSummary,
                        value: $settings.inputHistoryRetentionDays,
                        in: 0...365,
                        step: 7
                    )

                    Spacer()
                }

                HStack(spacing: 12) {
                    Button(action: copyInputHistory) {
                        Label("复制记录", systemImage: "doc.on.doc")
                    }
                    .disabled(settings.inputHistory.isEmpty)

                    Button(role: .destructive) {
                        pendingHistoryDeletion = .all(count: settings.inputHistory.count)
                    } label: {
                        Label("清空", systemImage: "trash")
                    }
                    .disabled(settings.inputHistory.isEmpty)

                    Spacer()
                }

                if let historyActionMessage {
                    Text(historyActionMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("输入记录")
                    .font(.headline)

                if settings.inputHistoryRows.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "text.badge.plus")
                            .font(.system(size: 28))
                            .foregroundStyle(.secondary)
                        Text("暂无输入记录")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 320)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(nsColor: .controlBackgroundColor))
                    )
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(settings.inputHistoryRows) { row in
                                InputHistoryRow(row: row) {
                                    pendingHistoryDeletion = .row(row)
                                }
                                Divider()
                            }
                        }
                    }
                    .frame(minHeight: 320)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(nsColor: .controlBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                    )
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.top, 8)
    }

    private var dictionarySettingsTab: some View {
        Form {
            Section("用户词库") {
                Toggle("自动从转写结果学习词库", isOn: $settings.autoGenerateVocabulary)

                TextEditor(text: $settings.vocabulary)
                    .font(.body)
                    .frame(minHeight: 300)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                    )
            }
        }
        .formStyle(.grouped)
        .padding(.top, 8)
    }

    private var apiSettingsTab: some View {
        Form {
            Section("连接") {
                HStack {
                    Text(settings.isConfigured ? "已配置" : "未配置")
                        .font(.body.weight(.medium))
                        .foregroundStyle(settings.isConfigured ? .green : .orange)

                    Spacer()

                    Text(apiConfigurationSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                TextField("API Endpoint", text: $settings.asrEndpointText)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: settings.asrEndpointText) { _ in
                        apiConnectionStatus = .untested
                    }

                SecureField("API key", text: $settings.apiKey)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: settings.apiKey) { _ in
                        apiConnectionStatus = .untested
                    }

                HStack {
                    ConnectionStatusBadge(status: apiConnectionStatus)

                    Spacer()

                    Button(action: testConnection) {
                        if isTestingConnection {
                            Label("测试中", systemImage: "network")
                        } else {
                            Label("测试连接", systemImage: "network")
                        }
                    }
                    .disabled(isFetchingModels || isTestingConnection)

                    Button(action: fetchModelOptions) {
                        if isFetchingModels {
                            Label("读取中", systemImage: "arrow.triangle.2.circlepath")
                        } else {
                            Label("读取模型列表", systemImage: "arrow.clockwise")
                        }
                    }
                    .disabled(isFetchingModels || isTestingConnection)

                    Button(role: .destructive, action: clearAPIKey) {
                        Label("清除 API key", systemImage: "key.slash")
                    }
                    .disabled(!settings.hasAPIKey)
                }
            }

            Section("模型") {
                modelSelector(
                    title: "ASR 模型",
                    selection: $settings.asrModel,
                    choices: settings.asrModelChoices,
                    fallbackPrompt: "ASR Model"
                )
                .onChange(of: settings.asrModel) { newModel in
                    syncRequestModeWithASRModel(newModel)
                }

                Toggle("低延迟流式 ASR（推荐）", isOn: streamingASRBinding)

                Toggle("开启润色", isOn: $settings.rewriteEnabled)

                modelSelector(
                    title: "润色模型",
                    selection: $settings.rewriteModel,
                    choices: settings.rewriteModelChoices,
                    fallbackPrompt: "Rewrite Model"
                )

                Toggle("极速输出，润色慢时先用 ASR 原文", isOn: $settings.fastOutputEnabled)

                TextEditor(text: $settings.stylePrompt)
                    .font(.body)
                    .frame(minHeight: 78)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                    )
            }

            Section("高级") {
                DisclosureGroup("兼容性设置") {
                    Picker("ASR 请求格式", selection: $settings.requestMode) {
                        ForEach(RequestMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: settings.requestMode) { newMode in
                    if newMode == .dashScopeQwenASRRealtime,
                       !UserSettings.isDashScopeRealtimeASRModel(settings.asrModel) {
                        settings.asrModel = preferredRealtimeASRModel(for: settings.asrModel)
                    }
                }

                    TextField("ASR response key path", text: $settings.asrResponseKeyPath)
                        .textFieldStyle(.roundedBorder)

                    TextField("润色 Endpoint 覆盖（留空使用 API Endpoint）", text: $settings.rewriteEndpointText)
                        .textFieldStyle(.roundedBorder)

                    TextField("润色 response key path", text: $settings.rewriteResponseKeyPath)
                        .textFieldStyle(.roundedBorder)

                    if !settings.asrModelChoices.isEmpty {
                        TextField("自定义 ASR Model", text: $settings.asrModel)
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: settings.asrModel) { newModel in
                                syncRequestModeWithASRModel(newModel)
                            }
                    }

                    if !settings.rewriteModelChoices.isEmpty {
                        TextField("自定义润色 Model", text: $settings.rewriteModel)
                            .textFieldStyle(.roundedBorder)
                    }

                    TextField("Header name", text: $settings.authHeaderName)
                        .textFieldStyle(.roundedBorder)

                    TextField("Header prefix", text: $settings.authHeaderPrefix)
                        .textFieldStyle(.roundedBorder)
                }
            }
        }
        .formStyle(.grouped)
        .padding(.top, 8)
    }

    private var apiConfigurationSummary: String {
        let asrModel = settings.asrModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let rewriteModel = settings.rewriteModel.trimmingCharacters(in: .whitespacesAndNewlines)

        if !rewriteModel.isEmpty {
            return "ASR \(asrModel.isEmpty ? "未选择" : asrModel) · 润色 \(rewriteModel)"
        }

        return "ASR \(asrModel.isEmpty ? "未选择" : asrModel)"
    }

    private var streamingASRBinding: Binding<Bool> {
        Binding(
            get: {
                settings.requestMode == .dashScopeQwenASRRealtime
            },
            set: { enabled in
                if enabled {
                    settings.requestMode = .dashScopeQwenASRRealtime
                    if !settings.asrModel.lowercased().contains("realtime") {
                        settings.asrModel = preferredRealtimeASRModel(for: settings.asrModel)
                    }
                } else if settings.requestMode == .dashScopeQwenASRRealtime {
                    settings.requestMode = settings.asrModel.lowercased().contains("asr") ? .dashScopeQwenASR : .multipart
                }
            }
        )
    }

    private func preferredRealtimeASRModel(for model: String) -> String {
        let normalized = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.contains("fun-asr-mtl") {
            return "fun-asr-mtl-realtime"
        }
        if normalized.contains("fun-asr") {
            return "fun-asr-realtime"
        }
        if normalized.contains("paraformer") {
            return "paraformer-realtime-v2"
        }
        return "qwen3-asr-flash-realtime"
    }

    private var inputHistoryRetentionSummary: String {
        guard settings.inputHistoryRetentionDays > 0 else {
            return "保留时间：永久"
        }

        return "保留时间：\(settings.inputHistoryRetentionDays) 天"
    }

    private var dictationLanguageOptions: [DictationLanguageOption] {
        [
            DictationLanguageOption(code: "", title: "自动检测"),
            DictationLanguageOption(code: "zh", title: "中文"),
            DictationLanguageOption(code: "en", title: "English"),
            DictationLanguageOption(code: "yue", title: "粤语"),
            DictationLanguageOption(code: "ja", title: "日本語"),
            DictationLanguageOption(code: "ko", title: "한국어"),
            DictationLanguageOption(code: "fr", title: "Français"),
            DictationLanguageOption(code: "de", title: "Deutsch"),
            DictationLanguageOption(code: "es", title: "Español"),
            DictationLanguageOption(code: "ru", title: "Русский")
        ]
    }

    @ViewBuilder
    private func modelSelector(
        title: String,
        selection: Binding<String>,
        choices: [String],
        fallbackPrompt: String
    ) -> some View {
        if choices.isEmpty {
            TextField(fallbackPrompt, text: selection)
                .textFieldStyle(.roundedBorder)
        } else {
            Picker(title, selection: selection) {
                ForEach(choices, id: \.self) { model in
                    Text(model).tag(model)
                }
            }
            .pickerStyle(.menu)
        }
    }

    private func requestMicrophonePermission() {
        requestMicrophone()
        refreshPermissionStatusSoon()
    }

    private func requestAccessibilityPermission() {
        requestAccessibility()
        refreshPermissionStatusSoon()
    }

    private func requestInputMonitoringPermission() {
        requestInputMonitoring()
        refreshPermissionStatusSoon()
    }

    private func refreshPermissionStatus() {
        microphonePermissionStatus = PermissionCenter.microphonePermissionStatus()
        accessibilityPermissionStatus = PermissionCenter.accessibilityPermissionStatus()
        inputMonitoringPermissionStatus = PermissionCenter.inputMonitoringPermissionStatus()
    }

    private func refreshPermissionStatusSoon() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            refreshPermissionStatus()
        }
    }

    private func copyInputHistory() {
        let text = settings.exportInputHistoryText()
        guard !text.isEmpty else {
            historyActionMessage = "没有可复制的记录"
            return
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        historyActionMessage = "已复制 \(settings.inputHistory.count) 条记录"
    }

    private func clearInputHistory() {
        settings.clearInputHistory()
        historyActionMessage = "已清空输入记录"
    }

    private func historyDeletionAlert(for request: HistoryDeletionRequest) -> Alert {
        switch request {
        case .row(let row):
            return Alert(
                title: Text("删除这条记录？"),
                message: Text("删除后无法撤销。"),
                primaryButton: .destructive(Text("删除")) {
                    settings.deleteInputHistoryEntry(id: row.id)
                    historyActionMessage = "已删除 1 条记录"
                    pendingHistoryDeletion = nil
                },
                secondaryButton: .cancel(Text("取消")) {
                    pendingHistoryDeletion = nil
                }
            )
        case .all(let count):
            return Alert(
                title: Text("清空输入记录？"),
                message: Text("将删除 \(count) 条输入记录，删除后无法撤销。"),
                primaryButton: .destructive(Text("清空")) {
                    clearInputHistory()
                    pendingHistoryDeletion = nil
                },
                secondaryButton: .cancel(Text("取消")) {
                    pendingHistoryDeletion = nil
                }
            )
        }
    }

    private func testConnection() {
        isTestingConnection = true
        apiConnectionStatus = .testing

        Task {
            do {
                _ = try await fetchModels()
                await MainActor.run {
                    apiConnectionStatus = .connected
                    isTestingConnection = false
                }
            } catch {
                await MainActor.run {
                    apiConnectionStatus = .failed(error.localizedDescription)
                    isTestingConnection = false
                }
            }
        }
    }

    private func clearAPIKey() {
        settings.apiKey = ""
        apiConnectionStatus = .untested
    }

    private func fetchModelOptions() {
        isFetchingModels = true
        apiConnectionStatus = .testing

        Task {
            do {
                let models = try await fetchModels()
                await MainActor.run {
                    settings.asrModelOptions = UserSettings.filteredASRModelOptions(from: models)
                    settings.rewriteModelOptions = models
                    if shouldReplaceASRModel(settings.asrModel),
                       let first = settings.asrModelOptions.first {
                        settings.asrModel = first
                    }
                    if settings.rewriteModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       let first = models.first {
                        settings.rewriteModel = first
                    }
                    apiConnectionStatus = .connected
                    isFetchingModels = false
                }
            } catch {
                await MainActor.run {
                    apiConnectionStatus = .failed(error.localizedDescription)
                    isFetchingModels = false
                }
            }
        }
    }

    private func shouldReplaceASRModel(_ model: String) -> Bool {
        let normalized = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty ||
            normalized.contains("filetrans")
    }

    private func syncRequestModeWithASRModel(_ model: String) {
        let normalized = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if settings.requestMode == .dashScopeQwenASRRealtime,
           !UserSettings.isDashScopeRealtimeASRModel(normalized) {
            settings.requestMode = UserSettings.isDashScopeQwenASRModel(normalized) ? .dashScopeQwenASR : .multipart
        } else if settings.requestMode == .dashScopeQwenASR,
                  !UserSettings.isDashScopeQwenASRModel(normalized) {
            settings.requestMode = .multipart
        }
    }

    private func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.compactMap { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !seen.contains(trimmed) else {
                return nil
            }
            seen.insert(trimmed)
            return trimmed
        }
    }
}

private struct DictationLanguageOption: Identifiable {
    let code: String
    let title: String

    var id: String { code }
}

private struct StatisticBox: View {
    let title: String
    let value: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(value.formatted())
                .font(.title2.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }
}

private struct ConfigurationStatusIcon: View {
    let isConfigured: Bool

    var body: some View {
        Image(systemName: isConfigured ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
            .font(.system(size: 20, weight: .semibold))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(isConfigured ? Color.green : Color.orange)
            .frame(width: 28, height: 28)
            .help(isConfigured ? "配置正常" : "配置未完成")
            .accessibilityLabel(isConfigured ? "配置正常" : "配置未完成")
    }
}

private struct ConnectionStatusBadge: View {
    let status: APIConnectionStatus

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(status.color)
                .frame(width: 9, height: 9)

            Text(status.title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .help(status.title)
    }
}

private struct PermissionStatusRow: View {
    let title: String
    let systemImage: String
    let status: PermissionGrantStatus
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Label(title, systemImage: systemImage)

            Spacer()

            Label(status.title, systemImage: statusSystemImage)
                .foregroundStyle(statusColor)
                .font(.callout.weight(.medium))

            Button(actionTitle, action: action)
        }
    }

    private var statusSystemImage: String {
        switch status {
        case .granted:
            return "checkmark.circle.fill"
        case .denied:
            return "xmark.circle.fill"
        case .notDetermined:
            return "questionmark.circle"
        case .unknown:
            return "exclamationmark.triangle"
        }
    }

    private var statusColor: Color {
        switch status {
        case .granted:
            return .green
        case .denied:
            return .red
        case .notDetermined:
            return .orange
        case .unknown:
            return .secondary
        }
    }
}

private enum APIConnectionStatus: Equatable {
    case untested
    case testing
    case connected
    case failed(String)

    var title: String {
        switch self {
        case .untested:
            return "未测试"
        case .testing:
            return "正在测试"
        case .connected:
            return "已连接"
        case .failed(let message):
            return "连接失败：\(message)"
        }
    }

    var color: Color {
        switch self {
        case .untested:
            return .secondary
        case .testing:
            return .orange
        case .connected:
            return .green
        case .failed:
            return .red
        }
    }
}

private struct InputHistoryRow: View {
    let row: InputHistoryDisplayRow
    let deleteAction: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(row.timestampText)
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 118, alignment: .leading)

            Text(row.text)
                .font(.callout)
                .lineSpacing(2)
                .lineLimit(3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: deleteAction) {
                Image(systemName: "trash")
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("删除这条记录")
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 10)
    }
}

private enum HistoryDeletionRequest: Identifiable {
    case row(InputHistoryDisplayRow)
    case all(count: Int)

    var id: String {
        switch self {
        case .row(let row):
            return row.id.uuidString
        case .all:
            return "all"
        }
    }
}

private enum SettingsPane: CaseIterable, Identifiable {
    case general
    case statistics
    case dictionary
    case api

    var id: Self { self }

    var title: String {
        switch self {
        case .general:
            return "常规设置"
        case .statistics:
            return "统计"
        case .dictionary:
            return "字典设置"
        case .api:
            return "API 设置"
        }
    }

    var systemImage: String {
        switch self {
        case .general:
            return "gearshape"
        case .statistics:
            return "chart.bar"
        case .dictionary:
            return "text.book.closed"
        case .api:
            return "network"
        }
    }
}
