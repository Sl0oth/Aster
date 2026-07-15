import Foundation
import UniformTypeIdentifiers

struct WallpaperItem: Identifiable, Codable, Hashable {
    enum Kind: String, Codable {
        case image
        case video

        var label: String { self == .image ? "Still" : "Motion" }
        var symbol: String { self == .image ? "photo" : "play.rectangle.fill" }
    }

    let id: UUID
    var name: String
    var filename: String
    var kind: Kind
    var dateAdded: Date

    var isGIF: Bool { filename.lowercased().hasSuffix(".gif") }
    var mediaLabel: String { isGIF ? "GIF" : kind.label }
    var mediaSymbol: String { isGIF ? "photo.badge.arrow.down" : kind.symbol }
    var canShuffle: Bool { kind == .image || kind == .video }
    var canUseAsLockScreenStill: Bool { kind == .image && !isGIF }

    init(id: UUID = UUID(), name: String, filename: String, kind: Kind, dateAdded: Date = .now) {
        self.id = id
        self.name = name
        self.filename = filename
        self.kind = kind
        self.dateAdded = dateAdded
    }

    static func kind(for url: URL) -> Kind? {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return nil }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .movie) { return .video }
        return nil
    }
}
