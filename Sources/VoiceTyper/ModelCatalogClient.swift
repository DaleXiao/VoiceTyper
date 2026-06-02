import Foundation

final class ModelCatalogClient {
    func fetchModels(settings: ModelCatalogSnapshot) async throws -> [String] {
        var request = URLRequest(url: settings.endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 30

        let headerName = settings.authHeaderName.isEmpty ? "Authorization" : settings.authHeaderName
        request.setValue("\(settings.authHeaderPrefix)\(settings.apiKey)", forHTTPHeaderField: headerName)

        let (data, response) = try await URLSession.shared.data(for: request)
        if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
            let message = String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)"
            throw ModelCatalogError.requestFailed(statusCode: httpResponse.statusCode, message: message)
        }

        let object = try JSONSerialization.jsonObject(with: data)
        let models = Self.extractModelIDs(from: object)
        guard !models.isEmpty else {
            throw ModelCatalogError.missingModels
        }

        return models
    }

    private static func extractModelIDs(from object: Any) -> [String] {
        var values: [String] = []

        if let dictionary = object as? [String: Any] {
            appendModels(from: dictionary["data"], to: &values)
            appendModels(from: dictionary["models"], to: &values)
            appendModel(from: dictionary, to: &values)
        } else {
            appendModels(from: object, to: &values)
        }

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

    private static func appendModels(from object: Any?, to values: inout [String]) {
        guard let object else {
            return
        }

        if let array = object as? [Any] {
            for item in array {
                if let string = item as? String {
                    values.append(string)
                } else if let dictionary = item as? [String: Any] {
                    appendModel(from: dictionary, to: &values)
                }
            }
        } else if let dictionary = object as? [String: Any] {
            appendModel(from: dictionary, to: &values)
        } else if let string = object as? String {
            values.append(string)
        }
    }

    private static func appendModel(from dictionary: [String: Any], to values: inout [String]) {
        for key in ["id", "model", "name", "model_id"] {
            if let value = dictionary[key] as? String {
                values.append(value)
                return
            }
        }
    }
}

struct ModelCatalogSnapshot {
    let endpoint: URL
    let apiKey: String
    let authHeaderName: String
    let authHeaderPrefix: String
}

enum ModelCatalogError: LocalizedError {
    case requestFailed(statusCode: Int, message: String)
    case missingModels

    var errorDescription: String? {
        switch self {
        case .requestFailed(let statusCode, let message):
            return "模型列表请求失败（\(statusCode)）：\(message)"
        case .missingModels:
            return "模型服务响应里没有找到可用模型。"
        }
    }
}
