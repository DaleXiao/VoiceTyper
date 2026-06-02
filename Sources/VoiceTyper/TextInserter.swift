import AppKit
import ApplicationServices

struct TextInsertionTarget {
    let application: NSRunningApplication?
    let focusedElement: AXUIElement?
    let selectedRange: CFRange?
}

struct TextReplacementHandle {
    let element: AXUIElement
    let range: CFRange
    let text: String
}

enum TextOutputMethod: Equatable {
    case capturedAccessibilityElement
    case focusedAccessibilityElement
    case pasteboardShortcut
    case clipboardOnly

    var title: String {
        switch self {
        case .capturedAccessibilityElement:
            return "捕获焦点"
        case .focusedAccessibilityElement:
            return "当前焦点"
        case .pasteboardShortcut:
            return "剪贴板粘贴"
        case .clipboardOnly:
            return "复制到剪贴板"
        }
    }
}

final class TextInserter {
    func captureTarget(application: NSRunningApplication?) -> TextInsertionTarget {
        let focusedElement = focusedElement(for: application)
        return TextInsertionTarget(
            application: application,
            focusedElement: focusedElement,
            selectedRange: focusedElement.flatMap { selectedTextRange(for: $0) }
        )
    }

    func insert(
        _ text: String,
        preserveClipboard: Bool,
        target: TextInsertionTarget?,
        completion: ((TextOutputMethod, TextReplacementHandle?) -> Void)? = nil
    ) {
        let delay = activationDelay(for: target?.application)

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [self] in
            if let focusedElement = target?.focusedElement,
               insert(text, into: focusedElement) {
                completion?(
                    .capturedAccessibilityElement,
                    replacementHandle(element: focusedElement, selectedRange: target?.selectedRange, text: text)
                )
                return
            }

            if let focusedResult = insertViaFocusedElement(text) {
                completion?(.focusedAccessibilityElement, focusedResult)
                return
            }

            pasteIntoFocusedElement(text, preserveClipboard: preserveClipboard)
            completion?(.pasteboardShortcut, nil)
        }
    }

    func replace(_ handle: TextReplacementHandle, with text: String) -> TextReplacementHandle? {
        guard currentText(in: handle.element, matches: handle) else {
            return nil
        }

        guard setSelectedTextRange(handle.range, for: handle.element),
              insert(text, into: handle.element) else {
            return nil
        }

        return replacementHandle(element: handle.element, selectedRange: handle.range, text: text)
    }

    private func activationDelay(for application: NSRunningApplication?) -> TimeInterval {
        guard let application,
              application.bundleIdentifier != Bundle.main.bundleIdentifier else {
            return 0.02
        }

        if application.isActive {
            return 0.02
        }

        application.activate(options: [.activateIgnoringOtherApps])
        return 0.12
    }

    private func focusedElement(for application: NSRunningApplication?) -> AXUIElement? {
        guard PermissionCenter.hasAccessibilityPermission() else {
            return nil
        }

        guard let focusedElement = currentFocusedElement() else {
            return nil
        }

        if let application,
           let elementProcessIdentifier = processIdentifier(for: focusedElement),
           elementProcessIdentifier != application.processIdentifier {
            return nil
        }

        return focusedElement
    }

    private func currentFocusedElement() -> AXUIElement? {
        let systemWideElement = AXUIElementCreateSystemWide()
        var focusedElement: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            systemWideElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElement
        )

        guard result == .success, let focusedElement else {
            return nil
        }

        guard CFGetTypeID(focusedElement) == AXUIElementGetTypeID() else {
            return nil
        }

        return (focusedElement as! AXUIElement)
    }

    private func processIdentifier(for element: AXUIElement) -> pid_t? {
        var processIdentifier = pid_t()
        guard AXUIElementGetPid(element, &processIdentifier) == .success else {
            return nil
        }
        return processIdentifier
    }

    private func insertViaFocusedElement(_ text: String) -> TextReplacementHandle? {
        guard let focusedElement = currentFocusedElement() else {
            return nil
        }

        let selectedRange = selectedTextRange(for: focusedElement)
        guard insert(text, into: focusedElement) else {
            return nil
        }

        return replacementHandle(element: focusedElement, selectedRange: selectedRange, text: text)
    }

    private func insert(_ text: String, into element: AXUIElement) -> Bool {
        AXUIElementSetAttributeValue(
            element,
            kAXFocusedAttribute as CFString,
            kCFBooleanTrue
        )

        return AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            text as CFTypeRef
        ) == .success
    }

    private func replacementHandle(
        element: AXUIElement,
        selectedRange: CFRange?,
        text: String
    ) -> TextReplacementHandle? {
        guard let selectedRange,
              selectedRange.location >= 0 else {
            return nil
        }

        return TextReplacementHandle(
            element: element,
            range: CFRange(location: selectedRange.location, length: (text as NSString).length),
            text: text
        )
    }

    private func selectedTextRange(for element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &value
        ) == .success,
        let value,
        CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }

        var range = CFRange()
        guard AXValueGetValue((value as! AXValue), .cfRange, &range) else {
            return nil
        }

        return range
    }

    private func setSelectedTextRange(_ range: CFRange, for element: AXUIElement) -> Bool {
        var range = range
        guard let value = AXValueCreate(.cfRange, &range) else {
            return false
        }

        return AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            value
        ) == .success
    }

    private func currentText(in element: AXUIElement, matches handle: TextReplacementHandle) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXValueAttribute as CFString,
            &value
        ) == .success,
        let currentText = value as? String else {
            return false
        }

        let nsText = currentText as NSString
        let range = NSRange(location: handle.range.location, length: handle.range.length)
        guard range.location >= 0,
              range.length >= 0,
              range.location + range.length <= nsText.length else {
            return false
        }

        return nsText.substring(with: range) == handle.text
    }

    private func sendPasteShortcut() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)

        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand

        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }

    private func pasteIntoFocusedElement(_ text: String, preserveClipboard: Bool) {
        let snapshot = preserveClipboard ? PasteboardSnapshot.capture() : nil
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        sendPasteShortcut()

        if let snapshot {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                snapshot.restore()
            }
        }
    }
}

private struct PasteboardSnapshot {
    private let items: [[NSPasteboard.PasteboardType: Data]]

    static func capture() -> PasteboardSnapshot {
        let copiedItems = NSPasteboard.general.pasteboardItems?.map { item in
            item.types.reduce(into: [NSPasteboard.PasteboardType: Data]()) { partialResult, type in
                partialResult[type] = item.data(forType: type)
            }
        } ?? []

        return PasteboardSnapshot(items: copiedItems)
    }

    func restore() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        let pasteboardItems = items.map { itemData in
            let item = NSPasteboardItem()
            for (type, data) in itemData {
                item.setData(data, forType: type)
            }
            return item
        }

        if !pasteboardItems.isEmpty {
            pasteboard.writeObjects(pasteboardItems)
        }
    }
}
