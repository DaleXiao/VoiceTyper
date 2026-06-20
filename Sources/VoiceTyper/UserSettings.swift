import Combine
import Foundation

final class UserSettings: ObservableObject {
    @Published var asrEndpointText: String {
        didSet { saveString(asrEndpointText, forKey: Keys.asrEndpointText) }
    }

    @Published var apiKey: String {
        didSet { saveString(apiKey, forKey: Keys.apiKey) }
    }

    @Published var asrModel: String {
        didSet { saveString(asrModel, forKey: Keys.asrModel) }
    }

    @Published var asrModelOptions: [String] {
        didSet { saveStringArray(asrModelOptions, forKey: Keys.asrModelOptions) }
    }

    @Published var rewriteEnabled: Bool {
        didSet { saveBool(rewriteEnabled, forKey: Keys.rewriteEnabled) }
    }

    @Published var rewriteEndpointText: String {
        didSet { saveString(rewriteEndpointText, forKey: Keys.rewriteEndpointText) }
    }

    @Published var rewriteModel: String {
        didSet { saveString(rewriteModel, forKey: Keys.rewriteModel) }
    }

    @Published var rewriteModelOptions: [String] {
        didSet { saveStringArray(rewriteModelOptions, forKey: Keys.rewriteModelOptions) }
    }

    @Published var requestMode: RequestMode {
        didSet { saveString(requestMode.rawValue, forKey: Keys.requestMode) }
    }

    @Published var authHeaderName: String {
        didSet { saveString(authHeaderName, forKey: Keys.authHeaderName) }
    }

    @Published var authHeaderPrefix: String {
        didSet { saveString(authHeaderPrefix, forKey: Keys.authHeaderPrefix) }
    }

    @Published var languageCode: String {
        didSet { saveString(languageCode, forKey: Keys.languageCode) }
    }

    @Published var stylePrompt: String {
        didSet { saveString(stylePrompt, forKey: Keys.stylePrompt) }
    }

    @Published var vocabulary: String {
        didSet { saveString(vocabulary, forKey: Keys.vocabulary) }
    }

    @Published var asrResponseKeyPath: String {
        didSet { saveString(asrResponseKeyPath, forKey: Keys.asrResponseKeyPath) }
    }

    @Published var rewriteResponseKeyPath: String {
        didSet { saveString(rewriteResponseKeyPath, forKey: Keys.rewriteResponseKeyPath) }
    }

    @Published var rewriteSkipMaxCharacters: Int {
        didSet { saveInt(rewriteSkipMaxCharacters, forKey: Keys.rewriteSkipMaxCharacters) }
    }

    @Published var fastOutputEnabled: Bool {
        didSet { saveBool(fastOutputEnabled, forKey: Keys.fastOutputEnabled) }
    }

    @Published var autoGenerateVocabulary: Bool {
        didSet { saveBool(autoGenerateVocabulary, forKey: Keys.autoGenerateVocabulary) }
    }

    @Published var autoPaste: Bool {
        didSet { saveBool(autoPaste, forKey: Keys.autoPaste) }
    }

    @Published var preserveClipboard: Bool {
        didSet { saveBool(preserveClipboard, forKey: Keys.preserveClipboard) }
    }

    @Published var showDockIcon: Bool {
        didSet { saveBool(showDockIcon, forKey: Keys.showDockIcon) }
    }

    @Published var recordingShortcut: RecordingShortcut {
        didSet { recordingShortcut.save(to: defaults) }
    }

    @Published var holdToRecordEnabled: Bool {
        didSet { saveBool(holdToRecordEnabled, forKey: Keys.holdToRecordEnabled) }
    }

    @Published var inputHistoryEnabled: Bool {
        didSet { saveBool(inputHistoryEnabled, forKey: Keys.inputHistoryEnabled) }
    }

    @Published var inputHistoryRetentionDays: Int {
        didSet {
            pruneInputHistory()
            saveInt(inputHistoryRetentionDays, forKey: Keys.inputHistoryRetentionDays)
        }
    }

    @Published var inputHistory: [InputHistoryEntry] {
        didSet {
            guard !isReplacingInputHistory else {
                return
            }
            refreshInputHistoryCache()
            saveInputHistoryIfNeeded()
        }
    }

    @Published private(set) var inputStatistics = InputStatistics(entries: [])
    @Published private(set) var inputHistoryRows: [InputHistoryDisplayRow] = []

    private static let maxInputHistoryCount = 1_000
    private static let inputHistoryDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.dateFormat = "yyyy/MM/dd HH:mm"
        return formatter
    }()
    private let defaults = UserDefaults.standard
    private var lastSavedInputHistory: [InputHistoryEntry] = []
    private var isReplacingInputHistory = false

    init() {
        asrEndpointText = defaults.string(forKey: Keys.asrEndpointText)
            ?? defaults.string(forKey: LegacyKeys.endpointText)
            ?? ""
        apiKey = defaults.string(forKey: Keys.apiKey) ?? ""
        asrModel = defaults.string(forKey: Keys.asrModel)
            ?? defaults.string(forKey: LegacyKeys.model)
            ?? ""
        asrModelOptions = defaults.stringArray(forKey: Keys.asrModelOptions)
            ?? defaults.stringArray(forKey: LegacyKeys.modelOptions)
            ?? []
        rewriteEnabled = defaults.object(forKey: Keys.rewriteEnabled) as? Bool ?? false
        rewriteEndpointText = defaults.string(forKey: Keys.rewriteEndpointText) ?? ""
        rewriteModel = defaults.string(forKey: Keys.rewriteModel) ?? ""
        rewriteModelOptions = defaults.stringArray(forKey: Keys.rewriteModelOptions) ?? []
        requestMode = RequestMode(rawValue: defaults.string(forKey: Keys.requestMode) ?? "") ?? .multipart
        authHeaderName = defaults.string(forKey: Keys.authHeaderName) ?? "Authorization"
        authHeaderPrefix = defaults.string(forKey: Keys.authHeaderPrefix) ?? "Bearer "
        languageCode = defaults.string(forKey: Keys.languageCode) ?? "zh"
        stylePrompt = defaults.string(forKey: Keys.stylePrompt) ?? Self.defaultPrompt
        vocabulary = defaults.string(forKey: Keys.vocabulary) ?? ""
        asrResponseKeyPath = defaults.string(forKey: Keys.asrResponseKeyPath)
            ?? defaults.string(forKey: LegacyKeys.responseKeyPath)
            ?? "text"
        rewriteResponseKeyPath = defaults.string(forKey: Keys.rewriteResponseKeyPath) ?? "choices.0.message.content"
        rewriteSkipMaxCharacters = defaults.object(forKey: Keys.rewriteSkipMaxCharacters) as? Int ?? 20
        fastOutputEnabled = defaults.object(forKey: Keys.fastOutputEnabled) as? Bool ?? true
        autoGenerateVocabulary = defaults.object(forKey: Keys.autoGenerateVocabulary) as? Bool ?? true
        autoPaste = defaults.object(forKey: Keys.autoPaste) as? Bool ?? true
        preserveClipboard = defaults.object(forKey: Keys.preserveClipboard) as? Bool ?? true
        showDockIcon = defaults.object(forKey: Keys.showDockIcon) as? Bool ?? true
        recordingShortcut = RecordingShortcut.load(from: defaults)
        holdToRecordEnabled = defaults.object(forKey: Keys.holdToRecordEnabled) as? Bool ?? false
        inputHistoryEnabled = defaults.object(forKey: Keys.inputHistoryEnabled) as? Bool ?? true
        inputHistoryRetentionDays = max(0, defaults.object(forKey: Keys.inputHistoryRetentionDays) as? Int ?? 0)
        inputHistory = Self.loadInputHistory(from: defaults)
        pruneInputHistory()
        refreshInputHistoryCache()

        if requestMode == .multipart,
           asrEndpointText.contains("dashscope.aliyuncs.com"),
           asrModel.lowercased().contains("asr") {
            requestMode = .dashScopeQwenASR
        }
        lastSavedInputHistory = inputHistory
    }

    var isConfigured: Bool {
        guard URL(string: asrEndpointText.trimmingCharacters(in: .whitespacesAndNewlines))?.scheme != nil else {
            return false
        }

        let hasASR = hasAPIKey &&
            !asrModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        guard hasASR else {
            return false
        }

        return true
    }

    var hasAPIKey: Bool {
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var asrModelChoices: [String] {
        choices(current: asrModel, options: Self.filteredASRModelOptions(from: asrModelOptions))
    }

    var rewriteModelChoices: [String] {
        choices(current: rewriteModel, options: rewriteModelOptions)
    }

    static func filteredASRModelOptions(from models: [String]) -> [String] {
        let asrModels = models.filter(Self.isASRModelOption)
        return unique(Self.defaultASRModelOptions + asrModels)
    }

    static func isASRModelOption(_ model: String) -> Bool {
        let normalized = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty,
              !normalized.contains("filetrans") else {
            return false
        }

        return normalized.contains("asr") ||
            normalized.contains("fun-asr") ||
            normalized.contains("paraformer") ||
            normalized.contains("sensevoice") ||
            normalized.contains("whisper") ||
            normalized.contains("speech-recognition") ||
            normalized.contains("transcription") ||
            normalized.contains("qwen3.5-omni") ||
            normalized.contains("qwen3-omni")
    }

    static func isDashScopeQwenASRModel(_ model: String) -> Bool {
        let normalized = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.hasPrefix("qwen3-asr-flash") &&
            !normalized.contains("filetrans") &&
            !normalized.contains("realtime")
    }

    static func isDashScopeQwenRealtimeASRModel(_ model: String) -> Bool {
        let normalized = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.hasPrefix("qwen3-asr-flash-realtime")
    }

    static func isDashScopeInferenceRealtimeASRModel(_ model: String) -> Bool {
        let normalized = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalized.contains("realtime") else {
            return false
        }

        return normalized.contains("fun-asr") ||
            normalized.contains("paraformer")
    }

    static func isDashScopeRealtimeASRModel(_ model: String) -> Bool {
        isDashScopeQwenRealtimeASRModel(model) ||
            isDashScopeInferenceRealtimeASRModel(model)
    }

    func snapshot(rewriteSkipMaxCharactersOverride: Int? = nil) throws -> SettingsSnapshot {
        let trimmedASREndpoint = asrEndpointText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let asrEndpoint = URL(string: trimmedASREndpoint), asrEndpoint.scheme != nil else {
            throw SettingsError.invalidASREndpoint
        }

        let trimmedAPIKey = try resolvedAPIKey()

        let trimmedASRModel = asrModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedASRModel.isEmpty else {
            throw SettingsError.missingASRModel
        }

        let effectiveRewriteEnabled = rewriteEnabled
        let rewriteEndpoint = try resolvedRewriteEndpoint(
            defaultEndpoint: asrEndpoint,
            rewriteEnabled: effectiveRewriteEnabled
        )
        let trimmedRewriteModel = rewriteModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if effectiveRewriteEnabled, trimmedRewriteModel.isEmpty {
            throw SettingsError.missingRewriteModel
        }

        return SettingsSnapshot(
            asrEndpoint: asrEndpoint,
            apiKey: trimmedAPIKey,
            asrModel: trimmedASRModel,
            requestMode: resolvedRequestMode(endpoint: asrEndpoint, model: trimmedASRModel),
            authHeaderName: authHeaderName.trimmingCharacters(in: .whitespacesAndNewlines),
            authHeaderPrefix: authHeaderPrefix,
            languageCode: languageCode.trimmingCharacters(in: .whitespacesAndNewlines),
            asrPrompt: asrPrompt(),
            asrResponseKeyPath: asrResponseKeyPath.trimmingCharacters(in: .whitespacesAndNewlines),
            rewriteEnabled: effectiveRewriteEnabled,
            rewriteEndpoint: rewriteEndpoint,
            rewriteModel: trimmedRewriteModel,
            rewritePrompt: rewritePrompt(),
            rewriteResponseKeyPath: rewriteResponseKeyPath.trimmingCharacters(in: .whitespacesAndNewlines),
            rewriteSkipMaxCharacters: max(0, rewriteSkipMaxCharactersOverride ?? rewriteSkipMaxCharacters),
            fastOutputEnabled: fastOutputEnabled,
            autoGenerateVocabulary: autoGenerateVocabulary,
            autoPaste: autoPaste,
            preserveClipboard: preserveClipboard
        )
    }

    func modelCatalogSnapshot() throws -> ModelCatalogSnapshot {
        let trimmedAPIKey = try resolvedAPIKey()

        return ModelCatalogSnapshot(
            endpoint: try resolvedModelsEndpoint(baseEndpointText: asrEndpointText),
            apiKey: trimmedAPIKey,
            authHeaderName: authHeaderName.trimmingCharacters(in: .whitespacesAndNewlines),
            authHeaderPrefix: authHeaderPrefix
        )
    }

    func appendVocabularyTerms(_ terms: [String]) -> Int {
        let existing = vocabulary
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var seen = Set(existing.map { $0.lowercased() })
        var merged = existing
        for term in terms {
            let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count >= 2, !seen.contains(trimmed.lowercased()) else {
                continue
            }

            seen.insert(trimmed.lowercased())
            merged.append(trimmed)
        }

        let added = merged.count - existing.count
        if added > 0 {
            vocabulary = merged.suffix(300).joined(separator: "\n")
        }
        return added
    }

    func recordInput(_ text: String, at timestamp: Date = Date()) {
        guard inputHistoryEnabled else {
            return
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }

        let entry = InputHistoryEntry(timestamp: timestamp, text: trimmed)
        var updatedHistory = inputHistory
        updatedHistory.append(entry)

        var needsFullCacheRefresh = false
        if updatedHistory.count > Self.maxInputHistoryCount {
            updatedHistory.removeFirst(updatedHistory.count - Self.maxInputHistoryCount)
            needsFullCacheRefresh = true
        }

        if inputHistoryRetentionDays > 0,
           let cutoff = Calendar.current.date(byAdding: .day, value: -inputHistoryRetentionDays, to: timestamp) {
            let countBeforePruning = updatedHistory.count
            updatedHistory.removeAll { $0.timestamp < cutoff }
            needsFullCacheRefresh = needsFullCacheRefresh || updatedHistory.count != countBeforePruning
        }

        replaceInputHistory(updatedHistory) { [entry] in
            if needsFullCacheRefresh {
                refreshInputHistoryCache()
            } else {
                appendInputHistoryCache(entry)
            }
        }
    }

    func deleteInputHistoryEntry(id: InputHistoryEntry.ID) {
        let updatedHistory = inputHistory.filter { $0.id != id }
        guard updatedHistory.count != inputHistory.count else {
            return
        }

        replaceInputHistory(updatedHistory, cacheUpdate: refreshInputHistoryCache)
    }

    func clearInputHistory() {
        guard !inputHistory.isEmpty else {
            return
        }

        replaceInputHistory([], cacheUpdate: refreshInputHistoryCache)
    }

    func exportInputHistoryText() -> String {
        inputHistory
            .map { entry in
                "\(Self.inputHistoryDateFormatter.string(from: entry.timestamp))\t\(entry.text)"
            }
            .joined(separator: "\n")
    }

    private func pruneInputHistory(now: Date = Date()) {
        guard inputHistoryRetentionDays > 0 else {
            return
        }

        guard let cutoff = Calendar.current.date(byAdding: .day, value: -inputHistoryRetentionDays, to: now) else {
            return
        }

        let prunedHistory = inputHistory.filter { $0.timestamp >= cutoff }
        guard prunedHistory.count != inputHistory.count else {
            return
        }

        replaceInputHistory(prunedHistory, cacheUpdate: refreshInputHistoryCache)
    }

    private func refreshInputHistoryCache() {
        inputStatistics = InputStatistics(entries: inputHistory)
        inputHistoryRows = inputHistory.reversed().map { Self.inputHistoryDisplayRow(for: $0) }
    }

    private func appendInputHistoryCache(_ entry: InputHistoryEntry) {
        inputStatistics = inputStatistics.adding(entry)
        inputHistoryRows.insert(Self.inputHistoryDisplayRow(for: entry), at: 0)
    }

    private func replaceInputHistory(_ history: [InputHistoryEntry], cacheUpdate: () -> Void) {
        isReplacingInputHistory = true
        inputHistory = history
        isReplacingInputHistory = false
        cacheUpdate()
        saveInputHistoryIfNeeded()
    }

    private static func inputHistoryDisplayRow(for entry: InputHistoryEntry) -> InputHistoryDisplayRow {
        InputHistoryDisplayRow(
            id: entry.id,
            timestampText: inputHistoryDateFormatter.string(from: entry.timestamp),
            text: entry.text
        )
    }

    private func resolvedAPIKey() throws -> String {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }

        throw SettingsError.missingAPIKey
    }

    private func choices(current: String, options: [String]) -> [String] {
        var choices = options
        let current = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !current.isEmpty, !choices.contains(current) {
            choices.insert(current, at: 0)
        }
        return choices
    }

    private func resolvedRequestMode(endpoint: URL, model: String) -> RequestMode {
        if requestMode == .multipart,
           Self.isDashScopeEndpoint(endpoint),
           Self.isDashScopeRealtimeASRModel(model) {
            return .dashScopeQwenASRRealtime
        }

        if requestMode == .multipart,
           Self.isDashScopeEndpoint(endpoint),
           Self.isDashScopeQwenASRModel(model) {
            return .dashScopeQwenASR
        }

        return requestMode
    }

    private func resolvedRewriteEndpoint(defaultEndpoint: URL, rewriteEnabled: Bool) throws -> URL? {
        guard rewriteEnabled else {
            return nil
        }

        let trimmed = rewriteEndpointText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return defaultEndpoint
        }

        guard let url = URL(string: trimmed), url.scheme != nil else {
            throw SettingsError.invalidRewriteEndpoint
        }
        return url
    }

    private func asrPrompt() -> String {
        let terms = vocabulary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !terms.isEmpty else {
            return ""
        }
        return "优先识别这些专有名词：\n\(terms)"
    }

    private func rewritePrompt() -> String {
        let prompt = stylePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let terms = vocabulary.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !terms.isEmpty else {
            return prompt
        }

        if prompt.isEmpty {
            return "把 ASR 原始文本整理成自然、清晰、可直接发送的文字。\n\n优先保留这些专有名词：\n\(terms)"
        }

        return "\(prompt)\n\n优先保留这些专有名词：\n\(terms)"
    }

    private func saveString(_ value: String, forKey key: String) {
        if defaults.string(forKey: key) != value {
            defaults.set(value, forKey: key)
        }
    }

    private func saveStringArray(_ value: [String], forKey key: String) {
        if defaults.stringArray(forKey: key) != value {
            defaults.set(value, forKey: key)
        }
    }

    private func saveBool(_ value: Bool, forKey key: String) {
        if (defaults.object(forKey: key) as? Bool) != value {
            defaults.set(value, forKey: key)
        }
    }

    private func saveInt(_ value: Int, forKey key: String) {
        if (defaults.object(forKey: key) as? Int) != value {
            defaults.set(value, forKey: key)
        }
    }

    private func saveInputHistoryIfNeeded() {
        guard inputHistory != lastSavedInputHistory else {
            return
        }

        if let historyData = try? JSONEncoder().encode(inputHistory),
           defaults.data(forKey: Keys.inputHistory) != historyData {
            defaults.set(historyData, forKey: Keys.inputHistory)
        }
        lastSavedInputHistory = inputHistory
    }

    private static func loadInputHistory(from defaults: UserDefaults) -> [InputHistoryEntry] {
        guard let data = defaults.data(forKey: Keys.inputHistory),
              let history = try? JSONDecoder().decode([InputHistoryEntry].self, from: data) else {
            return []
        }

        return Array(history.suffix(maxInputHistoryCount))
    }

    private static func unique(_ values: [String]) -> [String] {
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

    private static func isDashScopeEndpoint(_ endpoint: URL) -> Bool {
        guard let host = endpoint.host?.lowercased() else {
            return false
        }
        return host.contains("dashscope") && host.contains("aliyuncs.com")
    }

    private static let defaultASRModelOptions = [
        "qwen3-asr-flash",
        "qwen3-asr-flash-realtime",
        "fun-asr",
        "fun-asr-realtime",
        "fun-asr-mtl",
        "fun-asr-mtl-realtime",
        "paraformer-v2",
        "paraformer-realtime-v2",
        "paraformer-mtl-v1",
        "sensevoice-v1"
    ]

    private func resolvedModelsEndpoint(baseEndpointText: String) throws -> URL {
        let baseText = baseEndpointText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let baseEndpoint = URL(string: baseText), baseEndpoint.scheme != nil else {
            throw SettingsError.invalidModelsEndpoint
        }

        guard var components = URLComponents(url: baseEndpoint, resolvingAgainstBaseURL: false) else {
            throw SettingsError.invalidModelsEndpoint
        }

        let path = components.path
        if path.hasSuffix("/audio/transcriptions") {
            components.path = String(path.dropLast("/audio/transcriptions".count)) + "/models"
        } else if path.hasSuffix("/chat/completions") {
            components.path = String(path.dropLast("/chat/completions".count)) + "/models"
        } else if let range = path.range(of: "/v1/") {
            components.path = String(path[..<range.upperBound]) + "models"
        } else if path.isEmpty || path == "/" {
            components.path = "/models"
        } else {
            components.path = path.hasSuffix("/") ? path + "models" : path + "/models"
        }

        components.query = nil
        components.fragment = nil

        guard let url = components.url else {
            throw SettingsError.invalidModelsEndpoint
        }
        return url
    }

    private enum Keys {
        static let asrEndpointText = "asrEndpointText"
        static let apiKey = "apiKey"
        static let asrModel = "asrModel"
        static let asrModelsEndpointText = "asrModelsEndpointText"
        static let asrModelOptions = "asrModelOptions"
        static let rewriteEnabled = "rewriteEnabled"
        static let rewriteEndpointText = "rewriteEndpointText"
        static let rewriteModel = "rewriteModel"
        static let rewriteModelsEndpointText = "rewriteModelsEndpointText"
        static let rewriteModelOptions = "rewriteModelOptions"
        static let requestMode = "requestMode"
        static let authHeaderName = "authHeaderName"
        static let authHeaderPrefix = "authHeaderPrefix"
        static let languageCode = "languageCode"
        static let stylePrompt = "stylePrompt"
        static let vocabulary = "vocabulary"
        static let asrResponseKeyPath = "asrResponseKeyPath"
        static let rewriteResponseKeyPath = "rewriteResponseKeyPath"
        static let rewriteSkipMaxCharacters = "rewriteSkipMaxCharacters"
        static let fastOutputEnabled = "fastOutputEnabled"
        static let autoGenerateVocabulary = "autoGenerateVocabulary"
        static let autoPaste = "autoPaste"
        static let preserveClipboard = "preserveClipboard"
        static let showDockIcon = "showDockIcon"
        static let holdToRecordEnabled = "holdToRecordEnabled"
        static let inputHistoryEnabled = "inputHistoryEnabled"
        static let inputHistoryRetentionDays = "inputHistoryRetentionDays"
        static let inputHistory = "inputHistory"
    }

    private enum LegacyKeys {
        static let endpointText = "endpointText"
        static let model = "model"
        static let modelOptions = "modelOptions"
        static let responseKeyPath = "responseKeyPath"
    }

    private static let defaultPrompt = "把 ASR 原始文本整理成自然、清晰、可直接发送的文字。保留说话人的原意，自动处理明显口误、重复词、标点和分段。"
}

struct SettingsSnapshot {
    let asrEndpoint: URL
    let apiKey: String
    let asrModel: String
    let requestMode: RequestMode
    let authHeaderName: String
    let authHeaderPrefix: String
    let languageCode: String
    let asrPrompt: String
    let asrResponseKeyPath: String
    let rewriteEnabled: Bool
    let rewriteEndpoint: URL?
    let rewriteModel: String
    let rewritePrompt: String
    let rewriteResponseKeyPath: String
    let rewriteSkipMaxCharacters: Int
    let fastOutputEnabled: Bool
    let autoGenerateVocabulary: Bool
    let autoPaste: Bool
    let preserveClipboard: Bool
}

struct InputHistoryEntry: Identifiable, Codable, Equatable {
    let id: UUID
    let timestamp: Date
    let text: String

    init(id: UUID = UUID(), timestamp: Date = Date(), text: String) {
        self.id = id
        self.timestamp = timestamp
        self.text = text
    }
}

struct InputHistoryDisplayRow: Identifiable, Equatable {
    let id: UUID
    let timestampText: String
    let text: String
}

struct InputStatistics: Equatable {
    let characterCount: Int
    let usageCount: Int
    let wordCount: Int
    let sentenceCount: Int

    init(entries: [InputHistoryEntry]) {
        usageCount = entries.count
        characterCount = entries.reduce(0) { total, entry in
            total + Self.countCharacters(in: entry.text)
        }
        wordCount = entries.reduce(0) { total, entry in
            total + Self.countWords(in: entry.text)
        }
        sentenceCount = entries.reduce(0) { total, entry in
            total + Self.countSentences(in: entry.text)
        }
    }

    private init(characterCount: Int, usageCount: Int, wordCount: Int, sentenceCount: Int) {
        self.characterCount = characterCount
        self.usageCount = usageCount
        self.wordCount = wordCount
        self.sentenceCount = sentenceCount
    }

    func adding(_ entry: InputHistoryEntry) -> InputStatistics {
        InputStatistics(
            characterCount: characterCount + Self.countCharacters(in: entry.text),
            usageCount: usageCount + 1,
            wordCount: wordCount + Self.countWords(in: entry.text),
            sentenceCount: sentenceCount + Self.countSentences(in: entry.text)
        )
    }

    private static func countCharacters(in text: String) -> Int {
        text.filter { !$0.isWhitespace }.count
    }

    private static func countWords(in text: String) -> Int {
        var count = 0
        text.enumerateSubstrings(
            in: text.startIndex..<text.endIndex,
            options: [.byWords, .localized]
        ) { substring, _, _, _ in
            if substring?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                count += 1
            }
        }
        return count
    }

    private static func countSentences(in text: String) -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return 0
        }

        var count = 0
        trimmed.enumerateSubstrings(
            in: trimmed.startIndex..<trimmed.endIndex,
            options: [.bySentences, .localized]
        ) { substring, _, _, _ in
            if substring?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                count += 1
            }
        }
        return max(count, 1)
    }
}

enum RequestMode: String, CaseIterable, Identifiable {
    case multipart
    case jsonBase64
    case dashScopeQwenASR
    case dashScopeQwenASRRealtime

    var id: String { rawValue }

    var title: String {
        switch self {
        case .multipart:
            return "Multipart audio"
        case .jsonBase64:
            return "JSON base64"
        case .dashScopeQwenASR:
            return "DashScope Qwen ASR"
        case .dashScopeQwenASRRealtime:
            return "DashScope Realtime ASR"
        }
    }
}

enum ModelPurpose: String, CaseIterable, Identifiable {
    case asr
    case rewrite

    var id: String { rawValue }

    var title: String {
        switch self {
        case .asr:
            return "ASR"
        case .rewrite:
            return "转写"
        }
    }
}

enum SettingsError: LocalizedError {
    case invalidASREndpoint
    case invalidRewriteEndpoint
    case invalidModelsEndpoint
    case missingAPIKey
    case missingASRModel
    case missingRewriteModel

    var errorDescription: String? {
        switch self {
        case .invalidASREndpoint:
            return "ASR endpoint URL 无效。"
        case .invalidRewriteEndpoint:
            return "转写 endpoint URL 无效。"
        case .invalidModelsEndpoint:
            return "模型列表 endpoint URL 无效。"
        case .missingAPIKey:
            return "API key 不能为空。"
        case .missingASRModel:
            return "ASR 模型不能为空。"
        case .missingRewriteModel:
            return "转写模型不能为空。"
        }
    }
}
