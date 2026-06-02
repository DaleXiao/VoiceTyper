import AppKit

final class OutputController {
    private let inserter = TextInserter()
    private var insertionTarget: TextInsertionTarget?
    private var insertionTargetApplication: NSRunningApplication?
    private var lastExternalApplication: NSRunningApplication?

    func updateLastExternalApplication(_ application: NSRunningApplication?) {
        guard let application, !isVoiceTyper(application) else {
            return
        }
        lastExternalApplication = application
    }

    func captureTarget() {
        insertionTargetApplication = captureInsertionTargetApplication()
        insertionTarget = inserter.captureTarget(application: insertionTargetApplication)
    }

    func clearTarget() {
        insertionTarget = nil
        insertionTargetApplication = nil
    }

    func output(
        _ text: String,
        autoPaste: Bool,
        preserveClipboard: Bool,
        completion: @escaping (TextOutputMethod, TextReplacementHandle?) -> Void
    ) {
        if autoPaste {
            inserter.insert(
                text,
                preserveClipboard: preserveClipboard,
                target: insertionTarget,
                completion: { outputMethod, replacementHandle in
                    completion(outputMethod, replacementHandle)
                }
            )
        } else {
            copyToClipboard(text)
            completion(.clipboardOnly, nil)
        }
    }

    func replaceOutput(_ handle: TextReplacementHandle, with text: String) -> Bool {
        inserter.replace(handle, with: text) != nil
    }

    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func captureInsertionTargetApplication() -> NSRunningApplication? {
        let frontmost = NSWorkspace.shared.frontmostApplication
        if isVoiceTyper(frontmost) {
            return lastExternalApplication
        }

        updateLastExternalApplication(frontmost)
        return frontmost
    }

    private func isVoiceTyper(_ application: NSRunningApplication?) -> Bool {
        application?.bundleIdentifier == (Bundle.main.bundleIdentifier ?? "com.local.VoiceTyper")
    }
}
