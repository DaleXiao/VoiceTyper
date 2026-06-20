import Foundation

final class VocabularyGenerator {
    private static let heuristicRegex = try? NSRegularExpression(
        pattern: #"([A-Za-z][A-Za-z0-9._+-]{2,}|[A-Za-z]+[一-龥]+|[一-龥]+[A-Za-z0-9]+|[A-Z]{2,})"#
    )

    private let cache = VocabularyTermCache()

    func generateTerms(from text: String, settings: SettingsSnapshot) async -> [String] {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else {
            return []
        }

        let cacheKey = VocabularyTermCache.Key(
            text: trimmedText,
            endpoint: settings.rewriteEndpoint?.absoluteString ?? "",
            model: settings.rewriteModel
        )
        if let cachedTerms = await cache.terms(for: cacheKey) {
            return cachedTerms
        }

        let heuristicTerms = Self.heuristicTerms(from: trimmedText)
        guard !heuristicTerms.isEmpty else {
            await cache.store([], for: cacheKey)
            return []
        }

        let terms: [String]
        let shouldCache: Bool
        if settings.rewriteEnabled,
           let endpoint = settings.rewriteEndpoint,
           !settings.rewriteModel.isEmpty {
            do {
                let modelTerms = try await generateWithModel(text: trimmedText, endpoint: endpoint, settings: settings)
                terms = modelTerms.isEmpty ? heuristicTerms : Self.merge(modelTerms + heuristicTerms)
                shouldCache = true
            } catch {
                terms = heuristicTerms
                shouldCache = false
            }
        } else {
            terms = heuristicTerms
            shouldCache = true
        }

        if shouldCache {
            await cache.store(terms, for: cacheKey)
        }
        return terms
    }

    private func generateWithModel(text: String, endpoint: URL, settings: SettingsSnapshot) async throws -> [String] {
        var request = URLRequest(url: Self.chatCompletionsEndpoint(from: endpoint))
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let headerName = settings.authHeaderName.isEmpty ? "Authorization" : settings.authHeaderName
        request.setValue("\(settings.authHeaderPrefix)\(settings.apiKey)", forHTTPHeaderField: headerName)

        let payload = VocabularyPayload(
            model: settings.rewriteModel,
            messages: [
                VocabularyMessage(
                    role: "system",
                    content: "你是用户词库提取器。只返回 JSON 字符串数组，不要解释。提取容易被 ASR 误识别、用户可能反复使用的专有名词、产品名、人名、技术词、英文缩写、代码名。不要返回普通虚词或完整句子。"
                ),
                VocabularyMessage(role: "user", content: text)
            ],
            temperature: 0
        )
        let body = try JSONEncoder().encode(payload)
        request.httpBody = body

        let (data, response) = try await AppNetworkSession.shared.data(for: request)
        if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
            throw VocabularyError.requestFailed(httpResponse.statusCode)
        }

        let content = try ResponseTextExtractor.extractText(from: data, preferredKeyPath: "choices.0.message.content")
        return try Self.parseTerms(from: content)
    }

    private static func parseTerms(from content: String) throws -> [String] {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let jsonText: String
        if trimmed.hasPrefix("[") {
            jsonText = trimmed
        } else if let start = trimmed.firstIndex(of: "["), let end = trimmed.lastIndex(of: "]"), start < end {
            jsonText = String(trimmed[start...end])
        } else {
            return heuristicTerms(from: content)
        }

        guard let data = jsonText.data(using: .utf8),
              let array = try JSONSerialization.jsonObject(with: data) as? [Any] else {
            return heuristicTerms(from: content)
        }

        return merge(array.compactMap { $0 as? String })
    }

    private static func heuristicTerms(from text: String) -> [String] {
        guard let regex = heuristicRegex else {
            return []
        }

        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, range: nsRange)
        let terms = matches.compactMap { match -> String? in
            guard let range = Range(match.range(at: 1), in: text) else {
                return nil
            }
            let value = String(text[range]).trimmingCharacters(in: .punctuationCharacters.union(.whitespacesAndNewlines))
            guard value.count >= 3 else {
                return nil
            }
            return value
        }

        return merge(terms)
    }

    private static func merge(_ terms: [String]) -> [String] {
        var seen = Set<String>()
        return terms.compactMap { term in
            let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count >= 2, trimmed.count <= 40, !seen.contains(trimmed.lowercased()) else {
                return nil
            }
            seen.insert(trimmed.lowercased())
            return trimmed
        }
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
}

private actor VocabularyTermCache {
    struct Key: Hashable {
        let text: String
        let endpoint: String
        let model: String
    }

    private var values: [Key: [String]] = [:]
    private var keys: [Key] = []
    private let maxCount = 64

    func terms(for key: Key) -> [String]? {
        values[key]
    }

    func store(_ terms: [String], for key: Key) {
        guard values[key] == nil else {
            values[key] = terms
            return
        }

        values[key] = terms
        keys.append(key)
        if keys.count > maxCount {
            let removed = Array(keys.prefix(keys.count - maxCount))
            keys.removeFirst(keys.count - maxCount)
            for key in removed {
                values.removeValue(forKey: key)
            }
        }
    }
}

private struct VocabularyPayload: Encodable {
    let model: String
    let messages: [VocabularyMessage]
    let temperature: Double
}

private struct VocabularyMessage: Encodable {
    let role: String
    let content: String
}

private enum VocabularyError: Error {
    case requestFailed(Int)
}
