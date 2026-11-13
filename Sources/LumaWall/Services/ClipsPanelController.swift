import AppKit
import Carbon
import Observation
import SwiftUI

@MainActor
@Observable
final class ClipsPanelController {
    private let hotKeySignature: OSType = 0x41535452 // "ASTR"
    private let hotKeyIdentifier: UInt32 = 1
    private weak var clipboard: ClipboardManager?
    private weak var shortcuts: ShortcutStore?
    private var panel: ClipsHotKeyPanel?
    private var hotKey: EventHotKeyRef?
    private var hotKeyHandler: EventHandlerRef?
    private var hotKeyObserver: NSObjectProtocol?
    private var shortcutChangesObserver: NSObjectProtocol?
    private var outsideClickMonitor: Any?

    func activate(clipboard: ClipboardManager, shortcuts: ShortcutStore) {
        self.clipboard = clipboard
        self.shortcuts = shortcuts
        if shortcutChangesObserver == nil {
            shortcutChangesObserver = NotificationCenter.default.addObserver(
                forName: .asterShortcutsChanged,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.reregisterHotKey() }
            }
        }
        setEnabled(clipboard.isPanelAvailable)
    }

    func setEnabled(_ enabled: Bool) {
        if enabled {
            registerHotKeyIfNeeded()
        } else {
            deactivate()
        }
    }

    func toggle() {
        if panel?.isVisible == true {
            dismiss()
        } else {
            show()
        }
    }

    func show() {
        guard let clipboard else { return }
        createPanelIfNeeded(clipboard: clipboard)
        guard let panel else { return }

        clipboard.searchText = ""
        position(panel)
        panel.orderFrontRegardless()
        panel.makeKey()
        installOutsideClickMonitor()
    }

    func dismiss() {
        panel?.orderOut(nil)
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
    }

    /// Called after a clip was chosen in the panel: closes it and, when the user
    /// asked for it, pastes into the app they were working in.
    private func finishCopy() {
        dismiss()
        guard clipboard?.pastesAfterCopy == true else { return }
        // Give the previous app a moment to take keyboard focus back.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            ClipsPasteAction.pasteIntoFrontmostApp()
        }
    }

    private func registerHotKeyIfNeeded() {
        guard hotKey == nil,
              shortcuts?.isDisabled(.showClipsGlobally) != true else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ in
                guard let event else { return OSStatus(eventNotHandledErr) }
                var identifier = EventHotKeyID()
                var actualSize = 0
                let parameterStatus = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    &actualSize,
                    &identifier
                )
                guard parameterStatus == noErr,
                      identifier.signature == 0x41535452,
                      identifier.id == 1 else { return OSStatus(eventNotHandledErr) }
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .asterClipsHotKeyPressed, object: nil)
                }
                return noErr
            },
            1,
            &eventType,
            nil,
            &hotKeyHandler
        )
        guard status == noErr else {
            NSLog("Aster could not install the Clips hotkey handler (status %d).", status)
            shortcuts?.reportGlobalShortcutRegistration(
                error: "Aster couldn’t start the global shortcut handler. Try relaunching Aster."
            )
            return
        }

        let shortcut = shortcuts?.binding(for: .showClipsGlobally)
            ?? AsterShortcutAction.showClipsGlobally.defaultBinding
        let identifier = EventHotKeyID(signature: hotKeySignature, id: hotKeyIdentifier)
        let modifiers = carbonModifiers(for: shortcut.modifiers)
        let registrationStatus = RegisterEventHotKey(
            UInt32(shortcut.keyCode),
            modifiers,
            identifier,
            GetApplicationEventTarget(),
            0,
            &hotKey
        )
        guard registrationStatus == noErr else {
            NSLog("Aster could not register %@ (status %d).", shortcut.display, registrationStatus)
            shortcuts?.reportGlobalShortcutRegistration(
                error: "macOS or another app is already using \(shortcut.display). Choose another shortcut."
            )
            if let hotKeyHandler { RemoveEventHandler(hotKeyHandler) }
            hotKeyHandler = nil
            return
        }
        shortcuts?.reportGlobalShortcutRegistration(error: nil)

        hotKeyObserver = NotificationCenter.default.addObserver(
            forName: .asterClipsHotKeyPressed,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.toggle() }
        }
    }

    private func deactivate() {
        dismiss()
        unregisterHotKey()
        panel = nil
    }

    private func reregisterHotKey() {
        guard clipboard?.isPanelAvailable == true else { return }
        unregisterHotKey()
        registerHotKeyIfNeeded()
    }

    private func unregisterHotKey() {
        if let hotKey {
            UnregisterEventHotKey(hotKey)
            self.hotKey = nil
        }
        if let hotKeyHandler {
            RemoveEventHandler(hotKeyHandler)
            self.hotKeyHandler = nil
        }
        if let hotKeyObserver {
            NotificationCenter.default.removeObserver(hotKeyObserver)
            self.hotKeyObserver = nil
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

    private func createPanelIfNeeded(clipboard: ClipboardManager) {
        guard panel == nil else { return }
        let panel = ClipsHotKeyPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.animationBehavior = .utilityWindow
        panel.contentView = NSHostingView(
            rootView: ClipsPopupView(
                shortcuts: shortcuts,
                onCopied: { [weak self] in self?.finishCopy() },
                onDismiss: { [weak self] in self?.dismiss() }
            )
                .environment(clipboard)
                .asterAccentAware()
                .preferredColorScheme(.dark)
        )
        self.panel = panel
    }

    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen else { return }
        let visible = screen.visibleFrame
        let width = min(780, visible.width - 32)
        let height = min(520, visible.height - 32)
        panel.setFrame(
            NSRect(
                x: visible.midX - width / 2,
                y: visible.maxY - height - 24,
                width: width,
                height: height
            ),
            display: true
        )
    }

    private func installOutsideClickMonitor() {
        guard outsideClickMonitor == nil else { return }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.dismiss() }
        }
    }
}

/// Sends ⌘V to the frontmost app. macOS only allows this once Aster has been
/// granted Accessibility access.
@MainActor
enum ClipsPasteAction {
    static var isAllowed: Bool { CGPreflightPostEventAccess() }

    /// Asks macOS to show its permission prompt. Returns whether access is already granted.
    @discardableResult
    static func requestAccess() -> Bool { CGRequestPostEventAccess() }

    static func pasteIntoFrontmostApp() {
        guard isAllowed else { return }
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyCode: CGKeyCode = 9 // V
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cgAnnotatedSessionEventTap)
        keyUp?.post(tap: .cgAnnotatedSessionEventTap)
    }
}

private final class ClipsHotKeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

extension Notification.Name {
    static let asterClipsHotKeyPressed = Notification.Name("Aster.clipsHotKeyPressed")
}
