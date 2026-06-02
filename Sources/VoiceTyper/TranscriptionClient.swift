import Foundation

final class TranscriptionClient {
    private static let requestTimeout: TimeInterval = 90
    private static let fastRewriteTimeoutNanoseconds: UInt64 = 800_000_000
    fileprivate static let realtimePreviewFallbackDelayNanoseconds: UInt64 = 900_000_000
    fileprivate static let realtimePreviewFallbackMinimumCharacters = 48
    fileprivate static let realtimeSendTimeout: DispatchTimeInterval = .seconds(10)
    typealias RealtimePreviewHandler = @MainActor (String) -> Void

    func transcribe(audioURL: URL, settings: SettingsSnapshot) async throws -> TranscriptionResult {
        let rawText = try await transcribeAudio(audioURL: audioURL, settings: settings)
        return try await rewriteIfNeeded(text: rawText, settings: settings)
    }

    func transcribeImmediately(audioURL: URL, settings: SettingsSnapshot) async throws -> TranscriptionOutcome {
        let rawText = try await transcribeAudio(audioURL: audioURL, settings: settings)
        let result = try await rewriteIfNeeded(text: rawText, settings: settings)
        return TranscriptionOutcome(
            initial: result,
            finalReplacement: finalQualityReplacementTaskIfNeeded(
                for: rawText,
                initial: result,
                settings: settings
            )
        )
    }

    func startRealtimeTranscription(
        settings: SettingsSnapshot,
        onPreview: RealtimePreviewHandler? = nil
    ) async throws -> RealtimeTranscriptionSession {
        let realtimeProtocol = Self.realtimeProtocol(for: settings.asrModel)
        let endpoint = Self.dashScopeRealtimeEndpoint(
            from: settings.asrEndpoint,
            model: settings.asrModel,
            realtimeProtocol: realtimeProtocol
        )
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = Self.requestTimeout
        request.setValue("\(settings.authHeaderPrefix)\(settings.apiKey)", forHTTPHeaderField: settings.authHeaderName.isEmpty ? "Authorization" : settings.authHeaderName)

        let webSocketTask = URLSession.shared.webSocketTask(with: request)
        webSocketTask.resume()
        let previewStore = RealtimeTranscriptStore()
        let streamingRewriteSession = settings.rewriteEnabled
            ? RealtimeStreamingRewriteSession(client: self, settings: settings)
            : nil

        let receiveTask: Task<String, Error>
        let initialEvent: [String: Any]?
        switch realtimeProtocol {
        case .qwenSession:
            initialEvent = Self.dashScopeRealtimeSessionUpdate(settings: settings)
            receiveTask = Task {
                try await self.receiveDashScopeRealtimeTranscript(
                    from: webSocketTask,
                    onPreview: onPreview,
                    previewStore: previewStore,
                    streamingRewriteSession: streamingRewriteSession
                )
            }

        case .inferenceTask(let taskID):
            do {
                try await sendWebSocketEvent(
                    Self.dashScopeInferenceRunTask(taskID: taskID, settings: settings),
                    to: webSocketTask
                )
                try await waitForDashScopeInferenceTaskStarted(from: webSocketTask, taskID: taskID)
            } catch {
                streamingRewriteSession?.cancel()
                webSocketTask.cancel(with: .goingAway, reason: nil)
                throw error
            }

            initialEvent = nil
            receiveTask = Task {
                try await self.receiveDashScopeInferenceRealtimeTranscript(
                    from: webSocketTask,
                    taskID: taskID,
                    onPreview: onPreview,
                    previewStore: previewStore,
                    streamingRewriteSession: streamingRewriteSession
                )
            }
        }

        return RealtimeTranscriptionSession(
            webSocketTask: webSocketTask,
            receiveTask: receiveTask,
            realtimeProtocol: realtimeProtocol,
            initialEvent: initialEvent,
            previewStore: previewStore,
            streamingRewriteSession: streamingRewriteSession
        )
    }

    func finishRealtimeTranscription(
        _ session: RealtimeTranscriptionSession,
        settings: SettingsSnapshot
    ) async throws -> TranscriptionResult {
        let rawText = try await session.finish()
        return try await rewriteIfNeeded(text: rawText, settings: settings)
    }

    func finishRealtimeTranscriptionImmediately(
        _ session: RealtimeTranscriptionSession,
        settings: SettingsSnapshot
    ) async throws -> TranscriptionOutcome {
        let outcome: RealtimeFinishOutcome
        if settings.rewriteEnabled {
            outcome = try await session.finishImmediately()
        } else {
            outcome = .final(try await session.finish())
        }

        switch outcome {
        case .final(let finalText):
            let result = try await rewriteIfNeeded(text: finalText, settings: settings)
            session.stopStreamingRewrite()
            return TranscriptionOutcome(
                initial: result,
                finalReplacement: finalQualityReplacementTaskIfNeeded(
                    for: finalText,
                    initial: result,
                    settings: settings
                )
            )

        case .preview(let previewText):
            let finalReplacement = Task<TranscriptionResult?, Never> { [self, session, settings] in
                do {
                    let finalText = try await session.finalText()
                    return try await rewriteFinalQualityIfNeeded(text: finalText, settings: settings)
                } catch {
                    return nil
                }
            }

            if let streamingRewriteText = session.latestStreamingRewrite(matching: previewText) {
                session.stopStreamingRewrite()
                return TranscriptionOutcome(
                    initial: TranscriptionResult(text: streamingRewriteText, stage: .streamingRewrite),
                    finalReplacement: finalReplacement
                )
            }

            session.stopStreamingRewrite()
            return TranscriptionOutcome(
                initial: TranscriptionResult(text: previewText, stage: .asrPreview),
                finalReplacement: finalReplacement
            )
        }
    }

    private func transcribeAudio(audioURL: URL, settings: SettingsSnapshot) async throws -> String {
        var request = URLRequest(url: settings.asrEndpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = Self.requestTimeout
        applyAuthHeader(to: &request, apiKey: settings.apiKey, headerName: settings.authHeaderName, headerPrefix: settings.authHeaderPrefix)

        let audioData = try Data(contentsOf: audioURL)

        switch settings.requestMode {
        case .multipart:
            let boundary = "VoiceTyper-\(UUID().uuidString)"
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            let body = MultipartBody(boundary: boundary)
                .field(name: "model", value: settings.asrModel)
                .optionalField(name: "language", value: settings.languageCode)
                .optionalField(name: "prompt", value: settings.asrPrompt)
                .field(name: "response_format", value: "json")
                .file(name: "file", filename: "dictation.wav", mimeType: "audio/wav", data: audioData)
                .finalized()
            return try await perform(request: request, body: body, responseKeyPath: settings.asrResponseKeyPath)

        case .jsonBase64:
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let payload = JSONTranscriptionPayload(
                model: settings.asrModel,
                audio_base64: audioData.base64EncodedString(),
                mime_type: "audio/wav",
                language: settings.languageCode.isEmpty ? nil : settings.languageCode,
                prompt: settings.asrPrompt.isEmpty ? nil : settings.asrPrompt
            )
            let body = try JSONEncoder().encode(payload)
            return try await perform(request: request, body: body, responseKeyPath: settings.asrResponseKeyPath)

        case .dashScopeQwenASR:
            request = URLRequest(url: Self.chatCompletionsEndpoint(from: settings.asrEndpoint))
            request.httpMethod = "POST"
            request.timeoutInterval = Self.requestTimeout
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            applyAuthHeader(to: &request, apiKey: settings.apiKey, headerName: settings.authHeaderName, headerPrefix: settings.authHeaderPrefix)

            var messages: [DashScopeQwenASRMessage] = []
            if !settings.asrPrompt.isEmpty {
                messages.append(
                    DashScopeQwenASRMessage(
                        role: "system",
                        content: [
                            DashScopeQwenASRContent(text: settings.asrPrompt)
                        ]
                    )
                )
            }
            messages.append(
                DashScopeQwenASRMessage(
                    role: "user",
                    content: [
                        DashScopeQwenASRContent(
                            input_audio: DashScopeQwenASRAudio(
                                data: Self.audioDataURL(from: audioData),
                                format: "wav"
                            )
                        )
                    ]
                )
            )

            let payload = DashScopeQwenASRPayload(
                model: Self.dashScopeQwenASRModel(from: settings.asrModel),
                messages: messages,
                stream: false,
                asr_options: DashScopeQwenASROptions(
                    language: settings.languageCode.isEmpty ? nil : settings.languageCode,
                    enable_itn: false
                )
            )
            let body = try JSONEncoder().encode(payload)
            return try await perform(request: request, body: body, responseKeyPath: settings.asrResponseKeyPath)

        case .dashScopeQwenASRRealtime:
            return try await transcribeDashScopeRealtime(audioURL: audioURL, settings: settings)
        }
    }

    fileprivate func rewrite(text: String, settings: SettingsSnapshot) async throws -> String {
        guard let endpoint = settings.rewriteEndpoint else {
            throw TranscriptionError.missingRewriteEndpoint
        }

        var request = URLRequest(url: Self.chatCompletionsEndpoint(from: endpoint))
        request.httpMethod = "POST"
        request.timeoutInterval = Self.requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuthHeader(to: &request, apiKey: settings.apiKey, headerName: settings.authHeaderName, headerPrefix: settings.authHeaderPrefix)

        let payload = ChatCompletionPayload(
            model: settings.rewriteModel,
            messages: [
                ChatMessage(role: "system", content: settings.rewritePrompt),
                ChatMessage(role: "user", content: "ASR 原始文本：\n\(text)")
            ],
            temperature: 0.2
        )
        let body = try JSONEncoder().encode(payload)
        return try await perform(request: request, body: body, responseKeyPath: settings.rewriteResponseKeyPath)
    }

    private func rewriteIfNeeded(text: String, settings: SettingsSnapshot) async throws -> TranscriptionResult {
        guard settings.rewriteEnabled else {
            return TranscriptionResult(text: text, stage: .asr)
        }

        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if settings.rewriteSkipMaxCharacters > 0,
           trimmedText.count <= settings.rewriteSkipMaxCharacters {
            return TranscriptionResult(text: text, stage: .rewriteSkippedForShortText)
        }

        if settings.fastOutputEnabled {
            switch await rewriteWithFastFallback(text: text, settings: settings) {
            case .rewritten(let rewrittenText):
                return TranscriptionResult(text: rewrittenText, stage: .rewrite)
            case .timedOut:
                return TranscriptionResult(text: text, stage: .rewriteTimedOut)
            case .failed:
                return TranscriptionResult(text: text, stage: .rewriteFailed)
            }
        }

        return TranscriptionResult(
            text: try await rewrite(text: text, settings: settings),
            stage: .rewrite
        )
    }

    private func rewriteFinalQualityIfNeeded(text: String, settings: SettingsSnapshot) async throws -> TranscriptionResult {
        guard settings.rewriteEnabled else {
            return TranscriptionResult(text: text, stage: .asr)
        }

        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if settings.rewriteSkipMaxCharacters > 0,
           trimmedText.count <= settings.rewriteSkipMaxCharacters {
            return TranscriptionResult(text: text, stage: .rewriteSkippedForShortText)
        }

        return TranscriptionResult(
            text: try await rewrite(text: text, settings: settings),
            stage: .rewrite
        )
    }

    private func finalQualityReplacementTaskIfNeeded(
        for text: String,
        initial: TranscriptionResult,
        settings: SettingsSnapshot
    ) -> Task<TranscriptionResult?, Never>? {
        guard settings.rewriteEnabled else {
            return nil
        }

        switch initial.stage {
        case .rewriteTimedOut, .rewriteFailed:
            return Task<TranscriptionResult?, Never> { [self, settings] in
                do {
                    return try await rewriteFinalQualityIfNeeded(text: text, settings: settings)
                } catch {
                    return nil
                }
            }
        case .asr, .asrPreview, .streamingRewrite, .rewriteSkippedForShortText, .rewrite:
            return nil
        }
    }

    private func rewriteWithFastFallback(text: String, settings: SettingsSnapshot) async -> FastRewriteOutcome {
        await withTaskGroup(of: FastRewriteOutcome.self) { group in
            group.addTask {
                do {
                    return .rewritten(try await self.rewrite(text: text, settings: settings))
                } catch {
                    return .failed
                }
            }

            group.addTask {
                try? await Task.sleep(nanoseconds: Self.fastRewriteTimeoutNanoseconds)
                return .timedOut
            }

            let outcome = await group.next() ?? .timedOut
            group.cancelAll()
            return outcome
        }
    }

    private func normalizedText(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func applyAuthHeader(to request: inout URLRequest, apiKey: String, headerName: String, headerPrefix: String) {
        let headerName = headerName.isEmpty ? "Authorization" : headerName
        request.setValue("\(headerPrefix)\(apiKey)", forHTTPHeaderField: headerName)
    }

    private static func chatCompletionsEndpoint(from endpoint: URL) -> URL {
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            return endpoint
        }

        let path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !path.hasSuffix("chat/completions") else {
            return endpoint
        }

        components.path = "/" + (path.isEmpty ? "chat/completions" : path + "/chat/completions")
        return components.url ?? endpoint
    }

    private static func audioDataURL(from audioData: Data) -> String {
        "data:audio/wav;base64,\(audioData.base64EncodedString())"
    }

    private static func dashScopeQwenASRModel(from model: String) -> String {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("qwen3-asr-flash") {
            return "qwen3-asr-flash"
        }
        return trimmed
    }

    private static func dashScopeQwenASRRealtimeModel(from model: String) -> String {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if UserSettings.isDashScopeQwenRealtimeASRModel(trimmed) {
            return trimmed
        }
        return "qwen3-asr-flash-realtime"
    }

    private static func realtimeProtocol(for model: String) -> DashScopeRealtimeProtocol {
        if UserSettings.isDashScopeInferenceRealtimeASRModel(model) {
            return .inferenceTask(taskID: taskID())
        }
        return .qwenSession
    }

    private static func dashScopeRealtimeEndpoint(
        from endpoint: URL,
        model: String,
        realtimeProtocol: DashScopeRealtimeProtocol
    ) -> URL {
        switch realtimeProtocol {
        case .qwenSession:
            return dashScopeQwenRealtimeEndpoint(from: endpoint, model: model)
        case .inferenceTask:
            return dashScopeInferenceRealtimeEndpoint(from: endpoint)
        }
    }

    private static func dashScopeQwenRealtimeEndpoint(from endpoint: URL, model: String) -> URL {
        var components = URLComponents()
        components.scheme = "wss"

        if endpoint.host?.contains("dashscope-intl") == true {
            components.host = "dashscope-intl.aliyuncs.com"
        } else {
            components.host = "dashscope.aliyuncs.com"
        }

        components.path = "/api-ws/v1/realtime"
        components.queryItems = [
            URLQueryItem(name: "model", value: dashScopeQwenASRRealtimeModel(from: model))
        ]
        return components.url ?? endpoint
    }

    private static func dashScopeInferenceRealtimeEndpoint(from endpoint: URL) -> URL {
        var components = URLComponents()
        components.scheme = "wss"
        components.host = endpoint.host?.contains("dashscope-intl") == true
            ? "dashscope-intl.aliyuncs.com"
            : "dashscope.aliyuncs.com"
        components.path = "/api-ws/v1/inference"
        return components.url ?? endpoint
    }

    private func transcribeDashScopeRealtime(audioURL: URL, settings: SettingsSnapshot) async throws -> String {
        if UserSettings.isDashScopeInferenceRealtimeASRModel(settings.asrModel) {
            return try await transcribeDashScopeInferenceRealtime(audioURL: audioURL, settings: settings)
        }

        let pcmData = try WAVPCMExtractor.extractPCMData(from: audioURL)
        let endpoint = Self.dashScopeQwenRealtimeEndpoint(from: settings.asrEndpoint, model: settings.asrModel)
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = Self.requestTimeout
        request.setValue("\(settings.authHeaderPrefix)\(settings.apiKey)", forHTTPHeaderField: settings.authHeaderName.isEmpty ? "Authorization" : settings.authHeaderName)

        let webSocketTask = URLSession.shared.webSocketTask(with: request)
        webSocketTask.resume()
        defer {
            webSocketTask.cancel(with: .normalClosure, reason: nil)
        }

        let receiveTask = Task {
            try await receiveDashScopeRealtimeTranscript(
                from: webSocketTask,
                onPreview: nil,
                previewStore: nil,
                streamingRewriteSession: nil
            )
        }

        do {
            try await sendDashScopeRealtimeSessionUpdate(to: webSocketTask, settings: settings)
            try await sendDashScopeRealtimeAudio(pcmData, to: webSocketTask)
            try await sendWebSocketEvent(["event_id": Self.eventID(), "type": "input_audio_buffer.commit"], to: webSocketTask)
            try await sendWebSocketEvent(["event_id": Self.eventID(), "type": "session.finish"], to: webSocketTask)
            return try await receiveTask.value
        } catch {
            receiveTask.cancel()
            throw error
        }
    }

    private func transcribeDashScopeInferenceRealtime(audioURL: URL, settings: SettingsSnapshot) async throws -> String {
        let pcmData = try WAVPCMExtractor.extractPCMData(from: audioURL)
        let endpoint = Self.dashScopeInferenceRealtimeEndpoint(from: settings.asrEndpoint)
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = Self.requestTimeout
        request.setValue("\(settings.authHeaderPrefix)\(settings.apiKey)", forHTTPHeaderField: settings.authHeaderName.isEmpty ? "Authorization" : settings.authHeaderName)

        let taskID = Self.taskID()
        let webSocketTask = URLSession.shared.webSocketTask(with: request)
        webSocketTask.resume()
        defer {
            webSocketTask.cancel(with: .normalClosure, reason: nil)
        }

        let receiveTask: Task<String, Error>
        do {
            try await sendWebSocketEvent(Self.dashScopeInferenceRunTask(taskID: taskID, settings: settings), to: webSocketTask)
            try await waitForDashScopeInferenceTaskStarted(from: webSocketTask, taskID: taskID)
            receiveTask = Task {
                try await receiveDashScopeInferenceRealtimeTranscript(
                    from: webSocketTask,
                    taskID: taskID,
                    onPreview: nil,
                    previewStore: nil,
                    streamingRewriteSession: nil
                )
            }
            try await sendDashScopeInferenceRealtimeAudio(pcmData, to: webSocketTask)
            try await sendWebSocketEvent(Self.dashScopeInferenceFinishTask(taskID: taskID), to: webSocketTask)
            return try await receiveTask.value
        } catch {
            throw error
        }
    }

    private func sendDashScopeRealtimeSessionUpdate(to task: URLSessionWebSocketTask, settings: SettingsSnapshot) async throws {
        try await sendWebSocketEvent(Self.dashScopeRealtimeSessionUpdate(settings: settings), to: task)
    }

    private static func dashScopeRealtimeSessionUpdate(settings: SettingsSnapshot) -> [String: Any] {
        var transcription: [String: Any] = [:]
        if !settings.languageCode.isEmpty {
            transcription["language"] = settings.languageCode
        }
        if !settings.asrPrompt.isEmpty {
            transcription["corpus"] = ["text": settings.asrPrompt]
        }

        var session: [String: Any] = [
            "input_audio_format": "pcm",
            "sample_rate": 16_000,
            "turn_detection": NSNull()
        ]
        if !transcription.isEmpty {
            session["input_audio_transcription"] = transcription
        }

        return [
            "event_id": Self.eventID(),
            "type": "session.update",
            "session": session
        ]
    }

    private func sendDashScopeRealtimeAudio(_ pcmData: Data, to task: URLSessionWebSocketTask) async throws {
        let chunkSize = 32_000
        var offset = 0
        while offset < pcmData.count {
            let end = min(offset + chunkSize, pcmData.count)
            let chunk = pcmData.subdata(in: offset..<end)
            try await sendWebSocketEvent([
                "event_id": Self.eventID(),
                "type": "input_audio_buffer.append",
                "audio": chunk.base64EncodedString()
            ], to: task)
            offset = end
        }
    }

    private func sendDashScopeInferenceRealtimeAudio(_ pcmData: Data, to task: URLSessionWebSocketTask) async throws {
        let chunkSize = 32_000
        var offset = 0
        while offset < pcmData.count {
            let end = min(offset + chunkSize, pcmData.count)
            let chunk = pcmData.subdata(in: offset..<end)
            try await task.send(.data(chunk))
            offset = end
        }
    }

    private func receiveDashScopeRealtimeTranscript(
        from task: URLSessionWebSocketTask,
        onPreview: RealtimePreviewHandler?,
        previewStore: RealtimeTranscriptStore?,
        streamingRewriteSession: RealtimeStreamingRewriteSession?
    ) async throws -> String {
        var finalTranscripts: [String] = []
        var latestPreview = ""

        while !Task.isCancelled {
            let message = try await task.receive()
            let data: Data
            switch message {
            case .data(let messageData):
                data = messageData
            case .string(let string):
                data = Data(string.utf8)
            @unknown default:
                continue
            }

            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = object["type"] as? String else {
                continue
            }

            switch type {
            case "conversation.item.input_audio_transcription.completed":
                if let transcript = object["transcript"] as? String,
                   !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    finalTranscripts.append(transcript)
                    await emitRealtimePreview(
                        finalTranscripts.joined(separator: "\n"),
                        to: onPreview,
                        previewStore: previewStore,
                        streamingRewriteSession: streamingRewriteSession
                    )
                }
            case "conversation.item.input_audio_transcription.text":
                let text = object["text"] as? String ?? ""
                let stash = object["stash"] as? String ?? ""
                latestPreview = text + stash
                await emitRealtimePreview(
                    latestPreview,
                    to: onPreview,
                    previewStore: previewStore,
                    streamingRewriteSession: streamingRewriteSession
                )
            case "conversation.item.input_audio_transcription.failed":
                let message = Self.errorMessage(from: object)
                if Self.isNoAudioRealtimeError(message) {
                    throw TranscriptionError.noAudioCaptured
                }
                throw TranscriptionError.realtimeFailed(message)
            case "error":
                let message = Self.errorMessage(from: object)
                if Self.isNoAudioRealtimeError(message) {
                    throw TranscriptionError.noAudioCaptured
                }
                throw TranscriptionError.realtimeFailed(message)
            case "session.finished":
                let finalText = finalTranscripts
                    .joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let preview = latestPreview.trimmingCharacters(in: .whitespacesAndNewlines)
                let outputText = Self.realtimeOutputText(finalText: finalText, previewText: preview)
                if !outputText.isEmpty {
                    await emitRealtimePreview(
                        outputText,
                        to: onPreview,
                        previewStore: previewStore,
                        streamingRewriteSession: streamingRewriteSession
                    )
                    return outputText
                }

                throw TranscriptionError.noAudioCaptured
            default:
                break
            }
        }

        throw CancellationError()
    }

    private func waitForDashScopeInferenceTaskStarted(
        from task: URLSessionWebSocketTask,
        taskID: String
    ) async throws {
        while !Task.isCancelled {
            guard let object = try await receiveWebSocketJSONObject(from: task),
                  Self.matchesInferenceTaskID(object, taskID: taskID) else {
                continue
            }
            guard let event = Self.inferenceEvent(from: object) else {
                if object["error"] != nil {
                    throw TranscriptionError.realtimeFailed(Self.inferenceErrorMessage(from: object))
                }
                continue
            }

            switch event {
            case "task-started":
                return
            case "task-failed":
                let message = Self.inferenceErrorMessage(from: object)
                if Self.isNoAudioRealtimeError(message) {
                    throw TranscriptionError.noAudioCaptured
                }
                throw TranscriptionError.realtimeFailed(message)
            default:
                break
            }
        }

        throw CancellationError()
    }

    private func receiveDashScopeInferenceRealtimeTranscript(
        from task: URLSessionWebSocketTask,
        taskID: String,
        onPreview: RealtimePreviewHandler?,
        previewStore: RealtimeTranscriptStore?,
        streamingRewriteSession: RealtimeStreamingRewriteSession?
    ) async throws -> String {
        var finalTranscripts: [String] = []
        var latestPreview = ""

        while !Task.isCancelled {
            guard let object = try await receiveWebSocketJSONObject(from: task),
                  Self.matchesInferenceTaskID(object, taskID: taskID) else {
                continue
            }
            guard let event = Self.inferenceEvent(from: object) else {
                if object["error"] != nil {
                    throw TranscriptionError.realtimeFailed(Self.inferenceErrorMessage(from: object))
                }
                continue
            }

            switch event {
            case "result-generated":
                guard let sentence = Self.inferenceSentence(from: object),
                      sentence["heartbeat"] as? Bool != true else {
                    continue
                }

                let text = (sentence["text"] as? String ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else {
                    continue
                }

                if Self.inferenceSentenceEnded(sentence) {
                    if finalTranscripts.last != text {
                        finalTranscripts.append(text)
                    }
                    latestPreview = ""
                } else {
                    latestPreview = text
                }

                let outputText = Self.realtimeOutputText(
                    finalText: finalTranscripts.joined(separator: "\n"),
                    previewText: latestPreview
                )
                await emitRealtimePreview(
                    outputText,
                    to: onPreview,
                    previewStore: previewStore,
                    streamingRewriteSession: streamingRewriteSession
                )

            case "task-finished":
                let outputText = Self.realtimeOutputText(
                    finalText: finalTranscripts.joined(separator: "\n"),
                    previewText: latestPreview
                )
                if !outputText.isEmpty {
                    await emitRealtimePreview(
                        outputText,
                        to: onPreview,
                        previewStore: previewStore,
                        streamingRewriteSession: streamingRewriteSession
                    )
                    return outputText
                }

                throw TranscriptionError.noAudioCaptured

            case "task-failed":
                let message = Self.inferenceErrorMessage(from: object)
                if Self.isNoAudioRealtimeError(message) {
                    throw TranscriptionError.noAudioCaptured
                }
                throw TranscriptionError.realtimeFailed(message)

            default:
                break
            }
        }

        throw CancellationError()
    }

    private func emitRealtimePreview(
        _ text: String,
        to onPreview: RealtimePreviewHandler?,
        previewStore: RealtimeTranscriptStore?,
        streamingRewriteSession: RealtimeStreamingRewriteSession?
    ) async {
        let preview = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !preview.isEmpty else {
            return
        }

        await previewStore?.update(preview)
        streamingRewriteSession?.submit(preview)
        guard let onPreview else {
            return
        }

        await MainActor.run {
            onPreview(preview)
        }
    }

    private func sendWebSocketEvent(_ event: [String: Any], to task: URLSessionWebSocketTask) async throws {
        let data = try JSONSerialization.data(withJSONObject: event)
        guard let string = String(data: data, encoding: .utf8) else {
            throw TranscriptionError.invalidRealtimePayload
        }
        try await task.send(.string(string))
    }

    private func receiveWebSocketJSONObject(from task: URLSessionWebSocketTask) async throws -> [String: Any]? {
        let message = try await task.receive()
        let data: Data
        switch message {
        case .data(let messageData):
            data = messageData
        case .string(let string):
            data = Data(string.utf8)
        @unknown default:
            return nil
        }

        return try JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    fileprivate static func eventID() -> String {
        "event_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
    }

    fileprivate static func taskID() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    private static func dashScopeInferenceRunTask(taskID: String, settings: SettingsSnapshot) -> [String: Any] {
        var parameters: [String: Any] = [
            "format": "pcm",
            "sample_rate": 16_000
        ]

        if !settings.languageCode.isEmpty {
            parameters["language_hints"] = [settings.languageCode]
        }

        return [
            "header": [
                "action": "run-task",
                "task_id": taskID,
                "streaming": "duplex"
            ],
            "payload": [
                "task_group": "audio",
                "task": "asr",
                "function": "recognition",
                "model": settings.asrModel,
                "parameters": parameters,
                "input": [:]
            ]
        ]
    }

    fileprivate static func dashScopeInferenceFinishTask(taskID: String) -> [String: Any] {
        [
            "header": [
                "action": "finish-task",
                "task_id": taskID,
                "streaming": "duplex"
            ],
            "payload": [
                "input": [:]
            ]
        ]
    }

    private static func inferenceEvent(from object: [String: Any]) -> String? {
        (object["header"] as? [String: Any])?["event"] as? String
    }

    private static func matchesInferenceTaskID(_ object: [String: Any], taskID: String) -> Bool {
        guard let header = object["header"] as? [String: Any],
              let receivedTaskID = header["task_id"] as? String else {
            return true
        }
        return receivedTaskID == taskID
    }

    private static func inferenceSentence(from object: [String: Any]) -> [String: Any]? {
        guard let payload = object["payload"] as? [String: Any],
              let output = payload["output"] as? [String: Any] else {
            return nil
        }

        return output["sentence"] as? [String: Any]
    }

    private static func inferenceSentenceEnded(_ sentence: [String: Any]) -> Bool {
        if let sentenceEnd = sentence["sentence_end"] as? Bool {
            return sentenceEnd
        }

        guard let endTime = sentence["end_time"] else {
            return false
        }
        return !(endTime is NSNull)
    }

    private static func errorMessage(from object: [String: Any]) -> String {
        if let error = object["error"] as? [String: Any],
           let message = error["message"] as? String {
            return message
        }

        return String(data: (try? JSONSerialization.data(withJSONObject: object)) ?? Data(), encoding: .utf8) ?? "Realtime ASR failed."
    }

    private static func inferenceErrorMessage(from object: [String: Any]) -> String {
        if let header = object["header"] as? [String: Any] {
            if let message = header["error_message"] as? String {
                return message
            }
            if let message = header["message"] as? String {
                return message
            }
        }

        return errorMessage(from: object)
    }

    private static func isNoAudioRealtimeError(_ message: String) -> Bool {
        let normalized = message.lowercased()
        if normalized.contains("no audio") ||
            normalized.contains("no speech") ||
            normalized.contains("valid speech") ||
            normalized.contains("valid voice") {
            return true
        }

        return normalized.contains("input audio buffer") &&
            (normalized.contains("invalid audio") || normalized.contains("no invalid audio"))
    }

    private static func realtimeOutputText(finalText: String, previewText: String) -> String {
        let final = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
        let preview = previewText.trimmingCharacters(in: .whitespacesAndNewlines)
        if final.isEmpty {
            return preview
        }
        if preview.isEmpty {
            return final
        }
        if preview.hasPrefix(final) || preview.contains(final) {
            return preview
        }
        if final.hasPrefix(preview) || final.contains(preview) {
            return final
        }
        return final + "\n" + preview
    }

    private func perform(request: URLRequest, body: Data, responseKeyPath: String) async throws -> String {
        var request = request
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
            let message = String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)"
            throw TranscriptionError.requestFailed(statusCode: httpResponse.statusCode, message: message)
        }

        return try ResponseTextExtractor.extractText(from: data, preferredKeyPath: responseKeyPath)
    }
}

private actor RealtimeTranscriptStore {
    private var latestText = ""

    func update(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            latestText = trimmed
        }
    }

    func latest() -> String {
        latestText
    }
}

private final class RealtimeStreamingRewriteSession: @unchecked Sendable {
    private let client: TranscriptionClient
    private let settings: SettingsSnapshot
    private let queue = DispatchQueue(label: "VoiceTyper.TranscriptionClient.streamingRewrite")
    private var latestSource = ""
    private var latestRewrittenSource = ""
    private var latestRewrittenText = ""
    private var pendingSource = ""
    private var isRewriting = false
    private var isCancelled = false

    init(client: TranscriptionClient, settings: SettingsSnapshot) {
        self.client = client
        self.settings = settings
    }

    func submit(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > max(12, settings.rewriteSkipMaxCharacters) else {
            return
        }

        queue.async { [weak self] in
            guard let self, !self.isCancelled, self.latestSource != trimmed else {
                return
            }

            self.latestSource = trimmed
            self.pendingSource = trimmed
            if !self.isRewriting {
                self.startNextRewriteLocked()
            }
        }
    }

    func latestRewrite(matching text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return queue.sync {
            guard !latestRewrittenText.isEmpty,
                  latestRewrittenSource == trimmed else {
                return nil
            }

            return latestRewrittenText
        }
    }

    func cancel() {
        queue.async { [weak self] in
            self?.isCancelled = true
        }
    }

    private func startNextRewriteLocked() {
        let source = pendingSource
        pendingSource = ""
        isRewriting = true

        Task { [weak self] in
            guard let self else {
                return
            }

            try? await Task.sleep(nanoseconds: 250_000_000)

            let rewritten: String?
            do {
                rewritten = try await self.client.rewrite(text: source, settings: self.settings)
            } catch {
                rewritten = nil
            }

            self.queue.async { [weak self] in
                guard let self, !self.isCancelled else {
                    return
                }

                if let rewritten,
                   self.latestSource == source {
                    self.latestRewrittenSource = source
                    self.latestRewrittenText = rewritten.trimmingCharacters(in: .whitespacesAndNewlines)
                }

                self.isRewriting = false
                if !self.pendingSource.isEmpty,
                   self.pendingSource != source {
                    self.startNextRewriteLocked()
                }
            }
        }
    }
}

private enum RealtimeFinishOutcome {
    case final(String)
    case preview(String)
}

fileprivate enum DashScopeRealtimeProtocol {
    case qwenSession
    case inferenceTask(taskID: String)
}

final class RealtimeTranscriptionSession {
    private let webSocketTask: URLSessionWebSocketTask
    private let receiveTask: Task<String, Error>
    private let sender: RealtimeWebSocketSender
    private let previewStore: RealtimeTranscriptStore
    private let streamingRewriteSession: RealtimeStreamingRewriteSession?

    fileprivate init(
        webSocketTask: URLSessionWebSocketTask,
        receiveTask: Task<String, Error>,
        realtimeProtocol: DashScopeRealtimeProtocol,
        initialEvent: [String: Any]? = nil,
        previewStore: RealtimeTranscriptStore,
        streamingRewriteSession: RealtimeStreamingRewriteSession?
    ) {
        self.webSocketTask = webSocketTask
        self.receiveTask = receiveTask
        self.previewStore = previewStore
        self.streamingRewriteSession = streamingRewriteSession
        sender = RealtimeWebSocketSender(webSocketTask: webSocketTask, realtimeProtocol: realtimeProtocol)
        if let initialEvent {
            sender.enqueueEvent(initialEvent)
        }
    }

    func sendAudio(_ pcmData: Data) {
        sender.enqueueAudio(pcmData)
    }

    fileprivate func finish() async throws -> String {
        do {
            try await sender.finish()
            return try await receiveTask.value
        } catch {
            cancel()
            throw error
        }
    }

    fileprivate func finishImmediately() async throws -> RealtimeFinishOutcome {
        do {
            try await sender.finish()
            return try await finishWithPreviewFallback()
        } catch {
            cancel()
            throw error
        }
    }

    fileprivate func finalText() async throws -> String {
        do {
            return try await receiveTask.value
        } catch {
            cancel()
            throw error
        }
    }

    fileprivate func latestStreamingRewrite(matching text: String) -> String? {
        streamingRewriteSession?.latestRewrite(matching: text)
    }

    fileprivate func stopStreamingRewrite() {
        streamingRewriteSession?.cancel()
    }

    private func finishWithPreviewFallback() async throws -> RealtimeFinishOutcome {
        try await withThrowingTaskGroup(of: RealtimeFinishOutcome.self) { group in
            group.addTask { [receiveTask] in
                .final(try await receiveTask.value)
            }

            group.addTask { [previewStore] in
                try await Task.sleep(nanoseconds: TranscriptionClient.realtimePreviewFallbackDelayNanoseconds)

                while !Task.isCancelled {
                    let preview = await previewStore.latest()
                    let trimmedPreview = preview.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmedPreview.count >= TranscriptionClient.realtimePreviewFallbackMinimumCharacters {
                        return .preview(trimmedPreview)
                    }

                    try await Task.sleep(nanoseconds: 50_000_000)
                }

                throw CancellationError()
            }

            let outcome: RealtimeFinishOutcome
            if let firstOutcome = try await group.next() {
                outcome = firstOutcome
            } else {
                outcome = .final(try await receiveTask.value)
            }
            group.cancelAll()
            return outcome
        }
    }

    func cancel() {
        streamingRewriteSession?.cancel()
        sender.cancel()
        receiveTask.cancel()
        webSocketTask.cancel(with: .normalClosure, reason: nil)
    }
}

private final class RealtimeWebSocketSender: @unchecked Sendable {
    private let webSocketTask: URLSessionWebSocketTask
    private let realtimeProtocol: DashScopeRealtimeProtocol
    private let queue = DispatchQueue(label: "VoiceTyper.TranscriptionClient.realtimeSender")
    private var firstError: Error?
    private var isFinishing = false
    private var audioByteCount = 0
    private let minimumAudioByteCount = 3_200

    init(webSocketTask: URLSessionWebSocketTask, realtimeProtocol: DashScopeRealtimeProtocol) {
        self.webSocketTask = webSocketTask
        self.realtimeProtocol = realtimeProtocol
    }

    func enqueueAudio(_ pcmData: Data) {
        guard !pcmData.isEmpty else {
            return
        }

        queue.async { [weak self] in
            guard let self, !self.isFinishing, self.firstError == nil else {
                return
            }

            switch self.realtimeProtocol {
            case .qwenSession:
                self.sendSync([
                    "event_id": TranscriptionClient.eventID(),
                    "type": "input_audio_buffer.append",
                    "audio": pcmData.base64EncodedString()
                ])
            case .inferenceTask:
                self.sendDataSync(pcmData)
            }

            if self.firstError == nil {
                self.audioByteCount += pcmData.count
            }
        }
    }

    func enqueueEvent(_ event: [String: Any]) {
        queue.async { [weak self] in
            guard let self, !self.isFinishing, self.firstError == nil else {
                return
            }

            self.sendSync(event)
        }
    }

    func finish() async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [weak self] in
                guard let self else {
                    continuation.resume()
                    return
                }

                self.isFinishing = true
                if let firstError = self.firstError {
                    continuation.resume(throwing: firstError)
                    return
                }
                guard self.audioByteCount >= self.minimumAudioByteCount else {
                    continuation.resume(throwing: TranscriptionError.noAudioCaptured)
                    return
                }

                switch self.realtimeProtocol {
                case .qwenSession:
                    self.sendSync(["event_id": TranscriptionClient.eventID(), "type": "input_audio_buffer.commit"])
                    self.sendSync(["event_id": TranscriptionClient.eventID(), "type": "session.finish"])
                case .inferenceTask(let taskID):
                    self.sendSync(TranscriptionClient.dashScopeInferenceFinishTask(taskID: taskID))
                }

                if let firstError = self.firstError {
                    continuation.resume(throwing: firstError)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    func cancel() {
        queue.async { [weak self] in
            self?.isFinishing = true
        }
    }

    private func sendSync(_ event: [String: Any]) {
        guard firstError == nil else {
            return
        }

        do {
            let data = try JSONSerialization.data(withJSONObject: event)
            guard let string = String(data: data, encoding: .utf8) else {
                firstError = TranscriptionError.invalidRealtimePayload
                return
            }

            let semaphore = DispatchSemaphore(value: 0)
            webSocketTask.send(.string(string)) { [weak self] error in
                if let error {
                    self?.firstError = error
                }
                semaphore.signal()
            }
            if semaphore.wait(timeout: .now() + TranscriptionClient.realtimeSendTimeout) == .timedOut {
                firstError = TranscriptionError.realtimeSendTimedOut
                webSocketTask.cancel(with: .goingAway, reason: nil)
            }
        } catch {
            firstError = error
        }
    }

    private func sendDataSync(_ data: Data) {
        guard firstError == nil else {
            return
        }

        let semaphore = DispatchSemaphore(value: 0)
        webSocketTask.send(.data(data)) { [weak self] error in
            if let error {
                self?.firstError = error
            }
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + TranscriptionClient.realtimeSendTimeout) == .timedOut {
            firstError = TranscriptionError.realtimeSendTimedOut
            webSocketTask.cancel(with: .goingAway, reason: nil)
        }
    }
}

private struct JSONTranscriptionPayload: Encodable {
    let model: String
    let audio_base64: String
    let mime_type: String
    let language: String?
    let prompt: String?
}

private struct DashScopeQwenASRPayload: Encodable {
    let model: String
    let messages: [DashScopeQwenASRMessage]
    let stream: Bool
    let asr_options: DashScopeQwenASROptions
}

private struct DashScopeQwenASRMessage: Encodable {
    let role: String
    let content: [DashScopeQwenASRContent]
}

private struct DashScopeQwenASRContent: Encodable {
    let type: String?
    let text: String?
    let input_audio: DashScopeQwenASRAudio?

    init(text: String) {
        type = nil
        self.text = text
        input_audio = nil
    }

    init(input_audio: DashScopeQwenASRAudio) {
        type = "input_audio"
        text = nil
        self.input_audio = input_audio
    }
}

private struct DashScopeQwenASRAudio: Encodable {
    let data: String
    let format: String
}

private struct DashScopeQwenASROptions: Encodable {
    let language: String?
    let enable_itn: Bool
}

private struct ChatCompletionPayload: Encodable {
    let model: String
    let messages: [ChatMessage]
    let temperature: Double
}

private struct ChatMessage: Encodable {
    let role: String
    let content: String
}

struct TranscriptionResult {
    let text: String
    let stage: TranscriptionStage
}

struct TranscriptionOutcome {
    let initial: TranscriptionResult
    let finalReplacement: Task<TranscriptionResult?, Never>?
}

enum TranscriptionStage {
    case asr
    case asrPreview
    case streamingRewrite
    case rewriteSkippedForShortText
    case rewrite
    case rewriteTimedOut
    case rewriteFailed

    var timingLabel: String {
        switch self {
        case .asr:
            return "ASR"
        case .asrPreview:
            return "ASR 预览"
        case .streamingRewrite:
            return "边听边润色"
        case .rewriteSkippedForShortText:
            return "ASR（短文本跳过润色）"
        case .rewrite:
            return "ASR+润色"
        case .rewriteTimedOut:
            return "ASR（润色超时，极速输出）"
        case .rewriteFailed:
            return "ASR（润色失败，极速输出）"
        }
    }
}

private enum FastRewriteOutcome {
    case rewritten(String)
    case timedOut
    case failed
}

struct MultipartBody {
    private let boundary: String
    private var data = Data()

    init(boundary: String) {
        self.boundary = boundary
    }

    func field(name: String, value: String) -> MultipartBody {
        var copy = self
        copy.append("--\(boundary)\r\n")
        copy.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
        copy.append("\(value)\r\n")
        return copy
    }

    func optionalField(name: String, value: String) -> MultipartBody {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return self
        }
        return field(name: name, value: trimmed)
    }

    func file(name: String, filename: String, mimeType: String, data fileData: Data) -> MultipartBody {
        var copy = self
        copy.append("--\(boundary)\r\n")
        copy.append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n")
        copy.append("Content-Type: \(mimeType)\r\n\r\n")
        copy.data.append(fileData)
        copy.append("\r\n")
        return copy
    }

    func finalized() -> Data {
        var copy = self
        copy.append("--\(boundary)--\r\n")
        return copy.data
    }

    private mutating func append(_ string: String) {
        data.append(Data(string.utf8))
    }
}

enum TranscriptionError: LocalizedError {
    case requestFailed(statusCode: Int, message: String)
    case missingRewriteEndpoint
    case missingTextField
    case invalidRealtimePayload
    case noAudioCaptured
    case realtimeFailed(String)
    case realtimeSendTimedOut

    var errorDescription: String? {
        switch self {
        case .requestFailed(let statusCode, let message):
            return "API 请求失败（\(statusCode)）：\(message)"
        case .missingRewriteEndpoint:
            return "转写 endpoint 不能为空。"
        case .missingTextField:
            return "API 响应里没有找到文本。可以在设置里调整 response key path。"
        case .invalidRealtimePayload:
            return "Realtime ASR 请求无法编码。"
        case .noAudioCaptured:
            return "没有检测到可提交的音频，请开始说话后再停止录音。"
        case .realtimeFailed(let message):
            return "Realtime ASR 失败：\(message)"
        case .realtimeSendTimedOut:
            return "Realtime ASR 音频发送超时，请检查网络或稍后重试。"
        }
    }
}

private enum WAVPCMExtractor {
    static func extractPCMData(from url: URL) throws -> Data {
        let data = try Data(contentsOf: url)
        var offset = 12

        while offset + 8 <= data.count {
            let chunkID = String(data: data[offset..<offset + 4], encoding: .ascii)
            let chunkSize = Int(readUInt32LE(data, offset: offset + 4))
            let chunkDataStart = offset + 8
            let chunkDataEnd = min(chunkDataStart + chunkSize, data.count)

            if chunkID == "data" {
                return data.subdata(in: chunkDataStart..<chunkDataEnd)
            }

            offset = chunkDataEnd + (chunkSize % 2)
        }

        return data
    }

    private static func readUInt32LE(_ data: Data, offset: Int) -> UInt32 {
        guard offset + 4 <= data.count else {
            return 0
        }

        return UInt32(data[offset]) |
            (UInt32(data[offset + 1]) << 8) |
            (UInt32(data[offset + 2]) << 16) |
            (UInt32(data[offset + 3]) << 24)
    }
}
