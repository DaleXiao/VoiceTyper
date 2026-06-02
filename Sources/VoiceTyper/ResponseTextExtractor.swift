import Foundation

enum ResponseTextExtractor {
    static func extractText(from data: Data, preferredKeyPath: String) throws -> String {
        let trimmedRaw = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedRaw, trimmedRaw.first != "{", trimmedRaw.first != "[" {
            return trimmedRaw
        }

        let object = try JSONSerialization.jsonObject(with: data)
        let candidates = [
            preferredKeyPath,
            "text",
            "transcript",
            "transcription",
            "result",
            "content",
            "data.text",
            "data.transcript",
            "choices.0.message.content",
            "choices.0.text"
        ].filter { !$0.isEmpty }

        for keyPath in candidates {
            if let value = value(at: keyPath, in: object), let text = stringify(value) {
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        throw TranscriptionError.missingTextField
    }

    static func value(at keyPath: String, in object: Any) -> Any? {
        keyPath.split(separator: ".").reduce(Optional(object)) { current, part in
            guard let current else {
                return nil
            }

            if let dictionary = current as? [String: Any] {
                return dictionary[String(part)]
            }

            if let array = current as? [Any], let index = Int(part), array.indices.contains(index) {
                return array[index]
            }

            return nil
        }
    }

    private static func stringify(_ value: Any) -> String? {
        if let string = value as? String {
            return string
        }

        if let number = value as? NSNumber {
            return number.stringValue
        }

        return nil
    }
}
