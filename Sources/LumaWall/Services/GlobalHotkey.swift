import AppKit
import Carbon

private func asterGlobalHotkeyHandler(
    nextHandler: EventHandlerCallRef?,
    event: EventRef?,
    userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    var identifier = EventHotKeyID()
    var actualSize = 0
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        &actualSize,
        &identifier
    )
    let hotkey = Unmanaged<GlobalHotkey>.fromOpaque(userData).takeUnretainedValue()
    guard status == noErr,
          identifier.signature == hotkey.signature,
          identifier.id == hotkey.identifier else {
        return OSStatus(eventNotHandledErr)
    }
    Task { @MainActor in hotkey.action() }
    return noErr
}

/// One system-wide keyboard shortcut that works while Aster is in the background.
final class GlobalHotkey: @unchecked Sendable {
    fileprivate let signature: OSType
    fileprivate let identifier: UInt32
    fileprivate let action: @MainActor () -> Void
    private var registration: EventHotKeyRef?
    private var handler: EventHandlerRef?

    @MainActor
    init(signature: OSType, identifier: UInt32, action: @escaping @MainActor () -> Void) {
        self.signature = signature
        self.identifier = identifier
        self.action = action
    }

    @MainActor
    var isRegistered: Bool { registration != nil }

    /// Replaces any current registration. Returns false when macOS or another
    /// app already owns the shortcut.
    @MainActor
    @discardableResult
    func register(_ binding: ShortcutBinding) -> Bool {
        unregister()
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let installed = InstallEventHandler(
            GetApplicationEventTarget(),
            asterGlobalHotkeyHandler,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &handler
        )
        guard installed == noErr else {
            handler = nil
            return false
        }
        var modifiers: UInt32 = 0
        if binding.modifiers.contains(.command) { modifiers |= UInt32(cmdKey) }
        if binding.modifiers.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if binding.modifiers.contains(.option) { modifiers |= UInt32(optionKey) }
        if binding.modifiers.contains(.control) { modifiers |= UInt32(controlKey) }
        let status = RegisterEventHotKey(
            UInt32(binding.keyCode),
            modifiers,
            EventHotKeyID(signature: signature, id: identifier),
            GetApplicationEventTarget(),
            0,
            &registration
        )
        guard status == noErr, registration != nil else {
            unregister()
            return false
        }
        return true
    }

    @MainActor
    func unregister() {
        if let registration {
            UnregisterEventHotKey(registration)
            self.registration = nil
        }
        if let handler {
            RemoveEventHandler(handler)
            self.handler = nil
        }
    }
}
