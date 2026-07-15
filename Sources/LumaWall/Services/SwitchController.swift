import AppKit
import Observation

@MainActor
@Observable
final class SwitchController {
    var isEnabled: Bool {
        didSet {
            defaults.set(isEnabled, forKey: enabledKey)
            if isEnabled { activate() } else { deactivate() }
        }
    }
    private(set) var keepsMacAwake = false
    private(set) var keepsDisplayAwake = false
    private(set) var hidesDesktopIcons = false
    private(set) var revealsDesktopOnWallpaperClick = true
    private(set) var showsHiddenFiles = false
    private(set) var showsFileExtensions = false
    private(set) var usesDarkMode = false
    private(set) var automaticallyHidesDock = false
    private(set) var mutesSystemAudio = false
    private(set) var mutesMicrophone = false
    private(set) var automaticallyHidesMenuBar = false
    private(set) var showsFinderPathBar = false
    private(set) var showsFinderStatusBar = false
    private(set) var usesDockMagnification = false
    private(set) var showsScreenshotThumbnail = true
    private(set) var isApplying = false
    private(set) var statusMessage = "Changes stay on this Mac"

    private var systemSleepActivity: NSObjectProtocol?
    private var displaySleepActivity: NSObjectProtocol?
    private let defaults = UserDefaults.standard
    private let enabledKey = "Aster.Switch.enabled"
    private let keepAwakeKey = "Aster.Switch.keepAwake"
    private let keepDisplayAwakeKey = "Aster.Switch.keepDisplayAwake"
    private let previousInputVolumeKey = "Aster.Switch.previousInputVolume"
    private let menuBarMigrationKey = "Aster.Switch.migratedMenuBarAutoHide"

    init() {
        isEnabled = defaults.bool(forKey: enabledKey)
        guard isEnabled else {
            statusMessage = "Switch is off"
            return
        }
        activate()
    }

    private func activate() {
        migrateMenuBarSettingIfNeeded()
        keepsMacAwake = defaults.bool(forKey: keepAwakeKey)
        keepsDisplayAwake = defaults.bool(forKey: keepDisplayAwakeKey)
        refreshSystemState()
        updateSleepActivities()
        statusMessage = "Changes stay on this Mac"
    }

    private func deactivate() {
        if let systemSleepActivity {
            ProcessInfo.processInfo.endActivity(systemSleepActivity)
            self.systemSleepActivity = nil
        }
        if let displaySleepActivity {
            ProcessInfo.processInfo.endActivity(displaySleepActivity)
            self.displaySleepActivity = nil
        }
        statusMessage = "Switch is off"
    }

    private func migrateMenuBarSettingIfNeeded() {
        guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26,
              !UserDefaults.standard.bool(forKey: menuBarMigrationKey),
              Self.readDefault(domain: "NSGlobalDomain", key: "_HIHideMenuBar") != nil else { return }
        let legacyValue = Self.readBooleanDefault(
            domain: "NSGlobalDomain",
            key: "_HIHideMenuBar",
            fallback: false
        )
        _ = Self.run(
            "/usr/bin/defaults",
            arguments: [
                "write", "com.apple.WindowManager", "AutoHide", "-bool",
                legacyValue ? "true" : "false"
            ]
        )
        _ = Self.run("/usr/bin/killall", arguments: ["SystemUIServer"])
        UserDefaults.standard.set(true, forKey: menuBarMigrationKey)
    }

    func setKeepAwake(_ enabled: Bool) {
        guard isEnabled else { return }
        keepsMacAwake = enabled
        UserDefaults.standard.set(enabled, forKey: keepAwakeKey)
        updateSleepActivities()
        statusMessage = enabled ? "Aster will keep this Mac awake" : "Normal system sleep restored"
    }

    func setKeepDisplayAwake(_ enabled: Bool) {
        guard isEnabled else { return }
        keepsDisplayAwake = enabled
        UserDefaults.standard.set(enabled, forKey: keepDisplayAwakeKey)
        updateSleepActivities()
        statusMessage = enabled ? "Display sleep is paused" : "Normal display sleep restored"
    }

    func setDesktopIconsHidden(_ hidden: Bool) {
        guard isEnabled else { return }
        applyBooleanDefault(
            hidden ? false : true,
            domain: "com.apple.finder",
            key: "CreateDesktop",
            restart: "Finder",
            success: hidden ? "Desktop icons hidden" : "Desktop icons shown"
        ) { [weak self] in
            self?.hidesDesktopIcons = hidden
        }
    }

    func setRevealDesktopOnWallpaperClick(_ enabled: Bool) {
        guard isEnabled else { return }
        applyBooleanDefault(
            enabled,
            domain: "com.apple.WindowManager",
            key: "EnableStandardClickToShowDesktop",
            restart: "Dock",
            success: enabled
                ? "Wallpaper clicks will reveal the desktop"
                : "Wallpaper clicks will only reveal the desktop in Stage Manager"
        ) { [weak self] in
            self?.revealsDesktopOnWallpaperClick = enabled
        }
    }

    func setHiddenFilesShown(_ shown: Bool) {
        guard isEnabled else { return }
        applyBooleanDefault(
            shown,
            domain: "com.apple.finder",
            key: "AppleShowAllFiles",
            restart: "Finder",
            success: shown ? "Hidden files are visible" : "Hidden files are concealed"
        ) { [weak self] in
            self?.showsHiddenFiles = shown
        }
    }

    func setFileExtensionsShown(_ shown: Bool) {
        guard isEnabled else { return }
        applyBooleanDefault(
            shown,
            domain: "NSGlobalDomain",
            key: "AppleShowAllExtensions",
            restart: "Finder",
            success: shown ? "File extensions are visible" : "File extensions use Finder defaults"
        ) { [weak self] in
            self?.showsFileExtensions = shown
        }
    }

    func setDockAutoHide(_ enabled: Bool) {
        guard isEnabled else { return }
        applyBooleanDefault(
            enabled,
            domain: "com.apple.dock",
            key: "autohide",
            restart: "Dock",
            success: enabled ? "Dock will hide automatically" : "Dock will remain visible"
        ) { [weak self] in
            self?.automaticallyHidesDock = enabled
        }
    }

    func setDarkMode(_ enabled: Bool) {
        guard isEnabled, !isApplying else { return }
        isApplying = true
        let source = """
        tell application "System Events"
            tell appearance preferences
                set dark mode to \(enabled ? "true" : "false")
            end tell
        end tell
        """
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if error == nil {
            usesDarkMode = enabled
            statusMessage = enabled ? "Dark appearance enabled" : "Light appearance enabled"
        } else {
            statusMessage = "macOS did not allow the appearance change"
        }
        isApplying = false
    }

    func setSystemAudioMuted(_ muted: Bool) {
        guard isEnabled else { return }
        applyAppleScript(
            "set volume output muted \(muted ? "true" : "false")",
            success: muted ? "System audio muted" : "System audio restored"
        ) { [weak self] in
            self?.mutesSystemAudio = muted
        }
    }

    func setMicrophoneMuted(_ muted: Bool) {
        guard isEnabled else { return }
        let currentVolume = Self.readAppleScriptInteger("input volume of (get volume settings)") ?? 50
        if muted, currentVolume > 0 {
            UserDefaults.standard.set(currentVolume, forKey: previousInputVolumeKey)
        }
        let savedVolume = UserDefaults.standard.integer(forKey: previousInputVolumeKey)
        let restoredVolume = savedVolume > 0 ? savedVolume : 50
        applyAppleScript(
            "set volume input volume \(muted ? 0 : restoredVolume)",
            success: muted ? "Microphone input muted" : "Microphone input restored"
        ) { [weak self] in
            self?.mutesMicrophone = muted
        }
    }

    func setMenuBarAutoHide(_ enabled: Bool) {
        guard isEnabled else { return }
        applyBooleanDefault(
            enabled,
            domain: "com.apple.WindowManager",
            key: "AutoHide",
            restart: "SystemUIServer",
            success: enabled ? "Menu bar will hide automatically" : "Menu bar will remain visible"
        ) { [weak self] in
            self?.automaticallyHidesMenuBar = enabled
            _ = Self.run(
                "/usr/bin/defaults",
                arguments: ["write", "NSGlobalDomain", "_HIHideMenuBar", "-bool", enabled ? "true" : "false"]
            )
        }
    }

    func setFinderPathBarShown(_ shown: Bool) {
        guard isEnabled else { return }
        applyBooleanDefault(
            shown,
            domain: "com.apple.finder",
            key: "ShowPathbar",
            restart: nil,
            success: shown ? "Finder path bar shown" : "Finder path bar hidden"
        ) { [weak self] in
            self?.showsFinderPathBar = shown
        }
    }

    func setFinderStatusBarShown(_ shown: Bool) {
        guard isEnabled else { return }
        applyBooleanDefault(
            shown,
            domain: "com.apple.finder",
            key: "ShowStatusBar",
            restart: nil,
            success: shown ? "Finder status bar shown" : "Finder status bar hidden"
        ) { [weak self] in
            self?.showsFinderStatusBar = shown
        }
    }

    func setDockMagnification(_ enabled: Bool) {
        guard isEnabled else { return }
        applyBooleanDefault(
            enabled,
            domain: "com.apple.dock",
            key: "magnification",
            restart: "Dock",
            success: enabled ? "Dock magnification enabled" : "Dock magnification disabled"
        ) { [weak self] in
            self?.usesDockMagnification = enabled
        }
    }

    func setScreenshotThumbnailShown(_ shown: Bool) {
        guard isEnabled else { return }
        applyBooleanDefault(
            shown,
            domain: "com.apple.screencapture",
            key: "show-thumbnail",
            restart: "SystemUIServer",
            success: shown ? "Screenshot thumbnails enabled" : "Screenshot thumbnails disabled"
        ) { [weak self] in
            self?.showsScreenshotThumbnail = shown
        }
    }

    func refreshSystemState() {
        guard isEnabled else { return }
        hidesDesktopIcons = !Self.readBooleanDefault(
            domain: "com.apple.finder",
            key: "CreateDesktop",
            fallback: true
        )
        revealsDesktopOnWallpaperClick = Self.readBooleanDefault(
            domain: "com.apple.WindowManager",
            key: "EnableStandardClickToShowDesktop",
            fallback: true
        )
        showsHiddenFiles = Self.readBooleanDefault(
            domain: "com.apple.finder",
            key: "AppleShowAllFiles",
            fallback: false
        )
        showsFileExtensions = Self.readBooleanDefault(
            domain: "NSGlobalDomain",
            key: "AppleShowAllExtensions",
            fallback: false
        )
        usesDarkMode = Self.readDefault(domain: "NSGlobalDomain", key: "AppleInterfaceStyle") == "Dark"
        automaticallyHidesDock = Self.readBooleanDefault(
            domain: "com.apple.dock",
            key: "autohide",
            fallback: false
        )
        mutesSystemAudio = Self.readAppleScriptBoolean("output muted of (get volume settings)") ?? false
        mutesMicrophone = (Self.readAppleScriptInteger("input volume of (get volume settings)") ?? 50) == 0
        automaticallyHidesMenuBar = Self.readMenuBarAutoHide()
        showsFinderPathBar = Self.readBooleanDefault(
            domain: "com.apple.finder",
            key: "ShowPathbar",
            fallback: false
        )
        showsFinderStatusBar = Self.readBooleanDefault(
            domain: "com.apple.finder",
            key: "ShowStatusBar",
            fallback: false
        )
        usesDockMagnification = Self.readBooleanDefault(
            domain: "com.apple.dock",
            key: "magnification",
            fallback: false
        )
        showsScreenshotThumbnail = Self.readBooleanDefault(
            domain: "com.apple.screencapture",
            key: "show-thumbnail",
            fallback: true
        )
    }

    private func updateSleepActivities() {
        if let systemSleepActivity {
            ProcessInfo.processInfo.endActivity(systemSleepActivity)
            self.systemSleepActivity = nil
        }
        if let displaySleepActivity {
            ProcessInfo.processInfo.endActivity(displaySleepActivity)
            self.displaySleepActivity = nil
        }

        if isEnabled, keepsMacAwake {
            systemSleepActivity = ProcessInfo.processInfo.beginActivity(
                options: [.idleSystemSleepDisabled],
                reason: "Aster Switch is keeping the Mac awake"
            )
        }
        if isEnabled, keepsDisplayAwake {
            displaySleepActivity = ProcessInfo.processInfo.beginActivity(
                options: [.idleDisplaySleepDisabled],
                reason: "Aster Switch is keeping the display awake"
            )
        }
    }

    private func applyBooleanDefault(
        _ value: Bool,
        domain: String,
        key: String,
        restart processName: String?,
        success: String,
        update: () -> Void
    ) {
        guard !isApplying else { return }
        isApplying = true
        let result = Self.run(
            "/usr/bin/defaults",
            arguments: ["write", domain, key, "-bool", value ? "true" : "false"]
        )
        if result.status == 0 {
            update()
            if let processName {
                _ = Self.run("/usr/bin/killall", arguments: [processName])
            }
            statusMessage = success
        } else {
            statusMessage = "macOS did not allow that change"
            refreshSystemState()
        }
        isApplying = false
    }

    private func applyAppleScript(
        _ source: String,
        success: String,
        update: () -> Void
    ) {
        guard !isApplying else { return }
        isApplying = true
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if error == nil {
            update()
            statusMessage = success
        } else {
            statusMessage = "macOS did not allow that audio change"
            refreshSystemState()
        }
        isApplying = false
    }

    private static func readBooleanDefault(domain: String, key: String, fallback: Bool) -> Bool {
        guard let value = readDefault(domain: domain, key: key)?.lowercased() else { return fallback }
        return value == "1" || value == "true" || value == "yes"
    }

    private static func readMenuBarAutoHide() -> Bool {
        if readDefault(domain: "com.apple.WindowManager", key: "AutoHide") != nil {
            return readBooleanDefault(
                domain: "com.apple.WindowManager",
                key: "AutoHide",
                fallback: false
            )
        }
        return readBooleanDefault(
            domain: "NSGlobalDomain",
            key: "_HIHideMenuBar",
            fallback: false
        )
    }

    private static func readDefault(domain: String, key: String) -> String? {
        let result = run("/usr/bin/defaults", arguments: ["read", domain, key])
        guard result.status == 0 else { return nil }
        let value = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func readAppleScriptBoolean(_ source: String) -> Bool? {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        guard error == nil, let result else { return nil }
        return result.booleanValue
    }

    private static func readAppleScriptInteger(_ source: String) -> Int? {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        guard error == nil, let result else { return nil }
        return Int(result.int32Value)
    }

    private static func run(_ executable: String, arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self))
        } catch {
            return (-1, error.localizedDescription)
        }
    }
}
