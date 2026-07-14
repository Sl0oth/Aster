import AppKit
import IOKit.ps
import Observation
import SwiftUI

@MainActor
@Observable
final class ShelfController {
    var isEnabled: Bool {
        didSet {
            defaults.set(isEnabled, forKey: Keys.enabled)
            syncActivation()
        }
    }

    var opensOnHover: Bool {
        didSet { defaults.set(opensOnHover, forKey: Keys.hover) }
    }

    var shelfWidth: Double {
        didSet {
            let clampedWidth = min(max(shelfWidth, 360), 620)
            if shelfWidth != clampedWidth {
                shelfWidth = clampedWidth
                return
            }
            defaults.set(shelfWidth, forKey: Keys.width)
            updatePanelFrame(animated: false)
        }
    }

    var showsCalendar: Bool { didSet { saveWidgetSettings() } }
    var showsTimer: Bool { didSet { saveWidgetSettings() } }
    var showsAlarm: Bool { didSet { saveWidgetSettings() } }
    var showsBattery: Bool { didSet { saveWidgetSettings() } }
    var showsClipboard: Bool { didSet { saveWidgetSettings() } }
    var showsSwitches: Bool { didSet { saveWidgetSettings() } }
    var showsDropZone: Bool { didSet { saveWidgetSettings() } }
    var showsReminders: Bool {
        didSet {
            saveWidgetSettings()
            if isEnabled, showsReminders { refreshReminders() }
        }
    }
    var showsShortcuts: Bool {
        didSet {
            saveWidgetSettings()
            if isEnabled, showsShortcuts { refreshShortcuts() }
        }
    }
    var showsSystemHealth: Bool { didSet { saveWidgetSettings() } }
    var showsWeather: Bool {
        didSet {
            saveWidgetSettings()
            if isEnabled, showsWeather { refreshWeather() }
        }
    }
    var showsNowPlaying: Bool {
        didSet {
            saveWidgetSettings()
            if isEnabled, showsNowPlaying { refreshNowPlaying() }
            else { clearNowPlaying() }
        }
    }
    var showsOutline: Bool {
        didSet {
            saveAppearanceSettings()
            panel?.hasShadow = showsOutline
        }
    }
    var showsHeaderDate: Bool { didSet { saveAppearanceSettings() } }
    var showsHeaderTime: Bool { didSet { saveAppearanceSettings() } }
    var weatherLocation: String {
        didSet { defaults.set(weatherLocation, forKey: Keys.weatherLocation) }
    }

    private(set) var isExpanded = false
    private(set) var batteryLevel: Int?
    private(set) var isCharging = false
    private(set) var timerEndDate: Date?
    private(set) var timerDuration: TimeInterval = 0
    private(set) var alarmDate: Date?
    private(set) var now = Date()
    private(set) var nowPlayingTitle: String?
    private(set) var nowPlayingArtist = ""
    private(set) var nowPlayingAlbum = ""
    private(set) var nowPlayingApp: MediaPlayerApp?
    private(set) var nowPlayingIsPlaying = false
    private(set) var nowPlayingPosition: TimeInterval = 0
    private(set) var nowPlayingDuration: TimeInterval = 0
    private(set) var nowPlayingUpdatedAt = Date()
    private(set) var nowPlayingArtwork: NSImage?
    private(set) var droppedItems: [ShelfDropItem] = []
    private(set) var reminders: [ShelfReminderItem] = []
    private(set) var remindersStatus: String?
    private(set) var shortcuts: [String] = []
    private(set) var shortcutStatus: String?
    private(set) var systemHealth = ShelfSystemHealth()
    private(set) var weather: ShelfWeather?
    private(set) var weatherStatus: String?
    private(set) var weatherIsLoading = false

    private let defaults = UserDefaults.standard
    private var panel: ShelfPanel?
    private weak var clipboard: ClipboardManager?
    private weak var switches: SwitchController?
    private var heartbeat: Timer?
    private var collapseTask: Task<Void, Never>?
    private var screenObserver: NSObjectProtocol?
    private var timerDidFinish = false
    private var alarmDidFinish = false
    private var lastArtworkIdentity: String?
    private let systemHealthReader = SystemHealthReader()
    private var runningShortcutProcesses: [Process] = []
    private var weatherTask: Task<Void, Never>?
    private var lastWeatherRefresh: Date?
    private var isActive = false

    private enum Keys {
        static let enabled = "Aster.Shelf.enabled"
        static let hover = "Aster.Shelf.hover"
        static let width = "Aster.Shelf.width"
        static let calendar = "Aster.Shelf.widget.calendar"
        static let timer = "Aster.Shelf.widget.timer"
        static let alarm = "Aster.Shelf.widget.alarm"
        static let battery = "Aster.Shelf.widget.battery"
        static let clipboard = "Aster.Shelf.widget.clipboard"
        static let switches = "Aster.Shelf.widget.switches"
        static let nowPlaying = "Aster.Shelf.widget.nowPlaying"
        static let dropZone = "Aster.Shelf.widget.dropZone"
        static let reminders = "Aster.Shelf.widget.reminders"
        static let shortcuts = "Aster.Shelf.widget.shortcuts"
        static let systemHealth = "Aster.Shelf.widget.systemHealth"
        static let weather = "Aster.Shelf.widget.weather"
        static let outline = "Aster.Shelf.appearance.outline"
        static let headerDate = "Aster.Shelf.appearance.date"
        static let headerTime = "Aster.Shelf.appearance.time"
        static let weatherLocation = "Aster.Shelf.weather.location"
        static let timerEnd = "Aster.Shelf.timer.end"
        static let timerDuration = "Aster.Shelf.timer.duration"
        static let alarmDate = "Aster.Shelf.alarm.date"
    }

    init() {
        isEnabled = defaults.bool(forKey: Keys.enabled)
        opensOnHover = defaults.object(forKey: Keys.hover) as? Bool ?? true
        shelfWidth = defaults.object(forKey: Keys.width) as? Double ?? 480
        showsCalendar = defaults.object(forKey: Keys.calendar) as? Bool ?? true
        showsTimer = defaults.object(forKey: Keys.timer) as? Bool ?? true
        showsAlarm = defaults.object(forKey: Keys.alarm) as? Bool ?? true
        showsBattery = defaults.object(forKey: Keys.battery) as? Bool ?? true
        showsClipboard = defaults.object(forKey: Keys.clipboard) as? Bool ?? false
        showsSwitches = defaults.object(forKey: Keys.switches) as? Bool ?? false
        showsNowPlaying = defaults.object(forKey: Keys.nowPlaying) as? Bool ?? true
        showsDropZone = defaults.object(forKey: Keys.dropZone) as? Bool ?? true
        showsReminders = defaults.object(forKey: Keys.reminders) as? Bool ?? true
        showsShortcuts = defaults.object(forKey: Keys.shortcuts) as? Bool ?? true
        showsSystemHealth = defaults.object(forKey: Keys.systemHealth) as? Bool ?? true
        showsWeather = defaults.object(forKey: Keys.weather) as? Bool ?? true
        showsOutline = defaults.object(forKey: Keys.outline) as? Bool ?? false
        showsHeaderDate = defaults.object(forKey: Keys.headerDate) as? Bool ?? true
        showsHeaderTime = defaults.object(forKey: Keys.headerTime) as? Bool ?? true
        weatherLocation = defaults.string(forKey: Keys.weatherLocation) ?? ""

        let storedEnd = defaults.double(forKey: Keys.timerEnd)
        let storedDuration = defaults.double(forKey: Keys.timerDuration)
        if storedEnd > Date().timeIntervalSince1970 {
            timerEndDate = Date(timeIntervalSince1970: storedEnd)
            timerDuration = storedDuration
        }
        let storedAlarm = defaults.double(forKey: Keys.alarmDate)
        if storedAlarm > Date().timeIntervalSince1970 {
            alarmDate = Date(timeIntervalSince1970: storedAlarm)
        }
    }

    func activate(clipboard: ClipboardManager, switches: SwitchController) {
        self.clipboard = clipboard
        self.switches = switches
        syncActivation()
    }

    private func syncActivation() {
        guard clipboard != nil, switches != nil else { return }
        if !isEnabled {
            deactivate()
            return
        }
        guard !isActive else {
            syncPanelVisibility()
            return
        }
        isActive = true
        refreshBattery()
        refreshNowPlaying()
        refreshSystemHealth()
        refreshShortcuts()
        refreshReminders()
        refreshWeather()
        startHeartbeat()
        if screenObserver == nil {
            screenObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.screenConfigurationChanged() }
            }
        }
        syncPanelVisibility()
    }

    private func deactivate() {
        isActive = false
        heartbeat?.invalidate()
        heartbeat = nil
        collapseTask?.cancel()
        collapseTask = nil
        weatherTask?.cancel()
        weatherTask = nil
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
            self.screenObserver = nil
        }
        setExpanded(false, animated: false)
        panel?.orderOut(nil)
    }

    func hoverChanged(_ isInside: Bool) {
        guard isEnabled, opensOnHover else { return }
        collapseTask?.cancel()
        if isInside {
            setExpanded(true)
        } else {
            collapseTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                guard let self else { return }
                self.collapseTask = nil
                if let panel = self.panel, panel.frame.contains(NSEvent.mouseLocation) { return }
                self.setExpanded(false)
            }
        }
    }

    func toggleExpansion() {
        guard isEnabled else { return }
        collapseTask?.cancel()
        setExpanded(!isExpanded)
    }

    func startTimer(minutes: Int) {
        timerDuration = TimeInterval(minutes * 60)
        timerEndDate = Date().addingTimeInterval(timerDuration)
        timerDidFinish = false
        persistTimer()
        setExpanded(true)
    }

    func cancelTimer() {
        timerEndDate = nil
        timerDuration = 0
        timerDidFinish = false
        persistTimer()
    }

    func setAlarm(minutesFromNow minutes: Int) {
        alarmDate = Date().addingTimeInterval(TimeInterval(minutes * 60))
        alarmDidFinish = false
        persistAlarm()
        setExpanded(true)
    }

    func setMorningAlarm(hour: Int = 8) {
        let calendar = Calendar.current
        let now = Date()
        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = hour
        components.minute = 0
        components.second = 0
        var target = calendar.date(from: components) ?? now
        if target <= now {
            target = calendar.date(byAdding: .day, value: 1, to: target) ?? now.addingTimeInterval(86_400)
        }
        alarmDate = target
        alarmDidFinish = false
        persistAlarm()
        setExpanded(true)
    }

    func cancelAlarm() {
        alarmDate = nil
        alarmDidFinish = false
        persistAlarm()
    }

    @discardableResult
    func addDroppedFiles(_ urls: [URL]) -> Bool {
        let existingPaths = Set(droppedItems.map { $0.url.standardizedFileURL.path })
        let additions = urls
            .filter { $0.isFileURL && !existingPaths.contains($0.standardizedFileURL.path) }
            .map(ShelfDropItem.init(url:))
        guard !additions.isEmpty else { return false }
        droppedItems.append(contentsOf: additions)
        if droppedItems.count > 12 { droppedItems.removeFirst(droppedItems.count - 12) }
        return true
    }

    func removeDroppedItem(_ item: ShelfDropItem) {
        droppedItems.removeAll { $0.id == item.id }
    }

    func clearDroppedItems() {
        droppedItems.removeAll()
    }

    func refreshReminders() {
        guard showsReminders else { return }
        if let loaded = ReminderAppleScript.pendingReminders() {
            reminders = loaded
            remindersStatus = loaded.isEmpty ? "Nothing due" : nil
        } else {
            remindersStatus = "Allow Aster to use Reminders"
        }
    }

    @discardableResult
    func addReminder(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, ReminderAppleScript.add(trimmed) else { return false }
        refreshReminders()
        return true
    }

    func completeReminder(_ reminder: ShelfReminderItem) {
        guard ReminderAppleScript.complete(id: reminder.id) else { return }
        reminders.removeAll { $0.id == reminder.id }
        if reminders.isEmpty { remindersStatus = "Nothing due" }
    }

    func refreshShortcuts() {
        guard showsShortcuts else { return }
        shortcuts = Array(ShortcutCommand.list().prefix(4))
        shortcutStatus = shortcuts.isEmpty ? "Create a Shortcut to see it here" : nil
    }

    func runShortcut(_ name: String) {
        guard let process = ShortcutCommand.launch(name: name) else {
            shortcutStatus = "Couldn’t run \(name)"
            return
        }
        runningShortcutProcesses.append(process)
        shortcutStatus = "Running \(name)…"
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            self?.shortcutStatus = nil
        }
    }

    func refreshWeather() {
        weatherTask?.cancel()
        let location = weatherLocation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard showsWeather, !location.isEmpty else {
            weather = nil
            weatherStatus = location.isEmpty ? "Set a city in Aster" : nil
            weatherIsLoading = false
            return
        }
        weatherIsLoading = true
        weatherStatus = nil
        weatherTask = Task { @MainActor [weak self] in
            do {
                let result = try await ShelfWeatherService.fetch(location: location)
                guard !Task.isCancelled, let self else { return }
                self.weather = result
                self.weatherStatus = nil
                self.weatherIsLoading = false
                self.lastWeatherRefresh = .now
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.weather = nil
                self.weatherStatus = error.localizedDescription
                self.weatherIsLoading = false
            }
        }
    }

    func openCalendar() {
        let calendarURL = URL(fileURLWithPath: "/System/Applications/Calendar.app")
        NSWorkspace.shared.openApplication(
            at: calendarURL,
            configuration: NSWorkspace.OpenConfiguration()
        )
    }

    var timerRemaining: TimeInterval {
        guard let timerEndDate else { return 0 }
        return max(timerEndDate.timeIntervalSince(now), 0)
    }

    var enabledWidgetCount: Int {
        let singleSlotWidgets = [
            showsCalendar, showsTimer, showsAlarm, showsBattery, showsClipboard,
            showsSystemHealth, showsWeather
        ]
            .filter { $0 }.count
        let doubleSlotWidgets = [showsNowPlaying, showsDropZone, showsReminders, showsShortcuts, showsSwitches]
            .filter { $0 }.count * 2
        return singleSlotWidgets + doubleSlotWidgets
    }

    var currentPlaybackPosition: TimeInterval {
        guard nowPlayingIsPlaying else { return nowPlayingPosition }
        return min(nowPlayingPosition + now.timeIntervalSince(nowPlayingUpdatedAt), nowPlayingDuration)
    }

    func togglePlayback() {
        guard let nowPlayingApp else { return }
        MediaAppleScript.control(.playPause, app: nowPlayingApp)
        scheduleNowPlayingRefresh()
    }

    func previousTrack() {
        guard let nowPlayingApp else { return }
        MediaAppleScript.control(.previous, app: nowPlayingApp)
        scheduleNowPlayingRefresh()
    }

    func nextTrack() {
        guard let nowPlayingApp else { return }
        MediaAppleScript.control(.next, app: nowPlayingApp)
        scheduleNowPlayingRefresh()
    }

    private func syncPanelVisibility() {
        guard clipboard != nil, switches != nil else { return }
        if isEnabled {
            createPanelIfNeeded()
            updatePanelFrame(animated: false)
            panel?.orderFrontRegardless()
        } else {
            setExpanded(false, animated: false)
            panel?.orderOut(nil)
        }
    }

    private func createPanelIfNeeded() {
        guard panel == nil, let clipboard, let switches else { return }
        let panel = ShelfPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = showsOutline
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.animationBehavior = .none
        panel.contentView = NSHostingView(
            rootView: ShelfPanelView()
                .environment(self)
                .environment(clipboard)
                .environment(switches)
                .preferredColorScheme(.dark)
        )
        self.panel = panel
    }

    private func setExpanded(_ expanded: Bool, animated: Bool = true) {
        guard isExpanded != expanded else { return }
        isExpanded = expanded
        updatePanelFrame(animated: animated)
    }

    private func updatePanelFrame(animated: Bool) {
        guard let panel, let screen = shelfScreen else { return }
        var size = isExpanded ? expandedSize : collapsedSize(for: screen)
        if isExpanded {
            size.height = min(size.height, screen.frame.height - 12)
        }
        let frame = NSRect(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.maxY - size.height,
            width: size.width,
            height: size.height
        )

        if animated && panel.isVisible {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }
    }

    private var shelfScreen: NSScreen? {
        NSScreen.screens.first(where: { screen in
            screen.safeAreaInsets.top > 0 ||
                (screen.auxiliaryTopLeftArea != nil && screen.auxiliaryTopRightArea != nil)
        }) ?? NSScreen.main ?? NSScreen.screens.first
    }

    private func collapsedSize(for screen: NSScreen) -> NSSize {
        let hardwareGap: CGFloat
        if let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            hardwareGap = max(right.minX - left.maxX, 0)
        } else {
            hardwareGap = 164
        }
        let menuBarHeight = max(screen.frame.maxY - screen.visibleFrame.maxY, 30)
        // Stay just inside the hardware notch. Any extra width is visible as
        // black tabs on the menu bar when Shelf is collapsed.
        return NSSize(width: max(hardwareGap - 8, 156), height: min(menuBarHeight, 31))
    }

    private var expandedSize: NSSize {
        let singleSlotCount = [
            showsCalendar, showsTimer, showsAlarm, showsBattery, showsClipboard,
            showsSystemHealth, showsWeather
        ].filter { $0 }.count
        let doubleSlotRows = [showsNowPlaying, showsDropZone, showsReminders, showsShortcuts, showsSwitches]
            .filter { $0 }.count
        let compactRows = Int(ceil(Double(singleSlotCount) / 2))
        let rows = max(doubleSlotRows + compactRows, 1)
        let headerHeight = (showsHeaderDate || showsHeaderTime) ? 48 : 42
        let rowHeight = 132
        let rowSpacing = max(rows - 1, 0) * 10
        let footerClearance = 14
        return NSSize(
            width: shelfWidth,
            height: CGFloat(headerHeight + rows * rowHeight + rowSpacing + footerClearance)
        )
    }

    private func startHeartbeat() {
        guard heartbeat == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        heartbeat = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func tick() {
        guard isEnabled else { return }
        now = Date()
        if Calendar.current.component(.second, from: now) == 0 {
            refreshBattery()
        }
        if showsNowPlaying && Calendar.current.component(.second, from: now).isMultiple(of: 3) {
            refreshNowPlaying()
        }
        if showsSystemHealth && Calendar.current.component(.second, from: now).isMultiple(of: 3) {
            refreshSystemHealth()
        }
        if showsReminders && Calendar.current.component(.second, from: now).isMultiple(of: 30) {
            refreshReminders()
        }
        if showsWeather,
           let lastWeatherRefresh,
           now.timeIntervalSince(lastWeatherRefresh) >= 900 {
            refreshWeather()
        }
        runningShortcutProcesses.removeAll { !$0.isRunning }
        if let timerEndDate, timerEndDate <= now, !timerDidFinish {
            timerDidFinish = true
            self.timerEndDate = nil
            persistTimer()
            NSSound.beep()
            setExpanded(true)
        }
        if let alarmDate, alarmDate <= now, !alarmDidFinish {
            alarmDidFinish = true
            self.alarmDate = nil
            persistAlarm()
            NSSound.beep()
            setExpanded(true)
        }
    }

    private func refreshBattery() {
        guard let snapshot = Self.readBattery() else {
            batteryLevel = nil
            isCharging = false
            return
        }
        batteryLevel = snapshot.level
        isCharging = snapshot.isCharging
    }

    private static func readBattery() -> (level: Int, isCharging: Bool)? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else {
            return nil
        }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue()
                as? [String: Any],
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = description[kIOPSMaxCapacityKey] as? Int,
                  maximum > 0 else { continue }
            let state = description[kIOPSPowerSourceStateKey] as? String
            let charging = (description[kIOPSIsChargingKey] as? Bool) ?? (state == kIOPSACPowerValue)
            return (Int((Double(current) / Double(maximum) * 100).rounded()), charging)
        }
        return nil
    }

    private func saveWidgetSettings() {
        defaults.set(showsCalendar, forKey: Keys.calendar)
        defaults.set(showsTimer, forKey: Keys.timer)
        defaults.set(showsAlarm, forKey: Keys.alarm)
        defaults.set(showsBattery, forKey: Keys.battery)
        defaults.set(showsClipboard, forKey: Keys.clipboard)
        defaults.set(showsSwitches, forKey: Keys.switches)
        defaults.set(showsNowPlaying, forKey: Keys.nowPlaying)
        defaults.set(showsDropZone, forKey: Keys.dropZone)
        defaults.set(showsReminders, forKey: Keys.reminders)
        defaults.set(showsShortcuts, forKey: Keys.shortcuts)
        defaults.set(showsSystemHealth, forKey: Keys.systemHealth)
        defaults.set(showsWeather, forKey: Keys.weather)
        updatePanelFrame(animated: false)
    }

    private func refreshSystemHealth() {
        systemHealth = systemHealthReader.snapshot()
    }

    private func saveAppearanceSettings() {
        defaults.set(showsOutline, forKey: Keys.outline)
        defaults.set(showsHeaderDate, forKey: Keys.headerDate)
        defaults.set(showsHeaderTime, forKey: Keys.headerTime)
    }

    private func refreshNowPlaying() {
        guard showsNowPlaying else { return }
        let runningIDs = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let candidates = MediaPlayerApp.allCases.filter { runningIDs.contains($0.bundleIdentifier) }
        guard !candidates.isEmpty else {
            clearNowPlaying()
            return
        }

        var snapshot: MediaSnapshot?
        for app in candidates {
            if let candidate = MediaAppleScript.snapshot(for: app) {
                snapshot = candidate
                if candidate.isPlaying { break }
            }
        }
        guard let snapshot else {
            clearNowPlaying()
            return
        }

        nowPlayingTitle = snapshot.title
        nowPlayingArtist = snapshot.artist
        nowPlayingAlbum = snapshot.album
        nowPlayingApp = snapshot.app
        nowPlayingIsPlaying = snapshot.isPlaying
        nowPlayingPosition = snapshot.position
        nowPlayingDuration = snapshot.duration
        nowPlayingUpdatedAt = now

        let artworkIdentity = "\(snapshot.app.rawValue)|\(snapshot.title)|\(snapshot.album)"
        if artworkIdentity != lastArtworkIdentity {
            lastArtworkIdentity = artworkIdentity
            loadArtwork(for: snapshot.app, identity: artworkIdentity)
        }
    }

    private func loadArtwork(for app: MediaPlayerApp, identity: String) {
        nowPlayingArtwork = nil
        switch app {
        case .music:
            nowPlayingArtwork = MediaAppleScript.musicArtwork()
        case .spotify:
            guard let url = MediaAppleScript.spotifyArtworkURL() else { return }
            Task { @MainActor [weak self] in
                let data = try? await URLSession.shared.data(from: url).0
                guard let self, self.lastArtworkIdentity == identity, let data else { return }
                self.nowPlayingArtwork = NSImage(data: data)
            }
        }
    }

    private func clearNowPlaying() {
        nowPlayingTitle = nil
        nowPlayingArtist = ""
        nowPlayingAlbum = ""
        nowPlayingApp = nil
        nowPlayingIsPlaying = false
        nowPlayingPosition = 0
        nowPlayingDuration = 0
        nowPlayingArtwork = nil
        lastArtworkIdentity = nil
    }

    private func scheduleNowPlayingRefresh() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            self?.refreshNowPlaying()
        }
    }

    private func persistTimer() {
        defaults.set(timerEndDate?.timeIntervalSince1970 ?? 0, forKey: Keys.timerEnd)
        defaults.set(timerDuration, forKey: Keys.timerDuration)
    }

    private func persistAlarm() {
        defaults.set(alarmDate?.timeIntervalSince1970 ?? 0, forKey: Keys.alarmDate)
    }

    private func screenConfigurationChanged() {
        updatePanelFrame(animated: false)
        if isEnabled { panel?.orderFrontRegardless() }
    }
}

enum MediaPlayerApp: String, CaseIterable {
    case music = "Music"
    case spotify = "Spotify"

    var bundleIdentifier: String {
        switch self {
        case .music: "com.apple.Music"
        case .spotify: "com.spotify.client"
        }
    }
}

private struct MediaSnapshot {
    let app: MediaPlayerApp
    let title: String
    let artist: String
    let album: String
    let isPlaying: Bool
    let position: TimeInterval
    let duration: TimeInterval
}

private enum MediaControl {
    case previous
    case playPause
    case next
}

@MainActor
private enum MediaAppleScript {
    static func snapshot(for app: MediaPlayerApp) -> MediaSnapshot? {
        let source: String
        switch app {
        case .music:
            source = """
            tell application "Music"
                if player state is stopped then return {}
                set t to current track
                return {name of t as text, artist of t as text, album of t as text, player state as text, player position, duration of t}
            end tell
            """
        case .spotify:
            source = """
            tell application "Spotify"
                if player state is stopped then return {}
                set t to current track
                return {name of t as text, artist of t as text, album of t as text, player state as text, player position, (duration of t) / 1000}
            end tell
            """
        }

        guard let result = execute(source), result.numberOfItems >= 6,
              let title = result.atIndex(1)?.stringValue else { return nil }
        let state = result.atIndex(4)?.stringValue?.lowercased() ?? ""
        return MediaSnapshot(
            app: app,
            title: title,
            artist: result.atIndex(2)?.stringValue ?? "",
            album: result.atIndex(3)?.stringValue ?? "",
            isPlaying: state == "playing",
            position: max(result.atIndex(5)?.doubleValue ?? 0, 0),
            duration: max(result.atIndex(6)?.doubleValue ?? 0, 0)
        )
    }

    static func musicArtwork() -> NSImage? {
        let source = """
        tell application "Music"
            try
                return data of artwork 1 of current track
            on error
                return missing value
            end try
        end tell
        """
        guard let data = execute(source)?.data, !data.isEmpty else { return nil }
        return NSImage(data: data)
    }

    static func spotifyArtworkURL() -> URL? {
        let source = """
        tell application "Spotify"
            try
                return artwork url of current track
            on error
                return ""
            end try
        end tell
        """
        guard let urlString = execute(source)?.stringValue else { return nil }
        return URL(string: urlString)
    }

    static func control(_ control: MediaControl, app: MediaPlayerApp) {
        let command: String
        switch control {
        case .previous: command = "previous track"
        case .playPause: command = "playpause"
        case .next: command = "next track"
        }
        _ = execute("tell application \"\(app.rawValue)\" to \(command)")
    }

    private static func execute(_ source: String) -> NSAppleEventDescriptor? {
        var error: NSDictionary?
        return NSAppleScript(source: source)?.executeAndReturnError(&error)
    }
}

@MainActor
private final class ShelfPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
