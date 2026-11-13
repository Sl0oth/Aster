import AppKit
import XCTest
@testable import Aster

final class CustomizationTests: XCTestCase {
    private func makeDefaults(_ name: String = #function) throws -> (UserDefaults, String) {
        let suiteName = "AsterTests.\(name).\(UUID().uuidString)"
        return (try XCTUnwrap(UserDefaults(suiteName: suiteName)), suiteName)
    }

    // MARK: Canvas

    func testDesktopStillBecomesSystemWallpaperUnlessLockScreenHoldsAnotherPicture() {
        let stillID = UUID()
        let still = DesktopAssignment(
            itemID: stillID,
            url: URL(fileURLWithPath: "/tmp/still.png"),
            media: .still
        )

        XCTAssertEqual(
            DesktopSurfacePlan.plan(for: still, lockScreenItemID: nil)?.presentation,
            .systemWallpaper
        )
        XCTAssertEqual(
            DesktopSurfacePlan.plan(for: still, lockScreenItemID: stillID)?.presentation,
            .systemWallpaper
        )
        // A different Lock Screen still owns the system wallpaper, so the desktop
        // still must be drawn by Aster rather than overwrite it.
        XCTAssertEqual(
            DesktopSurfacePlan.plan(for: still, lockScreenItemID: UUID())?.presentation,
            .stillWindow
        )
        XCTAssertNil(DesktopSurfacePlan.plan(for: nil, lockScreenItemID: UUID()))
    }

    func testGIFsAndVideosAreDrawnAsMotionRegardlessOfLockScreen() {
        let gifItem = WallpaperItem(name: "Loop", filename: "loop.GIF", kind: .image)
        let videoItem = WallpaperItem(name: "Movie", filename: "movie.mp4", kind: .video)
        let stillItem = WallpaperItem(name: "Still", filename: "still.png", kind: .image)
        XCTAssertEqual(DesktopMedia(gifItem), .animatedImage)
        XCTAssertEqual(DesktopMedia(videoItem), .video)
        XCTAssertEqual(DesktopMedia(stillItem), .still)

        for (item, expected) in [
            (gifItem, DesktopSurfacePlan.Presentation.animatedImageWindow),
            (videoItem, .videoWindow)
        ] {
            let assignment = DesktopAssignment(
                itemID: item.id,
                url: URL(fileURLWithPath: "/tmp/\(item.filename)"),
                media: DesktopMedia(item)
            )
            let plan = DesktopSurfacePlan.plan(for: assignment, lockScreenItemID: UUID())
            XCTAssertEqual(plan?.presentation, expected)
            XCTAssertEqual(plan?.isMotion, true)
        }
    }

    @MainActor
    func testCanvasPlaybackSettingsPersistAndClamp() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let fresh = WallpaperController(defaults: defaults, managesInstalledScreenSaver: false)
        XCTAssertTrue(fresh.muted)
        XCTAssertEqual(fresh.playbackSpeed, .normal)
        XCTAssertEqual(fresh.motionDimming, 0)
        XCTAssertFalse(fresh.pauseMotionOnBattery)
        XCTAssertEqual(fresh.shuffleOrder, .random)

        fresh.muted = false
        fresh.playbackSpeed = .half
        fresh.motionDimming = 5
        fresh.pauseMotionOnBattery = true
        fresh.shuffleOrder = .inOrder
        XCTAssertEqual(fresh.motionDimming, WallpaperController.maximumMotionDimming)

        let restored = WallpaperController(defaults: defaults, managesInstalledScreenSaver: false)
        XCTAssertFalse(restored.muted)
        XCTAssertEqual(restored.playbackSpeed, .half)
        XCTAssertEqual(restored.motionDimming, WallpaperController.maximumMotionDimming)
        XCTAssertTrue(restored.pauseMotionOnBattery)
        XCTAssertEqual(restored.shuffleOrder, .inOrder)
    }

    func testBatteryPauseAppliesOnlyWhenEnabledAndOnBattery() {
        func reason(pauseOnBattery: Bool, isOnBatteryPower: Bool) -> WallpaperController.MotionPauseReason? {
            WallpaperController.motionPauseReason(
                pauseForFullScreenApps: false,
                fullScreenApplicationName: nil,
                pauseForHighSystemLoad: false,
                isHighSystemLoad: false,
                systemLoadPercent: nil,
                pauseInLowPowerMode: false,
                isLowPowerModeEnabled: false,
                pauseOnBattery: pauseOnBattery,
                isOnBatteryPower: isOnBatteryPower
            )
        }
        XCTAssertEqual(reason(pauseOnBattery: true, isOnBatteryPower: true), .batteryPower)
        XCTAssertNil(reason(pauseOnBattery: true, isOnBatteryPower: false))
        XCTAssertNil(reason(pauseOnBattery: false, isOnBatteryPower: true))
    }

    @MainActor
    func testDesktopImageFitsTheDisplayForEachFitMode() {
        let display = CGRect(x: 0, y: 0, width: 1600, height: 1000)
        let wide = CGSize(width: 2000, height: 1000)

        // Fill covers the display and crops the sides.
        XCTAssertEqual(
            DesktopImageView.imageFrame(for: wide, in: display, fillMode: .fill),
            CGRect(x: -200, y: 0, width: 2000, height: 1000)
        )
        // Fit shows everything, leaving bars above and below.
        XCTAssertEqual(
            DesktopImageView.imageFrame(for: wide, in: display, fillMode: .fit),
            CGRect(x: 0, y: 100, width: 1600, height: 800)
        )
        XCTAssertEqual(DesktopImageView.imageFrame(for: wide, in: display, fillMode: .stretch), display)
        XCTAssertEqual(DesktopImageView.imageFrame(for: .zero, in: display, fillMode: .fill), display)
    }

    @MainActor
    func testDesktopImageViewDrawsThePictureAcrossTheWholeView() throws {
        let image = NSImage(size: NSSize(width: 40, height: 20), flipped: false) { rect in
            NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1).setFill()
            rect.fill()
            return true
        }
        let view = DesktopImageView(
            frame: NSRect(x: 0, y: 0, width: 200, height: 200),
            image: image,
            animates: false,
            fillMode: .fill,
            handlesDesktopClicks: false
        )
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)

        // A square view filled by a 2:1 picture is covered edge to edge.
        for point in [(5, 5), (100, 100), (195, 195)] {
            let color = try XCTUnwrap(
                bitmap.colorAt(x: point.0 * bitmap.pixelsWide / 200, y: point.1 * bitmap.pixelsHigh / 200)?
                    .usingColorSpace(.sRGB)
            )
            XCTAssertGreaterThan(color.redComponent, 0.8)
            XCTAssertLessThan(color.greenComponent, 0.2)
        }
    }

    // MARK: Shelf

    func testShelfRowsFollowTheChosenOrder() {
        XCTAssertEqual(
            ShelfWidget.rows(for: [.nowPlaying, .timer, .battery, .weather]),
            [[.nowPlaying], [.timer, .battery], [.weather]]
        )
        // A wide widget ends the row a compact widget started.
        XCTAssertEqual(
            ShelfWidget.rows(for: [.timer, .reminders, .battery, .calendar]),
            [[.timer], [.reminders], [.battery, .calendar]]
        )
        XCTAssertTrue(ShelfWidget.rows(for: []).isEmpty)
    }

    func testShelfOrderKeepsEveryWidgetExactlyOnce() {
        let order = ShelfWidget.normalizedOrder(["weather", "removedWidget", "timer", "weather"])
        XCTAssertEqual(Array(order.prefix(2)), [.weather, .timer])
        XCTAssertEqual(Set(order), Set(ShelfWidget.allCases))
        XCTAssertEqual(order.count, ShelfWidget.allCases.count)
        XCTAssertEqual(ShelfWidget.normalizedOrder([]), ShelfWidget.allCases)
    }

    @MainActor
    func testShelfCustomizationPersists() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let shelf = ShelfController(defaults: defaults)
        XCTAssertEqual(shelf.widgetOrder, ShelfWidget.allCases)
        XCTAssertEqual(shelf.timerPresets, ShelfController.defaultTimerPresets)
        XCTAssertEqual(shelf.hoverDelay, 0)

        shelf.moveWidget(.dropZone, by: -1)
        XCTAssertFalse(shelf.canMoveWidget(.dropZone, by: -1))
        shelf.setTimerPreset(at: 0, minutes: 9_999)
        shelf.setTimerPreset(at: 1, minutes: 45)
        shelf.hoverDelay = 0.3
        shelf.setShown(true, for: .timer)
        shelf.setShown(true, for: .dropZone)

        let restored = ShelfController(defaults: defaults)
        XCTAssertEqual(restored.widgetOrder.first, .dropZone)
        XCTAssertEqual(restored.timerPresets, [600, 45, 25])
        XCTAssertEqual(restored.hoverDelay, 0.3)
        XCTAssertEqual(restored.widgetRows, [[.dropZone], [.timer]])
    }

    // MARK: Bar

    func testCollapsedDividerFillsTheSpaceUpToTheNotch() {
        let screen = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        // Measured on a notched display: the divider's window ends at 1400 and
        // the menu bar's right-hand area starts at 956.5.
        let lengths = BarController.fittedCollapseLengths(
            dividerMaxX: 1400,
            screenFrame: screen,
            notchRightEdge: 956.5
        )
        XCTAssertEqual(lengths, [419.5])
    }

    func testCollapsedDividerTriesNarrowerWidthsWithoutANotch() {
        let screen = CGRect(x: 0, y: 0, width: 2000, height: 1200)
        let lengths = BarController.fittedCollapseLengths(
            dividerMaxX: 1700,
            screenFrame: screen,
            notchRightEdge: nil
        )
        XCTAssertEqual(lengths.count, 5)
        XCTAssertEqual(lengths, lengths.sorted(by: >), "Widest first")
        XCTAssertEqual(lengths.first, 1700 - 440 - 24)
        // A divider already at the left edge of the status area has nothing to hide.
        XCTAssertTrue(BarController.fittedCollapseLengths(
            dividerMaxX: 980,
            screenFrame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
            notchRightEdge: 956.5
        ).isEmpty)
    }

    func testRejectedDividerIsRecognizedByItsUnmovedFrame() {
        let expanded = CGRect(x: 1372, y: 1084, width: 28, height: 33)
        // macOS accepted the wider divider: it grew to the left.
        XCTAssertTrue(BarController.dividerWasPlaced(
            collapsedFrame: CGRect(x: 956, y: 1084, width: 436, height: 33),
            expandedFrame: expanded
        ))
        // macOS dropped it: the frame only got wider in place.
        XCTAssertFalse(BarController.dividerWasPlaced(
            collapsedFrame: CGRect(x: 1372, y: 1084, width: 3472, height: 33),
            expandedFrame: expanded
        ))
    }

    // MARK: App

    func testMenuBarFallbackAppearsOnlyWhenNothingElseCanOpenAster() {
        XCTAssertTrue(AsterMenuBarFallback.isNeeded(showsInDock: false, barIsEnabled: false))
        XCTAssertFalse(AsterMenuBarFallback.isNeeded(showsInDock: true, barIsEnabled: false))
        XCTAssertFalse(AsterMenuBarFallback.isNeeded(showsInDock: false, barIsEnabled: true))
    }

    @MainActor
    func testResetRemovesAsterSettingsAndNothingElse() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: "Aster.Onboarding.completed")
        defaults.set("teal", forKey: AsterAccent.defaultsKey)
        defaults.set(120.0, forKey: "NSStatusItem Preferred Position Aster.Bar.Control")
        defaults.set("keep", forKey: "SomeOtherApp.setting")

        AsterDataManagement.resetAllSettings(defaults: defaults)

        XCTAssertNil(defaults.object(forKey: "Aster.Onboarding.completed"))
        XCTAssertNil(defaults.object(forKey: AsterAccent.defaultsKey))
        XCTAssertNil(defaults.object(forKey: "NSStatusItem Preferred Position Aster.Bar.Control"))
        XCTAssertEqual(defaults.string(forKey: "SomeOtherApp.setting"), "keep")
    }

    @MainActor
    func testBarShortcutIsGlobalAndDoesNotCollideWithOtherDefaults() {
        let bar = AsterShortcutAction.toggleBar
        XCTAssertTrue(bar.isGlobal)
        let others = AsterShortcutAction.allCases.filter { $0 != bar }.map(\.defaultBinding)
            + ShortcutStore.macShortcuts.map(\.defaultBinding)
        XCTAssertFalse(others.contains {
            $0.keyCode == bar.defaultBinding.keyCode && $0.modifiers == bar.defaultBinding.modifiers
        })
    }

    func testClearHistoryMessageMentionsClipsKeptOnBoards() {
        XCTAssertFalse(ClipsCopy.clearHistoryMessage(boardClipCount: 0).contains("except"))
        XCTAssertTrue(ClipsCopy.clearHistoryMessage(boardClipCount: 1).contains("1 saved to a board"))
        XCTAssertTrue(ClipsCopy.clearHistoryMessage(boardClipCount: 4).contains("4 saved to boards"))
    }
}
