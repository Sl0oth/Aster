import AppKit
import ApplicationServices
import Observation

private let asterRemappedEventMarker: Int64 = 0x4153544B // "ASTK"

private func asterMacShortcutEventTap(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let remapper = Unmanaged<MacShortcutRemapper>.fromOpaque(userInfo).takeUnretainedValue()
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        Task { @MainActor in remapper.enableEventTap() }
        return Unmanaged.passUnretained(event)
    }
    return remapper.remap(event)
}

@MainActor
@Observable
final class MacShortcutRemapper: @unchecked Sendable {
    private struct Rule: Sendable {
        let source: ShortcutBinding?
        let destination: ShortcutBinding
    }

    private weak var shortcuts: ShortcutStore?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var shortcutsObserver: NSObjectProtocol?
    private var activationObserver: NSObjectProtocol?
    private let rulesLock = NSLock()
    @ObservationIgnored nonisolated(unsafe) private var rules: [Rule] = []

    private(set) var isActive = false
    private(set) var needsAccessibilityPermission = false
    private(set) var statusMessage = "Customize a Mac shortcut to enable live remapping."

    func activate(shortcuts: ShortcutStore) {
        self.shortcuts = shortcuts
        if shortcutsObserver == nil {
            shortcutsObserver = NotificationCenter.default.addObserver(
                forName: .asterMacShortcutsChanged,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.refresh(promptForPermission: false) }
            }
        }
        if activationObserver == nil {
            activationObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.refresh(promptForPermission: false) }
            }
        }
        refresh(promptForPermission: false)
    }

    func requestAccessibilityPermission() {
        refresh(promptForPermission: true)
        guard needsAccessibilityPermission,
              let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    func enableEventTap() {
        guard let eventTap else { return }
        CGEvent.tapEnable(tap: eventTap, enable: true)
    }

    nonisolated func remap(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        if event.getIntegerValueField(.eventSourceUserData) == asterRemappedEventMarker {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let modifiers = Self.shortcutModifiers(from: event.flags)
        let match = rulesLock.withLock { () -> (source: Rule?, replacesDefault: Bool) in
            let source = rules.first {
                $0.source?.keyCode == keyCode && $0.source?.modifiers == modifiers
            }
            let replacesDefault = rules.contains {
                $0.destination.keyCode == keyCode && $0.destination.modifiers == modifiers
            }
            return (source, replacesDefault)
        }
        guard let rule = match.source else {
            // Once an action has a custom shortcut, consume its original
            // combination. Synthesized replacement events carry our marker
            // and return before this check, so the action still fires once.
            return match.replacesDefault ? nil : Unmanaged.passUnretained(event)
        }

        let source = CGEventSource(stateID: .hidSystemState)
        guard let keyDown = CGEvent(
            keyboardEventSource: source,
            virtualKey: CGKeyCode(rule.destination.keyCode),
            keyDown: true
        ), let keyUp = CGEvent(
            keyboardEventSource: source,
            virtualKey: CGKeyCode(rule.destination.keyCode),
            keyDown: false
        ) else {
            return Unmanaged.passUnretained(event)
        }
        let flags = Self.eventFlags(from: rule.destination.modifiers)
        keyDown.flags = flags
        keyUp.flags = flags
        keyDown.setIntegerValueField(.eventSourceUserData, value: asterRemappedEventMarker)
        keyUp.setIntegerValueField(.eventSourceUserData, value: asterRemappedEventMarker)
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return nil
    }

    private func refresh(promptForPermission: Bool) {
        guard let shortcuts else { return }
        let newRules = ShortcutStore.macShortcuts.compactMap { shortcut -> Rule? in
            if shortcuts.isDisabled(shortcut) {
                return Rule(source: nil, destination: shortcut.defaultBinding)
            }
            let binding = shortcuts.binding(for: shortcut)
            guard binding != shortcut.defaultBinding,
                  binding.modifiers.contains(.command)
                    || binding.modifiers.contains(.option)
                    || binding.modifiers.contains(.control) else { return nil }
            return Rule(source: binding, destination: shortcut.defaultBinding)
        }
        rulesLock.withLock { rules = newRules }

        guard !newRules.isEmpty else {
            stopEventTap()
            needsAccessibilityPermission = false
            statusMessage = "Customize a Mac shortcut to enable live remapping."
            return
        }

        let isTrusted: Bool
        if promptForPermission {
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            isTrusted = AXIsProcessTrustedWithOptions(options)
        } else {
            isTrusted = AXIsProcessTrusted()
        }
        guard isTrusted else {
            stopEventTap()
            needsAccessibilityPermission = true
            statusMessage = "Accessibility access is required for instant Mac shortcut changes."
            return
        }

        needsAccessibilityPermission = false
        if eventTap == nil { installEventTap() }
        if isActive {
            statusMessage = "Live — custom Mac shortcuts work instantly while Aster is running."
        }
    }

    private func installEventTap() {
        let mask = CGEventMask(1) << CGEventType.keyDown.rawValue
        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        guard let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: asterMacShortcutEventTap,
            userInfo: userInfo
        ) else {
            isActive = false
            statusMessage = "Aster couldn’t start live remapping. Check Accessibility access and try again."
            return
        }
        guard let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0) else {
            CFMachPortInvalidate(eventTap)
            isActive = false
            statusMessage = "Aster couldn’t start live remapping."
            return
        }
        self.eventTap = eventTap
        self.runLoopSource = runLoopSource
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        isActive = true
    }

    private func stopEventTap() {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            self.runLoopSource = nil
        }
        if let eventTap {
            CFMachPortInvalidate(eventTap)
            self.eventTap = nil
        }
        isActive = false
    }

    nonisolated private static func shortcutModifiers(from flags: CGEventFlags) -> ShortcutModifiers {
        var modifiers: ShortcutModifiers = []
        if flags.contains(.maskControl) { modifiers.insert(.control) }
        if flags.contains(.maskAlternate) { modifiers.insert(.option) }
        if flags.contains(.maskShift) { modifiers.insert(.shift) }
        if flags.contains(.maskCommand) { modifiers.insert(.command) }
        return modifiers
    }

    nonisolated private static func eventFlags(from modifiers: ShortcutModifiers) -> CGEventFlags {
        var flags: CGEventFlags = []
        if modifiers.contains(.control) { flags.insert(.maskControl) }
        if modifiers.contains(.option) { flags.insert(.maskAlternate) }
        if modifiers.contains(.shift) { flags.insert(.maskShift) }
        if modifiers.contains(.command) { flags.insert(.maskCommand) }
        return flags
    }
}
