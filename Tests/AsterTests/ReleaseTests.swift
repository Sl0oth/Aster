import CryptoKit
import XCTest
@testable import Aster

final class ReleaseTests: XCTestCase {
    func testSemanticVersionOrdering() throws {
        XCTAssertGreaterThan(try version("1.0.0"), try version("1.0.0-beta.9"))
        XCTAssertGreaterThan(try version("1.0.0-beta.6"), try version("1.0.0-beta.5"))
        XCTAssertGreaterThan(try version("1.0.0-beta.5"), try version("1.0.0-beta.4"))
        XCTAssertGreaterThan(try version("1.0.0-beta.4"), try version("1.0.0-beta.3"))
        XCTAssertGreaterThan(try version("1.0.0-beta.3"), try version("1.0.0-beta.2"))
        XCTAssertGreaterThan(try version("1.0.0-beta.2"), try version("1.0.0-beta.1"))
        XCTAssertGreaterThan(try version("1.1.0"), try version("1.0.9"))
        XCTAssertEqual(try version("1.0"), try version("1.0.0"))
        XCTAssertEqual(try version("1.0.0+42"), try version("1.0.0+43"))
    }

    func testBundledReleaseNotesAreComplete() throws {
        let notes = try XCTUnwrap(AsterBundledReleaseNotes.load())
        XCTAssertEqual(notes.version, "1.0.0-beta.6")
        XCTAssertFalse(notes.headline.isEmpty)
        XCTAssertFalse(notes.summary.isEmpty)
        XCTAssertFalse(notes.features.isEmpty)
        XCTAssertTrue(notes.features.allSatisfy { !$0.title.isEmpty && !$0.description.isEmpty })
    }

    func testReleaseComparisonUsesVersionAndBuild() {
        XCTAssertTrue(UpdateManager.isNewer(
            candidateVersion: "1.0.1",
            candidateBuild: 1,
            installedVersion: "1.0.0",
            installedBuild: 99
        ))
        XCTAssertTrue(UpdateManager.isNewer(
            candidateVersion: "1.0.0",
            candidateBuild: 2,
            installedVersion: "1.0.0",
            installedBuild: 1
        ))
        XCTAssertFalse(UpdateManager.isNewer(
            candidateVersion: "1.0.0",
            candidateBuild: 1,
            installedVersion: "1.0.0",
            installedBuild: 1
        ))
    }

    func testMinimumSystemVersionComparison() {
        let macOS14 = OperatingSystemVersion(majorVersion: 14, minorVersion: 0, patchVersion: 0)
        XCTAssertTrue(UpdateManager.systemVersion(macOS14, meetsMinimum: "14.0"))
        XCTAssertTrue(UpdateManager.systemVersion(macOS14, meetsMinimum: "13.6.9"))
        XCTAssertFalse(UpdateManager.systemVersion(macOS14, meetsMinimum: "14.1"))
        XCTAssertFalse(UpdateManager.systemVersion(macOS14, meetsMinimum: "invalid"))
    }

    func testSignedFeedAcceptsValidPayloadAndRejectsTampering() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let release = AsterRelease(
            version: "1.1.0",
            build: 2,
            headline: "Test release",
            summary: "A signed update.",
            releaseDate: "2026-07-13",
            downloadURL: try XCTUnwrap(URL(string: "https://updates.example.org/Aster-1.1.0.dmg")),
            sha256: String(repeating: "a", count: 64),
            minimumSystemVersion: "14.0",
            features: []
        )
        let payload = try JSONEncoder().encode(release)
        let envelope = AsterReleaseEnvelope(
            payload: payload.base64EncodedString(),
            signature: try privateKey.signature(for: payload).base64EncodedString()
        )
        let feed = try JSONEncoder().encode(envelope)
        let decoded = try UpdateManager.decodeSignedRelease(feed, publicKey: privateKey.publicKey)
        XCTAssertEqual(decoded, release)

        var tamperedPayload = payload
        tamperedPayload.append(0x20)
        let tampered = AsterReleaseEnvelope(
            payload: tamperedPayload.base64EncodedString(),
            signature: envelope.signature
        )
        XCTAssertThrowsError(
            try UpdateManager.decodeSignedRelease(
                JSONEncoder().encode(tampered),
                publicKey: privateKey.publicKey
            )
        )
    }

    func testUpdateInstallerValidatesAdvertisedApplicationMetadata() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AsterUpdateMetadataTests-\(UUID().uuidString)", isDirectory: true)
        let app = root.appendingPathComponent("Aster.app", isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)

        let info: [String: Any] = [
            "CFBundleIdentifier": AsterUpdateInstaller.expectedBundleIdentifier,
            "CFBundleShortVersionString": "1.0.0-beta.3",
            "CFBundleVersion": "3"
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: info,
            format: .xml,
            options: 0
        )
        try data.write(to: contents.appendingPathComponent("Info.plist"))

        let release = try updateRelease(version: "1.0.0-beta.3", build: 3)
        XCTAssertNoThrow(try AsterUpdateInstaller.validateMetadata(at: app, release: release))
        XCTAssertThrowsError(
            try AsterUpdateInstaller.validateMetadata(
                at: app,
                release: updateRelease(version: "1.0.0-beta.4", build: 4)
            )
        ) { error in
            guard case AsterUpdateInstaller.InstallationError.unexpectedVersion = error else {
                return XCTFail("Expected version validation failure, got \(error)")
            }
        }
    }

    func testOnlyLocationFailuresAllowManualUpdateFallback() {
        XCTAssertTrue(AsterUpdateInstaller.InstallationError.appIsNotInstalled.allowsManualInstallation)
        XCTAssertTrue(AsterUpdateInstaller.InstallationError.destinationIsNotWritable.allowsManualInstallation)
        XCTAssertFalse(AsterUpdateInstaller.InstallationError.invalidCodeSignature.allowsManualInstallation)
        XCTAssertFalse(AsterUpdateInstaller.InstallationError.unexpectedVersion.allowsManualInstallation)
    }

    func testRelaunchHelperFinishesStuckProcessAndLaunchesReplacement() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AsterRelaunchTests-\(UUID().uuidString)", isDirectory: true)
        let backup = root.appendingPathComponent("Aster-backup.app", isDirectory: true)
        let launchMarker = root.appendingPathComponent("replacement-launched")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)

        let oldApplication = Process()
        oldApplication.executableURL = URL(fileURLWithPath: "/bin/sleep")
        oldApplication.arguments = ["30"]
        try oldApplication.run()
        defer {
            if oldApplication.isRunning { oldApplication.terminate() }
        }

        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/zsh")
        helper.arguments = [
            "-c",
            AsterUpdateInstaller.relaunchHelperScript,
            "aster-update-relaunch-test",
            String(oldApplication.processIdentifier),
            launchMarker.path,
            backup.path,
            "/usr/bin/true",
            "/usr/bin/touch"
        ]
        try helper.run()
        helper.waitUntilExit()
        oldApplication.waitUntilExit()

        XCTAssertEqual(helper.terminationStatus, 0)
        XCTAssertFalse(oldApplication.isRunning)
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: launchMarker.path))
        XCTAssertFalse(AsterUpdateInstaller.relaunchHelperScript.contains("\"$opener\" -n"))
    }

    func testModuleSelectionPersistsAndChoosesFirstEnabledModule() throws {
        let suiteName = "AsterTests.ModuleSelection.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        AsterModuleSelection.save([.switchboard, .canvas], to: defaults)
        XCTAssertEqual(AsterModuleSelection.load(from: defaults), [.canvas, .switchboard])
        XCTAssertEqual(AsterModuleSelection.initialModule(from: defaults), .canvas)

        XCTAssertEqual(
            AsterModuleSelection.initialModuleForLaunch(
                releaseIdentifier: "1.0.0-beta.3 (3)",
                from: defaults
            ),
            .home
        )
        XCTAssertEqual(
            AsterModuleSelection.initialModuleForLaunch(
                releaseIdentifier: "1.0.0-beta.3 (3)",
                from: defaults
            ),
            .canvas
        )
        XCTAssertEqual(
            AsterModuleSelection.initialModuleForLaunch(
                releaseIdentifier: "1.0.0-beta.4 (4)",
                from: defaults
            ),
            .home
        )
        XCTAssertEqual(
            defaults.string(forKey: AsterModuleSelection.lastOpenedReleaseKey),
            "1.0.0-beta.4 (4)"
        )
    }

    @MainActor
    func testShelfStartsWithoutWidgetsAndPreservesSavedSelections() throws {
        let suiteName = "AsterTests.ShelfDefaults.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let freshShelf = ShelfController(defaults: defaults)
        XCTAssertEqual(freshShelf.enabledWidgetCount, 0)

        defaults.set(true, forKey: "Aster.Shelf.widget.calendar")
        defaults.set(true, forKey: "Aster.Shelf.widget.nowPlaying")
        let configuredShelf = ShelfController(defaults: defaults)
        XCTAssertTrue(configuredShelf.showsCalendar)
        XCTAssertTrue(configuredShelf.showsNowPlaying)
        XCTAssertEqual(configuredShelf.enabledWidgetCount, 3)
    }

    func testShuffleAcceptsAllCanvasMedia() {
        let screenshot = WallpaperItem(name: "Screenshot", filename: "screen.png", kind: .image)
        let gif = WallpaperItem(name: "Animation", filename: "loop.gif", kind: .image)
        let video = WallpaperItem(name: "Movie", filename: "clip.mov", kind: .video)

        XCTAssertTrue(screenshot.canShuffle)
        XCTAssertTrue(gif.canShuffle)
        XCTAssertTrue(video.canShuffle)
    }

    func testAppPresenceDefaultsToShowingInDockAndReadsPreference() throws {
        let suiteName = "AsterTests.AppPresence.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertTrue(AsterAppPresence.showsInDock(defaults: defaults))
        defaults.set(false, forKey: AsterAppPresence.showsInDockKey)
        XCTAssertFalse(AsterAppPresence.showsInDock(defaults: defaults))
    }

    func testExecutablePreferenceMigrationCopiesOnlyAsterValuesOnce() throws {
        let targetName = "AsterTests.PreferenceTarget.\(UUID().uuidString)"
        let legacyName = "AsterTests.PreferenceLegacy.\(UUID().uuidString)"
        let target = try XCTUnwrap(UserDefaults(suiteName: targetName))
        let legacy = try XCTUnwrap(UserDefaults(suiteName: legacyName))
        defer {
            target.removePersistentDomain(forName: targetName)
            legacy.removePersistentDomain(forName: legacyName)
        }
        legacy.set(true, forKey: "Aster.Bar.enabled")
        legacy.set("ignore", forKey: "Unrelated.value")

        AsterPreferencesMigration.migrateExecutableDefaultsIfNeeded(
            target: target,
            legacy: legacy
        )
        XCTAssertTrue(target.bool(forKey: "Aster.Bar.enabled"))
        XCTAssertNil(target.object(forKey: "Unrelated.value"))

        legacy.set(false, forKey: "Aster.Bar.enabled")
        AsterPreferencesMigration.migrateExecutableDefaultsIfNeeded(
            target: target,
            legacy: legacy
        )
        XCTAssertTrue(target.bool(forKey: "Aster.Bar.enabled"))
    }

    @MainActor
    func testMotionWallpaperAutoResumeDefaultsOnAndHonorsOptOut() throws {
        let suiteName = "AsterTests.MotionResume.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertTrue(WallpaperController(defaults: defaults).autoResumeMotionWallpaper)

        defaults.set(false, forKey: "Aster.Canvas.autoResumeMotion")
        XCTAssertFalse(WallpaperController(defaults: defaults).autoResumeMotionWallpaper)
    }

    @MainActor
    func testSmartPauseDefaultsAndPersistedSettings() throws {
        let suiteName = "AsterTests.SmartPause.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let defaultsController = WallpaperController(defaults: defaults)
        XCTAssertTrue(defaultsController.pauseMotionForFullScreenApps)
        XCTAssertTrue(defaultsController.pauseMotionForHighSystemLoad)
        XCTAssertEqual(defaultsController.highSystemLoadThreshold, 80)
        XCTAssertTrue(defaultsController.pauseMotionInLowPowerMode)

        defaults.set(false, forKey: "Aster.Canvas.smartPause.fullScreenApps")
        defaults.set(false, forKey: "Aster.Canvas.smartPause.highSystemLoad")
        defaults.set(65.0, forKey: "Aster.Canvas.smartPause.highSystemLoadThreshold")
        defaults.set(false, forKey: "Aster.Canvas.smartPause.lowPowerMode")
        let customizedController = WallpaperController(defaults: defaults)
        XCTAssertFalse(customizedController.pauseMotionForFullScreenApps)
        XCTAssertFalse(customizedController.pauseMotionForHighSystemLoad)
        XCTAssertEqual(customizedController.highSystemLoadThreshold, 65)
        XCTAssertFalse(customizedController.pauseMotionInLowPowerMode)
    }

    func testSmartPausePolicySelectsEnabledResourceCondition() {
        XCTAssertEqual(
            WallpaperController.motionPauseReason(
                pauseForFullScreenApps: true,
                fullScreenApplicationName: "Final Cut Pro",
                pauseForHighSystemLoad: true,
                isHighSystemLoad: true,
                systemLoadPercent: 88,
                pauseInLowPowerMode: true,
                isLowPowerModeEnabled: true
            ),
            .fullScreenApplication("Final Cut Pro")
        )
        XCTAssertEqual(
            WallpaperController.motionPauseReason(
                pauseForFullScreenApps: false,
                fullScreenApplicationName: "Final Cut Pro",
                pauseForHighSystemLoad: true,
                isHighSystemLoad: true,
                systemLoadPercent: 88,
                pauseInLowPowerMode: false,
                isLowPowerModeEnabled: false
            ),
            .highSystemLoad(88)
        )
        XCTAssertEqual(
            WallpaperController.motionPauseReason(
                pauseForFullScreenApps: false,
                fullScreenApplicationName: nil,
                pauseForHighSystemLoad: false,
                isHighSystemLoad: false,
                systemLoadPercent: nil,
                pauseInLowPowerMode: true,
                isLowPowerModeEnabled: true
            ),
            .lowPowerMode
        )
        XCTAssertNil(
            WallpaperController.motionPauseReason(
                pauseForFullScreenApps: false,
                fullScreenApplicationName: "Ignored",
                pauseForHighSystemLoad: false,
                isHighSystemLoad: true,
                systemLoadPercent: 99,
                pauseInLowPowerMode: false,
                isLowPowerModeEnabled: true
            )
        )
    }

    func testManualLockScreenAcceptsOnlyStillImages() {
        let still = WallpaperItem(name: "Still", filename: "still.png", kind: .image)
        let gif = WallpaperItem(name: "Animation", filename: "loop.gif", kind: .image)
        let video = WallpaperItem(name: "Movie", filename: "movie.mp4", kind: .video)

        XCTAssertTrue(still.canUseAsLockScreenStill)
        XCTAssertFalse(gif.canUseAsLockScreenStill)
        XCTAssertFalse(video.canUseAsLockScreenStill)
    }

    @MainActor
    func testShuffleRunningStateLoadsAndStopsPersistently() throws {
        let suiteName = "AsterTests.ShuffleResume.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let firstID = UUID()
        let secondID = UUID()
        defaults.set(true, forKey: "Aster.Canvas.shuffleRunning")
        defaults.set(
            [firstID.uuidString, secondID.uuidString],
            forKey: "Aster.Canvas.shuffleItems"
        )
        defaults.set(60, forKey: "Aster.Canvas.shuffleRate")

        let controller = WallpaperController(defaults: defaults)
        XCTAssertTrue(controller.shouldResumeShuffle)
        XCTAssertEqual(controller.shuffleItemIDs, [firstID, secondID])
        XCTAssertEqual(controller.shuffleRate, .oneMinute)

        controller.stopShuffle()
        XCTAssertFalse(controller.shouldResumeShuffle)
        XCTAssertFalse(defaults.bool(forKey: "Aster.Canvas.shuffleRunning"))
    }

    func testDevelopmentLoginAgentCanBeEnabledAndDisabled() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AsterLoginItemTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("Aster")

        try AsterLoginItemManager.setDevelopmentAgentEnabled(
            true,
            executableURL: executable,
            launchAgentsDirectory: root
        )

        let agentURL = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
                .first(where: { $0.pathExtension == "plist" })
        )
        let data = try Data(contentsOf: agentURL)
        let propertyList = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        XCTAssertEqual(propertyList["RunAtLoad"] as? Bool, true)
        XCTAssertEqual(
            propertyList["ProgramArguments"] as? [String],
            [executable.standardizedFileURL.path]
        )

        try AsterLoginItemManager.setDevelopmentAgentEnabled(
            false,
            executableURL: executable,
            launchAgentsDirectory: root
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: agentURL.path))
    }

    func testOnlyInstalledAppBundlesUseNativeLoginItemRegistration() {
        XCTAssertTrue(AsterLoginItemManager.isPackagedApplication(
            bundleURL: URL(fileURLWithPath: "/Applications/Aster.app")
        ))
        XCTAssertFalse(AsterLoginItemManager.isPackagedApplication(
            bundleURL: URL(fileURLWithPath: "/tmp/Aster.app")
        ))
        XCTAssertFalse(AsterLoginItemManager.isPackagedApplication(
            bundleURL: URL(fileURLWithPath: "/tmp/Aster")
        ))
    }

    private func version(_ value: String) throws -> AsterSemanticVersion {
        try XCTUnwrap(AsterSemanticVersion(value), "Invalid test version: \(value)")
    }

    private func updateRelease(version: String, build: Int) throws -> AsterRelease {
        AsterRelease(
            version: version,
            build: build,
            headline: "Test update",
            summary: "Installer validation fixture.",
            releaseDate: "2026-07-16",
            downloadURL: try XCTUnwrap(URL(string: "https://updates.example.org/Aster.dmg")),
            sha256: String(repeating: "a", count: 64),
            minimumSystemVersion: "14.0",
            features: []
        )
    }
}
