import Foundation

enum DiagnosticLogger {
    private static let queue = DispatchQueue(label: "VoiceTyper.DiagnosticLogger")
    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static var logFileURL: URL {
        FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/VoiceTyper/VoiceTyper.log")
    }

    static func log(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(message)\n"
        queue.async {
            do {
                let url = logFileURL
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )

                guard let data = line.data(using: .utf8) else {
                    return
                }

                if FileManager.default.fileExists(atPath: url.path) {
                    let handle = try FileHandle(forWritingTo: url)
                    try handle.seekToEnd()
                    try handle.write(contentsOf: data)
                    try handle.close()
                } else {
                    try data.write(to: url)
                }
            } catch {
                NSLog("[说入法] diagnostic log failed: %@", error.localizedDescription)
            }
        }
    }
}
