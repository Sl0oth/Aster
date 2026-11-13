import AppKit
import AVFoundation
import Darwin
import IOKit.ps
import Observation

/// How a wallpaper has to be shown on the desktop.
enum DesktopMedia: Equatable, Sendable {
    case still
    case animatedImage
    case video

    init(_ item: WallpaperItem) {
        switch item.kind {
        case .video: self = .video
        case .image: self = item.isGIF ? .animatedImage : .still
        }
    }

    var isMotion: Bool { self != .still }
}

/// A wallpaper chosen for the desktop, for every display or for one of them.
struct DesktopAssignment: Equatable, Sendable {
    let itemID: UUID
    let url: URL
    let media: DesktopMedia
}

/// What one display shows, worked out from the user's choices.
struct DesktopSurfacePlan: Equatable, Sendable {
    enum Presentation: Equatable, Sendable {
        /// A still that macOS draws as the system wallpaper.
        case systemWallpaper
        /// A still Aster draws itself, because the system wallpaper is holding
        /// a different picture for the Lock Screen.
        case stillWindow
        case animatedImageWindow
        case videoWindow
    }

    let itemID: UUID
    let url: URL
    let presentation: Presentation

    var isMotion: Bool {
        presentation == .animatedImageWindow || presentation == .videoWindow
    }

    /// macOS shows the system wallpaper on the Lock Screen, so a Lock Screen
    /// still takes that slot. A different desktop still must then be drawn by
    /// Aster above it instead of replacing it.
    static func plan(
        for assignment: DesktopAssignment?,
        lockScreenItemID: UUID?
    ) -> DesktopSurfacePlan? {
        guard let assignment else { return nil }
        let presentation: Presentation = switch assignment.media {
        case .video: .videoWindow
        case .animatedImage: .animatedImageWindow
        case .still:
            lockScreenItemID == nil || lockScreenItemID == assignment.itemID
                ? .systemWallpaper
                : .stillWindow
        }
        return DesktopSurfacePlan(
            itemID: assignment.itemID,
            url: assignment.url,
            presentation: presentation
        )
    }
}

@MainActor
@Observable
final class WallpaperController {
    enum CanvasDestination: String, CaseIterable, Identifiable {
        case desktop = "Desktop"
        case lockScreen = "Lock Screen"
        case screenSaver = "Screen Saver"

        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .desktop: "desktopcomputer"
            case .lockScreen: "lock.fill"
            case .screenSaver: "sparkles"
            }
        }
        var detail: String {
            switch self {
            case .desktop: "Behind your windows"
            case .lockScreen: "When you lock or wake"
            case .screenSaver: "While your Mac is idle"
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
        case threeHours = 10_800
        case twelveHours = 43_200
        case oneDay = 86_400

        var id: Int { rawValue }
        var label: String {
            switch self {
            case .thirtySeconds: "30 seconds"
            case .oneMinute: "1 minute"
            case .fiveMinutes: "5 minutes"
            case .fifteenMinutes: "15 minutes"
            case .thirtyMinutes: "30 minutes"
            case .oneHour: "1 hour"
            case .threeHours: "3 hours"
            case .twelveHours: "12 hours"
            case .oneDay: "24 hours"
            }
        }
    }

    enum ShuffleOrder: String, CaseIterable, Identifiable {
        case random = "Random"
        case inOrder = "In order"
        var id: String { rawValue }
    }

    enum PlaybackSpeed: Double, CaseIterable, Identifiable {
        case half = 0.5
        case threeQuarters = 0.75
        case normal = 1
        case oneAndQuarter = 1.25
        case oneAndHalf = 1.5
        case double = 2

        var id: Double { rawValue }
        var label: String {
            switch self {
            case .half: "0.5×"
            case .threeQuarters: "0.75×"
            case .normal: "Normal"
            case .oneAndQuarter: "1.25×"
            case .oneAndHalf: "1.5×"
            case .double: "2×"
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
        case batteryPower

        var message: String {
            switch self {
            case let .fullScreenApplication(name):
                "\(name) is full screen"
            case let .highSystemLoad(percent):
                "system CPU usage is \(percent)%"
            case .lowPowerMode:
                "Low Power Mode is enabled"
            case .batteryPower:
                "this Mac is on battery power"
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
                // Bring back what Aster was drawing before Canvas was turned off.
                try? rebuildDesktop(appliesSystemWallpaper: false)
            } else {
                stopShuffle(message: "Canvas is off")
                stopAnimatedWallpaper()
            }
        }
    }
    /// The wallpaper for every display that has no choice of its own.
    private var defaultAssignment: DesktopAssignment?
    /// Wallpapers chosen for one display, keyed by `NSScreen.asterDisplayKey`.
    private var displayAssignments: [String: DesktopAssignment] = [:]
    private var didLoadDisplayAssignments = false
    private var lockScreenURL: URL?
    /// False after launch when the user turned off resuming motion wallpapers.
    private var showsMotionSurfaces = true
    var activeItemID: UUID? { defaultAssignment?.itemID }
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
    var fillMode: FillMode = .fill {
        didSet {
            guard fillMode != oldValue else { return }
            defaults.set(fillMode.rawValue, forKey: fillModeKey)
            updateActiveWallpaperScaling()
            synchronizeScreenSaverPresentation()
        }
    }
    var muted = true {
        didSet {
            guard muted != oldValue else { return }
            defaults.set(muted, forKey: mutedKey)
            surfaces.forEach { $0.setMuted(muted) }
            synchronizeScreenSaverPresentation()
        }
    }
    var playbackSpeed: PlaybackSpeed = .normal {
        didSet {
            guard playbackSpeed != oldValue else { return }
            defaults.set(playbackSpeed.rawValue, forKey: playbackSpeedKey)
            surfaces.forEach { $0.setPlaybackRate(Float(playbackSpeed.rawValue)) }
        }
    }
    /// Darkens motion wallpapers so desktop icons and widgets stay readable. 0 is off.
    var motionDimming = 0.0 {
        didSet {
            let clamped = min(max(motionDimming, 0), Self.maximumMotionDimming)
            if motionDimming != clamped {
                motionDimming = clamped
                return
            }
            guard motionDimming != oldValue else { return }
            defaults.set(motionDimming, forKey: motionDimmingKey)
            surfaces.forEach { $0.setDimming(motionDimming) }
        }
    }
    static let maximumMotionDimming = 0.8
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
    var pauseMotionOnBattery = false {
        didSet {
            guard pauseMotionOnBattery != oldValue else { return }
            defaults.set(pauseMotionOnBattery, forKey: pauseOnBatteryKey)
            evaluateSmartPausePolicy(samplesSystemLoad: false)
        }
    }
    private(set) var motionPauseReason: MotionPauseReason?
    private(set) var currentSystemLoadPercent: Int?
    private var globalMotionPauseReason: MotionPauseReason?
    private var fullScreenDisplayApplications: [CGDirectDisplayID: String] = [:]
    /// Motion displays that are paused because something covers them.
    private var coveredMotionDisplayCount: Int {
        motionSurfaces.count { fullScreenDisplayApplications[$0.displayID] != nil }
    }
    var isMotionWallpaperPaused: Bool {
        globalMotionPauseReason != nil || coveredMotionDisplayCount > 0
    }
    var smartPauseStatusMessage: String {
        if let globalMotionPauseReason {
            return "Paused — \(globalMotionPauseReason.message)"
        }
        if coveredMotionDisplayCount > 0 {
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
    var shuffleOrder: ShuffleOrder = .random {
        didSet {
            guard shuffleOrder != oldValue else { return }
            defaults.set(shuffleOrder.rawValue, forKey: shuffleOrderKey)
            shuffleQueue.removeAll()
        }
    }
    private(set) var shuffleItemIDs: Set<UUID> = []
    private(set) var nextShuffleDate: Date?
    private(set) var isShuffling = false
    private(set) var shouldResumeShuffle = false
    var launchAtLogin = false
    private(set) var launchAtLoginStatusMessage = "Aster will stay available after you sign in."

    /// The windows Aster draws on the desktop: videos, GIFs, and stills that
    /// cannot be the system wallpaper.
    private var surfaces: [any DesktopSurface] = []
    private var retiringSurfaces: [any DesktopSurface] = []
    private var motionSurfaces: [any DesktopSurface] { surfaces.filter(\.isMotion) }
    private var desktopInteractionWindows: [DesktopInteractionWindow] = []
    private var screenObserver: NSObjectProtocol?
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
    private var screenSaverPresentationTask: Task<Void, Never>?
    private var isRecoveringPlayback = false
    private var didAttemptRestore = false
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
    private let displayWallpapersKey = "Aster.Canvas.displayWallpapers"
    private let screenSaverConfiguredKey = "Aster.Canvas.screenSaverConfigured"
    private let screenSaverShiftIntervalKey = "Aster.Canvas.screenSaverPixelShiftInterval"
    private let screenSaverRotationIntervalKey = "Aster.Canvas.screenSaverRotationInterval"
    private let lockScreenItemKey = "Aster.Canvas.lockScreenWallpaper"
    private let screenSaverItemKey = "Aster.Canvas.screenSaverWallpaper"
    private let mutedKey = "Aster.Canvas.muted"
    private let playbackSpeedKey = "Aster.Canvas.playbackSpeed"
    private let motionDimmingKey = "Aster.Canvas.motionDimming"
    private let pauseOnBatteryKey = "Aster.Canvas.smartPause.batteryPower"
    private let shuffleOrderKey = "Aster.Canvas.shuffleOrder"
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
        pauseMotionOnBattery = defaults.object(forKey: pauseOnBatteryKey) as? Bool ?? false
        muted = defaults.object(forKey: mutedKey) as? Bool ?? true
        if let storedSpeed = defaults.object(forKey: playbackSpeedKey) as? Double,
           let speed = PlaybackSpeed(rawValue: storedSpeed) {
            playbackSpeed = speed
        }
        let storedDimming = defaults.object(forKey: motionDimmingKey) as? Double ?? 0
        motionDimming = min(max(storedDimming, 0), Self.maximumMotionDimming)
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
        if let storedOrder = defaults.string(forKey: shuffleOrderKey),
           let order = ShuffleOrder(rawValue: storedOrder) {
            shuffleOrder = order
        }
        shuffleItemIDs = Set(
            (defaults.stringArray(forKey: shuffleItemsKey) ?? [])
                .compactMap(UUID.init(uuidString:))
        )
        shouldResumeShuffle = defaults.bool(forKey: shuffleRunningKey)
    }

    /// Sets the desktop wallpaper. With a `displayKey` only that display changes;
    /// without one the wallpaper goes on every display and replaces any
    /// per-display choices.
    func apply(_ item: WallpaperItem, url: URL, displayKey: String? = nil) {
        guard isEnabled, !isApplying else { return }
        isApplying = true
        statusMessage = "Applying…"
        let assignment = DesktopAssignment(itemID: item.id, url: url, media: DesktopMedia(item))
        if let displayKey {
            displayAssignments[displayKey] = assignment
        } else {
            defaultAssignment = assignment
            displayAssignments.removeAll()
        }
        persistDesktopAssignments()
        showsMotionSurfaces = true
        do {
            try rebuildDesktop(appliesSystemWallpaper: true, reusesSurfaces: true)
            if let displayKey,
               let screen = NSScreen.screens.first(where: { $0.asterDisplayKey == displayKey }) {
                statusMessage = "Set on \(screen.localizedName)"
            } else if assignment.media.isMotion {
                statusMessage = "Motion wallpaper is playing"
            } else {
                let count = NSScreen.screens.count
                statusMessage = "Applied to \(count) display\(count == 1 ? "" : "s")"
            }
        } catch {
            statusMessage = error.localizedDescription
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(650))
            self?.isApplying = false
        }
    }

    func assign(_ item: WallpaperItem, url: URL, to destination: CanvasDestination) {
        guard isEnabled else { return }
        switch destination {
        case .desktop:
            apply(item, url: url)
        case .lockScreen:
            configureLockScreen(item, url: url)
        case .screenSaver:
            configureScreenSaver(item, url: url)
        }
    }

    /// Takes a wallpaper off the desktop because the user asked to, so it stays
    /// off after Aster restarts. The system wallpaper underneath becomes visible.
    func stopMotionWallpaper(_ item: WallpaperItem) {
        if defaultAssignment?.itemID == item.id { defaultAssignment = nil }
        displayAssignments = displayAssignments.filter { $0.value.itemID != item.id }
        persistDesktopAssignments()
        try? rebuildDesktop(appliesSystemWallpaper: false, reusesSurfaces: true)
        statusMessage = "Motion wallpaper stopped"
    }

    func assignedItemID(for destination: CanvasDestination) -> UUID? {
        switch destination {
        case .desktop: activeItemID
        case .lockScreen: lockScreenItemID
        case .screenSaver: screenSaverItemID
        }
    }

    /// The connected displays showing this wallpaper on the desktop.
    func desktopDisplayKeys(for item: WallpaperItem) -> [String] {
        NSScreen.screens.map(\.asterDisplayKey).filter {
            assignment(forDisplayKey: $0)?.itemID == item.id
        }
    }

    func isAssigned(_ item: WallpaperItem, to destination: CanvasDestination) -> Bool {
        switch destination {
        case .desktop:
            NSScreen.screens.isEmpty
                ? defaultAssignment?.itemID == item.id
                : !desktopDisplayKeys(for: item).isEmpty
        case .lockScreen: lockScreenItemID == item.id
        case .screenSaver: screenSaverItemID == item.id
        }
    }

    /// Whether this wallpaper is a video or GIF that Aster is drawing right now.
    func isPlayingOnDesktop(_ item: WallpaperItem) -> Bool {
        surfaces.contains { $0.isMotion && $0.plan.itemID == item.id }
    }

    private func assignment(forDisplayKey key: String) -> DesktopAssignment? {
        displayAssignments[key] ?? defaultAssignment
    }

    private var hasDesktopAssignments: Bool {
        defaultAssignment != nil || !displayAssignments.isEmpty
    }

    private func persistDesktopAssignments() {
        if let defaultAssignment {
            defaults.set(defaultAssignment.itemID.uuidString, forKey: lastAppliedKey)
            if defaultAssignment.media.isMotion {
                defaults.set(defaultAssignment.itemID.uuidString, forKey: lastMotionAppliedKey)
            } else {
                // A still replaces the motion wallpaper for good; without this the
                // previous video would come back the next time Aster opens.
                defaults.removeObject(forKey: lastMotionAppliedKey)
            }
        } else {
            defaults.removeObject(forKey: lastAppliedKey)
            defaults.removeObject(forKey: lastMotionAppliedKey)
        }
        defaults.set(
            displayAssignments.mapValues(\.itemID.uuidString),
            forKey: displayWallpapersKey
        )
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

    func selectAllForShuffle(in library: WallpaperLibrary) {
        guard isEnabled else { return }
        shuffleItemIDs = Set(library.items.lazy.filter(\.canShuffle).map(\.id))
        persistShuffleSelection()
    }

    func clearShuffleSelection() {
        guard isEnabled else { return }
        shuffleItemIDs.removeAll()
        shuffleQueue.removeAll()
        persistShuffleSelection()
        if isShuffling {
            stopShuffle(message: "Select at least two wallpapers to shuffle")
        }
    }

    /// Moves to the next shuffled wallpaper now and restarts the countdown.
    func skipToNextShuffleItem() {
        guard isEnabled, isShuffling, !isApplying, let library = shuffleLibrary else { return }
        advanceShuffle(in: library)
        restartShuffleTask()
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

    /// Brings back, after launch, everything Aster draws on the desktop itself:
    /// videos and GIFs when resuming is on, and stills held above a Lock Screen
    /// picture. Stills that are the system wallpaper need nothing.
    func restoreMotionWallpaperIfNeeded(from library: WallpaperLibrary) {
        guard isEnabled, !didAttemptRestore, surfaces.isEmpty else { return }
        didAttemptRestore = true
        validateAssignments(in: library)
        showsMotionSurfaces = autoResumeMotionWallpaper
        try? rebuildDesktop(appliesSystemWallpaper: false)
        guard isAnimating else { return }
        if let defaultAssignment, defaultAssignment.media.isMotion {
            library.selectedID = defaultAssignment.itemID
        }
        statusMessage = "Motion wallpaper is playing"
    }

    /// Removes everything Aster draws on the desktop without forgetting what
    /// was chosen.
    func stopAnimatedWallpaper() {
        retireSurfaces(surfaces)
        surfaces.removeAll()
        synchronizeDesktopState()
    }

    /// Brings observers, Smart Pause, and the click-through helper windows in
    /// line with the surfaces that now exist.
    private func synchronizeDesktopState() {
        rebuildDesktopInteractionWindows()

        let needsScreenObserver = !surfaces.isEmpty || !desktopInteractionWindows.isEmpty
        if needsScreenObserver, screenObserver == nil {
            screenObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    // Displays keep their own system wallpaper; only Aster's
                    // windows have to follow the new arrangement.
                    try? self?.rebuildDesktop(appliesSystemWallpaper: false)
                }
            }
        } else if !needsScreenObserver, let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
            self.screenObserver = nil
        }

        let hasMotion = surfaces.contains(where: \.isMotion)
        if hasMotion, !isAnimating {
            beginPlaybackActivityIfNeeded()
            observePlaybackLifecycle()
            isAnimating = true
            startSmartPauseMonitoring()
            evaluateSmartPausePolicy()
        } else if !hasMotion, isAnimating {
            endMotionLifecycle()
        }
        applySmartPausePlaybackState()
    }

    private func endMotionLifecycle() {
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
        endPlaybackActivityIfNeeded()
        isAnimating = false
    }

    /// When Finder's desktop is hidden, nothing receives clicks on the wallpaper.
    /// Aster's own windows handle them; these cover the displays without one.
    private func rebuildDesktopInteractionWindows() {
        desktopInteractionWindows.forEach { $0.close() }
        desktopInteractionWindows.removeAll()
        guard isEnabled, hasDesktopAssignments,
              DesktopInteractionSupport.needsAsterHitTarget else { return }
        let coveredDisplayIDs = Set(surfaces.map(\.displayID))
        desktopInteractionWindows = NSScreen.screens
            .filter { !coveredDisplayIDs.contains($0.asterDisplayID) }
            .map(DesktopInteractionWindow.init)
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
            let ids = eligibleItems.map(\.id)
            switch shuffleOrder {
            case .random:
                shuffleQueue = ids.filter { $0 != activeItemID }.shuffled()
            case .inOrder:
                if let activeItemID, let index = ids.firstIndex(of: activeItemID) {
                    shuffleQueue = Array(ids[(index + 1)...] + ids[..<index])
                } else {
                    shuffleQueue = ids
                }
            }
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
        let nextDate = Date().addingTimeInterval(TimeInterval(delay))
        nextShuffleDate = nextDate
        if updatesNextDate {
            defaults.set(nextDate, forKey: shuffleNextDateKey)
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
        nextShuffleDate = nil
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
        validateAssignments(in: library)
        showsMotionSurfaces = true
        try? rebuildDesktop(appliesSystemWallpaper: false)
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
            screenSaverStatusMessage = "The Lock Screen supports still images only"
            return
        }
        let previousID = lockScreenItemID
        let previousURL = lockScreenURL
        do {
            // macOS shows the system wallpaper on the Lock Screen after a manual
            // lock, lid close, or wake, so the still goes there on every display.
            for screen in NSScreen.screens {
                try setSystemWallpaper(url, for: screen)
            }
            lockScreenItemID = item.id
            lockScreenURL = url
            defaults.set(item.id.uuidString, forKey: lockScreenItemKey)
            // A different desktop still now has to be drawn by Aster on top.
            try rebuildDesktop(appliesSystemWallpaper: false, reusesSurfaces: true)
            screenSaverStatusMessage = "Lock Screen set to \(item.name)"
        } catch {
            lockScreenItemID = previousID
            lockScreenURL = previousURL
            screenSaverStatusMessage = error.localizedDescription
        }
    }

    /// Stops managing the Lock Screen. Desktop stills become the system
    /// wallpaper again, so the Lock Screen follows the Desktop.
    func clearLockScreen() {
        guard isEnabled, lockScreenItemID != nil else { return }
        lockScreenItemID = nil
        lockScreenURL = nil
        defaults.removeObject(forKey: lockScreenItemKey)
        do {
            try rebuildDesktop(appliesSystemWallpaper: true, reusesSurfaces: true)
            screenSaverStatusMessage = defaultAssignment?.media == .still
                ? "The Lock Screen now matches your Desktop"
                : "The Lock Screen keeps its picture until you set a new one"
        } catch {
            screenSaverStatusMessage = error.localizedDescription
        }
    }

    /// Reconciles the saved assignments with the library: loads what was chosen
    /// before, and forgets wallpapers that were removed.
    func validateAssignments(in library: WallpaperLibrary) {
        func resolve(_ id: UUID) -> DesktopAssignment? {
            library.items.first { $0.id == id }.map {
                DesktopAssignment(itemID: id, url: library.url(for: $0), media: DesktopMedia($0))
            }
        }

        var lockScreenWasRemoved = false
        if let lockScreenItemID {
            if let item = library.items.first(where: { $0.id == lockScreenItemID }),
               item.canUseAsLockScreenStill {
                lockScreenURL = library.url(for: item)
            } else {
                self.lockScreenItemID = nil
                lockScreenURL = nil
                defaults.removeObject(forKey: lockScreenItemKey)
                screenSaverStatusMessage = "Choose a still image for the Lock Screen"
                lockScreenWasRemoved = true
            }
        }
        if let screenSaverItemID,
           !library.items.contains(where: { $0.id == screenSaverItemID }) {
            // The installed saver keeps its own copy, so it continues to work.
            self.screenSaverItemID = nil
            defaults.removeObject(forKey: screenSaverItemKey)
        }

        var removedDesktopWallpaper = false
        if let current = defaultAssignment {
            if resolve(current.itemID) == nil {
                defaultAssignment = nil
                removedDesktopWallpaper = true
            }
        } else if let storedID = storedUUID(forKey: lastAppliedKey)
                    ?? storedUUID(forKey: lastMotionAppliedKey) {
            defaultAssignment = resolve(storedID)
            if defaultAssignment == nil { removedDesktopWallpaper = true }
        }

        if !didLoadDisplayAssignments {
            didLoadDisplayAssignments = true
            let stored = defaults.dictionary(forKey: displayWallpapersKey) as? [String: String] ?? [:]
            for (displayKey, value) in stored {
                guard let id = UUID(uuidString: value) else { continue }
                if let assignment = resolve(id) {
                    displayAssignments[displayKey] = assignment
                } else {
                    removedDesktopWallpaper = true
                }
            }
        }
        for (displayKey, assignment) in displayAssignments where resolve(assignment.itemID) == nil {
            displayAssignments[displayKey] = nil
            removedDesktopWallpaper = true
        }

        if removedDesktopWallpaper { persistDesktopAssignments() }
        let showsRemovedWallpaper = surfaces.contains { surface in
            !library.items.contains { $0.id == surface.plan.itemID }
        }
        if showsRemovedWallpaper {
            statusMessage = "That wallpaper was removed from Canvas"
        }
        if showsRemovedWallpaper || (lockScreenWasRemoved && didAttemptRestore) {
            // Losing the Lock Screen still lets desktop stills return to being
            // the system wallpaper.
            try? rebuildDesktop(appliesSystemWallpaper: lockScreenWasRemoved, reusesSurfaces: true)
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
            screenSaverStatusMessage = "Screen Saver set to \(item.name)"
            if !wasInstalled { ScreenSaverInstaller.openSystemSettings() }
        } catch {
            screenSaverStatusMessage = error.localizedDescription
        }
    }

    func openScreenSaverSettings() {
        ScreenSaverInstaller.openSystemSettings()
    }

    /// Fit and mute are shared with the installed Screen Saver. Re-signing its
    /// bundle can take a moment, so it runs off the main thread.
    private func synchronizeScreenSaverPresentation() {
        guard managesInstalledScreenSaver, screenSaverIsInstalled, screenSaverIsConfigured else { return }
        let fillMode = fillMode
        let muted = muted
        screenSaverPresentationTask?.cancel()
        screenSaverPresentationTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            let failure = await Task.detached(priority: .utility) { () -> String? in
                do {
                    try ScreenSaverInstaller.setPresentation(fillMode: fillMode, muted: muted)
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }.value
            guard !Task.isCancelled, let failure else { return }
            self?.screenSaverStatusMessage = failure
        }
    }

    private func setSystemWallpaper(_ url: URL, for screen: NSScreen) throws {
        var options: [NSWorkspace.DesktopImageOptionKey: Any] = [
            .allowClipping: fillMode != .fit,
            .fillColor: NSColor.black
        ]
        options[.imageScaling] = scalingValue
        try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: options)
    }

    private var scalingValue: NSNumber {
        let scaling: NSImageScaling = switch fillMode {
        case .fill, .fit: .scaleProportionallyUpOrDown
        case .stretch: .scaleAxesIndependently
        }
        return NSNumber(value: scaling.rawValue)
    }

    private func plan(for screen: NSScreen) -> DesktopSurfacePlan? {
        DesktopSurfacePlan.plan(
            for: assignment(forDisplayKey: screen.asterDisplayKey),
            lockScreenItemID: lockScreenItemID
        )
    }

    /// Makes the desktop match the current choices.
    ///
    /// - Parameters:
    ///   - appliesSystemWallpaper: Hand stills to macOS as the system wallpaper.
    ///     False when only Aster's own windows need refreshing, such as at
    ///     launch, where the system wallpaper is already in place.
    ///   - reusesSurfaces: Keep windows whose display and wallpaper did not
    ///     change, so changing one display does not restart the others.
    private func rebuildDesktop(
        appliesSystemWallpaper: Bool,
        reusesSurfaces: Bool = false
    ) throws {
        guard isEnabled else { return }
        var firstError: Error?
        var reusable = reusesSurfaces ? surfaces : []
        var retiring = reusesSurfaces ? [] : surfaces
        var rebuilt: [any DesktopSurface] = []

        for screen in NSScreen.screens {
            guard let plan = plan(for: screen) else { continue }
            if plan.presentation == .systemWallpaper {
                if appliesSystemWallpaper {
                    do {
                        try setSystemWallpaper(plan.url, for: screen)
                    } catch {
                        firstError = firstError ?? error
                    }
                }
                continue
            }
            if plan.isMotion, !showsMotionSurfaces { continue }
            if let index = reusable.firstIndex(where: {
                $0.displayID == screen.asterDisplayID && $0.plan == plan && $0.frame == screen.frame
            }) {
                rebuilt.append(reusable.remove(at: index))
            } else if let surface = makeSurface(for: screen, plan: plan) {
                rebuilt.append(surface)
            }
        }

        retiring.append(contentsOf: reusable)
        retireSurfaces(retiring)
        surfaces = rebuilt
        synchronizeDesktopState()
        if let firstError { throw firstError }
    }

    /// Returns nil when the picture cannot be read. Leaving the system wallpaper
    /// visible is better than covering the desktop with an empty window.
    private func makeSurface(for screen: NSScreen, plan: DesktopSurfacePlan) -> (any DesktopSurface)? {
        if plan.presentation == .videoWindow {
            return DesktopVideoWindow(
                screen: screen,
                plan: plan,
                fillMode: fillMode,
                muted: muted,
                playbackRate: Float(playbackSpeed.rawValue),
                dimming: motionDimming
            ) { [weak self] in
                Task { @MainActor [weak self] in
                    self?.recoverMotionWallpaper()
                }
            }
        }
        return DesktopImageWindow(
            screen: screen,
            plan: plan,
            fillMode: fillMode,
            dimming: plan.isMotion ? motionDimming : 0
        )
    }

    private func updateActiveWallpaperScaling() {
        surfaces.forEach { $0.setFillMode(fillMode) }
        guard isEnabled, hasDesktopAssignments || lockScreenURL != nil else { return }
        do {
            // The system wallpaper holds either this display's still or the
            // Lock Screen still; both follow the Fit setting.
            for screen in NSScreen.screens {
                if let plan = plan(for: screen), plan.presentation == .systemWallpaper {
                    try setSystemWallpaper(plan.url, for: screen)
                } else if let lockScreenURL {
                    try setSystemWallpaper(lockScreenURL, for: screen)
                }
            }
            statusMessage = "Wallpaper set to \(fillMode.rawValue.lowercased())"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func observePlaybackLifecycle() {
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
                    self?.resumeMotionWallpaper()
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
                    self?.resumeMotionWallpaper()
                }
            }
        }
    }

    private func resumeMotionWallpaper() {
        guard isAnimating else { return }
        evaluateSmartPausePolicy(samplesSystemLoad: false)
        applySmartPausePlaybackState()
    }

    private func recoverMotionWallpaper() {
        guard isAnimating, !allDisplaysArePaused, !isRecoveringPlayback else { return }
        isRecoveringPlayback = true
        statusMessage = "Recovering motion wallpaper…"
        try? rebuildDesktop(appliesSystemWallpaper: false)
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
            isLowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled,
            pauseOnBattery: pauseMotionOnBattery,
            isOnBatteryPower: pauseMotionOnBattery && Self.isOnBatteryPower
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
        } else if coveredMotionDisplayCount > 0 {
            statusMessage = fullScreenPauseMessage.replacingOccurrences(of: "Paused", with: "Motion wallpaper paused")
        } else {
            statusMessage = "Motion wallpaper is playing"
        }
    }

    private func applySmartPausePlaybackState() {
        var hasPlayingDisplay = false
        let coveredDisplayIDs = Set(fullScreenDisplayApplications.keys)
        for surface in surfaces {
            guard surface.isMotion else {
                // A still has nothing to pause; it only has to stay in place.
                surface.ensureVisibleAndPlaying()
                continue
            }
            let shouldPause = Self.shouldPauseDisplay(
                surface.displayID,
                hasGlobalPause: globalMotionPauseReason != nil,
                coveredDisplayIDs: coveredDisplayIDs
            )
            if shouldPause {
                surface.pausePlayback()
            } else {
                surface.ensureVisibleAndPlaying()
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
        let motion = motionSurfaces
        guard !motion.isEmpty else { return globalMotionPauseReason != nil }
        return globalMotionPauseReason != nil || motion.allSatisfy {
            fullScreenDisplayApplications[$0.displayID] != nil
        }
    }

    private var fullScreenPauseMessage: String {
        let motion = motionSurfaces
        let pausedSurfaces = motion.filter { fullScreenDisplayApplications[$0.displayID] != nil }
        let names = Set(pausedSurfaces.compactMap { fullScreenDisplayApplications[$0.displayID] })
        let reason = names.count == 1
            ? "\(names.first ?? "An app") is full screen"
            : "full-screen apps cover those desktops"
        if pausedSurfaces.count < motion.count {
            return "Paused on \(pausedSurfaces.count) of \(motion.count) displays — \(reason)"
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
        isLowPowerModeEnabled: Bool,
        pauseOnBattery: Bool = false,
        isOnBatteryPower: Bool = false
    ) -> MotionPauseReason? {
        if pauseForFullScreenApps, let fullScreenApplicationName {
            return .fullScreenApplication(fullScreenApplicationName)
        }
        if pauseInLowPowerMode, isLowPowerModeEnabled {
            return .lowPowerMode
        }
        if pauseOnBattery, isOnBatteryPower {
            return .batteryPower
        }
        if pauseForHighSystemLoad, isHighSystemLoad {
            return .highSystemLoad(systemLoadPercent ?? 100)
        }
        return nil
    }

    private static var isOnBatteryPower: Bool {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let source = IOPSGetProvidingPowerSourceType(blob)?.takeUnretainedValue() else {
            return false
        }
        return (source as String) == kIOPSBatteryPowerValue
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

    private func retireSurfaces(_ retiring: [any DesktopSurface]) {
        guard !retiring.isEmpty else { return }
        let retiringIDs = Set(retiring.map(\.id))
        retiring.forEach { $0.beginRetirement() }
        retiringSurfaces.append(contentsOf: retiring)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            self?.retiringSurfaces.removeAll { retiringIDs.contains($0.id) }
        }
    }

    private func storedUUID(forKey key: String) -> UUID? {
        defaults.string(forKey: key).flatMap(UUID.init(uuidString:))
    }
}

/// A window Aster draws on the desktop, just above the system wallpaper.
@MainActor
private protocol DesktopSurface: AnyObject {
    var id: UUID { get }
    var displayID: CGDirectDisplayID { get }
    var plan: DesktopSurfacePlan { get }
    /// The display frame this surface was built for.
    var frame: CGRect { get }
    func pausePlayback()
    func ensureVisibleAndPlaying()
    func beginRetirement()
    func setFillMode(_ fillMode: WallpaperController.FillMode)
    func setDimming(_ dimming: Double)
    func setMuted(_ muted: Bool)
    func setPlaybackRate(_ rate: Float)
}

extension DesktopSurface {
    var isMotion: Bool { plan.isMotion }
}

private extension NSWindow {
    /// A borderless window that sits one level above the system wallpaper and
    /// below Finder's desktop icons, on every Space.
    static func asterDesktopWindow(for screen: NSScreen, contentView: NSView) -> NSWindow {
        let window = NSWindow(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.contentView = contentView
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.ignoresMouseEvents = !DesktopInteractionSupport.needsAsterHitTarget
        window.isOpaque = true
        window.backgroundColor = .black
        window.animationBehavior = .none
        window.setFrame(screen.frame, display: true)
        window.orderBack(nil)
        return window
    }
}

@MainActor
private final class DesktopVideoWindow: DesktopSurface {
    let id = UUID()
    let displayID: CGDirectDisplayID
    let plan: DesktopSurfacePlan
    let frame: CGRect
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
        plan: DesktopSurfacePlan,
        fillMode: WallpaperController.FillMode,
        muted: Bool,
        playbackRate: Float,
        dimming: Double,
        onPlaybackFailure: @escaping () -> Void
    ) {
        self.onPlaybackFailure = onPlaybackFailure
        self.plan = plan
        frame = screen.frame
        displayID = screen.asterDisplayID
        asset = AVURLAsset(url: plan.url)
        let templateItem = AVPlayerItem(asset: asset)
        player = AVQueuePlayer()
        player.actionAtItemEnd = .advance
        player.automaticallyWaitsToMinimizeStalling = false
        player.isMuted = muted
        // play() starts at defaultRate, so every resume and recovery path keeps the speed.
        player.defaultRate = playbackRate
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
        videoView.setDimming(dimming)

        window = .asterDesktopWindow(for: screen, contentView: videoView)

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

    func setMuted(_ muted: Bool) {
        guard !isRetiring else { return }
        player.isMuted = muted
    }

    func setPlaybackRate(_ rate: Float) {
        guard !isRetiring else { return }
        player.defaultRate = rate
        if player.rate != 0 { player.rate = rate }
    }

    func setDimming(_ dimming: Double) {
        guard !isRetiring else { return }
        videoView.setDimming(dimming)
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

/// Draws a GIF, or a still that cannot be the system wallpaper, on the desktop.
@MainActor
private final class DesktopImageWindow: DesktopSurface {
    let id = UUID()
    let displayID: CGDirectDisplayID
    let plan: DesktopSurfacePlan
    let frame: CGRect
    private let window: NSWindow
    private let imageView: DesktopImageView
    private var isRetiring = false

    init?(
        screen: NSScreen,
        plan: DesktopSurfacePlan,
        fillMode: WallpaperController.FillMode,
        dimming: Double
    ) {
        guard let image = NSImage(contentsOf: plan.url), image.isValid else { return nil }
        self.plan = plan
        frame = screen.frame
        displayID = screen.asterDisplayID
        imageView = DesktopImageView(
            frame: NSRect(origin: .zero, size: screen.frame.size),
            image: image,
            animates: plan.isMotion,
            fillMode: fillMode,
            handlesDesktopClicks: DesktopInteractionSupport.needsAsterHitTarget
        )
        imageView.setDimming(dimming)
        window = .asterDesktopWindow(for: screen, contentView: imageView)
    }

    func pausePlayback() {
        guard !isRetiring else { return }
        imageView.setAnimating(false)
    }

    func ensureVisibleAndPlaying() {
        guard !isRetiring else { return }
        if !window.isVisible { window.orderBack(nil) }
        imageView.setAnimating(true)
    }

    func beginRetirement() {
        guard !isRetiring else { return }
        isRetiring = true
        imageView.setAnimating(false)
        window.orderOut(nil)
    }

    func setFillMode(_ fillMode: WallpaperController.FillMode) {
        guard !isRetiring else { return }
        imageView.fillMode = fillMode
    }

    func setDimming(_ dimming: Double) {
        guard !isRetiring, plan.isMotion else { return }
        imageView.setDimming(dimming)
    }

    func setMuted(_ muted: Bool) {}
    func setPlaybackRate(_ rate: Float) {}
}

final class DesktopImageView: NSView {
    var fillMode: WallpaperController.FillMode {
        didSet { needsLayout = true }
    }
    private let imageView = NSImageView()
    private let dimView = NSView()
    private let animates: Bool
    private let handlesDesktopClicks: Bool
    /// The picture's shape in pixels, which is what decides how it is fitted.
    private let pixelSize: CGSize

    init(
        frame frameRect: NSRect,
        image: NSImage,
        animates: Bool,
        fillMode: WallpaperController.FillMode,
        handlesDesktopClicks: Bool
    ) {
        self.fillMode = fillMode
        self.animates = animates
        self.handlesDesktopClicks = handlesDesktopClicks
        if let representation = image.representations.first,
           representation.pixelsWide > 0, representation.pixelsHigh > 0 {
            pixelSize = CGSize(width: representation.pixelsWide, height: representation.pixelsHigh)
        } else {
            pixelSize = image.size
        }
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.masksToBounds = true

        imageView.image = image
        imageView.imageFrameStyle = .none
        // The frame below already has the right shape, so the image fills it exactly.
        imageView.imageScaling = .scaleAxesIndependently
        imageView.animates = animates
        addSubview(imageView)

        dimView.wantsLayer = true
        dimView.layer?.backgroundColor = NSColor.black.cgColor
        dimView.alphaValue = 0
        addSubview(dimView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setAnimating(_ isAnimating: Bool) {
        guard animates, imageView.animates != isAnimating else { return }
        imageView.animates = isAnimating
    }

    func setDimming(_ dimming: Double) {
        dimView.alphaValue = CGFloat(min(max(dimming, 0), 1))
    }

    override func layout() {
        super.layout()
        dimView.frame = bounds
        imageView.frame = Self.imageFrame(for: pixelSize, in: bounds, fillMode: fillMode)
    }

    static func imageFrame(
        for imageSize: CGSize,
        in bounds: CGRect,
        fillMode: WallpaperController.FillMode
    ) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0,
              bounds.width > 0, bounds.height > 0, fillMode != .stretch else { return bounds }
        let widthScale = bounds.width / imageSize.width
        let heightScale = bounds.height / imageSize.height
        let scale = fillMode == .fill ? max(widthScale, heightScale) : min(widthScale, heightScale)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(
            x: bounds.midX - size.width / 2,
            y: bounds.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    // Clicks belong to this view, not the image inside it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        handlesDesktopClicks
    }

    override func mouseDown(with event: NSEvent) {
        guard handlesDesktopClicks, event.clickCount == 2 else { return }
        DesktopInteractionSupport.revealDesktop()
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
    private let dimLayer = CALayer()
    private let handlesDesktopClicks: Bool

    init(frame frameRect: NSRect, handlesDesktopClicks: Bool) {
        self.handlesDesktopClicks = handlesDesktopClicks
        super.init(frame: frameRect)
        wantsLayer = true
        layer = playerLayer
        playerLayer.backgroundColor = NSColor.black.cgColor
        dimLayer.backgroundColor = NSColor.black.cgColor
        dimLayer.opacity = 0
        dimLayer.frame = bounds
        dimLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        playerLayer.addSublayer(dimLayer)
    }

    func setDimming(_ dimming: Double) {
        dimLayer.opacity = Float(min(max(dimming, 0), 1))
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
