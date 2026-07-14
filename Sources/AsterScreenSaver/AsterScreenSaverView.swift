import AppKit
import AVFoundation
import AVKit
import CoreGraphics
import ScreenSaver

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
    private var imageView: NSImageView?
    private var player: AVQueuePlayer?
    private var playerLooper: AVPlayerLooper?
    private var playerView: AVPlayerView?
    private var videoPosterView: NSImageView?
    private var firstFrameObserver: Any?
    private var lockObserver: NSObjectProtocol?
    private var unlockObserver: NSObjectProtocol?
    private var showingLockScreenMedia = false
    private var lastPlaybackCheck = Date.distantPast
    private var lastPlaybackTime = -1.0
    private var stagnantChecks = 0

    public override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        animationTimeInterval = 1.0 / 30.0
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        observeSessionLockState()
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
    }

    public override func stopAnimation() {
        player?.pause()
        imageView?.animates = false
        super.stopAnimation()
    }

    public override func animateOneFrame() {
        super.animateOneFrame()
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
        playerView?.frame = bounds
        videoPosterView?.frame = bounds
        layoutImageView()
    }

    private func loadConfiguredMedia() {
        guard let manifest = Self.readConfiguration() else {
            NSLog("Aster saver: configuration could not be read from %@", Self.moduleBundle.bundlePath)
            return
        }
        self.manifest = manifest
        showingLockScreenMedia = Self.isSessionLocked
        let configuration = showingLockScreenMedia ? manifest.lockScreen : manifest.screenSaver
        show(configuration)
    }

    private func show(_ configuration: MediaConfiguration) {
        self.configuration = configuration
        let url: URL
        if let filename = configuration.mediaFilename,
           let bundledURL = Bundle(for: AsterScreenSaverView.self).resourceURL?
            .appendingPathComponent(filename) {
            url = bundledURL
        } else if let path = configuration.mediaPath {
            url = URL(fileURLWithPath: path)
        } else {
            return
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            NSLog("Aster saver: configured media is missing at %@", url.path)
            return
        }
        NSLog("Aster saver: loading %@ from %@", configuration.mediaKind, url.path)

        if configuration.mediaKind == "video" {
            showVideo(url, configuration: configuration)
        } else {
            showImage(url, configuration: configuration)
        }
    }

    private func observeSessionLockState() {
        let center = DistributedNotificationCenter.default()
        lockObserver = center.addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async { self?.switchMedia(forLockedSession: true) }
        }
        unlockObserver = center.addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async { self?.switchMedia(forLockedSession: false) }
        }
    }

    private func switchMedia(forLockedSession locked: Bool) {
        guard showingLockScreenMedia != locked, let manifest else { return }
        showingLockScreenMedia = locked
        clearMedia()
        show(locked ? manifest.lockScreen : manifest.screenSaver)
        if isAnimating { player?.play() }
        NSLog("Aster saver: switched to %@ media", locked ? "Lock Screen" : "Screen Saver")
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
            let posterView = NSImageView(frame: bounds)
            posterView.image = poster
            posterView.imageFrameStyle = .none
            posterView.imageAlignment = .alignCenter
            posterView.imageScaling = configuration.fillMode == "Stretch"
                ? .scaleAxesIndependently
                : .scaleProportionallyUpOrDown
            posterView.autoresizingMask = [.width, .height]
            addSubview(posterView)
            videoPosterView = posterView
        }

        let player = AVQueuePlayer()
        player.isMuted = configuration.muted
        player.actionAtItemEnd = .advance
        player.automaticallyWaitsToMinimizeStalling = false
        let item = AVPlayerItem(url: url)
        let looper = AVPlayerLooper(player: player, templateItem: item)
        let playerView = AVPlayerView(frame: bounds)
        playerView.player = player
        playerView.controlsStyle = .none
        playerView.videoGravity = gravity(for: configuration.fillMode)
        playerView.autoresizingMask = [.width, .height]
        addSubview(playerView)
        if let posterView = videoPosterView {
            addSubview(posterView, positioned: .above, relativeTo: playerView)
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
        let imageView = NSImageView(frame: bounds)
        imageView.image = image
        imageView.animates = url.pathExtension.lowercased() == "gif"
        imageView.imageFrameStyle = .none
        imageView.imageAlignment = .alignCenter
        imageView.imageScaling = configuration.fillMode == "Stretch"
            ? .scaleAxesIndependently
            : .scaleProportionallyUpOrDown
        addSubview(imageView)
        self.imageView = imageView
        layoutImageView()
    }

    private func layoutImageView() {
        guard let imageView, let image = imageView.image, let configuration else { return }
        if configuration.fillMode != "Fill" || image.size.width <= 0 || image.size.height <= 0 {
            imageView.frame = bounds
            return
        }

        let scale = max(bounds.width / image.size.width, bounds.height / image.size.height)
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        imageView.frame = NSRect(
            x: bounds.midX - size.width / 2,
            y: bounds.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
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
                return Configuration(screenSaver: legacy.media, lockScreen: legacy.media)
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
            return Configuration(screenSaver: legacy.media, lockScreen: legacy.media)
        }
        return nil
    }

    private static var moduleBundle: Bundle {
        Bundle(for: AsterScreenSaverView.self)
    }

    private static var isSessionLocked: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return session["CGSSessionScreenIsLocked"] as? Bool ?? false
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
