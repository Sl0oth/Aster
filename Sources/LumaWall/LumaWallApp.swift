import SwiftUI

enum AsterPreferencesMigration {
    private static let migrationKey = "Aster.Preferences.migratedExecutableDomain"

    static func migrateExecutableDefaultsIfNeeded(
        target: UserDefaults = .standard,
        legacy: UserDefaults? = UserDefaults(suiteName: "Aster")
    ) {
        guard !target.bool(forKey: migrationKey), let legacy else { return }
        for (key, value) in legacy.dictionaryRepresentation() where key.hasPrefix("Aster.") {
            target.set(value, forKey: key)
        }
        target.set(true, forKey: migrationKey)
    }
}

enum AsterAppPresence {
    static let showsInDockKey = "Aster.App.showsInDock"

    static func showsInDock(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: showsInDockKey) as? Bool ?? true
    }

    @MainActor
    static func setShowsInDock(_ showsInDock: Bool, defaults: UserDefaults = .standard) {
        defaults.set(showsInDock, forKey: showsInDockKey)
        apply(showsInDock)
        NotificationCenter.default.post(name: .asterPresenceChanged, object: nil)
    }

    @MainActor
    static func applySavedPreference(defaults: UserDefaults = .standard) {
        apply(showsInDock(defaults: defaults))
    }

    @MainActor
    private static func apply(_ showsInDock: Bool) {
        let app = NSApplication.shared
        let policy: NSApplication.ActivationPolicy = showsInDock ? .regular : .accessory
        guard app.activationPolicy() != policy else { return }

        let visibleWindows = app.orderedWindows.filter(\.isVisible)
        let keyWindow = app.keyWindow
        let wasActive = app.isActive
        guard app.setActivationPolicy(policy) else { return }

        restore(
            visibleWindows: visibleWindows,
            keyWindow: keyWindow,
            wasActive: wasActive
        )
        DispatchQueue.main.async {
            restore(
                visibleWindows: visibleWindows,
                keyWindow: keyWindow,
                wasActive: wasActive
            )
        }
    }

    @MainActor
    private static func restore(
        visibleWindows: [NSWindow],
        keyWindow: NSWindow?,
        wasActive: Bool
    ) {
        guard !visibleWindows.isEmpty else { return }
        let app = NSApplication.shared
        app.unhide(nil)
        for window in visibleWindows.reversed() {
            window.orderFrontRegardless()
        }
        keyWindow?.makeKeyAndOrderFront(nil)
        if wasActive { app.activate() }
    }
}

@MainActor
final class AsterWindowRouter {
    static let shared = AsterWindowRouter()
    static let mainWindowIdentifier = NSUserInterfaceItemIdentifier("Aster.MainWindow")

    private var openMainWindow: (() -> Void)?
    private var isOpeningWindow = false

    func register(openWindow: @escaping () -> Void) {
        openMainWindow = openWindow
    }

    func show(completion: (() -> Void)? = nil) {
        if let window = mainWindow {
            bringForward(window)
            completion?()
            return
        }
        guard let openMainWindow else {
            NSApplication.shared.activate(ignoringOtherApps: true)
            return
        }
        guard !isOpeningWindow else {
            waitForWindow(attemptsRemaining: 20, completion: completion)
            return
        }
        isOpeningWindow = true
        openMainWindow()
        waitForWindow(attemptsRemaining: 20, completion: completion)
    }

    private var mainWindow: NSWindow? {
        NSApplication.shared.windows.first {
            $0.identifier == Self.mainWindowIdentifier
        } ?? NSApplication.shared.windows.first {
            $0.level == .normal && !($0 is NSPanel) && $0.frame.width >= 900
        }
    }

    private func waitForWindow(attemptsRemaining: Int, completion: (() -> Void)?) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            if let window = self.mainWindow {
                self.isOpeningWindow = false
                self.bringForward(window)
                completion?()
            } else if attemptsRemaining > 0 {
                self.waitForWindow(
                    attemptsRemaining: attemptsRemaining - 1,
                    completion: completion
                )
            } else {
                self.isOpeningWindow = false
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
        }
    }

    private func bringForward(_ window: NSWindow) {
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

private struct AsterWindowRegistrationView: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                AsterWindowRouter.shared.register {
                    openWindow(id: "main")
                }
            }
    }
}

@main
struct AsterApp: App {
    @NSApplicationDelegateAdaptor(AsterAppDelegate.self) private var appDelegate
    @AppStorage("Aster.Onboarding.completed") private var hasCompletedOnboarding = false
    @State private var library: WallpaperLibrary
    @State private var controller: WallpaperController
    @State private var clipboard: ClipboardManager
    @State private var shelf: ShelfController
    @State private var bar: BarController
    @State private var switches: SwitchController
    @State private var clipsPanel: ClipsPanelController
    @State private var updates: UpdateManager
    @State private var shortcuts: ShortcutStore
    @State private var shortcutRemapper: MacShortcutRemapper
    @State private var appHotkeys: AppHotkeyController

    init() {
        AsterPreferencesMigration.migrateExecutableDefaultsIfNeeded()
        _library = State(initialValue: WallpaperLibrary())
        _controller = State(initialValue: WallpaperController())
        _clipboard = State(initialValue: ClipboardManager())
        _shelf = State(initialValue: ShelfController())
        _bar = State(initialValue: BarController())
        _switches = State(initialValue: SwitchController())
        _clipsPanel = State(initialValue: ClipsPanelController())
        _updates = State(initialValue: UpdateManager())
        _shortcuts = State(initialValue: ShortcutStore())
        _shortcutRemapper = State(initialValue: MacShortcutRemapper())
        _appHotkeys = State(initialValue: AppHotkeyController())
        AsterAppPresence.applySavedPreference()
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            Group {
                if hasCompletedOnboarding {
                    RootView()
                        .transition(.opacity.combined(with: .scale(scale: 1.01)))
                } else {
                    OnboardingView {
                        withAnimation(.easeInOut(duration: 0.6)) {
                            hasCompletedOnboarding = true
                        }
                    }
                    .transition(.opacity)
                }
            }
                .background(AsterWindowRegistrationView())
                .environment(library)
                .environment(controller)
                .environment(clipboard)
                .environment(shelf)
                .environment(bar)
                .environment(switches)
                .environment(updates)
                .environment(shortcuts)
                .environment(shortcutRemapper)
                .environment(appHotkeys)
                .frame(minWidth: 1_100, minHeight: 720)
                .preferredColorScheme(.dark)
                .onAppear {
                    clipsPanel.activate(clipboard: clipboard, shortcuts: shortcuts)
                    shortcutRemapper.activate(shortcuts: shortcuts)
                    appHotkeys.activate(shortcuts: shortcuts)
                    bar.activate(shortcuts: shortcuts)
                    updates.start()
                }
                .onChange(of: clipboard.isPanelAvailable) { _, isAvailable in
                    clipsPanel.setEnabled(isAvailable)
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Import into Canvas…") {
                    NotificationCenter.default.post(name: .importWallpaper, object: nil)
                }
                .optionalKeyboardShortcut(
                    shortcuts.isDisabled(.importCanvas)
                        ? nil
                        : shortcuts.binding(for: .importCanvas)
                )
            }
        }

        Settings {
            SettingsView()
                .environment(controller)
                .environment(clipboard)
                .environment(shelf)
                .environment(bar)
                .environment(switches)
                .environment(updates)
        }
    }
}

@MainActor
final class AsterAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AsterAppPresence.applySavedPreference()
        AsterMenuBarFallback.shared.start()
        DispatchQueue.main.async {
            AsterWindowRouter.shared.show()
        }
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        AsterWindowRouter.shared.show()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

}

/// Keeps Aster reachable when it has no Dock icon and Bar is off: without
/// either, there would be no way to open the window again.
@MainActor
final class AsterMenuBarFallback: NSObject {
    static let shared = AsterMenuBarFallback()

    private var item: NSStatusItem?
    private var observer: NSObjectProtocol?

    nonisolated static func isNeeded(showsInDock: Bool, barIsEnabled: Bool) -> Bool {
        !showsInDock && !barIsEnabled
    }

    func start() {
        if observer == nil {
            observer = NotificationCenter.default.addObserver(
                forName: .asterPresenceChanged,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.sync() }
            }
        }
        sync()
    }

    private func sync() {
        let needed = Self.isNeeded(
            showsInDock: AsterAppPresence.showsInDock(),
            barIsEnabled: UserDefaults.standard.bool(forKey: "Aster.Bar.enabled")
        )
        if needed, item == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.button?.image = BarController.asterStatusImage()
            item.button?.toolTip = "Aster"
            let menu = NSMenu()
            let open = NSMenuItem(title: "Open Aster", action: #selector(openAster), keyEquivalent: "")
            open.target = self
            menu.addItem(open)
            menu.addItem(.separator())
            menu.addItem(NSMenuItem(
                title: "Quit Aster",
                action: #selector(NSApplication.terminate(_:)),
                keyEquivalent: "q"
            ))
            item.menu = menu
            self.item = item
        } else if !needed, let item {
            NSStatusBar.system.removeStatusItem(item)
            self.item = nil
        }
    }

    @objc private func openAster() {
        AsterWindowRouter.shared.show()
    }
}

extension Notification.Name {
    static let importWallpaper = Notification.Name("Aster.importWallpaper")
}
