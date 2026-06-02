import AppKit
import SwiftUI

final class EditingHostingView<Content: View>: NSHostingView<Content> {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command),
              let characters = event.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: event)
        }

        let selector: Selector?
        switch characters {
        case "x":
            selector = #selector(NSText.cut(_:))
        case "c":
            selector = #selector(NSText.copy(_:))
        case "v":
            selector = #selector(NSText.paste(_:))
        case "a":
            selector = #selector(NSText.selectAll(_:))
        case "z":
            if event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.shift) {
                selector = Selector(("redo:"))
            } else {
                selector = Selector(("undo:"))
            }
        default:
            selector = nil
        }

        guard let selector else {
            return super.performKeyEquivalent(with: event)
        }

        if NSApp.sendAction(selector, to: nil, from: self) {
            return true
        }

        return super.performKeyEquivalent(with: event)
    }
}
