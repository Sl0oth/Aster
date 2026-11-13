import AppKit
import Observation

@MainActor
@Observable
final class ClipboardManager {
    private struct StoredState: Codable {
        var history: [ClipboardEntry]
        var boards: [ClipboardBoard]
    }

    struct ExcludedApp: Codable, Hashable, Identifiable {
        let bundleIdentifier: String
        let name: String
        var id: String { bundleIdentifier }
    }

    enum Retention: Int, CaseIterable, Identifiable {
        case forever = 0
        case oneDay = 1
        case oneWeek = 7
        case oneMonth = 30

        var id: Int { rawValue }
        var label: String {
            switch self {
            case .forever: "Forever"
            case .oneDay: "1 day"
            case .oneWeek: "7 days"
            case .oneMonth: "30 days"
            }
        }
    }

    static let historyLimitChoices = [50, 100, 300, 500, 1_000]

    private(set) var entries: [ClipboardEntry] = []
    private(set) var boards: [ClipboardBoard] = []
    var searchText = ""
    /// How many clips to keep, not counting clips saved to a board.
    var historyLimit = 300 {
        didSet {
            guard historyLimit != oldValue else { return }
            UserDefaults.standard.set(historyLimit, forKey: historyLimitKey)
            if pruneHistory() { save() }
        }
    }
    /// Clips older than this are removed unless they are saved to a board.
    var retention: Retention = .forever {
        didSet {
            guard retention != oldValue else { return }
            UserDefaults.standard.set(retention.rawValue, forKey: retentionKey)
            if pruneHistory() { save() }
        }
    }
    /// Apps whose copies are never recorded, in addition to the built-in password managers.
    private(set) var excludedApps: [ExcludedApp] = []
    /// Paste into the frontmost app right after choosing a clip in the Clips panel.
    var pastesAfterCopy = false {
        didSet {
            guard pastesAfterCopy != oldValue else { return }
            UserDefaults.standard.set(pastesAfterCopy, forKey: pastesAfterCopyKey)
        }
    }
    /// The global Clips panel and its shortcut exist only while Clips is on.
    var isPanelAvailable: Bool { isMonitoring }
    var isMonitoring = false {
        didSet {
            guard oldValue != isMonitoring else { return }
            UserDefaults.standard.set(isMonitoring, forKey: monitoringKey)
            // Turning Clips on always starts capturing again.
            if isMonitoring { isCapturePaused = false }
            configureTimer()
        }
    }
    /// A temporary pause from the Clips panel. Clips stays on — the panel and
    /// its shortcut keep working — but nothing new is recorded.
    var isCapturePaused = false {
        didSet {
            guard isCapturePaused != oldValue else { return }
            UserDefaults.standard.set(isCapturePaused, forKey: capturePausedKey)
        }
    }
    var isCapturing: Bool { isMonitoring && !isCapturePaused }

    var filteredEntries: [ClipboardEntry] {
        filteredEntries(in: nil)
    }

    private let pasteboard = NSPasteboard.general
    private let fileManager = FileManager.default
    private let stateURL: URL
    private let legacyDataURL: URL
    private let imagesURL: URL
    private let monitoringKey = "Aster.Clips.isMonitoring"
    private let capturePausedKey = "Aster.Clips.capturePaused"
    private let historyLimitKey = "Aster.Clips.historyLimit"
    private let retentionKey = "Aster.Clips.retentionDays"
    private let excludedAppsKey = "Aster.Clips.excludedApps"
    private let pastesAfterCopyKey = "Aster.Clips.pastesAfterCopy"
    private let maxImageDimension = 2_000
    private var lastChangeCount: Int
    private var timer: Timer?

    private let sensitiveBundleIDs: Set<String> = [
        "com.1password.1password",
        "com.agilebits.onepassword7",
        "com.apple.keychainaccess",
        "com.bitwarden.desktop",
        "com.lastpass.LastPass",
        "com.lastpass.LastPassMacDesktop",
        "com.dashlane.Dashlane"
    ]

    private let privatePasteboardTypes: Set<String> = [
        "org.nspasteboard.ConcealedType",
        "org.nspasteboard.TransientType"
    ]

    init() {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Aster", isDirectory: true)
        let clipsDirectory = support.appendingPathComponent("Clipboard", isDirectory: true)
        imagesURL = clipsDirectory.appendingPathComponent("Images", isDirectory: true)
        stateURL = clipsDirectory.appendingPathComponent("state.json")
        legacyDataURL = support.appendingPathComponent("clipboard.json")
        lastChangeCount = pasteboard.changeCount

        try? fileManager.createDirectory(at: imagesURL, withIntermediateDirectories: true)
        let defaults = UserDefaults.standard
        let storedLimit = defaults.integer(forKey: historyLimitKey)
        if Self.historyLimitChoices.contains(storedLimit) { historyLimit = storedLimit }
        if let storedRetention = defaults.object(forKey: retentionKey) as? Int,
           let retention = Retention(rawValue: storedRetention) {
            self.retention = retention
        }
        if let data = defaults.data(forKey: excludedAppsKey),
           let apps = try? JSONDecoder().decode([ExcludedApp].self, from: data) {
            excludedApps = apps
        }
        pastesAfterCopy = defaults.bool(forKey: pastesAfterCopyKey)
        load()
        if pruneHistory() { save() }
        isMonitoring = UserDefaults.standard.bool(forKey: monitoringKey)
        isCapturePaused = isMonitoring && UserDefaults.standard.bool(forKey: capturePausedKey)
        configureTimer()
    }

    func filteredEntries(in boardID: ClipboardBoard.ID?) -> [ClipboardEntry] {
        let boardItemIDs = boardID.flatMap { id in boards.first(where: { $0.id == id })?.itemIDs }
        return entries.filter { entry in
            let matchesBoard = boardItemIDs?.contains(entry.id) ?? true
            let matchesSearch = searchText.isEmpty ||
                entry.displayText.localizedCaseInsensitiveContains(searchText) ||
                (entry.sourceApp?.localizedCaseInsensitiveContains(searchText) ?? false)
            return matchesBoard && matchesSearch
        }
    }

    func imageURL(for entry: ClipboardEntry) -> URL? {
        guard let imageFilename = entry.imageFilename else { return nil }
        return imagesURL.appendingPathComponent(imageFilename)
    }

    func copy(_ entry: ClipboardEntry) {
        pasteboard.clearContents()
        switch entry.kind {
        case .image:
            guard let url = imageURL(for: entry), let image = NSImage(contentsOf: url) else { return }
            pasteboard.writeObjects([image])
        case .text, .link, .color:
            pasteboard.setString(entry.text, forType: .string)
        }
        lastChangeCount = pasteboard.changeCount
    }

    func remove(_ entry: ClipboardEntry, from boardID: ClipboardBoard.ID? = nil) {
        if let boardID {
            remove(entry, fromBoard: boardID)
            return
        }
        deleteImage(for: entry)
        entries.removeAll { $0.id == entry.id }
        for index in boards.indices {
            boards[index].itemIDs.removeAll { $0 == entry.id }
        }
        save()
    }

    /// Clears the history. Clips saved to a board are kept unless
    /// `includingBoardClips` is true.
    func clearHistory(includingBoardClips: Bool = false) {
        let kept = includingBoardClips ? [] : Set(boards.flatMap(\.itemIDs))
        entries.filter { !kept.contains($0.id) }.forEach(deleteImage)
        entries.removeAll { !kept.contains($0.id) }
        if includingBoardClips {
            for index in boards.indices { boards[index].itemIDs.removeAll() }
        }
        save()
    }

    /// The number of clips `clearHistory()` would keep because they are on a board.
    var boardClipCount: Int {
        let saved = Set(boards.flatMap(\.itemIDs))
        return entries.count { saved.contains($0.id) }
    }

    @discardableResult
    func excludeApplication(at url: URL) -> Bool {
        guard let bundle = Bundle(url: url),
              let bundleIdentifier = bundle.bundleIdentifier,
              !excludedApps.contains(where: { $0.bundleIdentifier == bundleIdentifier }) else {
            return false
        }
        let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? url.deletingPathExtension().lastPathComponent
        excludedApps.append(ExcludedApp(bundleIdentifier: bundleIdentifier, name: name))
        excludedApps.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        saveExcludedApps()
        return true
    }

    func removeExcludedApp(_ app: ExcludedApp) {
        excludedApps.removeAll { $0.id == app.id }
        saveExcludedApps()
    }

    private func saveExcludedApps() {
        guard let data = try? JSONEncoder().encode(excludedApps) else { return }
        UserDefaults.standard.set(data, forKey: excludedAppsKey)
    }

    @discardableResult
    func createBoard(named name: String) -> ClipboardBoard? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let board = ClipboardBoard(name: trimmed)
        boards.append(board)
        save()
        return board
    }

    func renameBoard(_ id: ClipboardBoard.ID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = boards.firstIndex(where: { $0.id == id }) else { return }
        boards[index].name = trimmed
        save()
    }

    func deleteBoard(_ id: ClipboardBoard.ID) {
        boards.removeAll { $0.id == id }
        save()
    }

    func toggle(_ entry: ClipboardEntry, in boardID: ClipboardBoard.ID) {
        guard let index = boards.firstIndex(where: { $0.id == boardID }) else { return }
        if boards[index].itemIDs.contains(entry.id) {
            boards[index].itemIDs.removeAll { $0 == entry.id }
        } else {
            boards[index].itemIDs.append(entry.id)
        }
        save()
    }

    @discardableResult
    func add(_ entry: ClipboardEntry, toBoard boardID: ClipboardBoard.ID) -> Bool {
        guard let index = boards.firstIndex(where: { $0.id == boardID }),
              !boards[index].itemIDs.contains(entry.id) else { return false }
        boards[index].itemIDs.append(entry.id)
        save()
        return true
    }

    func contains(_ entry: ClipboardEntry, in boardID: ClipboardBoard.ID) -> Bool {
        boards.first(where: { $0.id == boardID })?.itemIDs.contains(entry.id) ?? false
    }

    func remove(_ entry: ClipboardEntry, fromBoard boardID: ClipboardBoard.ID) {
        guard let index = boards.firstIndex(where: { $0.id == boardID }) else { return }
        boards[index].itemIDs.removeAll { $0 == entry.id }
        save()
    }

    private func configureTimer() {
        timer?.invalidate()
        timer = nil
        guard isMonitoring else { return }

        let timer = Timer(timeInterval: 0.7, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.captureIfChanged() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func captureIfChanged() {
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount
        // Keep following the pasteboard while paused, so nothing copied during
        // the pause is recorded when capture resumes.
        guard !isCapturePaused else { return }

        let frontmostApp = NSWorkspace.shared.frontmostApplication
        if let bundleID = frontmostApp?.bundleIdentifier,
           sensitiveBundleIDs.contains(bundleID)
            || excludedApps.contains(where: { $0.bundleIdentifier == bundleID }) {
            return
        }

        // Password managers and other apps mark secrets and throwaway copies with
        // these nspasteboard.org types; never keep them in history.
        let pasteboardTypes = Set((pasteboard.types ?? []).map(\.rawValue))
        if !pasteboardTypes.isDisjoint(with: privatePasteboardTypes) {
            return
        }

        if pasteboard.availableType(from: [.png, .tiff]) != nil,
           let image = NSImage(pasteboard: pasteboard),
           capture(image: image, sourceApp: frontmostApp?.localizedName) {
            return
        }

        guard let text = pasteboard.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty,
              text.utf8.count <= 100_000,
              !(entries.first?.kind != .image && entries.first?.text == text) else { return }

        entries.insert(ClipboardEntry(text: text, sourceApp: frontmostApp?.localizedName), at: 0)
        pruneHistory()
        save()
    }

    private func capture(image: NSImage, sourceApp: String?) -> Bool {
        guard let rendered = renderPNG(image, maxDimension: maxImageDimension) else { return false }
        let id = UUID()
        let filename = "\(id.uuidString).png"
        let destination = imagesURL.appendingPathComponent(filename)
        do {
            try rendered.data.write(to: destination, options: .atomic)
            entries.insert(
                .image(
                    id: id,
                    filename: filename,
                    width: rendered.width,
                    height: rendered.height,
                    sourceApp: sourceApp
                ),
                at: 0
            )
            pruneHistory()
            save()
            return true
        } catch {
            return false
        }
    }

    private func renderPNG(_ image: NSImage, maxDimension: Int) -> (data: Data, width: Int, height: Int)? {
        guard let tiff = image.tiffRepresentation,
              let source = NSBitmapImageRep(data: tiff) else { return nil }
        let originalWidth = source.pixelsWide
        let originalHeight = source.pixelsHigh
        guard originalWidth > 0, originalHeight > 0 else { return nil }

        let scale = min(1, Double(maxDimension) / Double(max(originalWidth, originalHeight)))
        let width = max(Int((Double(originalWidth) * scale).rounded()), 1)
        let height = max(Int((Double(originalHeight) * scale).rounded()), 1)
        guard let output = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: output)
        image.draw(
            in: NSRect(x: 0, y: 0, width: width, height: height),
            from: .zero,
            operation: .copy,
            fraction: 1
        )
        NSGraphicsContext.restoreGraphicsState()
        guard let data = output.representation(using: .png, properties: [:]) else { return nil }
        return (data, width, height)
    }

    /// Applies the history limit and retention period. Clips saved to a board
    /// are always kept. Returns whether anything was removed.
    @discardableResult
    private func pruneHistory() -> Bool {
        let referenced = Set(boards.flatMap(\.itemIDs))
        let cutoff = retention == .forever
            ? nil
            : Date().addingTimeInterval(-TimeInterval(retention.rawValue) * 86_400)
        var kept: [ClipboardEntry] = []
        var unreferencedCount = 0
        for entry in entries {
            if referenced.contains(entry.id) {
                kept.append(entry)
            } else if unreferencedCount < historyLimit,
                      cutoff.map({ entry.createdAt >= $0 }) ?? true {
                kept.append(entry)
                unreferencedCount += 1
            } else {
                deleteImage(for: entry)
            }
        }
        guard kept.count != entries.count else { return false }
        entries = kept
        return true
    }

    private func deleteImage(for entry: ClipboardEntry) {
        guard let url = imageURL(for: entry) else { return }
        try? fileManager.removeItem(at: url)
    }

    private func load() {
        if let data = try? Data(contentsOf: stateURL),
           let decoded = try? JSONDecoder().decode(StoredState.self, from: data) {
            entries = decoded.history
            boards = decoded.boards
        } else if let data = try? Data(contentsOf: legacyDataURL),
                  let legacyEntries = try? JSONDecoder().decode([ClipboardEntry].self, from: data) {
            entries = legacyEntries
            boards = []
            save()
        }

        entries.removeAll { entry in
            entry.kind == .image && imageURL(for: entry).map { !fileManager.fileExists(atPath: $0.path) } == true
        }
        let validIDs = Set(entries.map(\.id))
        for index in boards.indices {
            boards[index].itemIDs.removeAll { !validIDs.contains($0) }
        }
    }

    private func save() {
        let state = StoredState(history: entries, boards: boards)
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: stateURL, options: .atomic)
    }
}
