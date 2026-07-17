import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class WallpaperLibrary {
    enum MediaFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case still = "Still"
        case motion = "Motion"
        var id: String { rawValue }
    }

    enum SortOrder: String, CaseIterable, Identifiable {
        case newest = "Newest"
        case oldest = "Oldest"
        case name = "Name"
        var id: String { rawValue }
    }

    private(set) var items: [WallpaperItem] = []
    var selectedID: WallpaperItem.ID? {
        didSet {
            if let selectedID {
                UserDefaults.standard.set(selectedID.uuidString, forKey: selectionKey)
            } else {
                UserDefaults.standard.removeObject(forKey: selectionKey)
            }
        }
    }
    var searchText = ""
    var mediaFilter: MediaFilter = .all
    var sortOrder: SortOrder = .newest

    private let fileManager = FileManager.default
    private let metadataURL: URL
    private let selectionKey = "Aster.Canvas.selectedWallpaper"
    let libraryURL: URL

    var filteredItems: [WallpaperItem] {
        var result = items.filter { item in
            let matchesSearch = searchText.isEmpty || item.name.localizedCaseInsensitiveContains(searchText)
            let matchesType = switch mediaFilter {
            case .all: true
            case .still: item.kind == .image && !item.isGIF
            case .motion: item.kind == .video || item.isGIF
            }
            return matchesSearch && matchesType
        }
        switch sortOrder {
        case .newest: result.sort { $0.dateAdded > $1.dateAdded }
        case .oldest: result.sort { $0.dateAdded < $1.dateAdded }
        case .name: result.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        return result
    }

    var selectedItem: WallpaperItem? {
        items.first { $0.id == selectedID }
    }

    init() {
        let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let support = applicationSupport.appendingPathComponent("Aster", isDirectory: true)
        let legacySupport = applicationSupport.appendingPathComponent("LumaWall", isDirectory: true)

        // Preserve wallpapers imported before the app became Aster.
        if !fileManager.fileExists(atPath: support.path),
           fileManager.fileExists(atPath: legacySupport.path) {
            try? fileManager.moveItem(at: legacySupport, to: support)
        }
        libraryURL = support.appendingPathComponent("Library", isDirectory: true)
        metadataURL = support.appendingPathComponent("wallpapers.json")
        try? fileManager.createDirectory(at: libraryURL, withIntermediateDirectories: true)
        load()
    }

    func url(for item: WallpaperItem) -> URL {
        libraryURL.appendingPathComponent(item.filename)
    }

    @discardableResult
    func importFiles(_ urls: [URL]) throws -> [WallpaperItem] {
        var imported: [WallpaperItem] = []
        for sourceURL in urls {
            guard let kind = WallpaperItem.kind(for: sourceURL) else { continue }
            let accessed = sourceURL.startAccessingSecurityScopedResource()
            defer { if accessed { sourceURL.stopAccessingSecurityScopedResource() } }

            let filename = "\(UUID().uuidString).\(sourceURL.pathExtension.lowercased())"
            let destination = libraryURL.appendingPathComponent(filename)
            try fileManager.copyItem(at: sourceURL, to: destination)
            let item = WallpaperItem(
                name: sourceURL.deletingPathExtension().lastPathComponent,
                filename: filename,
                kind: kind
            )
            items.insert(item, at: 0)
            imported.append(item)
        }
        if let first = imported.first { selectedID = first.id }
        save()
        return imported
    }

    func remove(_ item: WallpaperItem) {
        try? fileManager.removeItem(at: url(for: item))
        items.removeAll { $0.id == item.id }
        if selectedID == item.id { selectedID = items.first?.id }
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: metadataURL),
              let decoded = try? JSONDecoder().decode([WallpaperItem].self, from: data) else { return }
        items = decoded.filter { fileManager.fileExists(atPath: url(for: $0).path) }
        if let stored = UserDefaults.standard.string(forKey: selectionKey),
           let storedID = UUID(uuidString: stored),
           items.contains(where: { $0.id == storedID }) {
            selectedID = storedID
        } else {
            selectedID = items.first?.id
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: metadataURL, options: .atomic)
        try? ScreenSaverInstaller.synchronizeCanvasPlaylistIfInstalled()
    }
}
