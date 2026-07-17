import AppKit
import AVFoundation
import AVKit
import QuartzCore
import ScreenSaver
import OSLog

private let screenSaverLog = Logger(subsystem: "app.aster.ScreenSaver", category: "playback")

@objc(AsterScreenSaverView)
public final class AsterScreenSaverView: ScreenSaverView {
    private struct MediaConfiguration: Decodable {
        let mediaPath: String?
        let mediaFilename: String?
        let mediaKind: String
        let fillMode: String
        let muted: Bool
    }

    private struct Configuration: Decodable {
        let screenSaver: MediaConfiguration
        let lockScreen: MediaConfiguration
        let pixelShiftInterval: TimeInterval?
        let rotationInterval: TimeInterval?
        let playlist: [MediaConfiguration]?
    }

    private struct CanvasWallpaper: Decodable {
        let filename: String
        let kind: String
    }

    private struct LegacyConfiguration: Decodable {
        let mediaPath: String?
        let mediaFilename: String?
        let mediaKind: String
        let fillMode: String
        let muted: Bool

        var media: MediaConfiguration {
            MediaConfiguration(
                mediaPath: mediaPath,
                mediaFilename: mediaFilename,
                mediaKind: mediaKind,
                fillMode: fillMode,
                muted: muted
            )
        }
    }

    private var manifest: Configuration?
    private var configuration: MediaConfiguration?
    private let mediaContainer = NSView()
    private var imageView: NSImageView?
    private var player: AVQueuePlayer?
    private var playerLooper: AVPlayerLooper?
    private var playerView: AVPlayerView?
    private var videoPosterView: NSImageView?
    private var firstFrameObserver: Any?
    private var configurationModificationDate: Date?
    private var lastConfigurationCheck = Date.distantPast
    private var lastPlaybackCheck = Date.distantPast
    private var lastPlaybackTime = -1.0
    private var stagnantChecks = 0
    private var pixelShiftPositionIndex = 0
    private var lastPixelShiftDate = Date()
    private var lastRotationDate = Date()
    private var rotationQueue: [String] = []
    private var currentMediaKey: String?
    private var lastPlaylistSignature: String?
    private var lastInsufficientPlaylistCount: Int?
    private var maintenanceTimer: Timer?

    public override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        animationTimeInterval = 1.0 / 30.0
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.masksToBounds = true
        mediaContainer.wantsLayer = true
        addSubview(mediaContainer)
        loadConfiguredMedia()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func startAnimation() {
        super.startAnimation()
        player?.play()
        imageView?.animates = true
        lastPixelShiftDate = Date()
        lastRotationDate = Date()
        startMaintenanceTimer()
    }

    public override func stopAnimation() {
        maintenanceTimer?.invalidate()
        maintenanceTimer = nil
        player?.pause()
        imageView?.animates = false
        super.stopAnimation()
    }

    public override func animateOneFrame() {
        super.animateOneFrame()
        performMaintenance()
    }

    private func startMaintenanceTimer() {
        maintenanceTimer?.invalidate()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.performMaintenance()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        maintenanceTimer = timer
        screenSaverLog.info(
            "Maintenance timer started; rotation interval is \(self.rotationInterval, privacy: .public) seconds"
        )
    }

    private func performMaintenance() {
        reloadConfigurationIfNeeded()
        rotateMediaIfNeeded()
        updatePixelShiftIfNeeded()
        guard let player,
              Date().timeIntervalSince(lastPlaybackCheck) >= 1 else { return }
        lastPlaybackCheck = Date()
        let currentTime = player.currentTime().seconds
        guard currentTime.isFinite, player.currentItem?.status == .readyToPlay else { return }
        if abs(currentTime - lastPlaybackTime) < 0.04 {
            stagnantChecks += 1
        } else {
            stagnantChecks = 0
        }
        lastPlaybackTime = currentTime
        if stagnantChecks >= 2 {
            stagnantChecks = 0
            lastPlaybackTime = 0
            player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                player.play()
            }
        }
    }

    public override func layout() {
        super.layout()
        mediaContainer.frame = Self.pixelShiftFrame(
            in: bounds,
            enabled: pixelShiftInterval > 0,
            positionIndex: pixelShiftPositionIndex
        )
        playerView?.frame = mediaContainer.bounds
        videoPosterView?.frame = mediaContainer.bounds
        layoutImageView()
    }

    private func loadConfiguredMedia() {
        guard let manifest = Self.readConfiguration() else {
            NSLog("Aster saver: configuration could not be read from %@", Self.moduleBundle.bundlePath)
            return
        }
        self.manifest = manifest
        configurationModificationDate = Self.configurationModificationDate
        resetPixelShift()
        resetRotation()
        show(manifest.screenSaver)
    }

    private func reloadConfigurationIfNeeded() {
        guard Date().timeIntervalSince(lastConfigurationCheck) >= 1 else { return }
        lastConfigurationCheck = Date()
        let modificationDate = Self.configurationModificationDate
        guard modificationDate != configurationModificationDate,
              let manifest = Self.readConfiguration() else { return }

        self.manifest = manifest
        configurationModificationDate = modificationDate
        clearMedia()
        resetPixelShift()
        resetRotation()
        show(manifest.screenSaver)
        if isAnimating { player?.play() }
        NSLog("Aster saver: reloaded changed configuration")
    }

    @discardableResult
    private func show(_ configuration: MediaConfiguration) -> Bool {
        self.configuration = configuration
        guard let url = Self.mediaURL(for: configuration) else { return false }
        guard FileManager.default.fileExists(atPath: url.path) else {
            NSLog("Aster saver: configured media is missing at %@", url.path)
            return false
        }
        currentMediaKey = url.standardizedFileURL.path
        NSLog("Aster saver: loading %@ from %@", configuration.mediaKind, url.path)

        if configuration.mediaKind == "video" {
            showVideo(url, configuration: configuration)
        } else {
            showImage(url, configuration: configuration)
        }
        return true
    }

    private func clearMedia() {
        if let firstFrameObserver, let player {
            player.removeTimeObserver(firstFrameObserver)
        }
        firstFrameObserver = nil
        player?.pause()
        player = nil
        playerLooper = nil
        playerView?.removeFromSuperview()
        playerView = nil
        videoPosterView?.removeFromSuperview()
        videoPosterView = nil
        imageView?.removeFromSuperview()
        imageView = nil
        configuration = nil
        lastPlaybackTime = -1
        stagnantChecks = 0
    }

    private func showVideo(_ url: URL, configuration: MediaConfiguration) {
        if let poster = Self.videoPoster(for: url) {
            let posterView = NSImageView(frame: mediaContainer.bounds)
            posterView.image = poster
            posterView.imageFrameStyle = .none
            posterView.imageAlignment = .alignCenter
            posterView.imageScaling = configuration.fillMode == "Stretch"
                ? .scaleAxesIndependently
                : .scaleProportionallyUpOrDown
            posterView.autoresizingMask = [.width, .height]
            mediaContainer.addSubview(posterView)
            videoPosterView = posterView
        }

        let player = AVQueuePlayer()
        player.isMuted = configuration.muted
        player.actionAtItemEnd = .advance
        player.automaticallyWaitsToMinimizeStalling = false
        let item = AVPlayerItem(url: url)
        let looper = AVPlayerLooper(player: player, templateItem: item)
        let playerView = AVPlayerView(frame: mediaContainer.bounds)
        playerView.player = player
        playerView.controlsStyle = .none
        playerView.videoGravity = gravity(for: configuration.fillMode)
        playerView.autoresizingMask = [.width, .height]
        mediaContainer.addSubview(playerView)
        if let posterView = videoPosterView {
            mediaContainer.addSubview(posterView, positioned: .above, relativeTo: playerView)
        }
        self.player = player
        playerLooper = looper
        self.playerView = playerView

        // Keep a decoded frame above the native video view until playback has genuinely
        // produced a frame. Some macOS screen-saver hosts start AVPlayer with a black view.
        if videoPosterView != nil {
            addPeriodicTimeObserver(to: player)
        }
    }

    private func addPeriodicTimeObserver(to player: AVPlayer) {
        firstFrameObserver = player.addBoundaryTimeObserver(
            forTimes: [NSValue(time: CMTime(seconds: 0.12, preferredTimescale: 600))],
            queue: .main
        ) { [weak self] in
            DispatchQueue.main.async {
                guard let self, player.currentItem?.status == .readyToPlay else { return }
                self.videoPosterView?.removeFromSuperview()
                self.videoPosterView = nil
                NSLog("Aster saver: video playback produced its first frame")
            }
        }
    }

    private func showImage(_ url: URL, configuration: MediaConfiguration) {
        guard let image = NSImage(contentsOf: url) else { return }
        let imageView = NSImageView(frame: mediaContainer.bounds)
        imageView.image = image
        imageView.animates = url.pathExtension.lowercased() == "gif"
        imageView.imageFrameStyle = .none
        imageView.imageAlignment = .alignCenter
        imageView.imageScaling = configuration.fillMode == "Stretch"
            ? .scaleAxesIndependently
            : .scaleProportionallyUpOrDown
        mediaContainer.addSubview(imageView)
        self.imageView = imageView
        layoutImageView()
    }

    private func layoutImageView() {
        guard let imageView, let image = imageView.image, let configuration else { return }
        let containerBounds = mediaContainer.bounds
        if configuration.fillMode != "Fill" || image.size.width <= 0 || image.size.height <= 0 {
            imageView.frame = containerBounds
            return
        }

        let scale = max(
            containerBounds.width / image.size.width,
            containerBounds.height / image.size.height
        )
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        imageView.frame = NSRect(
            x: containerBounds.midX - size.width / 2,
            y: containerBounds.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    private var pixelShiftInterval: TimeInterval {
        manifest?.pixelShiftInterval ?? 60
    }

    private var rotationInterval: TimeInterval {
        manifest?.rotationInterval ?? 300
    }

    private func resetRotation() {
        rotationQueue.removeAll()
        lastPlaylistSignature = nil
        lastInsufficientPlaylistCount = nil
        lastRotationDate = Date()
    }

    private func rotateMediaIfNeeded() {
        guard rotationInterval > 0,
              Date().timeIntervalSince(lastRotationDate) >= rotationInterval else { return }

        lastRotationDate = Date()
        let playlist = Self.canvasPlaylist(from: manifest)
        guard playlist.count > 1 else {
            if playlist.count != lastInsufficientPlaylistCount {
                screenSaverLog.error(
                    "Rotation needs at least 2 Canvas backgrounds; found \(playlist.count, privacy: .public)"
                )
                lastInsufficientPlaylistCount = playlist.count
            }
            return
        }
        lastInsufficientPlaylistCount = nil

        var configurations: [String: MediaConfiguration] = [:]
        for media in playlist {
            guard let url = Self.mediaURL(for: media) else { continue }
            configurations[url.standardizedFileURL.path] = media
        }
        let signature = configurations.keys.sorted().joined(separator: "\n")
        if signature != lastPlaylistSignature {
            rotationQueue = rotationQueue.filter { configurations[$0] != nil }
            lastPlaylistSignature = signature
            screenSaverLog.info(
                "Rotation loaded \(configurations.count, privacy: .public) Canvas backgrounds"
            )
        }

        if rotationQueue.isEmpty {
            rotationQueue = Array(configurations.keys).shuffled()
            if rotationQueue.first == currentMediaKey, rotationQueue.count > 1 {
                rotationQueue.swapAt(0, 1)
            }
        }

        while !rotationQueue.isEmpty {
            let key = rotationQueue.removeFirst()
            guard key != currentMediaKey, let next = configurations[key] else { continue }
            clearMedia()
            resetPixelShift()
            if show(next) {
                if isAnimating {
                    player?.play()
                    imageView?.animates = true
                }
                screenSaverLog.info(
                    "Rotation advanced to \(URL(fileURLWithPath: key).lastPathComponent, privacy: .public); \(self.rotationQueue.count, privacy: .public) backgrounds remain in this cycle"
                )
                return
            }
        }
    }

    private func resetPixelShift() {
        pixelShiftPositionIndex = 0
        lastPixelShiftDate = Date()
        mediaContainer.frame = Self.pixelShiftFrame(
            in: bounds,
            enabled: pixelShiftInterval > 0,
            positionIndex: pixelShiftPositionIndex
        )
    }

    private func updatePixelShiftIfNeeded() {
        guard pixelShiftInterval > 0,
              Date().timeIntervalSince(lastPixelShiftDate) >= pixelShiftInterval else { return }
        pixelShiftPositionIndex = (pixelShiftPositionIndex + 1)
            % Self.pixelShiftPositions.count
        lastPixelShiftDate = Date()
        let newFrame = Self.pixelShiftFrame(
            in: bounds,
            enabled: true,
            positionIndex: pixelShiftPositionIndex
        )
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 1.25
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            mediaContainer.animator().frame = newFrame
        }
    }

    private static let pixelShiftPositions = [
        CGPoint.zero,
        CGPoint(x: -1, y: -1),
        CGPoint(x: 1, y: 0),
        CGPoint(x: -1, y: 1),
        CGPoint(x: 0, y: -1),
        CGPoint(x: 1, y: 1),
        CGPoint(x: -1, y: 0),
        CGPoint(x: 1, y: -1),
        CGPoint(x: 0, y: 1)
    ]

    static func pixelShiftFrame(
        in bounds: CGRect,
        enabled: Bool,
        positionIndex: Int
    ) -> CGRect {
        guard enabled, bounds.width > 0, bounds.height > 0 else { return bounds }
        let margin = min(max(min(bounds.width, bounds.height) * 0.025, 18), 48)
        let normalizedIndex = (positionIndex % pixelShiftPositions.count
            + pixelShiftPositions.count) % pixelShiftPositions.count
        let position = pixelShiftPositions[normalizedIndex]
        return bounds
            .insetBy(dx: -margin, dy: -margin)
            .offsetBy(dx: position.x * margin * 0.7, dy: position.y * margin * 0.7)
    }

    private func gravity(for fillMode: String) -> AVLayerVideoGravity {
        switch fillMode {
        case "Fit": .resizeAspect
        case "Stretch": .resize
        default: .resizeAspectFill
        }
    }

    private static func readConfiguration() -> Configuration? {
        if let bundledURL = moduleBundle
            .url(forResource: "configuration", withExtension: "json"),
           let data = try? Data(contentsOf: bundledURL) {
            if let configuration = try? JSONDecoder().decode(Configuration.self, from: data) {
                return configuration
            }
            if let legacy = try? JSONDecoder().decode(LegacyConfiguration.self, from: data) {
                return Configuration(
                    screenSaver: legacy.media,
                    lockScreen: legacy.media,
                    pixelShiftInterval: nil,
                    rotationInterval: nil,
                    playlist: nil
                )
            }
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Aster", isDirectory: true)
            .appendingPathComponent("ScreenSaver", isDirectory: true)
        let url = support.appendingPathComponent("configuration.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        if let configuration = try? JSONDecoder().decode(Configuration.self, from: data) {
            return configuration
        }
        if let legacy = try? JSONDecoder().decode(LegacyConfiguration.self, from: data) {
            return Configuration(
                screenSaver: legacy.media,
                lockScreen: legacy.media,
                pixelShiftInterval: nil,
                rotationInterval: nil,
                playlist: nil
            )
        }
        return nil
    }

    private static var moduleBundle: Bundle {
        Bundle(for: AsterScreenSaverView.self)
    }

    private static func mediaURL(for configuration: MediaConfiguration) -> URL? {
        if let filename = configuration.mediaFilename {
            return moduleBundle.resourceURL?.appendingPathComponent(filename)
        }
        if let path = configuration.mediaPath {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    private static func canvasPlaylist(from manifest: Configuration?) -> [MediaConfiguration] {
        if let bundledPlaylist = manifest?.playlist {
            let available = bundledPlaylist.filter { media in
                guard let url = mediaURL(for: media) else { return false }
                return FileManager.default.fileExists(atPath: url.path)
            }
            if !available.isEmpty { return available }
        }

        let selected = manifest?.screenSaver
        let support = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Aster", isDirectory: true)
        let library = support.appendingPathComponent("Library", isDirectory: true)
        let metadataURL = support.appendingPathComponent("wallpapers.json")
        guard let data = try? Data(contentsOf: metadataURL),
              let wallpapers = try? JSONDecoder().decode([CanvasWallpaper].self, from: data) else {
            return []
        }

        let libraryRoot = library.standardizedFileURL.path + "/"
        return wallpapers.compactMap { wallpaper in
            let url = library.appendingPathComponent(wallpaper.filename).standardizedFileURL
            guard url.path.hasPrefix(libraryRoot),
                  FileManager.default.fileExists(atPath: url.path),
                  wallpaper.kind == "image" || wallpaper.kind == "video" else { return nil }
            return MediaConfiguration(
                mediaPath: url.path,
                mediaFilename: nil,
                mediaKind: wallpaper.kind,
                fillMode: selected?.fillMode ?? "Fill",
                muted: selected?.muted ?? true
            )
        }
    }

    private static var configurationModificationDate: Date? {
        let bundledURL = moduleBundle
            .url(forResource: "configuration", withExtension: "json")
        let supportURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
            .appendingPathComponent("Aster", isDirectory: true)
            .appendingPathComponent("ScreenSaver", isDirectory: true)
            .appendingPathComponent("configuration.json")
        for url in [bundledURL, supportURL].compactMap({ $0 }) {
            if let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]) {
                return values.contentModificationDate
            }
        }
        return nil
    }

    private static func videoPoster(for url: URL) -> NSImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.25, preferredTimescale: 600)
        guard let image = try? generator.copyCGImage(
            at: CMTime(seconds: 0.05, preferredTimescale: 600),
            actualTime: nil
        ) else {
            NSLog("Aster saver: could not decode a poster frame from %@", url.path)
            return nil
        }
        return NSImage(cgImage: image, size: .zero)
    }
}
