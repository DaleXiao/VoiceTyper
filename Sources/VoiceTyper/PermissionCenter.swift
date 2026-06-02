import AppKit
import ApplicationServices
import AVFoundation

enum PermissionCenter {
    static func microphonePermissionStatus() -> PermissionGrantStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return .granted
        case .denied, .restricted:
            return .denied
        case .notDetermined:
            return .notDetermined
        @unknown default:
            return .unknown
        }
    }

    static func requestMicrophoneAccess(openSettingsIfDenied: Bool = false) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .denied, .restricted:
            if openSettingsIfDenied {
                openMicrophoneSettings()
            }
            return false
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
        @unknown default:
            return false
        }
    }

    static func promptForAccessibilityPermission() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func accessibilityPermissionStatus() -> PermissionGrantStatus {
        hasAccessibilityPermission() ? .granted : .notDetermined
    }

    static func hasAccessibilityPermission() -> Bool {
        AXIsProcessTrusted()
    }

    static func promptForInputMonitoringPermission() -> Bool {
        if hasInputMonitoringPermission() {
            return true
        }

        return CGRequestListenEventAccess()
    }

    static func inputMonitoringPermissionStatus() -> PermissionGrantStatus {
        hasInputMonitoringPermission() ? .granted : .notDetermined
    }

    static func hasInputMonitoringPermission() -> Bool {
        CGPreflightListenEventAccess()
    }

    static func openAccessibilitySettings() {
        openSettings(urlString: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    static func openInputMonitoringSettings() {
        openSettings(urlString: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
    }

    private static func openMicrophoneSettings() {
        openSettings(urlString: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    private static func openSettings(urlString: String) {
        guard let url = URL(string: urlString) else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}

enum PermissionGrantStatus {
    case granted
    case denied
    case notDetermined
    case unknown

    var title: String {
        switch self {
        case .granted:
            return "已授权"
        case .denied:
            return "未授权"
        case .notDetermined:
            return "待确认"
        case .unknown:
            return "未知"
        }
    }
}
