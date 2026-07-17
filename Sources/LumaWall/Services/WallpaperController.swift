import AppKit
import AVFoundation
import Darwin
import Observation

@MainActor
@Observable
final class WallpaperController {
    enum CanvasDestination: String, CaseIterable, Identifiable {
        case desktop = "Desktop"
        case lockScreen = "Lock Screen"
        case screenSaver = "Screen Saver"

        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .desktop: "Desktop"
            case .lockScreen: "Manual-Lock Still"
            case .screenSaver: "Saver + Auto-Lock"
            }
        }
        var symbol: String {
            switch self {
            case .desktop: "desktopcomputer"
            case .lockScreen: "lock.display"
            case .screenSaver: "sparkles.rectangle.stack"
            }
        }
        var badge: String {
            switch self {
            case .desktop: "D"
            case .lockScreen: "L"
            case .screenSaver: "S"
            }
        }
    }

    enum FillMode: String, CaseIterable, Identifiable {
        case fill = "Fill"
        case fit = "Fit"
        case stretch = "Stretch"
        var id: String { rawValue }
    }

    enum ShuffleRate: Int, CaseIterable, Identifiable {
        case thirtySeconds = 30
        case oneMinute = 60
        case fiveMinutes = 300
        case fifteenMinutes = 900
        case thirtyMinutes = 1_800
        case oneHour = 3_600

        var id: Int { rawValue }
        var label: String {
            switch self {
            case .thirtySeconds: "30 seconds"
            case .oneMinute: "1 minute"
            case .fiveMinutes: "5 minutes"
            case .fifteenMinutes: "15 minutes"
            case .thirtyMinutes: "30 minutes"
            case .oneHour: "1 hour"
            }
        }
    }

    enum ScreenSaverShiftInterval: Double, CaseIterable, Identifiable {
        case off = 0
        case thirtySeconds = 30
        case oneMinute = 60
        case twoMinutes = 120
        case fiveMinutes = 300

        var id: Double { rawValue }
        var label: String {
            switch self {
            case .off: "Off"
            case .thirtySeconds: "Every 30 seconds"
            case .oneMinute: "Every minute"
            case .twoMinutes: "Every 2 minutes"
            case .fiveMinutes: "Every 5 minutes"
            }
        }
    }

    enum ScreenSaverRotationInterval: Double, CaseIterable, Identifiable {
        case off = 0
        case thirtySeconds = 30
        case oneMinute = 60
        case twoMinutes = 120
        case fiveMinutes = 300
        case fifteenMinutes = 900

        var id: Double { rawValue }
        var label: String {
            switch self {
            case .off: "Off"
            case .thirtySeconds: "Every 30 seconds"
            case .oneMinute: "Every minute"
            case .twoMinutes: "Every 2 minutes"
            case .fiveMinutes: "Every 5 minutes"
            case .fifteenMinutes: "Every 15 minutes"
            }
        }
    }

    enum MotionPauseReason: Equatable, Sendable {
        case fullScreenApplication(String)
        case highSystemLoad(Int)
        case lowPowerMode

        var message: String {
            switch self {
            case let .fullScreenApplication(name):
                "\(name) is full screen"
            case let .highSystemLoad(percent):
                "system CPU usage is \(percent)%"
            case .lowPowerMode:
                "Low Power Mode is enabled"
            }
        }
    }

    struct DisplayGeometry: Equatable {
        let id: CGDirectDisplayID
        let frame: CGRect
    }

    var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            defaults.set(isEnabled, forKey: enabledKey)
            if isEnabled {
                statusMessage = "Canvas is ready"
            } else {
                stopShuffle(message: "Canvas is off")
                stopAnimatedWallpaper()
            }
        }
    }
    private(set) var activeItemID: UUID?
    private(set) var isAnimating = false
    private(set) var isApplying = false
    private(set) var statusMessage = "Choose a wallpaper to begin"
    private(set) var screenSaverIsInstalled = false
    private(set) var screenSaverIsConfigured = false
    private(set) var screenSaverStatusMessage = "Auto-lock uses Screen Saver; manual lock uses the Lock Screen still"
    private(set) var lockScreenItemID: UUID?
    private(set) var screenSaverItemID: UUID?
    var screenSaverShiftInterval: ScreenSaverShiftInterval = .oneMinute {
        didSet {
            guard screenSaverShiftInterval != oldValue else { return }
            defaults.set(screenSaverShiftInterval.rawValue, forKey: screenSaverShiftIntervalKey)
            guard managesInstalledScreenSaver, screenSaverIsInstalled else { return }
            do {
                try ScreenSaverInstaller.setPixelShiftInterval(screenSaverShiftInterval.rawValue)
                screenSaverStatusMessage = screenSaverShiftInterval == .off
                    ? "Screen Saver pixel shifting is off"
                    : "Screen Saver shifts \(screenSaverShiftInterval.label.lowercased())"
            } catch {
                screenSaverStatusMessage = error.localizedDescription
            }
        }
    }
    var screenSaverRotationInterval: ScreenSaverRotationInterval = .fiveMinutes {
        didSet {
            guard screenSaverRotationInterval != oldValue else { return }
            defaults.set(
                screenSaverRotationInterval.rawValue,
                forKey: screenSaverRotationIntervalKey
            )
            guard managesInstalledScreenSaver, screenSaverIsInstalled else { return }
            do {
                try ScreenSaverInstaller.setRotationInterval(screenSaverRotationInterval.rawValue)
                screenSaverStatusMessage = screenSaverRotationInterval == .off
                    ? "Screen Saver Canvas rotation is off"
                    : "Screen Saver rotates Canvas backgrounds \(screenSaverRotationInterval.label.lowercased())"
            } catch {
                screenSaverStatusMessage = error.localizedDescription
            }
        }
    }
    var editingDestination: CanvasDestination = .desktop {
        didSet { defaults.set(editingDestination.rawValue, forKey: destinationKey) }
    }
    var fillMode: FillMode = .fill {
        didSet {
            guard fillMode != oldValue else { return }
            defaults.set(fillMode.rawValue, forKey: fillModeKey)
            updateActiveWallpaperScaling()
        }
    }
    var muted = true {
        didSet {
            videoWindows.forEach { $0.player.isMuted = muted }
        }
    }
    var autoResumeMotionWallpaper: Bool = true {
        didSet {
            defaults.set(autoResumeMotionWallpaper, forKey: autoResumeKey)
        }
    }
    var pauseMotionForFullScreenApps = true {
        didSet {
            guard pauseMotionForFullScreenApps != oldValue else { return }
            defaults.set(pauseMotionForFullScreenApps, forKey: pauseForFullScreenAppsKey)
            evaluateSmartPausePolicy(samplesSystemLoad: false)
        }
    }
    var pauseMotionForHighSystemLoad = true {
        didSet {
            guard pauseMotionForHighSystemLoad != oldValue else { return }
            defaults.set(pauseMotionForHighSystemLoad, forKey: pauseForHighSystemLoadKey)
            resetHighSystemLoadDetection()
            evaluateSmartPausePolicy(samplesSystemLoad: false)
        }
    }
    var highSystemLoadThreshold = 80.0 {
        didSet {
            guard highSystemLoadThreshold != oldValue else { return }
            defaults.set(highSystemLoadThreshold, forKey: highSystemLoadThresholdKey)
            resetHighSystemLoadDetection()
            evaluateSmartPausePolicy(samplesSystemLoad: false)
        }
    }
    var pauseMotionInLowPowerMode = false {
        didSet {
            guard pauseMotionInLowPowerMode != oldValue else { return }
            defaults.set(pauseMotionInLowPowerMode, forKey: pauseInLowPowerModeKey)
            evaluateSmartPausePolicy(samplesSystemLoad: false)
        }
    }
    private(set) var motionPauseReason: MotionPauseReason?
    private(set) var currentSystemLoadPercent: Int?
    private var globalMotionPauseReason: MotionPauseReason?
    private var fullScreenDisplayApplications: [CGDirectDisplayID: String] = [:]
    var isMotionWallpaperPaused: Bool {
        globalMotionPauseReason != nil || !fullScreenDisplayApplications.isEmpty
    }
    var smartPauseStatusMessage: String {
        if let globalMotionPauseReason {
            return "Paused — \(globalMotionPauseReason.message)"
        }
        if !fullScreenDisplayApplications.isEmpty {
            return fullScreenPauseMessage
        }
        if isAnimating, let currentSystemLoadPercent, pauseMotionForHighSystemLoad {
            return "Playing · System CPU usage \(currentSystemLoadPercent)%"
        }
        if isAnimating { return "Playing · Smart Pause is monitoring activity" }
        return "Applies to motion wallpapers; still images are unaffected."
    }
    var shuffleRate: ShuffleRate = .fiveMinutes {
        didSet {
            guard shuffleRate != oldValue else { return }
            defaults.set(shuffleRate.rawValue, forKey: shuffleRateKey)
            restartShuffleTask()
        }
    }
    private(set) var shuffleItemIDs: Set<UUID> = []
    private(set) var isShuffling = false
    private(set) var shouldResumeShuffle = false
    var launchAtLogin = false
    private(set) var launchAtLoginStatusMessage = "Aster will stay available after you sign in."

    private var videoWindows: [DesktopVideoWindow] = []
    private var retiringVideoWindows: [DesktopVideoWindow] = []
    private var desktopInteractionWindows: [DesktopInteractionWindow] = []
    private var screenObserver: NSObjectProtocol?
    private var desktopInteractionScreenObserver: NSObjectProtocol?
    private var applicationObservers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var playbackActivity: NSObjectProtocol?
    private var playbackRecoveryTask: Task<Void, Never>?
    private var smartPauseTask: Task<Void, Never>?
    private var cpuLoadSampler = SystemCPULoadSampler()
    private var highLoadSampleCount = 0
    private var lowLoadSampleCount = 0
    private var isHighSystemLoad = false
    private var shuffleTask: Task<Void, Never>?
    private weak var shuffleLibrary: WallpaperLibrary?
    private var shuffleQueue: [UUID] = []
    private var isRecoveringPlayback = false
    private var didAttemptRestore = false
    private var activeItemURL: URL?
    private var activeItemKind: WallpaperItem.Kind?
    private let defaults: UserDefaults
    private let managesInstalledScreenSaver: Bool
    private let enabledKey = "Aster.Canvas.enabled"
    private let autoResumeKey = "Aster.Canvas.autoResumeMotion"
    private let pauseForFullScreenAppsKey = "Aster.Canvas.smartPause.fullScreenApps"
    private let pauseForHighSystemLoadKey = "Aster.Canvas.smartPause.highSystemLoad"
    private let highSystemLoadThresholdKey = "Aster.Canvas.smartPause.highSystemLoadThreshold"
    private let pauseInLowPowerModeKey = "Aster.Canvas.smartPause.lowPowerMode"
    private let fillModeKey = "Aster.Canvas.fillMode"
    private let lastAppliedKey = "Aster.Canvas.lastAppliedWallpaper"
    private let lastMotionAppliedKey = "Aster.Canvas.lastMotionWallpaper"
    private let screenSaverConfiguredKey = "Aster.Canvas.screenSaverConfigured"
    private let screenSaverShiftIntervalKey = "Aster.Canvas.screenSaverPixelShiftInterval"
    private let screenSaverRotationIntervalKey = "Aster.Canvas.screenSaverRotationInterval"
    private let lockScreenItemKey = "Aster.Canvas.lockScreenWallpaper"
    private let screenSaverItemKey = "Aster.Canvas.screenSaverWallpaper"
    private let destinationKey = "Aster.Canvas.editingDestination"
    private let shuffleRateKey = "Aster.Canvas.shuffleRate"
    private let shuffleItemsKey = "Aster.Canvas.shuffleItems"
    private let shuffleRunningKey = "Aster.Canvas.shuffleRunning"
    private let shuffleNextDateKey = "Aster.Canvas.shuffleNextDate"

    init(
        defaults: UserDefaults = .standard,
        managesInstalledScreenSaver: Bool? = nil
    ) {
        self.defaults = defaults
        self.managesInstalledScreenSaver = managesInstalledScreenSaver
            ?? (defaults === UserDefaults.standard)
        isEnabled = defaults.object(forKey: enabledKey) as? Bool ?? true
        refreshLaunchAtLoginStatus()
        autoResumeMotionWallpaper = defaults.object(forKey: autoResumeKey) as? Bool ?? true
        pauseMotionForFullScreenApps = defaults.object(forKey: pauseForFullScreenAppsKey) as? Bool ?? true
        pauseMotionForHighSystemLoad = defaults.object(forKey: pauseForHighSystemLoadKey) as? Bool ?? true
        let storedLoadThreshold = defaults.object(forKey: highSystemLoadThresholdKey) as? Double ?? 80
        highSystemLoadThreshold = min(max(storedLoadThreshold, 50), 95)
        pauseMotionInLowPowerMode = defaults.object(forKey: pauseInLowPowerModeKey) as? Bool ?? false
        screenSaverIsInstalled = self.managesInstalledScreenSaver
            && ScreenSaverInstaller.isInstalled
        screenSaverIsConfigured = defaults.bool(forKey: screenSaverConfiguredKey)
            && screenSaverIsInstalled
        if let storedShiftInterval = defaults.object(
            forKey: screenSaverShiftIntervalKey
        ) as? Double,
           let shiftInterval = ScreenSaverShiftInterval(rawValue: storedShiftInterval) {
            screenSaverShiftInterval = shiftInterval
        }
        if let storedRotationInterval = defaults.object(
            forKey: screenSaverRotationIntervalKey
        ) as? Double,
           let rotationInterval = ScreenSaverRotationInterval(rawValue: storedRotationInterval) {
            screenSaverRotationInterval = rotationInterval
        }
        if screenSaverIsConfigured {
            screenSaverStatusMessage = "Screen Saver also continues through automatic lock"
        }
        if screenSaverIsInstalled {
            do {
                try ScreenSaverInstaller.refreshInstallationIfNeeded()
            } catch {
                screenSaverStatusMessage = error.localizedDescription
            }
        }
        lockScreenItemID = storedUUID(forKey: lockScreenItemKey)
        screenSaverItemID = storedUUID(forKey: screenSaverItemKey)
        if let storedDestination = defaults.string(forKey: destinationKey),
           let destination = CanvasDestination(rawValue: storedDestination) {
            editingDestination = destination
        }
        if screenSaverIsConfigured,
           lockScreenItemID == nil,
           screenSaverItemID == nil,
           let legacyID = storedUUID(forKey: lastAppliedKey) {
            lockScreenItemID = legacyID
            screenSaverItemID = legacyID
        }
        if let storedFillMode = defaults.string(forKey: fillModeKey),
           let restoredFillMode = FillMode(rawValue: storedFillMode) {
            fillMode = restoredFillMode
        }
        if let storedShuffleRate = ShuffleRate(
            rawValue: defaults.integer(forKey: shuffleRateKey)
        ) {
            shuffleRate = storedShuffleRate
        }
        shuffleItemIDs = Set(
            (defaults.stringArray(forKey: shuffleItemsKey) ?? [])
                .compactMap(UUID.init(uuidString:))
        )
        shouldResumeShuffle = defaults.bool(forKey: shuffleRunningKey)
    }

    func apply(_ item: WallpaperItem, url: URL) {
        guard isEnabled, !isApplying else { return }
        isApplying = true
        statusMessage = "Applying…"
        stopAnimatedWallpaper()
        do {
            switch item.kind {
            case .image:
                try applyImage(url)
                installDesktopInteractionWindowsIfNeeded()
                statusMessage = "Applied to \(NSScreen.screens.count) display\(NSScreen.screens.count == 1 ? "" : "s")"
            case .video:
                applyVideo(url)
                statusMessage = "Motion wallpaper is playing"
                defaults.set(item.id.uuidString, forKey: lastMotionAppliedKey)
            }
            activeItemID = item.id
            activeItemURL = url
            activeItemKind = item.kind
            defaults.set(item.id.uuidString, forKey: lastAppliedKey)
        } catch {
            statusMessage = error.localizedDescription
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(650))
            self?.isApplying = false
        }
    }

    func assign(_ item: WallpaperItem, url: URL) {
        guard isEnabled else { return }
        switch editingDestination {
        case .desktop:
            apply(item, url: url)
        case .lockScreen:
            configureLockScreen(item, url: url)
        case .screenSaver:
            configureScreenSaver(item, url: url)
        }
    }

    func assignedItemID(for destination: CanvasDestination) -> UUID? {
        switch destination {
        case .desktop: activeItemID ?? storedUUID(forKey: lastAppliedKey)
        case .lockScreen: lockScreenItemID
        case .screenSaver: screenSaverItemID
        }
    }

    func isSelectedForShuffle(_ item: WallpaperItem) -> Bool {
        shuffleItemIDs.contains(item.id)
    }

    func toggleShuffleSelection(_ item: WallpaperItem) {
        guard isEnabled, item.canShuffle else { return }
        if shuffleItemIDs.contains(item.id) {
            shuffleItemIDs.remove(item.id)
            shuffleQueue.removeAll { $0 == item.id }
        } else {
            shuffleItemIDs.insert(item.id)
        }
        persistShuffleSelection()
        if isShuffling, shuffleItemIDs.count < 2 {
            stopShuffle(message: "Select at least two wallpapers to shuffle")
        }
    }

    func shuffleSelectionCount(in library: WallpaperLibrary) -> Int {
        library.items.count { $0.canShuffle && shuffleItemIDs.contains($0.id) }
    }

    func validateShuffleSelection(in library: WallpaperLibrary) {
        let validIDs = Set(library.items.lazy.filter(\.canShuffle).map(\.id))
        let validated = shuffleItemIDs.intersection(validIDs)
        guard validated != shuffleItemIDs else { return }
        shuffleItemIDs = validated
        shuffleQueue.removeAll { !validated.contains($0) }
        persistShuffleSelection()
        if isShuffling, validated.count < 2 {
            stopShuffle(message: "Select at least two wallpapers to shuffle")
        }
    }

    func startShuffle(in library: WallpaperLibrary) {
        guard isEnabled else { return }
        validateShuffleSelection(in: library)
        guard shuffleSelectionCount(in: library) >= 2 else {
            statusMessage = "Select at least two wallpapers to shuffle"
            return
        }
        shuffleLibrary = library
        shuffleQueue.removeAll()
        isShuffling = true
        setShuffleRunningPreference(true)
        advanceShuffle(in: library)
        restartShuffleTask()
    }

    func stopShuffle() {
        stopShuffle(message: "Wallpaper shuffle stopped")
    }

    func restoreShuffleIfNeeded(in library: WallpaperLibrary) {
        guard isEnabled, shouldResumeShuffle, !isShuffling else { return }
        validateShuffleSelection(in: library)
        guard shuffleSelectionCount(in: library) >= 2 else {
            stopShuffle(message: "Shuffle couldn’t resume — select at least two wallpapers")
            return
        }

        shuffleLibrary = library
        shuffleQueue.removeAll()
        isShuffling = true
        statusMessage = "Wallpaper shuffle resumed"

        if let nextDate = defaults.object(forKey: shuffleNextDateKey) as? Date,
           nextDate > Date() {
            restoreCurrentShuffleVideoIfNeeded(from: library)
            let remainingSeconds = max(1, Int(ceil(nextDate.timeIntervalSinceNow)))
            scheduleShuffle(after: remainingSeconds, updatesNextDate: false)
        } else {
            advanceShuffle(in: library)
            restartShuffleTask()
        }
    }

    func restoreMotionWallpaperIfNeeded(from library: WallpaperLibrary) {
        guard isEnabled, autoResumeMotionWallpaper, !didAttemptRestore, !isAnimating else { return }

        let storedID = defaults.string(forKey: lastMotionAppliedKey)
            ?? defaults.string(forKey: lastAppliedKey)
        guard let storedID,
              let id = UUID(uuidString: storedID),
              let item = library.items.first(where: { $0.id == id && $0.kind == .video }) else {
            statusMessage = "The previous motion wallpaper is no longer in Canvas"
            return
        }

        didAttemptRestore = true
        library.selectedID = item.id
        apply(item, url: library.url(for: item))
    }

    func stopAnimatedWallpaper() {
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
            self.screenObserver = nil
        }
        if let desktopInteractionScreenObserver {
            NotificationCenter.default.removeObserver(desktopInteractionScreenObserver)
            self.desktopInteractionScreenObserver = nil
        }
        applicationObservers.forEach(NotificationCenter.default.removeObserver)
        applicationObservers.removeAll()
        workspaceObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        workspaceObservers.removeAll()
        playbackRecoveryTask?.cancel()
        playbackRecoveryTask = nil
        smartPauseTask?.cancel()
        smartPauseTask = nil
        cpuLoadSampler.reset()
        resetHighSystemLoadDetection()
        currentSystemLoadPercent = nil
        motionPauseReason = nil
        globalMotionPauseReason = nil
        fullScreenDisplayApplications.removeAll()
        isRecoveringPlayback = false
        retireCurrentVideoWindows()
        desktopInteractionWindows.forEach { $0.close() }
        desktopInteractionWindows.removeAll()
        if let playbackActivity {
            ProcessInfo.processInfo.endActivity(playbackActivity)
            self.playbackActivity = nil
        }
        isAnimating = false
    }

    private func installDesktopInteractionWindowsIfNeeded() {
        guard DesktopInteractionSupport.needsAsterHitTarget else { return }
        rebuildDesktopInteractionWindows()
        desktopInteractionScreenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.rebuildDesktopInteractionWindows() }
        }
    }

    private func rebuildDesktopInteractionWindows() {
        desktopInteractionWindows.forEach { $0.close() }
        desktopInteractionWindows = NSScreen.screens.map(DesktopInteractionWindow.init)
    }

    private func advanceShuffle(in library: WallpaperLibrary) {
        let eligibleItems = library.items.filter {
            $0.canShuffle && shuffleItemIDs.contains($0.id)
        }
        guard eligibleItems.count >= 2 else {
            stopShuffle(message: "Select at least two wallpapers to shuffle")
            return
        }

        let eligibleIDs = Set(eligibleItems.map(\.id))
        shuffleQueue.removeAll { !eligibleIDs.contains($0) || $0 == activeItemID }
        if shuffleQueue.isEmpty {
            shuffleQueue = eligibleItems.map(\.id).filter { $0 != activeItemID }.shuffled()
        }
        guard let nextID = shuffleQueue.first,
              let nextItem = eligibleItems.first(where: { $0.id == nextID }) else { return }
        shuffleQueue.removeFirst()
        library.selectedID = nextItem.id
        apply(nextItem, url: library.url(for: nextItem))
    }

    private func restartShuffleTask() {
        scheduleShuffle(after: shuffleRate.rawValue, updatesNextDate: true)
    }

    private func scheduleShuffle(after delay: Int, updatesNextDate: Bool) {
        shuffleTask?.cancel()
        shuffleTask = nil
        guard isShuffling, let library = shuffleLibrary else { return }
        if updatesNextDate {
            defaults.set(Date().addingTimeInterval(TimeInterval(delay)), forKey: shuffleNextDateKey)
        }
        shuffleTask = Task { @MainActor [weak self, weak library] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard !Task.isCancelled, let self, let library else { return }
            self.advanceShuffle(in: library)
            self.restartShuffleTask()
        }
    }

    private func stopShuffle(message: String) {
        shuffleTask?.cancel()
        shuffleTask = nil
        shuffleLibrary = nil
        shuffleQueue.removeAll()
        isShuffling = false
        setShuffleRunningPreference(false)
        statusMessage = message
    }

    private func setShuffleRunningPreference(_ isRunning: Bool) {
        shouldResumeShuffle = isRunning
        defaults.set(isRunning, forKey: shuffleRunningKey)
        if !isRunning { defaults.removeObject(forKey: shuffleNextDateKey) }
    }

    private func restoreCurrentShuffleVideoIfNeeded(from library: WallpaperLibrary) {
        guard let storedID = defaults.string(forKey: lastAppliedKey),
              let id = UUID(uuidString: storedID),
              let item = library.items.first(where: { $0.id == id && $0.kind == .video }) else {
            return
        }
        library.selectedID = item.id
        apply(item, url: library.url(for: item))
    }

    private func persistShuffleSelection() {
        defaults.set(
            shuffleItemIDs.map(\.uuidString).sorted(),
            forKey: shuffleItemsKey
        )
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            let newStatus = try AsterLoginItemManager.setEnabled(enabled)
            applyLoginItemStatus(newStatus)
            if newStatus == .requiresApproval {
                AsterLoginItemManager.openApprovalSettings()
            }
        } catch {
            refreshLaunchAtLoginStatus()
            launchAtLoginStatusMessage = "Launch at login couldn’t be changed: \(error.localizedDescription)"
        }
    }

    func refreshLaunchAtLoginStatus() {
        applyLoginItemStatus(AsterLoginItemManager.status)
    }

    private func applyLoginItemStatus(_ loginStatus: AsterLoginItemManager.Status) {
        switch loginStatus {
        case .disabled:
            launchAtLogin = false
            launchAtLoginStatusMessage = "Aster won’t open automatically when you sign in."
        case .enabled:
            launchAtLogin = true
            launchAtLoginStatusMessage = "Aster will open automatically when you sign in."
        case .requiresApproval:
            launchAtLogin = true
            launchAtLoginStatusMessage = "Allow Aster under System Settings → General → Login Items."
        }
    }

    func configureScreenSaver(_ item: WallpaperItem, url: URL) {
        guard isEnabled else { return }
        configureScreenSaverSurface(item, url: url)
    }

    func configureLockScreen(_ item: WallpaperItem, url: URL) {
        guard isEnabled else { return }
        guard item.canUseAsLockScreenStill else {
            screenSaverStatusMessage = "Manual Lock Screen supports still images only"
            return
        }
        do {
            // macOS uses this system-owned desktop layer for manual lock, lid close,
            // and wake. An already-running Aster saver remains visible on auto-lock.
            try applyImage(url)
            lockScreenItemID = item.id
            defaults.set(item.id.uuidString, forKey: lockScreenItemKey)
            screenSaverStatusMessage = "Manual Lock Screen still set to \(item.name)"
        } catch {
            screenSaverStatusMessage = error.localizedDescription
        }
    }

    func validateAssignments(in library: WallpaperLibrary) {
        guard let lockScreenItemID else { return }
        guard let item = library.items.first(where: { $0.id == lockScreenItemID }),
              item.canUseAsLockScreenStill else {
            self.lockScreenItemID = nil
            defaults.removeObject(forKey: lockScreenItemKey)
            screenSaverStatusMessage = "Choose a still image for manual Lock Screen"
            return
        }
    }

    private func configureScreenSaverSurface(_ item: WallpaperItem, url: URL) {
        let wasInstalled = screenSaverIsInstalled
        do {
            // Keep both manifest fields identical for compatibility with saver bundles
            // installed by earlier Aster builds. The runtime intentionally keeps showing
            // the Screen Saver media if that same session transitions into auto-lock.
            try ScreenSaverInstaller.configure(
                destinations: [.screenSaver, .lockScreen],
                mediaURL: url,
                mediaKind: item.kind,
                fillMode: fillMode,
                muted: muted,
                pixelShiftInterval: screenSaverShiftInterval.rawValue,
                rotationInterval: screenSaverRotationInterval.rawValue
            )
            screenSaverIsInstalled = true
            screenSaverIsConfigured = true
            defaults.set(true, forKey: screenSaverConfiguredKey)
            screenSaverItemID = item.id
            defaults.set(item.id.uuidString, forKey: screenSaverItemKey)
            screenSaverStatusMessage = "Screen Saver and automatic lock set to \(item.name)"
            if !wasInstalled { ScreenSaverInstaller.openSystemSettings() }
        } catch {
            screenSaverStatusMessage = error.localizedDescription
        }
    }

    func openScreenSaverSettings() {
        ScreenSaverInstaller.openSystemSettings()
    }

    private func applyImage(_ url: URL) throws {
        var options: [NSWorkspace.DesktopImageOptionKey: Any] = [
            .allowClipping: fillMode != .fit,
            .fillColor: NSColor.black
        ]
        options[.imageScaling] = scalingValue
        for screen in NSScreen.screens {
            try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: options)
        }
    }

    private var scalingValue: NSNumber {
        let scaling: NSImageScaling = switch fillMode {
        case .fill, .fit: .scaleProportionallyUpOrDown
        case .stretch: .scaleAxesIndependently
        }
        return NSNumber(value: scaling.rawValue)
    }

    private func updateActiveWallpaperScaling() {
        if isAnimating {
            videoWindows.forEach { $0.setFillMode(fillMode) }
            statusMessage = "Motion wallpaper set to \(fillMode.rawValue.lowercased())"
            return
        }

        guard activeItemKind == .image, let activeItemURL else { return }
        do {
            try applyImage(activeItemURL)
            statusMessage = "Wallpaper set to \(fillMode.rawValue.lowercased())"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func applyVideo(_ url: URL) {
        beginPlaybackActivityIfNeeded()
        rebuildVideoWindows(url: url)
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.rebuildVideoWindows(url: url) }
        }
        observePlaybackLifecycle(url: url)
        isAnimating = true
        startSmartPauseMonitoring()
        evaluateSmartPausePolicy()
    }

    private func rebuildVideoWindows(url: URL) {
        retireCurrentVideoWindows()
        videoWindows = NSScreen.screens.map {
            DesktopVideoWindow(
                screen: $0,
                url: url,
                fillMode: fillMode,
                muted: muted
            ) { [weak self] in
                Task { @MainActor [weak self] in
                    self?.recoverMotionWallpaper(url: url)
                }
            }
        }
        applySmartPausePlaybackState()
    }

    private func observePlaybackLifecycle(url: URL) {
        let resumeNames: [Notification.Name] = [
            NSApplication.didBecomeActiveNotification,
            NSApplication.didUnhideNotification
        ]
        applicationObservers = resumeNames.map { name in
            NotificationCenter.default.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.resumeMotionWallpaper(url: url)
                }
            }
        }

        let workspaceNames: [Notification.Name] = [
            NSWorkspace.didWakeNotification,
            NSWorkspace.sessionDidBecomeActiveNotification,
            NSWorkspace.activeSpaceDidChangeNotification,
            NSWorkspace.didActivateApplicationNotification
        ]
        workspaceObservers = workspaceNames.map { name in
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.resumeMotionWallpaper(url: url)
                }
            }
        }
    }

    private func resumeMotionWallpaper(url: URL) {
        guard isAnimating else { return }
        evaluateSmartPausePolicy(samplesSystemLoad: false)
        guard !videoWindows.isEmpty else {
            if !allDisplaysArePaused {
                recoverMotionWallpaper(url: url)
            }
            return
        }
        applySmartPausePlaybackState()
    }

    private func recoverMotionWallpaper(url: URL) {
        guard isAnimating, !allDisplaysArePaused, !isRecoveringPlayback else { return }
        isRecoveringPlayback = true
        statusMessage = "Recovering motion wallpaper…"
        rebuildVideoWindows(url: url)
        statusMessage = "Motion wallpaper is playing"

        playbackRecoveryTask?.cancel()
        playbackRecoveryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.isRecoveringPlayback = false
        }
    }

    private func beginPlaybackActivityIfNeeded() {
        guard playbackActivity == nil else { return }
        playbackActivity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep,
            reason: "Playing a motion wallpaper"
        )
    }

    private func endPlaybackActivityIfNeeded() {
        guard let playbackActivity else { return }
        ProcessInfo.processInfo.endActivity(playbackActivity)
        self.playbackActivity = nil
    }

    private func startSmartPauseMonitoring() {
        smartPauseTask?.cancel()
        cpuLoadSampler.reset()
        resetHighSystemLoadDetection()
        smartPauseTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.evaluateSmartPausePolicy()
                do {
                    try await Task.sleep(for: .seconds(3))
                } catch {
                    return
                }
            }
        }
    }

    private func evaluateSmartPausePolicy(samplesSystemLoad: Bool = true) {
        guard isAnimating else { return }
        if samplesSystemLoad {
            updateHighSystemLoadState()
        } else if !pauseMotionForHighSystemLoad {
            resetHighSystemLoadDetection()
        }

        let fullScreenApplications = pauseMotionForFullScreenApps
            ? Self.fullScreenApplicationsByDisplay()
            : [:]
        let newGlobalReason = Self.motionPauseReason(
            pauseForFullScreenApps: false,
            fullScreenApplicationName: nil,
            pauseForHighSystemLoad: pauseMotionForHighSystemLoad,
            isHighSystemLoad: isHighSystemLoad,
            systemLoadPercent: currentSystemLoadPercent,
            pauseInLowPowerMode: pauseMotionInLowPowerMode,
            isLowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled
        )
        setSmartPauseState(
            globalReason: newGlobalReason,
            fullScreenApplications: fullScreenApplications
        )
    }

    private func setSmartPauseState(
        globalReason: MotionPauseReason?,
        fullScreenApplications: [CGDirectDisplayID: String]
    ) {
        guard globalReason != globalMotionPauseReason
                || fullScreenApplications != fullScreenDisplayApplications else { return }
        globalMotionPauseReason = globalReason
        fullScreenDisplayApplications = fullScreenApplications
        motionPauseReason = globalReason ?? fullScreenApplications
            .sorted { $0.key < $1.key }
            .first
            .map { .fullScreenApplication($0.value) }
        applySmartPausePlaybackState()

        if let globalReason {
            statusMessage = "Motion wallpaper paused — \(globalReason.message)"
        } else if !fullScreenApplications.isEmpty {
            statusMessage = fullScreenPauseMessage.replacingOccurrences(of: "Paused", with: "Motion wallpaper paused")
        } else {
            statusMessage = "Motion wallpaper is playing"
        }
    }

    private func applySmartPausePlaybackState() {
        var hasPlayingDisplay = false
        let coveredDisplayIDs = Set(fullScreenDisplayApplications.keys)
        for videoWindow in videoWindows {
            let shouldPause = Self.shouldPauseDisplay(
                videoWindow.displayID,
                hasGlobalPause: globalMotionPauseReason != nil,
                coveredDisplayIDs: coveredDisplayIDs
            )
            if shouldPause {
                videoWindow.pausePlayback()
            } else {
                videoWindow.ensureVisibleAndPlaying()
                hasPlayingDisplay = true
            }
        }
        if hasPlayingDisplay {
            beginPlaybackActivityIfNeeded()
        } else {
            endPlaybackActivityIfNeeded()
        }
    }

    private var allDisplaysArePaused: Bool {
        guard !videoWindows.isEmpty else { return globalMotionPauseReason != nil }
        return globalMotionPauseReason != nil || videoWindows.allSatisfy {
            fullScreenDisplayApplications[$0.displayID] != nil
        }
    }

    private var fullScreenPauseMessage: String {
        let pausedCount = fullScreenDisplayApplications.count
        let displayCount = max(videoWindows.count, NSScreen.screens.count)
        let names = Set(fullScreenDisplayApplications.values)
        let reason = names.count == 1
            ? "\(names.first ?? "An app") is full screen"
            : "full-screen apps cover those desktops"
        if pausedCount < displayCount {
            return "Paused on \(pausedCount) of \(displayCount) displays — \(reason)"
        }
        return "Paused — \(reason)"
    }

    private func updateHighSystemLoadState() {
        guard pauseMotionForHighSystemLoad else {
            currentSystemLoadPercent = nil
            resetHighSystemLoadDetection()
            return
        }
        guard let load = cpuLoadSampler.sample() else { return }
        let percent = Int((load * 100).rounded())
        currentSystemLoadPercent = percent

        if Double(percent) >= highSystemLoadThreshold {
            highLoadSampleCount += 1
            lowLoadSampleCount = 0
            if highLoadSampleCount >= 2 { isHighSystemLoad = true }
        } else if Double(percent) <= highSystemLoadThreshold - 10 {
            lowLoadSampleCount += 1
            highLoadSampleCount = 0
            if lowLoadSampleCount >= 3 { isHighSystemLoad = false }
        } else {
            highLoadSampleCount = 0
            lowLoadSampleCount = 0
        }
    }

    private func resetHighSystemLoadDetection() {
        highLoadSampleCount = 0
        lowLoadSampleCount = 0
        isHighSystemLoad = false
    }

    nonisolated static func motionPauseReason(
        pauseForFullScreenApps: Bool,
        fullScreenApplicationName: String?,
        pauseForHighSystemLoad: Bool,
        isHighSystemLoad: Bool,
        systemLoadPercent: Int?,
        pauseInLowPowerMode: Bool,
        isLowPowerModeEnabled: Bool
    ) -> MotionPauseReason? {
        if pauseForFullScreenApps, let fullScreenApplicationName {
            return .fullScreenApplication(fullScreenApplicationName)
        }
        if pauseInLowPowerMode, isLowPowerModeEnabled {
            return .lowPowerMode
        }
        if pauseForHighSystemLoad, isHighSystemLoad {
            return .highSystemLoad(systemLoadPercent ?? 100)
        }
        return nil
    }

    private static func fullScreenApplicationsByDisplay() -> [CGDirectDisplayID: String] {
        let displays = NSScreen.screens.compactMap { screen -> DisplayGeometry? in
            guard let screenNumber = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? NSNumber else { return nil }
            let displayID = CGDirectDisplayID(screenNumber.uint32Value)
            return DisplayGeometry(id: displayID, frame: CGDisplayBounds(displayID))
        }
        guard !displays.isEmpty else { return [:] }

        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID)
            as? [[CFString: Any]] else { return [:] }

        var windowFrames: [CGDirectDisplayID: [CGRect]] = [:]
        var applicationNames: [CGDirectDisplayID: Set<String>] = [:]
        var exactFullScreenApplications: [CGDirectDisplayID: String] = [:]
        for window in windows {
            guard (window[kCGWindowLayer] as? Int) == 0,
                  (window[kCGWindowAlpha] as? Double ?? 1) > 0.01,
                  let ownerPID = window[kCGWindowOwnerPID] as? Int,
                  ownerPID != Int(ProcessInfo.processInfo.processIdentifier),
                  let application = NSRunningApplication(
                    processIdentifier: pid_t(ownerPID)
                  ),
                  application.activationPolicy == .regular,
                  let boundsDictionary = window[kCGWindowBounds] as? NSDictionary,
                  let bounds = CGRect(
                    dictionaryRepresentation: boundsDictionary as CFDictionary
                  ) else {
                continue
            }
            let name = application.localizedName
                ?? window[kCGWindowOwnerName] as? String
                ?? "A full-screen app"
            if let displayID = coveredDisplayID(for: bounds, displays: displays) {
                exactFullScreenApplications[displayID] = name
            }
            for display in displays {
                let intersection = bounds.intersection(display.frame)
                guard !intersection.isNull, !intersection.isEmpty else { continue }
                windowFrames[display.id, default: []].append(intersection)
                applicationNames[display.id, default: []].insert(name)
            }
        }

        var coveredApplications: [CGDirectDisplayID: String] = [:]
        for display in displays where isDisplayCovered(
            display.frame,
            by: windowFrames[display.id] ?? []
        ) {
            if let exactApplication = exactFullScreenApplications[display.id] {
                coveredApplications[display.id] = exactApplication
            } else {
                let names = applicationNames[display.id] ?? []
                coveredApplications[display.id] = names.count == 1
                    ? names.first
                    : "Split View"
            }
        }
        return coveredApplications
    }

    nonisolated static func coveredDisplayID(
        for windowFrame: CGRect,
        displays: [DisplayGeometry],
        tolerance: CGFloat = 6
    ) -> CGDirectDisplayID? {
        displays.first { display in
            abs(windowFrame.minX - display.frame.minX) <= tolerance
                && abs(windowFrame.minY - display.frame.minY) <= tolerance
                && abs(windowFrame.width - display.frame.width) <= tolerance
                && abs(windowFrame.height - display.frame.height) <= tolerance
        }?.id
    }

    nonisolated static func shouldPauseDisplay(
        _ displayID: CGDirectDisplayID,
        hasGlobalPause: Bool,
        coveredDisplayIDs: Set<CGDirectDisplayID>
    ) -> Bool {
        hasGlobalPause || coveredDisplayIDs.contains(displayID)
    }

    nonisolated static func isDisplayCovered(
        _ displayFrame: CGRect,
        by windowFrames: [CGRect],
        minimumCoverage: CGFloat = 0.985
    ) -> Bool {
        guard displayFrame.width > 0, displayFrame.height > 0 else { return false }
        let clippedFrames = windowFrames.compactMap { frame -> CGRect? in
            let intersection = frame.intersection(displayFrame)
            return intersection.isNull || intersection.isEmpty ? nil : intersection
        }
        guard !clippedFrames.isEmpty else { return false }

        let xCoordinates = Set(
            clippedFrames.flatMap { [$0.minX, $0.maxX] }
        ).sorted()
        var coveredArea: CGFloat = 0
        for (left, right) in zip(xCoordinates, xCoordinates.dropFirst()) where right > left {
            let midpoint = (left + right) / 2
            let intervals = clippedFrames
                .filter { $0.minX <= midpoint && $0.maxX >= midpoint }
                .map { ($0.minY, $0.maxY) }
                .sorted { $0.0 < $1.0 }
            guard var merged = intervals.first else { continue }
            var coveredHeight: CGFloat = 0
            for interval in intervals.dropFirst() {
                if interval.0 <= merged.1 {
                    merged.1 = max(merged.1, interval.1)
                } else {
                    coveredHeight += merged.1 - merged.0
                    merged = interval
                }
            }
            coveredHeight += merged.1 - merged.0
            coveredArea += (right - left) * coveredHeight
        }

        let displayArea = displayFrame.width * displayFrame.height
        return coveredArea / displayArea >= minimumCoverage
    }

    private func retireCurrentVideoWindows() {
        guard !videoWindows.isEmpty else { return }
        let retiring = videoWindows
        let retiringIDs = Set(retiring.map(\.id))
        videoWindows.removeAll()
        retiring.forEach { $0.beginRetirement() }
        retiringVideoWindows.append(contentsOf: retiring)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            self?.retiringVideoWindows.removeAll { retiringIDs.contains($0.id) }
        }
    }

    private func storedUUID(forKey key: String) -> UUID? {
        defaults.string(forKey: key).flatMap(UUID.init(uuidString:))
    }
}

@MainActor
private final class DesktopVideoWindow: Identifiable {
    let id = UUID()
    let displayID: CGDirectDisplayID
    let player: AVQueuePlayer
    private let looper: AVPlayerLooper
    private let asset: AVURLAsset
    private let window: NSWindow
    private let videoView: VideoDesktopView
    private let onPlaybackFailure: () -> Void
    private var stallObserver: NSObjectProtocol?
    private var failureObserver: NSObjectProtocol?
    private var boundaryObserver: Any?
    private var watchdog: Timer?
    private var lastPlaybackTime = -1.0
    private var stagnantChecks = 0
    private var unreadyChecks = 0
    private var restartAttempts = 0
    private var failureReported = false
    private var isRetiring = false
    private var isPlaybackPaused = false

    init(
        screen: NSScreen,
        url: URL,
        fillMode: WallpaperController.FillMode,
        muted: Bool,
        onPlaybackFailure: @escaping () -> Void
    ) {
        self.onPlaybackFailure = onPlaybackFailure
        displayID = (screen.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")
        ] as? NSNumber).map { CGDirectDisplayID($0.uint32Value) } ?? 0
        asset = AVURLAsset(url: url)
        let templateItem = AVPlayerItem(asset: asset)
        player = AVQueuePlayer()
        player.actionAtItemEnd = .advance
        player.automaticallyWaitsToMinimizeStalling = false
        player.isMuted = muted
        looper = AVPlayerLooper(player: player, templateItem: templateItem)

        videoView = VideoDesktopView(
            frame: screen.frame,
            handlesDesktopClicks: DesktopInteractionSupport.needsAsterHitTarget
        )
        videoView.playerLayer.player = player
        videoView.playerLayer.videoGravity = switch fillMode {
        case .fill: .resizeAspectFill
        case .fit: .resizeAspect
        case .stretch: .resize
        }

        window = NSWindow(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.contentView = videoView
        // One level above the system wallpaper, while remaining below Finder's desktop icons.
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.ignoresMouseEvents = !DesktopInteractionSupport.needsAsterHitTarget
        window.isOpaque = true
        window.backgroundColor = .black
        window.animationBehavior = .none
        window.setFrame(screen.frame, display: true)
        window.orderBack(nil)

        // A looper queues the next copy before the current one ends. The stall
        // observer handles uncommon decoder interruptions without leaving the
        // final decoded frame frozen on the desktop.
        stallObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemPlaybackStalled,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let itemID = (notification.object as? AVPlayerItem).map(ObjectIdentifier.init)
            MainActor.assumeIsolated {
                guard let self,
                      !self.isRetiring,
                      !self.isPlaybackPaused,
                      self.owns(itemID) else { return }
                self.player.play()
            }
        }
        failureObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let itemID = (notification.object as? AVPlayerItem).map(ObjectIdentifier.init)
            MainActor.assumeIsolated {
                guard let self,
                      self.owns(itemID) else { return }
                self.reportPlaybackFailure()
            }
        }

        Task { @MainActor [weak self] in
            await self?.installEndGuard()
        }
        let watchdog = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.verifyPlaybackIsAdvancing()
            }
        }
        self.watchdog = watchdog
        RunLoop.main.add(watchdog, forMode: .common)
        player.play()
    }

    private func installEndGuard() async {
        guard let duration = try? await asset.load(.duration),
              !isRetiring,
              duration.isNumeric,
              duration.seconds > 0.25 else { return }

        // Some H.264 files reach their final decoded frame without AVPlayerLooper
        // advancing. Restart just before that terminal timestamp so the decoder
        // never enters the frozen state.
        let restartTime = CMTime(
            seconds: max(duration.seconds - 0.08, 0),
            preferredTimescale: 600
        )
        boundaryObserver = player.addBoundaryTimeObserver(
            forTimes: [NSValue(time: restartTime)],
            queue: .main
        ) { [weak self] in
            Task { @MainActor [weak self] in self?.restartPlayback() }
        }
    }

    private func verifyPlaybackIsAdvancing() {
        guard !isRetiring, !isPlaybackPaused else { return }
        if !window.isVisible {
            window.orderBack(nil)
        }

        guard let currentItem = player.currentItem else {
            markPlayerUnready()
            return
        }
        switch currentItem.status {
        case .readyToPlay:
            unreadyChecks = 0
        case .failed:
            reportPlaybackFailure()
            return
        case .unknown:
            markPlayerUnready()
            return
        @unknown default:
            markPlayerUnready()
            return
        }

        let currentTime = player.currentTime().seconds
        guard currentTime.isFinite else {
            markPlayerUnready()
            return
        }

        if abs(currentTime - lastPlaybackTime) < 0.04 {
            stagnantChecks += 1
        } else {
            stagnantChecks = 0
            restartAttempts = 0
        }
        lastPlaybackTime = currentTime

        if stagnantChecks >= 2 {
            restartAttempts += 1
            if restartAttempts >= 3 {
                reportPlaybackFailure()
            } else {
                restartPlayback()
            }
        }
    }

    private func markPlayerUnready() {
        guard !isPlaybackPaused else { return }
        unreadyChecks += 1
        player.play()
        if unreadyChecks >= 4 {
            reportPlaybackFailure()
        }
    }

    private func reportPlaybackFailure() {
        guard !isRetiring, !isPlaybackPaused, !failureReported else { return }
        failureReported = true
        onPlaybackFailure()
    }

    private func owns(_ itemID: ObjectIdentifier?) -> Bool {
        guard let itemID else { return false }
        if let currentItem = player.currentItem,
           ObjectIdentifier(currentItem) == itemID {
            return true
        }
        return player.items().contains { ObjectIdentifier($0) == itemID }
    }

    private func restartPlayback() {
        guard !isRetiring, !isPlaybackPaused else { return }
        stagnantChecks = 0
        lastPlaybackTime = 0
        player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.isRetiring, !self.isPlaybackPaused else { return }
                self.player.play()
            }
        }
    }

    func beginRetirement() {
        guard !isRetiring else { return }
        isRetiring = true
        watchdog?.invalidate()
        watchdog = nil
        if let stallObserver {
            NotificationCenter.default.removeObserver(stallObserver)
            self.stallObserver = nil
        }
        if let failureObserver {
            NotificationCenter.default.removeObserver(failureObserver)
            self.failureObserver = nil
        }
        if let boundaryObserver {
            player.removeTimeObserver(boundaryObserver)
            self.boundaryObserver = nil
        }
        player.pause()
        player.isMuted = true
        window.orderOut(nil)
    }

    func ensureVisibleAndPlaying() {
        guard !isRetiring else { return }
        isPlaybackPaused = false
        stagnantChecks = 0
        lastPlaybackTime = player.currentTime().seconds
        if !window.isVisible {
            window.orderBack(nil)
        }
        player.play()
    }

    func pausePlayback() {
        guard !isRetiring, !isPlaybackPaused else { return }
        isPlaybackPaused = true
        stagnantChecks = 0
        unreadyChecks = 0
        restartAttempts = 0
        player.pause()
    }

    func setFillMode(_ fillMode: WallpaperController.FillMode) {
        guard !isRetiring else { return }
        videoView.playerLayer.videoGravity = switch fillMode {
        case .fill: .resizeAspectFill
        case .fit: .resizeAspect
        case .stretch: .resize
        }
    }
}

private struct SystemCPULoadSampler {
    private struct Ticks {
        let user: UInt64
        let system: UInt64
        let idle: UInt64
        let nice: UInt64

        var total: UInt64 { user + system + idle + nice }
    }

    private var previous: Ticks?

    mutating func reset() {
        previous = nil
    }

    mutating func sample() -> Double? {
        var load = host_cpu_load_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride
        )
        let result = withUnsafeMutablePointer(to: &load) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        let current = Ticks(
            user: UInt64(load.cpu_ticks.0),
            system: UInt64(load.cpu_ticks.1),
            idle: UInt64(load.cpu_ticks.2),
            nice: UInt64(load.cpu_ticks.3)
        )
        defer { previous = current }
        guard let previous,
              current.total >= previous.total,
              current.idle >= previous.idle else { return nil }
        let totalDelta = current.total - previous.total
        guard totalDelta > 0 else { return nil }
        let idleDelta = current.idle - previous.idle
        return min(max(Double(totalDelta - idleDelta) / Double(totalDelta), 0), 1)
    }
}

private final class VideoDesktopView: NSView {
    let playerLayer = AVPlayerLayer()
    private let handlesDesktopClicks: Bool

    init(frame frameRect: NSRect, handlesDesktopClicks: Bool) {
        self.handlesDesktopClicks = handlesDesktopClicks
        super.init(frame: frameRect)
        wantsLayer = true
        layer = playerLayer
        playerLayer.backgroundColor = NSColor.black.cgColor
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        handlesDesktopClicks
    }

    override func mouseDown(with event: NSEvent) {
        guard handlesDesktopClicks, event.clickCount == 2 else { return }
        DesktopInteractionSupport.revealDesktop()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

@MainActor
private final class DesktopInteractionWindow {
    private let window: NSWindow

    init(screen: NSScreen) {
        let view = DesktopInteractionView(frame: screen.frame)
        window = NSWindow(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.contentView = view
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.ignoresMouseEvents = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.animationBehavior = .none
        window.setFrame(screen.frame, display: true)
        window.orderBack(nil)
    }

    func close() {
        window.orderOut(nil)
    }
}

@MainActor
private final class DesktopInteractionView: NSView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard event.clickCount == 2 else { return }
        DesktopInteractionSupport.revealDesktop()
    }
}

@MainActor
private enum DesktopInteractionSupport {
    static var needsAsterHitTarget: Bool {
        let finderShowsDesktop = CFPreferencesCopyAppValue(
            "CreateDesktop" as CFString,
            "com.apple.finder" as CFString
        ) as? Bool
        return finderShowsDesktop == false
    }

    static func revealDesktop() {
        guard CGPreflightPostEventAccess() || CGRequestPostEventAccess() else { return }
        let source = CGEventSource(stateID: .hidSystemState)
        let keyCode: CGKeyCode = 103 // Fn-F11, macOS's default Show Desktop shortcut.
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        keyDown?.flags = .maskSecondaryFn
        keyUp?.flags = .maskSecondaryFn
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }
}
