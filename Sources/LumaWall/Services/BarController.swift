import AppKit
import Observation

@MainActor
@Observable
final class BarController {
    var isEnabled: Bool {
        didSet {
            defaults.set(isEnabled, forKey: Keys.enabled)
            syncActivation()
        }
    }

    var compactSpacing: Bool {
        didSet {
            defaults.set(compactSpacing, forKey: Keys.compactSpacing)
            if isEnabled && !isCollapsed { dividerItem?.length = expandedDividerLength }
        }
    }

    var rememberCollapsedState: Bool {
        didSet { defaults.set(rememberCollapsedState, forKey: Keys.rememberCollapsedState) }
    }

    var menuBarSpacingOffset: Double

    private(set) var isCollapsed: Bool
    private(set) var statusMessage = "Enable Bar, then arrange icons with Command-drag"
    private(set) var appliedMenuBarSpacingOffset: Double
    private(set) var isApplyingMenuBarSpacing = false
    private(set) var spacingStatusMessage = "Adjust the spacing, then apply"

    private let defaults = UserDefaults.standard
    private var controlItem: NSStatusItem?
    private var dividerItem: NSStatusItem?
    private var screenObserver: NSObjectProtocol?
    private var hasActivated = false
    private var toggleLocked = false

    private enum Keys {
        static let enabled = "Aster.Bar.enabled"
        static let compactSpacing = "Aster.Bar.spacing"
        static let rememberCollapsedState = "Aster.Bar.rememberCollapsedState"
        static let collapsed = "Aster.Bar.collapsed"
        static let menuBarSpacingOffset = "Aster.Bar.menuBarSpacingOffset"
        static let controlPosition = "NSStatusItem Preferred Position Aster.Bar.Control"
        static let dividerPosition = "NSStatusItem Preferred Position Aster.Bar.Divider"
    }

    private static let systemSpacingKeys = ["NSStatusItemSpacing", "NSStatusItemSelectionPadding"]
    private static let defaultSystemSpacing = 16

    init() {
        isEnabled = defaults.bool(forKey: Keys.enabled)
        compactSpacing = defaults.object(forKey: Keys.compactSpacing) as? Bool ?? true
        rememberCollapsedState = defaults.object(forKey: Keys.rememberCollapsedState) as? Bool ?? true
        isCollapsed = defaults.bool(forKey: Keys.collapsed)
        let savedSpacing = defaults.object(forKey: Keys.menuBarSpacingOffset) as? Double ?? 0
        menuBarSpacingOffset = savedSpacing
        appliedMenuBarSpacingOffset = savedSpacing
    }

    func activate() {
        guard !hasActivated else { return }
        hasActivated = true
        syncActivation()
    }

    private func syncActivation() {
        guard hasActivated else { return }
        if isEnabled, screenObserver == nil {
            screenObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.screenLayoutChanged() }
            }
        } else if !isEnabled, let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
            self.screenObserver = nil
        }
        syncStatusItems()
    }

    func toggle() {
        guard isEnabled, dividerItem != nil, !toggleLocked else { return }
        toggleLocked = true
        setCollapsed(!isCollapsed)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.toggleLocked = false
        }
    }

    func showAster() {
        AsterWindowRouter.shared.show {
            NotificationCenter.default.post(name: .openAsterBar, object: nil)
        }
    }

    func resetStatusItemPositions() {
        guard isEnabled else { return }
        if isCollapsed {
            dividerItem?.length = expandedDividerLength
            isCollapsed = false
            defaults.set(false, forKey: Keys.collapsed)
        }
        clearStatusItemAutosaveState()
        removeStatusItems()
        installStatusItemsIfNeeded()
        showStatusItems()
        statusMessage = "Controls restored — Command-drag the divider and Aster beside each other"
    }

    var hasUnappliedMenuBarSpacing: Bool {
        Int(menuBarSpacingOffset) != Int(appliedMenuBarSpacingOffset)
    }

    var menuBarSpacingLabel: String {
        let offset = Int(menuBarSpacingOffset)
        if offset == 0 { return "Default" }
        return offset < 0 ? "\(-offset) pt tighter" : "\(offset) pt wider"
    }

    func applyMenuBarSpacing() {
        guard !isApplyingMenuBarSpacing else { return }
        isApplyingMenuBarSpacing = true
        spacingStatusMessage = "Applying spacing…"

        let offset = Int(menuBarSpacingOffset)
        do {
            for key in Self.systemSpacingKeys {
                if offset == 0 {
                    try Self.runDefaults(
                        ["-currentHost", "delete", "-globalDomain", key],
                        allowsFailure: true
                    )
                } else {
                    try Self.runDefaults([
                        "-currentHost", "write", "-globalDomain", key,
                        "-int", String(Self.defaultSystemSpacing + offset)
                    ])
                }
            }
            defaults.set(Double(offset), forKey: Keys.menuBarSpacingOffset)
            menuBarSpacingOffset = Double(offset)
            appliedMenuBarSpacingOffset = Double(offset)
            spacingStatusMessage = offset == 0
                ? "Default spacing restored"
                : "Spacing applied — reopen third-party menu apps if needed"
            refreshSystemStatusItems()
        } catch {
            spacingStatusMessage = "Could not apply menu bar spacing"
        }
        isApplyingMenuBarSpacing = false
    }

    func resetMenuBarSpacing() {
        menuBarSpacingOffset = 0
        applyMenuBarSpacing()
    }

    private func syncStatusItems() {
        guard hasActivated else { return }
        if isEnabled {
            installStatusItemsIfNeeded()
            showStatusItems()
        } else {
            hideStatusItems()
        }
    }

    private func showStatusItems() {
        let shouldRestoreCollapsedState = isCollapsed
        // AppKit persists a Command-dragged removal through autosaveName. Bar has
        // its own enable switch, so enabling it always restores both controls.
        controlItem?.isVisible = true
        dividerItem?.isVisible = true
        controlItem?.length = NSStatusItem.squareLength
        dividerItem?.length = expandedDividerLength
        controlItem?.button?.isHidden = false
        dividerItem?.button?.isHidden = false

        if shouldRestoreCollapsedState {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isEnabled, self.isCollapsed else { return }
                self.dividerItem?.length = self.collapsedDividerLength
            }
        }
        statusMessage = isCollapsed
            ? "Utility icons left of the divider are hidden"
            : "Command-drag utility icons to the left of the divider"
    }

    private func hideStatusItems() {
        // Keep the native status-item objects anchored in the menu bar. Toggling
        // isVisible can make AppKit reinsert two neighboring items in the wrong
        // order, while removing them loses their dragged positions entirely.
        controlItem?.button?.isHidden = true
        dividerItem?.button?.isHidden = true
        controlItem?.length = 0
        dividerItem?.length = 0
        statusMessage = "Bar is off"
    }

    private func refreshSystemStatusItems() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        process.arguments = ["ControlCenter"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }

    private static func runDefaults(_ arguments: [String], allowsFailure: Bool = false) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 && !allowsFailure {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    private func installStatusItemsIfNeeded() {
        guard controlItem == nil, dividerItem == nil else { return }

        let statusBar = NSStatusBar.system
        let control = statusBar.statusItem(withLength: NSStatusItem.squareLength)
        control.autosaveName = "Aster.Bar.Control"
        control.behavior = []
        control.isVisible = true
        if let button = control.button {
            button.image = Self.asterStatusImage()
            button.imagePosition = .imageOnly
            button.toolTip = "Aster Bar — click to show or hide utility icons"
            button.target = self
            button.action = #selector(controlPressed(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        let divider = statusBar.statusItem(withLength: expandedDividerLength)
        divider.autosaveName = "Aster.Bar.Divider"
        divider.behavior = []
        divider.isVisible = true
        if let button = divider.button {
            button.image = Self.dividerImage()
            button.imagePosition = .imageOnly
            button.toolTip = "Command-drag this divider; utility icons to its left will collapse"
        }

        controlItem = control
        dividerItem = divider
        statusMessage = "Command-drag utility icons to the left of the divider"

        let shouldCollapse = rememberCollapsedState && isCollapsed
        isCollapsed = false
        divider.length = expandedDividerLength
        if shouldCollapse {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
                self?.setCollapsed(true)
            }
        }
    }

    private func removeStatusItems() {
        if let controlItem { NSStatusBar.system.removeStatusItem(controlItem) }
        if let dividerItem { NSStatusBar.system.removeStatusItem(dividerItem) }
        controlItem = nil
        dividerItem = nil
        statusMessage = "Bar is off"
    }

    private func clearStatusItemAutosaveState() {
        // AppKit documents assigning nil as the supported way to clear a status
        // item's persisted visibility. Clear the older position keys as well.
        controlItem?.autosaveName = nil
        dividerItem?.autosaveName = nil
        defaults.removeObject(forKey: Keys.controlPosition)
        defaults.removeObject(forKey: Keys.dividerPosition)
    }

    private func setCollapsed(_ collapsed: Bool) {
        guard let dividerItem, collapsed != isCollapsed else { return }
        if collapsed && !statusItemsAreInValidOrder {
            statusMessage = "Hold Command and drag Aster to the right of its divider"
            updateControlIcon()
            return
        }

        isCollapsed = collapsed
        if rememberCollapsedState {
            defaults.set(collapsed, forKey: Keys.collapsed)
        }
        statusMessage = collapsed
            ? "Utility icons left of the divider are hidden"
            : "Command-drag utility icons to the left of the divider"

        // Assign this in one layout pass. Repeatedly animating NSStatusItem.length
        // makes AppKit draw the separator as a giant sweeping bar and can leave
        // neighboring status items in their original positions.
        dividerItem.length = collapsed ? collapsedDividerLength : expandedDividerLength
        updateControlIcon()
    }

    private func updateControlIcon() {
        guard let button = controlItem?.button else { return }
        button.image = Self.asterStatusImage()
    }

    private func screenLayoutChanged() {
        guard isEnabled, isCollapsed else { return }
        dividerItem?.length = collapsedDividerLength
    }

    @objc private func controlPressed(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu(from: sender)
        } else {
            toggle()
        }
    }

    private func showContextMenu(from button: NSStatusBarButton) {
        let menu = NSMenu()
        let toggleItem = NSMenuItem(
            title: isCollapsed ? "Show Utility Icons" : "Hide Utility Icons",
            action: #selector(toggleFromMenu),
            keyEquivalent: ""
        )
        toggleItem.target = self
        menu.addItem(toggleItem)
        if !AsterAppPresence.showsInDock() {
            let openItem = NSMenuItem(
                title: "Open Aster",
                action: #selector(openSettings),
                keyEquivalent: ""
            )
            openItem.target = self
            menu.addItem(openItem)
        }
        let resetItem = NSMenuItem(title: "Restore Aster Menu Bar Controls", action: #selector(resetPositionsFromMenu), keyEquivalent: "")
        resetItem.target = self
        menu.addItem(resetItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Aster", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.maxY + 4), in: button)
    }

    @objc private func toggleFromMenu() {
        toggle()
    }

    @objc private func openSettings() {
        showAster()
    }

    @objc private func resetPositionsFromMenu() {
        resetStatusItemPositions()
    }

    private var expandedDividerLength: CGFloat { compactSpacing ? 12 : 18 }

    private var statusItemsAreInValidOrder: Bool {
        guard let controlX = controlItem?.button?.window?.frame.origin.x,
              let dividerX = dividerItem?.button?.window?.frame.origin.x else {
            return true
        }
        if NSApp.userInterfaceLayoutDirection == .rightToLeft {
            return controlX <= dividerX
        }
        return controlX >= dividerX
    }

    private var collapsedDividerLength: CGFloat {
        let width = NSScreen.screens.map(\.frame.width).max() ?? 1728
        return min(max(width * 2, 700), 10_000)
    }

    private static func asterStatusImage() -> NSImage? {
        guard let url = Bundle.asterResources.url(forResource: "AsterStatusIcon", withExtension: "svg"),
              let source = NSImage(contentsOf: url) else { return NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Aster") }
        let image = source.copy() as? NSImage ?? source
        image.size = NSSize(width: 22, height: 22)
        image.isTemplate = true
        return image
    }

    private static func dividerImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 8, height: 18))
        image.lockFocus()
        NSColor.secondaryLabelColor.withAlphaComponent(0.65).setFill()
        NSBezierPath(roundedRect: NSRect(x: 6, y: 2, width: 1, height: 14), xRadius: 0.5, yRadius: 0.5).fill()
        NSColor.secondaryLabelColor.withAlphaComponent(0.72).setStroke()
        let arrow = NSBezierPath()
        arrow.move(to: NSPoint(x: 4.2, y: 5.8))
        arrow.line(to: NSPoint(x: 1.8, y: 9))
        arrow.line(to: NSPoint(x: 4.2, y: 12.2))
        arrow.lineWidth = 1
        arrow.lineCapStyle = .round
        arrow.lineJoinStyle = .round
        arrow.stroke()
        image.unlockFocus()
        image.isTemplate = true
        return image
    }
}

extension Notification.Name {
    static let openAsterBar = Notification.Name("Aster.openBar")
}
