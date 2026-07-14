import SwiftUI

@main
struct AsterApp: App {
    @NSApplicationDelegateAdaptor(AsterAppDelegate.self) private var appDelegate
    @AppStorage("Aster.Onboarding.completed") private var hasCompletedOnboarding = false
    @State private var library = WallpaperLibrary()
    @State private var controller = WallpaperController()
    @State private var clipboard = ClipboardManager()
    @State private var shelf = ShelfController()
    @State private var bar = BarController()
    @State private var switches = SwitchController()
    @State private var clipsPanel = ClipsPanelController()
    @State private var updates = UpdateManager()

    init() {
        // Aster is a regular foreground utility. Explicitly setting this keeps
        // a Dock presence even when launched as a Swift Package executable.
        NSApplication.shared.setActivationPolicy(.regular)
        if let iconURL = Bundle.asterResources.url(forResource: "AsterIcon", withExtension: "svg"),
           let icon = NSImage(contentsOf: iconURL) {
            NSApplication.shared.applicationIconImage = icon
        }
    }

    var body: some Scene {
        WindowGroup {
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
                .environment(library)
                .environment(controller)
                .environment(clipboard)
                .environment(shelf)
                .environment(bar)
                .environment(switches)
                .environment(updates)
                .frame(minWidth: 1_100, minHeight: 720)
                .preferredColorScheme(.dark)
                .onAppear {
                    clipsPanel.activate(clipboard: clipboard)
                    bar.activate()
                    updates.start()
                }
                .onChange(of: clipboard.isMonitoring) { _, isMonitoring in
                    clipsPanel.setEnabled(isMonitoring)
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Import into Canvas…") {
                    NotificationCenter.default.post(name: .importWallpaper, object: nil)
                }
                .keyboardShortcut("o")
            }
        }

        Settings {
            SettingsView()
                .environment(controller)
                .environment(clipboard)
                .environment(updates)
        }
    }
}

@MainActor
final class AsterAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
        bringMainWindowForward()
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        bringMainWindowForward()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func bringMainWindowForward() {
        let app = NSApplication.shared
        let appWindow = app.windows.first {
            $0.level == .normal && $0.canBecomeKey && !($0 is NSPanel)
        }
        appWindow?.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
    }
}

extension Notification.Name {
    static let importWallpaper = Notification.Name("Aster.importWallpaper")
}
