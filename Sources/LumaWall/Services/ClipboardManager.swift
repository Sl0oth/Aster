import AppKit
import Observation

@MainActor
@Observable
final class ClipboardManager {
    private struct StoredState: Codable {
        var history: [ClipboardEntry]
        var boards: [ClipboardBoard]
    }

    private(set) var entries: [ClipboardEntry] = []
    private(set) var boards: [ClipboardBoard] = []
    var searchText = ""
    var isMonitoring = false {
        didSet {
            guard oldValue != isMonitoring else { return }
            UserDefaults.standard.set(isMonitoring, forKey: monitoringKey)
            configureTimer()
        }
    }

    var filteredEntries: [ClipboardEntry] {
        filteredEntries(in: nil)
    }

    private let pasteboard = NSPasteboard.general
    private let fileManager = FileManager.default
    private let stateURL: URL
    private let legacyDataURL: URL
    private let imagesURL: URL
    private let monitoringKey = "Aster.Clips.isMonitoring"
    private let maxHistory = 300
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

    init() {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Aster", isDirectory: true)
        let clipsDirectory = support.appendingPathComponent("Clipboard", isDirectory: true)
        imagesURL = clipsDirectory.appendingPathComponent("Images", isDirectory: true)
        stateURL = clipsDirectory.appendingPathComponent("state.json")
        legacyDataURL = support.appendingPathComponent("clipboard.json")
        lastChangeCount = pasteboard.changeCount

        try? fileManager.createDirectory(at: imagesURL, withIntermediateDirectories: true)
        load()
        isMonitoring = UserDefaults.standard.bool(forKey: monitoringKey)
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

    func clearHistory() {
        entries.forEach(deleteImage)
        entries.removeAll()
        for index in boards.indices { boards[index].itemIDs.removeAll() }
        save()
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

        let frontmostApp = NSWorkspace.shared.frontmostApplication
        if let bundleID = frontmostApp?.bundleIdentifier,
           sensitiveBundleIDs.contains(bundleID) {
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

    private func pruneHistory() {
        guard entries.count > maxHistory else { return }
        let referenced = Set(boards.flatMap(\.itemIDs))
        var kept: [ClipboardEntry] = []
        var unreferencedCount = 0
        for entry in entries {
            if referenced.contains(entry.id) || unreferencedCount < maxHistory {
                kept.append(entry)
                if !referenced.contains(entry.id) { unreferencedCount += 1 }
            } else {
                deleteImage(for: entry)
            }
        }
        entries = kept
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
