import AppKit
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gearshape") }
            ModulesSettingsTab()
                .tabItem { Label("Modules", systemImage: "square.grid.2x2") }
            ClipsSettingsTab()
                .tabItem { Label("Clips", systemImage: "doc.on.clipboard") }
            DataSettingsTab()
                .tabItem { Label("Privacy & Data", systemImage: "hand.raised") }
            UpdatesSettingsTab()
                .tabItem { Label("Updates", systemImage: "arrow.down.circle") }
        }
        .frame(width: 540)
        .asterAccentAware()
    }
}

struct GeneralSettingsTab: View {
    @Environment(WallpaperController.self) private var controller
    @State private var showsAsterInDock = AsterAppPresence.showsInDock()
    @AppStorage(AsterAccent.defaultsKey) private var accent = AsterAccent.purple.rawValue

    var body: some View {
        Form {
            Section {
                Toggle("Open Aster at login", isOn: Binding(
                    get: { controller.launchAtLogin },
                    set: { controller.setLaunchAtLogin($0) }
                ))
                Toggle("Show Aster in the Dock", isOn: Binding(
                    get: { showsAsterInDock },
                    set: { newValue in
                        showsAsterInDock = newValue
                        AsterAppPresence.setShowsInDock(newValue)
                    }
                ))
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(controller.launchAtLoginStatusMessage)
                    Text("With the Dock icon hidden, Aster keeps running and stays reachable from its menu bar icon.")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Appearance") {
                LabeledContent("Accent color") {
                    HStack(spacing: 8) {
                        ForEach(AsterAccent.allCases) { option in
                            Button { accent = option.rawValue } label: {
                                Circle()
                                    .fill(option.color)
                                    .frame(width: 20, height: 20)
                                    .overlay {
                                        if accent == option.rawValue {
                                            Image(systemName: "checkmark")
                                                .font(.system(size: 10, weight: .bold))
                                                .foregroundStyle(.white)
                                        }
                                    }
                                    .overlay(Circle().stroke(.white.opacity(0.25), lineWidth: 0.7))
                            }
                            .buttonStyle(.plain)
                            .help(option.title)
                            .accessibilityLabel(option.title)
                            .accessibilityAddTraits(accent == option.rawValue ? .isSelected : [])
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { controller.refreshLaunchAtLoginStatus() }
    }
}

struct ModulesSettingsTab: View {
    @Environment(WallpaperController.self) private var controller
    @Environment(ClipboardManager.self) private var clipboard
    @Environment(ShelfController.self) private var shelf
    @Environment(BarController.self) private var bar
    @Environment(SwitchController.self) private var switches

    var body: some View {
        @Bindable var controller = controller
        @Bindable var clipboard = clipboard
        @Bindable var shelf = shelf
        @Bindable var bar = bar
        @Bindable var switches = switches
        Form {
            Section {
                moduleToggle(.canvas, isOn: $controller.isEnabled)
                moduleToggle(.clips, isOn: $clipboard.isMonitoring)
                moduleToggle(.shelf, isOn: $shelf.isEnabled)
                moduleToggle(.bar, isOn: $bar.isEnabled)
                moduleToggle(.switchboard, isOn: $switches.isEnabled)
            } footer: {
                Text("A module that is off does nothing in the background. Keys is always available and only acts on shortcuts you set.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func moduleToggle(_ module: AsterModule, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Label {
                VStack(alignment: .leading, spacing: 1) {
                    Text(module.title)
                    Text(module.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: module.symbol)
                    .foregroundStyle(Color.asterAccent)
            }
        }
    }
}

struct ClipsSettingsTab: View {
    var body: some View {
        ScrollView {
            ClipsOptionsView()
                .padding(24)
        }
        .frame(height: 420)
    }
}

struct DataSettingsTab: View {
    @Environment(ClipboardManager.self) private var clipboard
    @State private var isConfirmingDeleteClips = false
    @State private var isConfirmingReset = false
    @State private var introductionsWereReset = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Aster’s data") {
                    Button("Show in Finder") { AsterDataManagement.revealDataFolder() }
                }
                LabeledContent("Clipboard history") {
                    Button("Delete All Clips…", role: .destructive) { isConfirmingDeleteClips = true }
                        .disabled(clipboard.entries.isEmpty)
                }
            } header: {
                Text("Your data")
            } footer: {
                Text("Wallpapers, clipboard history, and boards are stored only on this Mac. Aster has no account, analytics, telemetry, or advertising.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Start over") {
                LabeledContent("Module introductions") {
                    Button(introductionsWereReset ? "Will Show Again" : "Show Again") {
                        AsterDataManagement.resetIntroductions()
                        introductionsWereReset = true
                    }
                    .disabled(introductionsWereReset)
                }
                LabeledContent("All settings") {
                    Button("Reset Aster…", role: .destructive) { isConfirmingReset = true }
                }
            }
        }
        .formStyle(.grouped)
        .alert("Delete all clips?", isPresented: $isConfirmingDeleteClips) {
            Button("Cancel", role: .cancel) {}
            Button("Delete All", role: .destructive) {
                clipboard.clearHistory(includingBoardClips: true)
            }
        } message: {
            Text("This removes every clip, including clips saved to boards. Your boards stay, but empty. It can’t be undone.")
        }
        .alert("Reset all Aster settings?", isPresented: $isConfirmingReset) {
            Button("Cancel", role: .cancel) {}
            Button("Reset and Restart", role: .destructive) {
                AsterDataManagement.resetAllSettingsAndRelaunch()
            }
        } message: {
            Text("Every Aster setting returns to its default and Aster restarts with its welcome screen. Your wallpapers and clipboard history are kept.")
        }
    }
}

struct UpdatesSettingsTab: View {
    @Environment(UpdateManager.self) private var updates

    var body: some View {
        @Bindable var updates = updates
        Form {
            Section {
                LabeledContent("Version", value: "\(updates.currentVersion) (\(updates.currentBuild))")
                Toggle("Check for updates automatically", isOn: $updates.automaticallyChecksForUpdates)
                HStack {
                    Button(updates.updateButtonTitle) {
                        if updates.state == .updateAvailable {
                            updates.downloadAvailableUpdate()
                        } else if updates.state == .downloaded {
                            updates.openDownloadedUpdate()
                        } else {
                            updates.checkForUpdates()
                        }
                    }
                    .disabled(updates.isBusy)
                    Button("What’s New") { updates.showWhatsNew() }
                        .disabled(updates.whatsNew == nil)
                }
            } footer: {
                Text(updates.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

@MainActor
enum AsterDataManagement {
    static var dataFolderURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Aster", isDirectory: true)
    }

    static func revealDataFolder() {
        try? FileManager.default.createDirectory(at: dataFolderURL, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([dataFolderURL])
    }

    static func resetIntroductions(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: "Aster.ModuleIntroductions.seen")
        NotificationCenter.default.post(name: .asterIntroductionsReset, object: nil)
    }

    /// The defaults keys a reset removes: everything Aster stores, plus the menu
    /// bar positions AppKit saves for Aster's status items.
    static func settingsKeys(in defaults: UserDefaults = .standard) -> [String] {
        defaults.dictionaryRepresentation().keys.filter {
            $0.hasPrefix("Aster.") || $0.hasPrefix("NSStatusItem Preferred Position Aster.")
        }
    }

    static func resetAllSettings(defaults: UserDefaults = .standard) {
        for key in settingsKeys(in: defaults) {
            defaults.removeObject(forKey: key)
        }
        defaults.synchronize()
    }

    static func resetAllSettingsAndRelaunch() {
        resetAllSettings()
        relaunch()
    }

    /// Quits Aster and opens it again once this process has exited.
    static func relaunch() {
        let bundleURL = Bundle.main.bundleURL
        if bundleURL.pathExtension == "app" {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            let pid = ProcessInfo.processInfo.processIdentifier
            process.arguments = [
                "-c",
                "while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.1; done; /usr/bin/open \"$0\"",
                bundleURL.path
            ]
            try? process.run()
        }
        NSApplication.shared.terminate(nil)
    }
}

extension Notification.Name {
    static let asterIntroductionsReset = Notification.Name("Aster.introductionsReset")
    static let asterPresenceChanged = Notification.Name("Aster.presenceChanged")
}
