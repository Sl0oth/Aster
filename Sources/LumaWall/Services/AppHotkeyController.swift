import AppKit
import Carbon
import Observation

private let asterAppHotkeySignature: OSType = 0x41534150 // "ASAP"

private func asterAppHotkeyHandler(
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
    guard status == noErr, identifier.signature == asterAppHotkeySignature else {
        return OSStatus(eventNotHandledErr)
    }
    let controller = Unmanaged<AppHotkeyController>.fromOpaque(userData).takeUnretainedValue()
    Task { @MainActor in controller.handleHotkey(identifier: identifier.id) }
    return noErr
}

@MainActor
@Observable
final class AppHotkeyController {
    private weak var shortcuts: ShortcutStore?
    private var handler: EventHandlerRef?
    private var registrations: [EventHotKeyRef] = []
    private var applicationIDs: [UInt32: UUID] = [:]
    private var changesObserver: NSObjectProtocol?

    private(set) var isActive = false

    func activate(shortcuts: ShortcutStore) {
        self.shortcuts = shortcuts
        if changesObserver == nil {
            changesObserver = NotificationCenter.default.addObserver(
                forName: .asterAppHotkeysChanged,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.refresh() }
            }
        }
        refresh()
    }

    func handleHotkey(identifier: UInt32) {
        guard let id = applicationIDs[identifier],
              let hotkey = shortcuts?.appHotkeys.first(where: { $0.id == id }),
              !hotkey.isDisabled else { return }
        activateOrLaunch(hotkey)
    }

    private func refresh() {
        unregisterAll()
        guard let shortcuts else { return }
        for hotkey in shortcuts.appHotkeys {
            shortcuts.reportAppHotkeyRegistration(error: nil, for: hotkey.id)
        }

        let enabled = shortcuts.appHotkeys.filter {
            !$0.isDisabled && $0.binding != nil
        }
        guard !enabled.isEmpty else { return }
        guard installHandlerIfNeeded() else {
            for hotkey in enabled {
                shortcuts.reportAppHotkeyRegistration(
                    error: "Aster couldn’t start the global hotkey handler.",
                    for: hotkey.id
                )
            }
            return
        }

        for (offset, hotkey) in enabled.enumerated() {
            guard let binding = hotkey.binding else { continue }
            let identifierValue = UInt32(offset + 1)
            let identifier = EventHotKeyID(
                signature: asterAppHotkeySignature,
                id: identifierValue
            )
            var registration: EventHotKeyRef?
            let status = RegisterEventHotKey(
                UInt32(binding.keyCode),
                carbonModifiers(for: binding.modifiers),
                identifier,
                GetApplicationEventTarget(),
                0,
                &registration
            )
            guard status == noErr, let registration else {
                shortcuts.reportAppHotkeyRegistration(
                    error: "macOS or another app is already using \(binding.display). Choose another hotkey.",
                    for: hotkey.id
                )
                continue
            }
            registrations.append(registration)
            applicationIDs[identifierValue] = hotkey.id
        }
        isActive = !registrations.isEmpty
    }

    private func installHandlerIfNeeded() -> Bool {
        guard handler == nil else { return true }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let userData = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            asterAppHotkeyHandler,
            1,
            &eventType,
            userData,
            &handler
        )
        return status == noErr
    }

    private func unregisterAll() {
        registrations.forEach { UnregisterEventHotKey($0) }
        registrations.removeAll()
        applicationIDs.removeAll()
        isActive = false
    }

    private func activateOrLaunch(_ hotkey: AppHotkeyDefinition) {
        let workspace = NSWorkspace.shared
        let runningApp: NSRunningApplication? = {
            if let bundleIdentifier = hotkey.bundleIdentifier {
                return NSRunningApplication.runningApplications(
                    withBundleIdentifier: bundleIdentifier
                ).first
            }
            return workspace.runningApplications.first {
                $0.bundleURL?.standardizedFileURL.path == hotkey.applicationPath
            }
        }()

        if let runningApp {
            guard let applicationURL = runningApp.bundleURL ?? resolvedApplicationURL(for: hotkey) else {
                reportMissingApplication(hotkey)
                return
            }
            openAndFocus(hotkey, at: applicationURL, runningApp: runningApp)
            return
        }

        let applicationURL = resolvedApplicationURL(for: hotkey)
        guard let applicationURL else {
            reportMissingApplication(hotkey)
            return
        }

        openAndFocus(hotkey, at: applicationURL, runningApp: nil)
    }

    private func openAndFocus(
        _ hotkey: AppHotkeyDefinition,
        at applicationURL: URL,
        runningApp: NSRunningApplication?
    ) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = false
        if let bundleIdentifier = hotkey.bundleIdentifier {
            NSApplication.shared.yieldActivation(
                toApplicationWithBundleIdentifier: bundleIdentifier
            )
        }
        NSWorkspace.shared.openApplication(at: applicationURL, configuration: configuration) { [weak self] app, error in
            Task { @MainActor [weak self] in
                if let error {
                    self?.shortcuts?.reportAppHotkeyRegistration(
                        error: "\(hotkey.name) couldn’t open: \(error.localizedDescription)",
                        for: hotkey.id
                    )
                } else {
                    if let app = app ?? runningApp { self?.focus(app) }
                    self?.shortcuts?.reportAppHotkeyRegistration(error: nil, for: hotkey.id)
                }
            }
        }
    }

    private func resolvedApplicationURL(for hotkey: AppHotkeyDefinition) -> URL? {
        let storedURL = hotkey.applicationURL
        if FileManager.default.fileExists(atPath: storedURL.path) { return storedURL }
        return hotkey.bundleIdentifier.flatMap(NSWorkspace.shared.urlForApplication(withBundleIdentifier:))
    }

    private func reportMissingApplication(_ hotkey: AppHotkeyDefinition) {
        shortcuts?.reportAppHotkeyRegistration(
            error: "Aster can’t find \(hotkey.name). Remove it and add the app again.",
            for: hotkey.id
        )
    }

    private func focus(_ application: NSRunningApplication, retry: Bool = true) {
        _ = application.unhide()

        let source = NSRunningApplication.current
        NSApplication.shared.yieldActivation(to: application)
        let accepted = application.activate(from: source, options: [.activateAllWindows])
        if !accepted {
            _ = application.activate(options: [.activateAllWindows])
        }

        guard retry else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self, weak application] in
            guard let self, let application, !application.isActive else { return }
            self.focus(application, retry: false)
        }
    }

    private func carbonModifiers(for modifiers: ShortcutModifiers) -> UInt32 {
        var value: UInt32 = 0
        if modifiers.contains(.command) { value |= UInt32(cmdKey) }
        if modifiers.contains(.shift) { value |= UInt32(shiftKey) }
        if modifiers.contains(.option) { value |= UInt32(optionKey) }
        if modifiers.contains(.control) { value |= UInt32(controlKey) }
        return value
    }
}
