import AppKit

final class ShortcutGestureMonitor {
    private var eventTap: CFMachPort?
    private var eventTapRunLoopSource: CFRunLoopSource?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var shortcut: RecordingShortcut = .functionKey
    private var shortcutEventsEnabled = true
    private var holdEnabled = false
    private var isShortcutDown = false
    private var holdActive = false
    private var holdWorkItem: DispatchWorkItem?
    private var functionPressTracking: FunctionPressTracking = .none
    private var onPressBegan: (() -> Void)?
    private var onTap: (() -> Void)?
    private var onHoldBegan: (() -> Void)?
    private var onHoldEnded: (() -> Void)?
    private var onCancel: (() -> Void)?

    func start(
        shortcut: RecordingShortcut,
        shortcutEventsEnabled: Bool,
        holdEnabled: Bool,
        onPressBegan: @escaping () -> Void,
        onTap: @escaping () -> Void,
        onHoldBegan: @escaping () -> Void,
        onHoldEnded: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        stop()
        self.shortcut = shortcut
        self.shortcutEventsEnabled = shortcutEventsEnabled
        self.holdEnabled = holdEnabled
        self.onPressBegan = onPressBegan
        self.onTap = onTap
        self.onHoldBegan = onHoldBegan
        self.onHoldEnded = onHoldEnded
        self.onCancel = onCancel

        if !installEventTap() {
            installNSEventMonitors()
        }
    }

    func stop() {
        if let eventTapRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), eventTapRunLoopSource, .commonModes)
            self.eventTapRunLoopSource = nil
        }

        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            self.eventTap = nil
        }

        removeNSEventMonitors()
        holdWorkItem?.cancel()
        holdWorkItem = nil
        isShortcutDown = false
        holdActive = false
        functionPressTracking = .none
    }

    private func installEventTap() -> Bool {
        if installEventTap(at: .cghidEventTap) {
            return true
        }

        return installEventTap(at: .cgSessionEventTap)
    }

    private func installEventTap(at location: CGEventTapLocation) -> Bool {
        let eventMask = CGEventMask(
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue)
        )

        guard let eventTap = CGEvent.tapCreate(
            tap: location,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: Self.eventTapCallback,
            userInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        ) else {
            return false
        }

        guard let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0) else {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            return false
        }

        self.eventTap = eventTap
        eventTapRunLoopSource = runLoopSource
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        return true
    }

    private static let eventTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else {
            return Unmanaged.passUnretained(event)
        }

        let monitor = Unmanaged<ShortcutGestureMonitor>.fromOpaque(userInfo).takeUnretainedValue()

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap = monitor.eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        guard let shortcutEvent = ShortcutEvent(cgEventType: type, event: event) else {
            return Unmanaged.passUnretained(event)
        }

        DispatchQueue.main.async {
            monitor.handle(shortcutEvent)
        }

        return Unmanaged.passUnretained(event)
    }

    private func installNSEventMonitors() {
        let mask: NSEvent.EventTypeMask = [.keyDown, .keyUp, .flagsChanged]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handle(ShortcutEvent(nsEvent: event))
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handle(ShortcutEvent(nsEvent: event))
            return event
        }
    }

    private func removeNSEventMonitors() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }

        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
    }

    private func handle(_ event: ShortcutEvent) {
        if isCancelEvent(event) {
            onCancel?()
            return
        }

        guard shortcutEventsEnabled else {
            return
        }

        if shortcut.isFunctionKey {
            handleFunctionKeyEvent(event)
            return
        }

        if isDownEvent(event), !isShortcutDown {
            beginPress()
            return
        }

        if isUpEvent(event), isShortcutDown {
            finishPress()
        }
    }

    private func handleFunctionKeyEvent(_ event: ShortcutEvent) {
        switch event.type {
        case .keyDown:
            if event.keyCode == shortcut.keyCode, !event.isRepeat, !isShortcutDown {
                beginFunctionPress(tracking: .keyCode)
            }
        case .keyUp:
            if event.keyCode == shortcut.keyCode, isShortcutDown {
                finishPress()
            }
        case .flagsChanged:
            let keyMatches = event.keyCode == shortcut.keyCode
            let hasFunctionFlag = event.modifierFlags.contains(.function)

            if !isShortcutDown {
                if keyMatches, hasFunctionFlag {
                    beginFunctionPress(tracking: .keyCodeAndFlag)
                } else if keyMatches {
                    beginFunctionPress(tracking: .keyCode)
                } else if hasFunctionFlag {
                    beginFunctionPress(tracking: .modifierFlag)
                }
                return
            }

            switch functionPressTracking {
            case .none:
                break
            case .keyCode:
                if keyMatches {
                    finishPress()
                }
            case .modifierFlag:
                if !hasFunctionFlag {
                    finishPress()
                }
            case .keyCodeAndFlag:
                if keyMatches || !hasFunctionFlag {
                    finishPress()
                }
            }
        }
    }

    private func beginFunctionPress(tracking: FunctionPressTracking) {
        functionPressTracking = tracking
        beginPress()
    }

    private func beginPress() {
        isShortcutDown = true
        holdActive = false
        onPressBegan?()

        if holdEnabled {
            scheduleHoldRecognition()
            return
        }

        onTap?()
    }

    private func finishPress() {
        holdWorkItem?.cancel()
        holdWorkItem = nil
        isShortcutDown = false
        functionPressTracking = .none

        if holdActive {
            holdActive = false
            onHoldEnded?()
        } else {
            onTap?()
        }
    }

    private func scheduleHoldRecognition() {
        holdWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.isShortcutDown, !self.holdActive else {
                return
            }

            self.holdActive = true
            self.onHoldBegan?()
        }
        holdWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: workItem)
    }

    private func isDownEvent(_ event: ShortcutEvent) -> Bool {
        guard event.type == .keyDown, !event.isRepeat, event.keyCode == shortcut.keyCode else {
            return false
        }

        return normalizedModifiers(event.modifierFlags) == shortcut.eventModifiers
    }

    private func isUpEvent(_ event: ShortcutEvent) -> Bool {
        return event.type == .keyUp && event.keyCode == shortcut.keyCode
    }

    private func normalizedModifiers(_ flags: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
        flags.intersection([.command, .control, .option, .shift])
    }

    private func isCancelEvent(_ event: ShortcutEvent) -> Bool {
        event.type == .keyDown && !event.isRepeat && event.keyCode == 53
    }
}

private struct ShortcutEvent {
    let type: ShortcutEventType
    let keyCode: UInt32
    let modifierFlags: NSEvent.ModifierFlags
    let isRepeat: Bool

    init?(cgEventType: CGEventType, event: CGEvent) {
        switch cgEventType {
        case .keyDown:
            type = .keyDown
        case .keyUp:
            type = .keyUp
        case .flagsChanged:
            type = .flagsChanged
        default:
            return nil
        }

        keyCode = UInt32(event.getIntegerValueField(.keyboardEventKeycode))
        modifierFlags = Self.modifierFlags(from: event.flags)
        isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
    }

    init(nsEvent event: NSEvent) {
        switch event.type {
        case .keyDown:
            type = .keyDown
        case .keyUp:
            type = .keyUp
        case .flagsChanged:
            type = .flagsChanged
        default:
            type = .keyDown
        }

        keyCode = UInt32(event.keyCode)
        modifierFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        isRepeat = event.isARepeat
    }

    private static func modifierFlags(from cgFlags: CGEventFlags) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if cgFlags.contains(.maskCommand) {
            flags.insert(.command)
        }
        if cgFlags.contains(.maskControl) {
            flags.insert(.control)
        }
        if cgFlags.contains(.maskAlternate) {
            flags.insert(.option)
        }
        if cgFlags.contains(.maskShift) {
            flags.insert(.shift)
        }
        if cgFlags.contains(.maskSecondaryFn) {
            flags.insert(.function)
        }
        return flags
    }
}

private enum ShortcutEventType {
    case keyDown
    case keyUp
    case flagsChanged
}

private enum FunctionPressTracking {
    case none
    case keyCode
    case modifierFlag
    case keyCodeAndFlag
}
