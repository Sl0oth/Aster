import AppKit
import AVFoundation
import Observation
import ServiceManagement

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

    private(set) var activeItemID: UUID?
    private(set) var isAnimating = false
    private(set) var isApplying = false
    private(set) var statusMessage = "Choose a wallpaper to begin"
    private(set) var screenSaverIsInstalled = false
    private(set) var screenSaverIsConfigured = false
    private(set) var screenSaverStatusMessage = "Choose separate media for Lock Screen and Screen Saver"
    private(set) var lockScreenItemID: UUID?
    private(set) var screenSaverItemID: UUID?
    var editingDestination: CanvasDestination = .desktop {
        didSet { UserDefaults.standard.set(editingDestination.rawValue, forKey: destinationKey) }
    }
    var fillMode: FillMode = .fill {
        didSet {
            guard fillMode != oldValue else { return }
            UserDefaults.standard.set(fillMode.rawValue, forKey: fillModeKey)
            updateActiveWallpaperScaling()
        }
    }
    var muted = true {
        didSet {
            videoWindows.forEach { $0.player.isMuted = muted }
        }
    }
    var autoResumeMotionWallpaper: Bool = false {
        didSet {
            UserDefaults.standard.set(autoResumeMotionWallpaper, forKey: autoResumeKey)
        }
    }
    var launchAtLogin = false

    private var videoWindows: [DesktopVideoWindow] = []
    private var retiringVideoWindows: [DesktopVideoWindow] = []
    private var screenObserver: NSObjectProtocol?
    private var applicationObservers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var playbackActivity: NSObjectProtocol?
    private var playbackRecoveryTask: Task<Void, Never>?
    private var isRecoveringPlayback = false
    private var didAttemptRestore = false
    private var activeItemURL: URL?
    private var activeItemKind: WallpaperItem.Kind?
    private let autoResumeKey = "Aster.Canvas.autoResumeMotion"
    private let fillModeKey = "Aster.Canvas.fillMode"
    private let lastAppliedKey = "Aster.Canvas.lastAppliedWallpaper"
    private let lastMotionAppliedKey = "Aster.Canvas.lastMotionWallpaper"
    private let screenSaverConfiguredKey = "Aster.Canvas.screenSaverConfigured"
    private let lockScreenItemKey = "Aster.Canvas.lockScreenWallpaper"
    private let screenSaverItemKey = "Aster.Canvas.screenSaverWallpaper"
    private let destinationKey = "Aster.Canvas.editingDestination"

    init() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
        autoResumeMotionWallpaper = UserDefaults.standard.bool(forKey: autoResumeKey)
        screenSaverIsInstalled = ScreenSaverInstaller.isInstalled
        screenSaverIsConfigured = UserDefaults.standard.bool(forKey: screenSaverConfiguredKey)
            && screenSaverIsInstalled
        if screenSaverIsConfigured {
            screenSaverStatusMessage = "Lock Screen and Screen Saver can now use different media"
        }
        lockScreenItemID = Self.storedUUID(forKey: lockScreenItemKey)
        screenSaverItemID = Self.storedUUID(forKey: screenSaverItemKey)
        if let storedDestination = UserDefaults.standard.string(forKey: destinationKey),
           let destination = CanvasDestination(rawValue: storedDestination) {
            editingDestination = destination
        }
        if screenSaverIsConfigured,
           lockScreenItemID == nil,
           screenSaverItemID == nil,
           let legacyID = Self.storedUUID(forKey: lastAppliedKey) {
            lockScreenItemID = legacyID
            screenSaverItemID = legacyID
        }
        if let storedFillMode = UserDefaults.standard.string(forKey: fillModeKey),
           let restoredFillMode = FillMode(rawValue: storedFillMode) {
            fillMode = restoredFillMode
        }
    }

    func apply(_ item: WallpaperItem, url: URL) {
        guard !isApplying else { return }
        isApplying = true
        statusMessage = "Applying…"
        stopAnimatedWallpaper()
        do {
            switch item.kind {
            case .image:
                try applyImage(url)
                statusMessage = "Applied to \(NSScreen.screens.count) display\(NSScreen.screens.count == 1 ? "" : "s")"
            case .video:
                applyVideo(url)
                statusMessage = "Motion wallpaper is playing"
                UserDefaults.standard.set(item.id.uuidString, forKey: lastMotionAppliedKey)
            }
            activeItemID = item.id
            activeItemURL = url
            activeItemKind = item.kind
            UserDefaults.standard.set(item.id.uuidString, forKey: lastAppliedKey)
        } catch {
            statusMessage = error.localizedDescription
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(650))
            self?.isApplying = false
        }
    }

    func assign(_ item: WallpaperItem, url: URL) {
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
        case .desktop: activeItemID ?? Self.storedUUID(forKey: lastAppliedKey)
        case .lockScreen: lockScreenItemID
        case .screenSaver: screenSaverItemID
        }
    }

    func restoreMotionWallpaperIfNeeded(from library: WallpaperLibrary) {
        guard autoResumeMotionWallpaper, !didAttemptRestore, !isAnimating else { return }

        let storedID = UserDefaults.standard.string(forKey: lastMotionAppliedKey)
            ?? UserDefaults.standard.string(forKey: lastAppliedKey)
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
        applicationObservers.forEach(NotificationCenter.default.removeObserver)
        applicationObservers.removeAll()
        workspaceObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        workspaceObservers.removeAll()
        playbackRecoveryTask?.cancel()
        playbackRecoveryTask = nil
        isRecoveringPlayback = false
        retireCurrentVideoWindows()
        if let playbackActivity {
            ProcessInfo.processInfo.endActivity(playbackActivity)
            self.playbackActivity = nil
        }
        isAnimating = false
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLogin = enabled
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            statusMessage = "Launch at login could not be changed"
        }
    }

    func configureScreenSaver(_ item: WallpaperItem, url: URL) {
        configureProtectedSurface(.screenSaver, item: item, url: url)
    }

    func configureLockScreen(_ item: WallpaperItem, url: URL) {
        guard item.kind == .image, !item.isGIF else {
            screenSaverStatusMessage = "Lock Screen supports still images only"
            return
        }
        do {
            // macOS uses its real desktop layer as the secure Lock Screen backdrop.
            // Aster's motion window remains above it while the session is unlocked.
            try applyImage(url)
            if screenSaverIsInstalled {
                try ScreenSaverInstaller.configure(
                    destination: .lockScreen,
                    mediaURL: url,
                    mediaKind: item.kind,
                    fillMode: fillMode,
                    muted: true
                )
            }
            lockScreenItemID = item.id
            UserDefaults.standard.set(item.id.uuidString, forKey: lockScreenItemKey)
            screenSaverStatusMessage = "Lock Screen still set to \(item.name)"
        } catch {
            screenSaverStatusMessage = error.localizedDescription
        }
    }

    func validateAssignments(in library: WallpaperLibrary) {
        guard let lockScreenItemID,
              let item = library.items.first(where: { $0.id == lockScreenItemID }),
              item.kind != .image || item.isGIF else { return }
        self.lockScreenItemID = nil
        UserDefaults.standard.removeObject(forKey: lockScreenItemKey)
        screenSaverStatusMessage = "Choose a still image for Lock Screen"
    }

    private func configureProtectedSurface(
        _ destination: ScreenSaverInstaller.Destination,
        item: WallpaperItem,
        url: URL
    ) {
        let wasInstalled = screenSaverIsInstalled
        do {
            try ScreenSaverInstaller.configure(
                destination: destination,
                mediaURL: url,
                mediaKind: item.kind,
                fillMode: fillMode,
                muted: muted
            )
            screenSaverIsInstalled = true
            screenSaverIsConfigured = true
            UserDefaults.standard.set(true, forKey: screenSaverConfiguredKey)
            switch destination {
            case .lockScreen:
                lockScreenItemID = item.id
                UserDefaults.standard.set(item.id.uuidString, forKey: lockScreenItemKey)
                if !wasInstalled {
                    screenSaverItemID = item.id
                    UserDefaults.standard.set(item.id.uuidString, forKey: screenSaverItemKey)
                }
                screenSaverStatusMessage = "Aster lock animation set to \(item.name)"
            case .screenSaver:
                screenSaverItemID = item.id
                UserDefaults.standard.set(item.id.uuidString, forKey: screenSaverItemKey)
                if !wasInstalled {
                    lockScreenItemID = item.id
                    UserDefaults.standard.set(item.id.uuidString, forKey: lockScreenItemKey)
                }
                screenSaverStatusMessage = "Screen Saver set to \(item.name)"
            }
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
        playbackActivity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep,
            reason: "Playing a motion wallpaper"
        )
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
            NSWorkspace.activeSpaceDidChangeNotification
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
        guard !videoWindows.isEmpty else {
            recoverMotionWallpaper(url: url)
            return
        }
        videoWindows.forEach { $0.ensureVisibleAndPlaying() }
    }

    private func recoverMotionWallpaper(url: URL) {
        guard isAnimating, !isRecoveringPlayback else { return }
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

    private static func storedUUID(forKey key: String) -> UUID? {
        UserDefaults.standard.string(forKey: key).flatMap(UUID.init(uuidString:))
    }
}

@MainActor
private final class DesktopVideoWindow: Identifiable {
    let id = UUID()
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

    init(
        screen: NSScreen,
        url: URL,
        fillMode: WallpaperController.FillMode,
        muted: Bool,
        onPlaybackFailure: @escaping () -> Void
    ) {
        self.onPlaybackFailure = onPlaybackFailure
        asset = AVURLAsset(url: url)
        let templateItem = AVPlayerItem(asset: asset)
        player = AVQueuePlayer()
        player.actionAtItemEnd = .advance
        player.automaticallyWaitsToMinimizeStalling = false
        player.isMuted = muted
        looper = AVPlayerLooper(player: player, templateItem: templateItem)

        videoView = VideoDesktopView(frame: screen.frame)
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
        window.ignoresMouseEvents = true
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
        guard !isRetiring else { return }
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
        unreadyChecks += 1
        player.play()
        if unreadyChecks >= 4 {
            reportPlaybackFailure()
        }
    }

    private func reportPlaybackFailure() {
        guard !isRetiring, !failureReported else { return }
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
        guard !isRetiring else { return }
        stagnantChecks = 0
        lastPlaybackTime = 0
        player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.isRetiring else { return }
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
        if !window.isVisible {
            window.orderBack(nil)
        }
        player.play()
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

private final class VideoDesktopView: NSView {
    let playerLayer = AVPlayerLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = playerLayer
        playerLayer.backgroundColor = NSColor.black.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
